import AVFoundation
import Combine
import Foundation
import Speech

/// Central coordinator owning all audio services and driving the monitoring state machine.
@MainActor
final class MonitorViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case wakeDetected        // brief visual flash ~0.3s
        case capturing
        case analyzing
        case recording           // manual hold-to-record
        case error(String)
    }

    @Published var state: State = .idle
    @Published var lastTriggerKind: String = ""   // "name" | "cry" | "manual"
    @Published var replyText: String? = nil        // for support mode response

    // Rolling 10-min transcript buffer for Gemini context
    private var transcriptRingBuffer: [(timestamp: Date, text: String)] = []
    private var currentTranscript: String = ""

    // Dependencies
    private let profile: BabyProfile
    private let eventStore: EventStore
    private let speakerStore: SpeakerStore
    private let analysisService: AnalysisService

    private let audioCapture = AudioCaptureService()
    private let wakeWord = WakeWordService()
    private let cryDetector = CryDetector()

    init(profile: BabyProfile, eventStore: EventStore, speakerStore: SpeakerStore) {
        self.profile = profile
        self.eventStore = eventStore
        self.speakerStore = speakerStore
        self.analysisService = AnalysisService(backendURL: profile.backendURL)
        wireServices()
    }

    // MARK: - Start / Stop

    func startMonitoring() async {
        guard state == .idle || state == .error("") else { return }

        // Request permissions
        let micStatus = await AVAudioSession.sharedInstance().requestRecordPermission()
        guard micStatus else {
            state = .error("Microphone permission denied")
            return
        }

        let speechStatus = await WakeWordService.requestAuthorization()
        guard speechStatus == .authorized else {
            state = .error("Speech recognition permission denied")
            return
        }

        do {
            // Wire audio capture → trigger detection
            audioCapture.wakeWordService = wakeWord
            audioCapture.cryDetector = cryDetector

            // Start cry detector on the input format
            let inputFormat = AVAudioEngine().inputNode.outputFormat(forBus: 0)
            try cryDetector.start(format: inputFormat)

            // Start wake word detection
            try wakeWord.start(babyName: profile.babyName)

            // Start audio engine
            try audioCapture.startListening()

            state = .listening
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func stopMonitoring() {
        wakeWord.stop()
        cryDetector.stop()
        audioCapture.stopListening()
        state = .idle
    }

    // MARK: - Manual recording

    private var manualAudioData: Data?
    private var manualRecordStart: Date = .distantPast
    private var manualRecordBuffer: [Int16] = []

    func startManualRecording() {
        guard state == .listening else { return }
        manualRecordBuffer = []
        manualRecordStart = Date()
        lastTriggerKind = "manual"
        state = .recording
        // Set a callback on audioCapture to accumulate samples
        audioCapture.onClipReady = { [weak self] data, time, transcript in
            Task { @MainActor in
                self?.handleManualClip(wavData: data, transcript: transcript)
            }
        }
        // Trigger immediately to start accumulating
        audioCapture.triggerCapture(at: Date(), transcriptSoFar: "")
    }

    func stopManualRecording(mode: String) {
        // The flush will be called when the capture window ends OR we force it
        // For manual recording, the view calls this to finish
        state = .analyzing
    }

    func sendManualNote(audioData: Data, mode: String) async {
        state = .analyzing
        let dateStr = todayStr()
        do {
            let response = try await analysisService.sendVoiceNote(
                audioData: audioData,
                mode: mode,
                babyName: profile.babyName,
                ageMonths: profile.babyAgeMonths,
                dateStr: dateStr
            )
            if mode == "edit" {
                let analyzeResp = AnalyzeResponse(
                    newEvents: response.newEvents ?? [],
                    corrections: response.corrections ?? [],
                    correctionsApplied: nil,
                    usage: nil
                )
                eventStore.apply(response: analyzeResp, dateStr: dateStr)
            } else {
                replyText = response.reply
            }
        } catch {
            print("[MonitorVM] voice note failed: \(error)")
        }
        state = .listening
    }

    // MARK: - Clip handling

    private func handleClip(wavData: Data, triggerTime: Date, rawTranscript: String) async {
        guard state == .capturing || state == .wakeDetected else { return }
        state = .analyzing

        // 1. Noise suppression
        // (RNNoise passthrough if library not linked)
        let dateStr = todayStr()

        // 2. Diarize
        let diarResult: AnalysisService.DiarizeResponse
        do {
            diarResult = try await analysisService.diarize(audioData: wavData, rawTranscript: rawTranscript)
        } catch {
            print("[MonitorVM] diarize failed: \(error)")
            state = .listening
            return
        }

        let annotatedTranscript = diarResult.annotatedTranscript

        // Prompt user to name unknown speakers
        if !diarResult.unknownSpeakers.isEmpty {
            // We'll prompt in the UI via speakerStore
            // For now, skip blocking the pipeline
        }

        // 3. Relevance check
        do {
            let relevance = try await analysisService.checkRelevance(
                transcript: annotatedTranscript,
                babyName: profile.babyName,
                ageMonths: profile.babyAgeMonths
            )
            guard relevance.relevant else {
                print("[MonitorVM] clip not relevant: \(relevance.reason ?? "")")
                state = .listening
                return
            }
        } catch {
            print("[MonitorVM] relevance check failed: \(error), proceeding anyway")
        }

        // 4. Full analysis
        let transcriptContext = last10MinTranscript()
        do {
            let response = try await analysisService.analyze(
                transcript: annotatedTranscript,
                transcriptLast10min: transcriptContext,
                triggerHint: lastTriggerKind,
                babyName: profile.babyName,
                ageMonths: profile.babyAgeMonths,
                clipTimestamp: triggerTime,
                dateStr: dateStr
            )
            eventStore.apply(response: response, dateStr: dateStr)
        } catch {
            print("[MonitorVM] analysis failed: \(error)")
        }

        // Update rolling transcript buffer
        appendToTranscriptBuffer(text: annotatedTranscript)

        state = .listening
    }

    private func handleManualClip(wavData: Data, transcript: String) {
        // For manual clips, just store — the view will call sendManualNote
        manualAudioData = wavData
    }

    // MARK: - Wiring

    private func wireServices() {
        audioCapture.onClipReady = { [weak self] data, time, transcript in
            Task { @MainActor in
                await self?.handleClip(wavData: data, triggerTime: time, rawTranscript: transcript)
            }
        }

        wakeWord.onWakeWordDetected = { [weak self] transcript in
            guard let self else { return }
            self.lastTriggerKind = "name"
            self.currentTranscript = transcript
            self.flashWakeDetected()
            self.audioCapture.triggerCapture(at: Date(), transcriptSoFar: transcript)
        }

        cryDetector.onCryDetected = { [weak self] in
            guard let self else { return }
            self.lastTriggerKind = "cry"
            self.flashWakeDetected()
            self.audioCapture.triggerCapture(at: Date(), transcriptSoFar: "(crying detected)")
        }

        NotificationCenter.default.addObserver(
            forName: .audioSessionResumed, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.state != .idle else { return }
            Task { await self.startMonitoring() }
        }
    }

    private func flashWakeDetected() {
        state = .wakeDetected
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.state == .wakeDetected {
                self?.state = .capturing
            }
        }
    }

    // MARK: - Transcript buffer (rolling 10 min)

    private func appendToTranscriptBuffer(text: String) {
        let now = Date()
        transcriptRingBuffer.append((timestamp: now, text: text))
        // Trim entries older than 10 minutes
        let cutoff = now.addingTimeInterval(-600)
        transcriptRingBuffer.removeAll { $0.timestamp < cutoff }
    }

    private func last10MinTranscript() -> String {
        transcriptRingBuffer.map { $0.text }.joined(separator: "\n")
    }

    private func todayStr() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }
}

// Allow requestRecordPermission as async
private extension AVAudioSession {
    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
