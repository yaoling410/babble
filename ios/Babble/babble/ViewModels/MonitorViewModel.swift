import AVFoundation
import Combine
import Foundation
import os
import Speech

// ============================================================
//  MonitorViewModel.swift — Shared state & routing
// ============================================================
//
//  TWO PIPELINES (selected at compile time)
//  ─────────────────────────────────────────
//
//  ┌───────────────────────────────────┬──────────────────────────────────────┐
//  │ BACKEND (default build)           │ ON-DEVICE (BABBLE_ON_DEVICE build)   │
//  │ See: MonitorViewModel+Backend     │ See: MonitorViewModel+OnDevice       │
//  │                                   │                                      │
//  │ Clip-based, event-driven.         │ Continuous, streaming.               │
//  │ Wake word → clip → server.        │ WhisperKit → relevance → events.     │
//  │ States: idle/listening/           │ States: idle/listening/              │
//  │   wakeDetected/capturing/         │   analyzing/error                    │
//  │   analyzing/recording/error       │ No clips, no wake word.              │
//  └───────────────────────────────────┴──────────────────────────────────────┘
//
//  This file contains only shared infrastructure:
//    - State enum (superset of both pipelines)
//    - Published properties for the UI
//    - Dependencies (profile, eventStore, speakerStore, audioCapture, etc.)
//    - init() routing to the correct pipeline setup
//    - start/stop routing
//    - Shared helpers (permissions, date formatting, transcript buffer)

/// Central coordinator — delegates to either OnDevicePipeline or the backend clip pipeline.
@MainActor
final class MonitorViewModel: ObservableObject {

    // ── State (superset of both pipelines) ──────────────────────

    enum State: Equatable {
        case idle            // not started or explicitly stopped
        case listening       // backend: waiting for trigger; on-device: WhisperKit streaming
        case wakeDetected    // backend only — trigger fired, ~0.3s UI flash
        case capturing       // backend only — recording a clip
        case analyzing       // backend: Gemini; on-device: Foundation Models 3B
        case recording       // backend only — manual hold-to-record
        case error(String)   // permission denied or engine failure
    }

    @Published var state: State = .idle
    @Published var lastTriggerKind: String = ""
    @Published var replyText: String? = nil
    @Published var emotionalSupportDetected: Bool = false

    // ── Dependencies (shared by both pipelines) ─────────────────

    let profile: BabyProfile
    let eventStore: EventStore
    let speakerStore: SpeakerStore
    let analysisService: AnalysisService

    let audioCapture = AudioCaptureService()
    let wakeWord = WakeWordService()
    let cryDetector = CryDetector()
    let vault = AudioVaultService()
    var cancellables = Set<AnyCancellable>()

    // ── Backend path state ──────────────────────────────────────

    var transcriptRingBuffer: [(timestamp: Date, text: String)] = []
    var currentTranscript: String = ""
    var activePeriodEnd: Date = .distantPast
    var isInActivePeriod: Bool { Date() < activePeriodEnd }
    var manualAudioData: Data?

    // ── On-device pipeline ──────────────────────────────────────

    #if BABBLE_ON_DEVICE
    @available(iOS 26.0, *)
    var onDevicePipeline: OnDevicePipeline?
    #endif

    // ── On-device analysis fallback (backend build, iOS 26+) ────

    #if canImport(FoundationModels)
    var onDeviceService: Any?

    @available(iOS 26.0, *)
    var onDevice: OnDeviceAnalysisService {
        if let existing = onDeviceService as? OnDeviceAnalysisService { return existing }
        let service = OnDeviceAnalysisService()
        onDeviceService = service
        return service
    }

    var shouldUseOnDevice: Bool {
        guard profile.useOnDeviceAnalysis else { return false }
        if #available(iOS 26.0, *) { return OnDeviceAnalysisService.isAvailable }
        return false
    }
    #endif

    // ── Init ────────────────────────────────────────────────────

    init(profile: BabyProfile, eventStore: EventStore, speakerStore: SpeakerStore) {
        self.profile = profile
        self.eventStore = eventStore
        self.speakerStore = speakerStore
        self.analysisService = AnalysisService(backendURL: profile.backendURL)

        // Vault — hourly batch re-analysis (backend path)
        vault.backendURL = profile.backendURL
        vault.babyName = profile.babyName
        vault.babyAgeMonths = profile.babyAgeMonths
        vault.onEmotionalSupportDetected = { [weak self] in
            self?.emotionalSupportDetected = true
        }
        vault.scheduleBatchTimer()

        // Wire backend callbacks
        wireServices()

        // Sync backend URL changes
        profile.$backendURL
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                self?.analysisService.backendURL = url
                self?.vault.backendURL = url
            }
            .store(in: &cancellables)

        // Rebuild wake word aliases when speakers change
        speakerStore.$speakers
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildNameAliases() }
            .store(in: &cancellables)

        // On-device pipeline setup (no-op in default build)
        #if BABBLE_ON_DEVICE
        setupOnDevicePipeline()
        #endif

        registerAudioSessionObservers()
    }

    // MARK: - Start / Stop (routing)

    func startMonitoring() async {
        BabbleLog.app.info("\(BabbleLog.ts) startMonitoring() called, state=\(String(describing: self.state), privacy: .public)")

        #if BABBLE_ON_DEVICE
        await startOnDeviceMonitoring()
        #else
        await startBackendMonitoring()
        #endif
    }

    func stopMonitoring() {
        #if BABBLE_ON_DEVICE
        stopOnDeviceMonitoring()
        #else
        stopBackendMonitoring()
        #endif
    }

    // MARK: - Audio session interruption (shared)

    private func registerAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            forName: .audioSessionInterrupted, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.state != .idle else { return }
            BabbleLog.app.info("\(BabbleLog.ts) ⚠️ Audio session interrupted — stopping")
            self.stopMonitoring()
        }

        NotificationCenter.default.addObserver(
            forName: .audioSessionResumed, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            BabbleLog.app.info("\(BabbleLog.ts) 🔁 Audio session resumed — restarting in 0.5s")
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self.startMonitoring()
            }
        }
    }

    // MARK: - Shared helpers

    func requestPermissions() async -> Bool {
        let micStatus = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        guard micStatus else {
            state = .error("Microphone permission denied")
            return false
        }
        let speechStatus = await WakeWordService.requestAuthorization()
        guard speechStatus == .authorized else {
            state = .error("Speech recognition permission denied")
            return false
        }
        return true
    }

    func getCrySeed() -> String {
        var seed = "(crying detected)"
        #if BABBLE_ON_DEVICE
        if #available(iOS 26.0, *), let pipeline = onDevicePipeline {
            let t = pipeline.lastTranscription
            if !t.isEmpty { return t }
        }
        #endif
        let preCryTranscript = wakeWord.currentBestTranscript
        if !preCryTranscript.isEmpty { seed = preCryTranscript }
        return seed
    }

    func appendToTranscriptBuffer(text: String) {
        let now = Date()
        transcriptRingBuffer.append((timestamp: now, text: text))
        let cutoff = now.addingTimeInterval(-600)
        transcriptRingBuffer.removeAll { $0.timestamp < cutoff }
    }

    func last10MinTranscript() -> String {
        transcriptRingBuffer.map { $0.text }.joined(separator: "\n")
    }

    func rebuildNameAliases() {
        let speakerVariants = speakerStore.allNameVariants
        guard !speakerVariants.isEmpty else { return }
        let combined = Array(Set(profile.nameAliases + speakerVariants))
        wakeWord.nameAliases = combined
    }

    static let _dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    func todayStr() -> String { Self._dateFmt.string(from: Date()) }
}

// MARK: - Debug Token Tracker (backend path)

@MainActor
enum DebugTokenTracker {
    static let inputPricePer1M: Double  = 0.10
    static let outputPricePer1M: Double = 0.40

    private static let inputKey  = "debug.daily.inputTokens"
    private static let outputKey = "debug.daily.outputTokens"
    private static let dateKey   = "debug.daily.date"

    static func cost(input: Int, output: Int) -> Double {
        Double(input) / 1_000_000 * inputPricePer1M +
        Double(output) / 1_000_000 * outputPricePer1M
    }

    static func addAndGet(input: Int, output: Int) -> (input: Int, output: Int) {
        resetIfNewDay()
        let ud = UserDefaults.standard
        let newInput  = ud.integer(forKey: inputKey)  + input
        let newOutput = ud.integer(forKey: outputKey) + output
        ud.set(newInput,  forKey: inputKey)
        ud.set(newOutput, forKey: outputKey)
        return (newInput, newOutput)
    }

    private static func resetIfNewDay() {
        let today = MonitorViewModel._dateFmt.string(from: Date())
        let ud = UserDefaults.standard
        if ud.string(forKey: dateKey) != today {
            ud.set(0, forKey: inputKey)
            ud.set(0, forKey: outputKey)
            ud.set(today, forKey: dateKey)
        }
    }
}
