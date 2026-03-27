import Foundation
import Combine
import AVFoundation

// ============================================================
//  OnDevicePipeline.swift — Central coordinator for on-device build
// ============================================================

#if BABBLE_ON_DEVICE
@available(iOS 26.0, *)
@MainActor
final class OnDevicePipeline: ObservableObject {

    enum State: Equatable {
        case idle
        case listening
        case processing
        case error(String)
    }

    @Published var state: State = .idle
    @Published var lastTranscription: String = ""

    // ── Dependencies (injected by MonitorViewModel) ──────────────

    var profile: BabyProfile?
    var eventStore: EventStore?
    var speakerStore: SpeakerStore?
    var audioCapture: AudioCaptureService?
    var cryDetector: CryDetector?

    // ── On-device services ──────────────────────────────────────

    private let whisper = WhisperKitService()
    private var autoCompleteTimer: Timer?

    /// Counter for audio buffers received — logged periodically to confirm audio is flowing.
    private var bufferCount: Int = 0

    init() {
        NSLog("[OnDevice] 🏗️ Pipeline created")
        whisper.onTranscription = { [weak self] window in
            Task { @MainActor in
                await self?.handleWindow(window)
            }
        }
    }

    // MARK: - Start

    func start() async {
        NSLog("[OnDevice] ▶️ start() called — state=\(String(describing: state))")

        guard state == .idle || {
            if case .error = state { return true }
            return false
        }() else {
            NSLog("[OnDevice] ⚠️ start() skipped — already in state \(String(describing: state))")
            return
        }

        // Step 1: Permissions
        NSLog("[OnDevice] 📋 Step 1/4: Requesting microphone permission...")
        let micGranted = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        guard micGranted else {
            NSLog("[OnDevice] ❌ Microphone permission DENIED")
            state = .error("Microphone permission denied")
            return
        }
        NSLog("[OnDevice] ✅ Microphone permission granted")

        // Step 2: Load WhisperKit model
        NSLog("[OnDevice] 📋 Step 2/4: Loading WhisperKit model (first launch downloads ~75 MB)...")
        do {
            try await whisper.loadModel()
            NSLog("[OnDevice] ✅ WhisperKit model loaded — isModelReady=\(whisper.isModelReady)")
        } catch {
            NSLog("[OnDevice] ❌ WhisperKit model FAILED: \(error.localizedDescription)")
            state = .error("WhisperKit model not ready: \(error.localizedDescription)")
            return
        }

        // Step 3: Validate dependencies
        NSLog("[OnDevice] 📋 Step 3/4: Checking dependencies...")
        guard let audioCapture else {
            NSLog("[OnDevice] ❌ AudioCaptureService is nil — not injected")
            state = .error("AudioCaptureService not configured")
            return
        }
        guard let profile else {
            NSLog("[OnDevice] ❌ BabyProfile is nil — not injected")
            state = .error("BabyProfile not configured")
            return
        }
        NSLog("[OnDevice] ✅ Dependencies OK — baby='\(profile.babyName)' age=\(profile.babyAgeMonths)mo speakers=\(speakerStore?.speakers.count ?? 0)")

        // Wire audio buffer → WhisperKit
        bufferCount = 0
        audioCapture.onRawBuffer = { [weak self] samples, timestamp in
            guard let self else { return }
            self.bufferCount += 1
            // Log every 100th buffer (~8.5s at 85ms/buffer) to confirm audio is flowing
            if self.bufferCount % 100 == 1 {
                NSLog("[OnDevice] 🎤 Audio buffer #\(self.bufferCount) — \(samples.count) samples")
            }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { return }
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
            if let floatData = pcmBuffer.floatChannelData?[0] {
                for i in 0 ..< samples.count {
                    floatData[i] = Float(samples[i]) / 32767.0
                }
            }
            self.whisper.feedAudio(pcmBuffer)
        }

        // CryDetector fires independently
        cryDetector?.onCryDetected = { [weak self] in
            guard let self else { return }
            NSLog("[OnDevice] 😢 Cry detected — creating event")
            let event = BabyEvent(
                id: UUID().uuidString,
                type: .cry,
                timestamp: Date(),
                timestampConfidence: .exact,
                createdAt: Date(),
                detail: "Crying detected",
                notable: false,
                confidence: 0.85,
                status: .completed
            )
            let response = AnalyzeResponse(newEvents: [event], corrections: [])
            self.eventStore?.apply(response: response, dateStr: Self.todayStr())
        }

        // Step 4: Start audio engine
        NSLog("[OnDevice] 📋 Step 4/4: Starting audio engine...")
        do {
            try audioCapture.startListening()
            state = .listening
            startAutoCompleteTimer()
            NSLog("[OnDevice] ✅ Pipeline started — listening for speech")
            NSLog("[OnDevice] 📊 Config: VAD threshold=\(whisper.speechThresholdForLogging) silenceFlush=4s maxWindow=90s minWindow=0.5s")
        } catch {
            NSLog("[OnDevice] ❌ Audio engine FAILED: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Stop

    func stop() {
        NSLog("[OnDevice] ⏹️ stop() called — buffers processed: \(bufferCount)")
        audioCapture?.stopListening()
        autoCompleteTimer?.invalidate()
        autoCompleteTimer = nil
        whisper.reset()
        RelevanceGate.reset()
        state = .idle
    }

    // MARK: - Window handling

    private func handleWindow(_ window: WhisperKitService.TranscriptionWindow) async {
        let duration = window.endTime.timeIntervalSince(window.startTime)
        NSLog("[OnDevice] 📝 Window received — \(String(format: "%.1f", duration))s, \(window.audioSamples.count) samples, text='\(window.text.prefix(100))'")

        guard state == .listening else {
            NSLog("[OnDevice] ⚠️ Window dropped — state=\(String(describing: state)) (expected .listening)")
            return
        }
        guard let profile, let eventStore else {
            NSLog("[OnDevice] ⚠️ Window dropped — profile or eventStore is nil")
            return
        }

        lastTranscription = window.text

        // Gate 1: Is the text empty?
        guard !window.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSLog("[OnDevice] 🚫 Gate 1 BLOCKED — empty transcription (noise/music)")
            return
        }

        // Gate 2: Relevance (two-tier)
        let gateResult = RelevanceGate.isRelevant(text: window.text, babyName: profile.babyName)
        guard gateResult.isRelevant else {
            NSLog("[OnDevice] 🚫 Gate 2 BLOCKED — not baby-related: '\(window.text.prefix(80))' (activePeriod=\(RelevanceGate.isActivePeriod))")
            return
        }
        // Only Level 1 matches extend the active period
        if case .passed(.level1) = gateResult {
            RelevanceGate.markPassed()
        }
        let level: String = { if case .passed(let l) = gateResult { return l.rawValue } else { return "?" } }()
        NSLog("[OnDevice] ✅ Gate 2 PASSED [\(level)] — proceeding to diarize+analyze (activePeriod=\(RelevanceGate.isActivePeriod))")

        state = .processing

        // Step 3: Diarize
        let annotatedTranscript: String
        if let speakerStore, !speakerStore.speakers.isEmpty {
            NSLog("[OnDevice] 🎙️ Step 3: Diarizing with \(speakerStore.speakers.count) enrolled speakers...")
            do {
                let result = try await OnDeviceDiarizationService.diarize(
                    window: window,
                    speakerStore: speakerStore
                )
                annotatedTranscript = result.annotatedTranscript
                NSLog("[OnDevice] ✅ Diarized — \(result.segments.count) segments, \(result.unknownSpeakers.count) unknown")
                for seg in result.segments {
                    NSLog("[OnDevice]   [\(seg.speaker)] \(String(format: "%.1f", seg.start))–\(String(format: "%.1f", seg.end))s: \(seg.text.prefix(50))")
                }
            } catch {
                NSLog("[OnDevice] ⚠️ Diarization failed: \(error) — using raw transcript")
                annotatedTranscript = window.text
            }
        } else {
            NSLog("[OnDevice] ⚡ Step 3: No speakers enrolled — skipping diarization")
            annotatedTranscript = window.text
        }

        // Step 4: Foundation Models 3B
        let dateStr = Self.todayStr()
        NSLog("[OnDevice] 🧠 Step 4: Foundation Models 3B analysis — '\(annotatedTranscript.prefix(80))'")

        do {
            let service = OnDeviceAnalysisService()
            let response = try await service.analyze(
                transcript: annotatedTranscript,
                babyName: profile.babyName,
                ageMonths: profile.babyAgeMonths,
                triggerHint: "continuous",
                clipTimestamp: window.startTime
            )

            if response.newEvents.isEmpty {
                NSLog("[OnDevice] ℹ️ Analysis returned 0 events (relevant but no extractable activity)")
            } else {
                NSLog("[OnDevice] ✅ Extracted \(response.newEvents.count) events:")
                for ev in response.newEvents {
                    NSLog("[OnDevice]   + \(ev.type.emoji) \(ev.type.rawValue)\(ev.subtype.map { "/\($0)" } ?? ""): \(ev.detail.prefix(60)) [confidence=\(String(format: "%.2f", ev.confidence ?? 0)) status=\(ev.status?.rawValue ?? "nil")]")
                }
                eventStore.apply(response: response, dateStr: dateStr)
                NSLog("[OnDevice] 💾 Events saved to EventStore")
            }
        } catch {
            NSLog("[OnDevice] ❌ Foundation Models analysis FAILED: \(error)")
            NSLog("[OnDevice]    Error type: \(type(of: error))")
            NSLog("[OnDevice]    Description: \(error.localizedDescription)")
        }

        state = .listening
        NSLog("[OnDevice] 🔄 Back to listening")
    }

    // MARK: - Auto-completion

    private func startAutoCompleteTimer() {
        autoCompleteTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.autoCompleteStaleEvents()
            }
        }
        NSLog("[OnDevice] ⏰ Auto-completion timer started (every 5 min)")
    }

    private func autoCompleteStaleEvents() {
        guard let eventStore else { return }
        let now = Date()
        let inProgressEvents = eventStore.events.filter { $0.status == .inProgress }

        guard !inProgressEvents.isEmpty else { return }
        NSLog("[OnDevice] ⏰ Auto-complete scan — \(inProgressEvents.count) in_progress events")

        for event in inProgressEvents {
            let timeoutMin = AgeDefaults.autoCompleteTimeoutMinutes(
                eventType: event.type.rawValue,
                subtype: event.subtype
            )
            let elapsed = now.timeIntervalSince(event.timestamp) / 60

            if elapsed > Double(timeoutMin) {
                let durationDesc = elapsed < 60
                    ? "\(Int(elapsed))m"
                    : "\(Int(elapsed / 60))h \(Int(elapsed.truncatingRemainder(dividingBy: 60)))m"

                let completionEvent = BabyEvent(
                    id: UUID().uuidString,
                    type: event.type,
                    subtype: event.subtype,
                    timestamp: now,
                    timestampConfidence: .estimated,
                    createdAt: now,
                    detail: "\(event.type.displayName) ended (auto-completed after \(durationDesc))",
                    notable: false,
                    confidence: 0.5,
                    status: .completed
                )

                let response = AnalyzeResponse(newEvents: [completionEvent], corrections: [])
                eventStore.apply(response: response, dateStr: Self.todayStr())
                NSLog("[OnDevice] ⏰ Auto-completed \(event.type.rawValue) after \(durationDesc)")
            }
        }
    }

    // MARK: - Helpers

    private static let _dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func todayStr() -> String { _dateFmt.string(from: Date()) }
}
#endif
