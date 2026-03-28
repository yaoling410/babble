import AVFoundation
import Accelerate
import Combine

// ============================================================
//  AudioCaptureService.swift — Audio engine, VAD, and clip capture
// ============================================================
//
//  PURPOSE
//  -------
//  This is the lowest-level audio layer. It:
//    1. Manages AVAudioEngine (microphone input at native 48 kHz).
//    2. Maintains a 12-second ring buffer so pre-trigger audio is available.
//    3. Gates the ML pipelines (speech recognizer + cry detector) with a
//       hardware-accelerated speech-band VAD to prevent battery drain.
//    4. Accumulates audio + transcript during a capture window.
//    5. Flushes a complete WAV clip to `onClipReady` when silence is detected.
//
//  CAPTURE LIFECYCLE
//  -----------------
//  [Listening]
//    → VAD gate: 300 Hz high-pass RMS < threshold → skip ML (quiet room)
//    → VAD gate: RMS ≥ threshold → feed SFSpeechRecognizer + CryDetector
//    → WakeWordService detects baby's name OR CryDetector fires
//    → MonitorViewModel calls triggerCapture()
//
//  [Capturing]
//    → Audio buffers appended to postCaptureBuffer
//    → SFSpeechRecognizer sends partial transcripts via onPartialTranscript
//    → Each partial resets the 10-second silence timer
//    → Timer fires → flushClip() → onClipReady(wavData, time, transcript)
//    → OR hard cap (90 s) → flushClip()
//
//  VAD (VOICE ACTIVITY DETECTION)
//  --------------------------------
//  A 300 Hz Butterworth high-pass biquad filter runs on every buffer.
//  Only speech-band energy (300 Hz+) is measured, not broadband RMS.
//  This prevents white noise machines, fans, and AC from keeping the
//  ML pipelines running 24/7 (which causes the phone to overheat).
//
//  TWO VAD THRESHOLDS
//  -------------------
//  - `silenceThreshold` (default 0.015 = -36 dBFS): Used when idle.
//    Blocks background noise from waking SFSpeechRecognizer.
//  - `silenceThresholdActive` (default 0.005 = -46 dBFS): Used during the
//    2-minute active period after the baby's name is heard. More sensitive
//    to catch quiet follow-up speech.
//
//  TRANSCRIPT ACCUMULATION ACROSS TASK RESTARTS
//  -----------------------------------------------
//  SFSpeechRecognizer tasks expire after ~60 s and reset their cumulative
//  partial to "" when restarted. We detect this (incoming partial shorter
//  than last) and save the old transcript to `captureTranscriptBase`.
//  Full transcript = captureTranscriptBase + " " + currentPartial.
//
//  EARLY ABORT
//  -----------
//  After 10 s of capture, we evaluate only post-trigger speech. If it's
//  not baby-related (TranscriptFilter check), we abort with no cooldown.

/// Manages the AVAudioEngine, maintains the 12-second ring buffer,
/// and accumulates audio until 10s of silence or the hard cap is reached.
@MainActor
final class AudioCaptureService: ObservableObject {

    // ── Published state ──────────────────────────────────────────────

    /// True while AVAudioEngine is running and the microphone tap is installed.
    @Published var isListening: Bool = false

    /// True while a capture window is open (accumulating audio for a clip).
    @Published var isCapturing: Bool = false

    // ── Output callback ──────────────────────────────────────────────

    /// Called when a complete clip is ready. Parameters: WAV data, trigger time, transcript.
    var onClipReady: ((Data, Date, String) -> Void)?

    /// Called on every audio buffer with raw Int16 samples and timestamp.
    /// Used by OnDevicePipeline to feed WhisperKit continuously.
    var onRawBuffer: (([Int16], Date) -> Void)?

    // ── Audio engine + buffers ────────────────────────────────────────

    /// The AVAudioEngine driving the microphone input.
    private let engine = AVAudioEngine()

    /// Circular ring buffer — continuously holds the last 12 s of audio.
    /// Snapshotted at trigger time to prepend pre-trigger context to each clip.
    private let ringBuffer = AudioBuffer(sampleRate: 48_000, windowSeconds: Constants.ringBufferSeconds)

    /// Accumulates Int16 PCM samples from the moment the trigger fires onward.
    private var postCaptureBuffer: [Int16] = []

    // ── Capture timing ────────────────────────────────────────────────

    /// Fires after `silenceFlushSeconds` of no new transcript words → flushClip().
    private var captureTimer: Timer?

    /// When the trigger that started this capture fired (for hard-cap check + timestamp).
    private var triggerTime: Date?

    /// When audio capture actually started (may include pre-capture ring-buffer audio).
    /// Used for logging clip duration and elapsed capture time.
    private var captureStartTime: Date = .distantPast

    /// No new triggers accepted until this time. Set to now + 60 s after each flush.
    private var cooldownUntil: Date = .distantPast

    // ── Transcript accumulation ───────────────────────────────────────

    /// Full transcript built up since capture started.
    /// = captureTranscriptBase + " " + latestPartialFromRecognizer
    private var accumulatedTranscript: String = ""

    // Interim transcript tracking across recognition task restarts.
    // SFSpeechRecognizer resets its partial result every ~55 seconds.
    // captureTranscriptBase holds everything from completed sessions so
    // nothing is lost when a new session starts mid-capture.

    /// Text from all completed recognition sessions in this capture.
    /// Saved when a task restart is detected (incoming partial shorter than last seen).
    private var captureTranscriptBase: String = ""

    /// The last partial we received — used to detect recognizer restarts
    /// (a new task always starts with a shorter partial than the previous task ended with).
    private var lastInterimTranscript: String = ""
    /// Last post-trigger content checked by the early-abort filter.
    /// Skips redundant checks when multiple partials produce the same post-trigger text.
    private var lastEarlyAbortContent: String = ""

    /// Wall clock of the last partial transcript arrival (available for debugging).
    private var lastTranscriptTime: Date = .distantPast

    // The full transcript at the exact moment the trigger fired.
    // Early-abort checks only content AFTER this — the trigger phrase itself
    // always contains the baby's name, so checking the whole transcript
    // would always pass and never abort anything.

    /// Snapshot of accumulatedTranscript at trigger time.
    /// `postTriggerContent(from:)` strips this prefix before running early-abort.
    private var transcriptAtTrigger: String = ""

    // ── Active period state ───────────────────────────────────────────

    /// Set by MonitorViewModel when the baby's primary name is heard.
    /// Expires after Constants.activePeriodSeconds. Secondary references
    /// (she/he/little one) trigger analysis during this window.
    var activePeriodEnd: Date = .distantPast

    /// Fires when a secondary reference is detected during the active period
    /// while NOT already capturing. MonitorViewModel uses this to start a new clip.
    /// Secondary triggers do NOT extend activePeriodEnd.
    var onSecondaryTrigger: ((String) -> Void)?

    // ── Connected services ────────────────────────────────────────────

    /// Speech recognizer. `didSet` re-wires the `onPartialTranscript` callback.
    var wakeWordService: WakeWordService? {
        didSet { wirePartialTranscript() }
    }

    /// Cry detector — receives audio when VAD gate is open.
    var cryDetector: CryDetector?

    // ── VAD logging state ─────────────────────────────────────────────

    /// Tracks VAD transitions to avoid logging every buffer (only log changes).
    private var vadWasActive: Bool = false

    /// Tracks active-period transitions for enter/exit log messages.
    private var activePeriodWasActive: Bool = false

    /// Counts every buffer. Used to emit a periodic energy sample every ~4 s
    /// (50 buffers × 85 ms/buffer) so the log shows the ambient energy level
    /// even when the VAD state hasn't changed — lets you see if your voice is
    /// near or below the threshold without waiting for a transition log.
    private var vadSampleCount: Int = 0

    // MARK: - Interim transcript wiring

    private func wirePartialTranscript() {
        wakeWordService?.onPartialTranscript = { [weak self] transcript in
            guard let self else { return }

            // Not capturing — check if a secondary reference should start a new clip.
            // Only fires during the active period (2 min after primary name was heard).
            // Requires pronoun or nickname ("she's been fussy", "little one just woke") —
            // isolated keywords are too broad here and cause false positives on casual
            // adult conversation ("I'm so tired"). The early-abort at 10s catches any
            // false positives that slip through.
            if !self.isCapturing {
                guard Date() < self.activePeriodEnd else {
                    BabbleLog.active.debug("\(BabbleLog.ts) 💤 Not in active period — secondary ref check skipped (say baby's name to start)")
                    return
                }
                guard TranscriptFilter.containsSecondaryReference(transcript) else {
                    BabbleLog.active.debug("\(BabbleLog.ts) 🔇 Active period: no pronoun/nickname in '\(transcript.prefix(80), privacy: .public)' — no secondary trigger")
                    return
                }
                BabbleLog.active.info("\(BabbleLog.ts) Secondary ref during active period: '\(transcript.prefix(80), privacy: .public)'")
                self.onSecondaryTrigger?(transcript)
                return
            }

            // Detect a recognition task restart mid-capture.
            // SFSpeechRecognizer resets its cumulative partial to "" on each new task.
            // If incoming transcript is shorter than last seen, a restart happened —
            // save old content as base so nothing is lost.
            let didRestart = transcript.count < self.lastInterimTranscript.count
            if didRestart {
                self.captureTranscriptBase = self.accumulatedTranscript
                BabbleLog.capture.info("\(BabbleLog.ts) Recognizer task restarted mid-capture — transcript base saved (\(self.accumulatedTranscript.split(separator: " ").count, privacy: .public) words)")
            }
            self.lastInterimTranscript = transcript
            self.lastTranscriptTime = Date()

            // Build the full transcript from saved base + current partial.
            // After a task restart, the new task may re-transcribe audio still in
            // Apple's internal buffer, producing a near-duplicate of what's already
            // in captureTranscriptBase. Detect this overlap and skip appending if
            // the new partial is mostly a repeat of the base's tail.
            let full: String
            if self.captureTranscriptBase.isEmpty {
                full = transcript
            } else {
                let baseWords = self.captureTranscriptBase.split(separator: " ")
                let newWords = transcript.split(separator: " ")
                // Find overlap: check if the first N words of the new partial match
                // the last N words of the base (common after restart).
                let maxOverlap = min(baseWords.count, newWords.count)
                var overlapLen = 0
                for len in stride(from: maxOverlap, through: 3, by: -1) {
                    let baseTail = baseWords.suffix(len)
                    let newHead = newWords.prefix(len)
                    if Array(baseTail) == Array(newHead) {
                        overlapLen = len
                        break
                    }
                }
                if overlapLen > 0 {
                    // New partial overlaps with base — only append the non-overlapping tail
                    let uniquePart = newWords.dropFirst(overlapLen).joined(separator: " ")
                    full = uniquePart.isEmpty
                        ? self.captureTranscriptBase
                        : self.captureTranscriptBase + " " + uniquePart
                } else {
                    full = self.captureTranscriptBase + " " + transcript
                }
            }
            self.accumulatedTranscript = full

            BabbleLog.capture.debug("\(BabbleLog.ts) Transcript \(full.split(separator: " ").count, privacy: .public)w: '\(full.prefix(120), privacy: .public)'")

            // Reset the silence timer — speech is still happening.
            // The clip won't flush until this timer fires (10s of real silence).
            self.resetSilenceTimer()

            // Early abort: after earlyAbortCheckSeconds, evaluate only the
            // content spoken AFTER the trigger phrase. The trigger transcript
            // always contains the baby's name (that's how it fired), so checking
            // the full transcript would always pass. We want to know whether the
            // conversation that followed the trigger is baby-related.
            guard let triggerTime = self.triggerTime,
                  Date().timeIntervalSince(triggerTime) >= AppConfig.earlyAbortCheckSeconds
            else { return }

            let postTrigger = self.postTriggerContent(from: full)
            let wordCount = postTrigger.split(separator: " ").count
            guard wordCount >= AppConfig.earlyAbortMinWordCount else {
                BabbleLog.filter.debug("\(BabbleLog.ts) Early-abort deferred — \(wordCount, privacy: .public)/\(AppConfig.earlyAbortMinWordCount, privacy: .public) post-trigger words")
                return
            }

            // Skip if post-trigger content hasn't changed since last check
            guard postTrigger != self.lastEarlyAbortContent else { return }
            self.lastEarlyAbortContent = postTrigger

            let babyName = self.wakeWordService?.babyName ?? ""
            let passes = TranscriptFilter.shouldAnalyze(transcript: postTrigger, babyName: babyName, triggerKind: "name")
            if !passes {
                BabbleLog.filter.info("\(BabbleLog.ts) Early-abort check \(wordCount, privacy: .public)w: '\(postTrigger.prefix(80), privacy: .public)' → ABORT")
                self.abortCapture()
            }
        }
    }

    private func resetSilenceTimer() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: Constants.silenceFlushSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                BabbleLog.capture.info("\(BabbleLog.ts) ⏰ Silence timer fired (\(Int(Constants.silenceFlushSeconds), privacy: .public)s) → flushing clip")
                self?.flushClip()
            }
        }
    }

    /// Returns only the portion of the full transcript that came after the
    /// trigger phrase, so early-abort doesn't get confused by the baby's name
    /// that was always present in the trigger.
    private func postTriggerContent(from full: String) -> String {
        let base = transcriptAtTrigger.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, full.lowercased().hasPrefix(base.lowercased()) else {
            return full
        }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Cancels the current capture without flushing a clip or starting cooldown.
    /// Used when interim transcript shows the trigger was a false positive.
    private func abortCapture() {
        let elapsed = Date().timeIntervalSince(captureStartTime)
        BabbleLog.capture.info("\(BabbleLog.ts) 🚫 Aborted (false positive) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s — no cooldown")
        captureTimer?.invalidate()
        captureTimer = nil
        postCaptureBuffer = []
        triggerTime = nil
        captureStartTime = .distantPast
        accumulatedTranscript = ""
        captureTranscriptBase = ""
        lastInterimTranscript = ""
        lastEarlyAbortContent = ""
        lastTranscriptTime = .distantPast
        transcriptAtTrigger = ""
        isCapturing = false
        // No cooldown — false positive, stay ready to trigger immediately.
    }

    // MARK: - Speech-band VAD

    // 2nd-order Butterworth high-pass at 300 Hz / 48 kHz (Audio EQ Cookbook).
    // Passes speech (300–3400 Hz), rejects white noise machines, fans, and AC
    // which dominate broadband RMS in a nursery but carry no speech energy.
    // Coefficients: [b0, b1, b2, a1, a2] — used by vDSP_biquad (Double only).
    //
    // Calculated for 48 kHz. If the device runs at a different sample rate, the
    // cutoff shifts slightly but the filter remains effective.
    private static let vadCoefficients: [Double] = [
        0.97261, -1.94521, 0.97261,   // b0, b1, b2 (feed-forward)
       -1.94446,  0.94597             // a1, a2 (feedback; vDSP uses positive sign convention)
    ]

    /// IIR filter state. vDSP requires 2*(sections+1) = 4 floats.
    /// Carries memory between calls so the filter is continuous across buffers.
    /// Reset to zero on each startListening() call.
    private var vadState: [Float] = [Float](repeating: 0, count: 4)

    /// Opaque vDSP setup — created in startListening(), destroyed in stopListening().
    private var vadSetup: vDSP_biquad_Setup?

    // Hold-open hysteresis: keep the gate open for N buffers after energy
    // drops below threshold. Prevents choppy audio during short pauses in speech.
    // At 4096 frames / 48 kHz ≈ 85 ms/buffer, 5 buffers = ~425 ms of tail.

    /// Counts down from `silenceHoldBuffers` after speech energy drops.
    /// While > 0, the VAD gate stays open and ML pipelines keep receiving audio.
    private var silenceHoldCount: Int = 0

    // MARK: - Start / Stop

    func startListening() throws {
        guard !isListening else { return }

        // Configure the audio session for raw microphone capture.
        // .measurement mode disables iOS automatic gain control and noise reduction
        // so the VAD sees the actual speech-band energy. Without this, iOS crushes
        // the signal before our biquad filter ever sees it — causing energy readings
        // of ~0.001 even for loud speech, keeping the VAD gate permanently closed.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)
        let hwSampleRate = session.sampleRate
        let hwInputs = session.inputNumberOfChannels
        BabbleLog.vad.info("\(BabbleLog.ts) 🎛 AVAudioSession ready — sampleRate=\(hwSampleRate, privacy: .public)Hz inputs=\(hwInputs, privacy: .public) mode=measurement (AGC disabled)")

        vadSetup = vDSP_biquad_CreateSetup(Self.vadCoefficients, 1)
        if vadSetup == nil {
            BabbleLog.vad.error("\(BabbleLog.ts) ❌ vDSP biquad setup FAILED — falling back to broadband RMS (no HPF)")
        } else {
            BabbleLog.vad.info("\(BabbleLog.ts) ✅ VAD biquad 300Hz HPF ready — threshold=\(String(format:"%.4f", Constants.silenceThreshold), privacy: .public) active=\(String(format:"%.4f", Constants.silenceThresholdActive), privacy: .public)")
        }
        vadState = [Float](repeating: 0, count: 4)
        silenceHoldCount = 0
        vadSampleCount = 0

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        BabbleLog.vad.info("\(BabbleLog.ts) 🎤 Engine tap format — sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public) bits=\(inputFormat.streamDescription.pointee.mBitsPerChannel, privacy: .public)")

        // Start cry detector with the actual device format
        try cryDetector?.start(format: inputFormat)

        // Tap directly on the input node — no EQ node to cause graph issues
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // AVAudioEngine delivers buffers on a private audio thread.
            // AudioCaptureService is @MainActor — Task hops to the main actor
            // without forcing a synchronous main-thread dispatch (which is what
            // causes the "unsafeForcedSync" Swift 6 concurrency warning).
            Task { @MainActor [weak self] in self?.handleBuffer(buffer) }
        }

        try engine.start()
        isListening = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(engineConfigChanged),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    func stopListening() {
        captureTimer?.invalidate()
        captureTimer = nil
        if isListening {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let setup = vadSetup { vDSP_biquad_DestroySetup(setup) }
        vadSetup = nil
        isListening = false
        isCapturing = false
        NotificationCenter.default.removeObserver(self)
        // Don't deactivate the audio session — keeps the hardware warm so
        // restart after phone call interruption is fast (~100ms vs ~2s).
    }

    // MARK: - Force flush (for manual recording stop)

    func forceFlush() {
        flushClip()
    }

    // MARK: - Trigger

    func triggerCapture(at time: Date, transcriptSoFar: String) {
        let now = Date()
        guard now >= cooldownUntil || isCapturing else {
            let remaining = Int(cooldownUntil.timeIntervalSince(now))
            BabbleLog.capture.info("\(BabbleLog.ts) ⏳ Trigger ignored — cooldown \(remaining, privacy: .public)s remaining (not capturing)")
            return
        }

        if !isCapturing {
            // Prepend the last preCaptureSeconds from the ring buffer so the clip
            // contains audio that arrived BEFORE the trigger fired (e.g., the start
            // of the baby's name, or the caregiver's question that preceded it).
            postCaptureBuffer = ringBuffer.snapshot(lastSeconds: Constants.preCaptureSeconds)
            triggerTime = time
            captureStartTime = now
            accumulatedTranscript = transcriptSoFar
            transcriptAtTrigger = transcriptSoFar
            isCapturing = true
            let activeSuffix = now < activePeriodEnd
                ? " | active-period \(Int(activePeriodEnd.timeIntervalSince(now)))s left"
                : ""
            BabbleLog.capture.info("\(BabbleLog.ts) 🔴 Started — transcript='\(transcriptSoFar.prefix(60), privacy: .public)'\(activeSuffix, privacy: .public)")
        } else {
            let elapsed = Int(now.timeIntervalSince(captureStartTime))
            BabbleLog.capture.debug("\(BabbleLog.ts) Extended — already capturing for \(elapsed, privacy: .public)s")
        }

        // Hard cap: flush if we've been capturing too long regardless of speech.
        if let triggerTime, now.timeIntervalSince(triggerTime) >= Constants.maxCaptureSeconds {
            BabbleLog.capture.info("\(BabbleLog.ts) ⏱ Hard cap \(Int(Constants.maxCaptureSeconds), privacy: .public)s hit — force flush")
            flushClip()
            return
        }

        // Start (or reset) the silence timer. Flushing only happens when
        // this fires — i.e., silenceFlushSeconds of genuine silence.
        resetSilenceTimer()
    }

    // MARK: - Buffer tap

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        // Always write into the ring buffer — runs unconditionally so
        // the last 12 s of audio is always available when a trigger fires.
        ringBuffer.append(buffer)

        // Fire raw buffer callback for WhisperKit continuous transcription
        if let onRawBuffer, let floatData = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            var int16Samples = [Int16](repeating: 0, count: count)
            for i in 0 ..< count {
                let clamped = max(-1.0, min(1.0, floatData[i]))
                int16Samples[i] = Int16(clamped * 32767)
            }
            onRawBuffer(int16Samples, Date())
        }

        if isCapturing {
            let frameCount = Int(buffer.frameLength)
            if let samples = buffer.floatChannelData?[0] {
                for i in 0 ..< frameCount {
                    let clamped = max(-1.0, min(1.0, samples[i]))
                    postCaptureBuffer.append(Int16(clamped * 32767))
                }
            }
        }

        // Speech-band VAD gate — skip ML pipelines when no speech energy is present.
        //
        // Uses a 300 Hz high-pass biquad filter before computing RMS so that
        // broadband noise sources common in nurseries (white noise machines, fans,
        // AC units) don't keep SFSpeechRecognizer and SNAudioStreamAnalyzer running
        // continuously. A broadband RMS check would pass those sources; a speech-band
        // check won't. vDSP_biquad + vDSP_rmsqv are both hardware-accelerated and
        // together cost far less than a single ML inference call.
        //
        // Hysteresis (silenceHoldCount) holds the gate open for a short tail after
        // energy drops, preventing choppy input to the recognizer during brief pauses.
        let now = Date()
        let rawEnergy = rms(buffer)
        let speechEnergy = speechBandRMS(buffer)

        // Periodic energy sample — every 50 buffers (~4.25 s) regardless of VAD state.
        // Shows whether your voice is reaching the threshold even when no transition occurs.
        // raw= is broadband RMS before the biquad; filtered= is speech-band (300 Hz+) after.
        // If raw is also near zero → audio session issue (mic not providing signal).
        // If raw is high but filtered is low → biquad filter issue.
        vadSampleCount &+= 1
        if vadSampleCount % 12 == 0 {
            let inAP = now < activePeriodEnd
            let threshold: Float = inAP ? Constants.silenceThresholdActive : Constants.silenceThreshold
            let rawEnergy = rms(buffer)
            let db = speechEnergy > 0 ? 20 * log10(speechEnergy) : -100
            let rawDb = rawEnergy > 0 ? 20 * log10(rawEnergy) : -100
            let gateLabel = speechEnergy >= threshold ? "ABOVE gate ✅" : "BELOW gate ❌"
            BabbleLog.vad.debug("\(BabbleLog.ts) 📊 raw=\(String(format: "%.4f", rawEnergy), privacy: .public) (\(String(format: "%.1f", rawDb), privacy: .public)dBFS) filtered=\(String(format: "%.4f", speechEnergy), privacy: .public) (\(String(format: "%.1f", db), privacy: .public)dBFS) threshold=\(String(format: "%.4f", threshold), privacy: .public) \(gateLabel, privacy: .public)")
        }

        // Active-period transition logging
        let inActivePeriod = now < activePeriodEnd
        if inActivePeriod != activePeriodWasActive {
            activePeriodWasActive = inActivePeriod
            if inActivePeriod {
                let remaining = Int(activePeriodEnd.timeIntervalSince(now))
                BabbleLog.active.info("\(BabbleLog.ts) 🟢 Entered — expires in \(remaining, privacy: .public)s (secondary refs now trigger)")
            } else {
                BabbleLog.active.info("\(BabbleLog.ts) ⚪ Expired — back to strict wake-word only")
            }
        }

        let vadThreshold = inActivePeriod ? Constants.silenceThresholdActive : Constants.silenceThreshold
        if speechEnergy >= vadThreshold {
            silenceHoldCount = Constants.silenceHoldBuffers
        } else if silenceHoldCount > 0 {
            silenceHoldCount -= 1
        }

        let vadActive = silenceHoldCount > 0
        if vadActive != vadWasActive {
            vadWasActive = vadActive
            if vadActive {
                // Build a one-line summary of what happens next so the log reads as a chain:
                //   🎙 Speech … → wake-word ON, cry ON  (listening)
                //   🎙 Speech … → wake-word ON, cry ON  (capturing — silence timer reset)
                let action: String
                if isCapturing {
                    action = "→ wake-word ON, cry ON  (capturing — silence timer running)"
                } else if inActivePeriod {
                    let remaining = Int(activePeriodEnd.timeIntervalSince(now))
                    action = "→ wake-word ON, cry ON  (active-period \(remaining)s left — secondary refs enabled)"
                } else {
                    action = "→ wake-word ON, cry ON  (listening for name)"
                }
                BabbleLog.vad.info("\(BabbleLog.ts) 🎙 Speech raw=\(String(format: "%.4f", rawEnergy), privacy: .public) filtered=\(String(format: "%.4f", speechEnergy), privacy: .public) threshold=\(String(format: "%.4f", vadThreshold), privacy: .public) \(action, privacy: .public)")
            } else {
                let action: String
                if isCapturing {
                    action = "→ wake-word KEPT ON (mid-capture), cry OFF"
                } else {
                    action = "→ wake-word OFF, cry OFF  (all ML paused)"
                }
                BabbleLog.vad.info("\(BabbleLog.ts) 🔇 Silence energy=\(String(format: "%.4f", speechEnergy), privacy: .public) \(action, privacy: .public)")
            }
        }

        // CryDetector always gets audio regardless of VAD — baby cries have
        // strong energy at 300-600 Hz which the speech-band high-pass filter
        // attenuates, causing the VAD to read "silence" during actual crying.
        // SNAudioStreamAnalyzer has its own internal detection, so it doesn't
        // need the VAD gate.
        cryDetector?.appendBuffer(buffer)

        if vadActive {
            wakeWordService?.appendBuffer(buffer)
        } else if isCapturing {
            // During an active capture, keep feeding the recognizer even through
            // silent pauses. Without this, a 425ms pause in speech starves the
            // recognizer, it declares the utterance final and restarts — resetting
            // the cumulative partial transcript mid-capture.
            wakeWordService?.appendBuffer(buffer)
        }
    }

    /// RMS energy in the speech band (300 Hz+) only.
    /// Filters the buffer through the biquad high-pass, then measures energy.
    /// The original buffer is never modified — the recognizer still receives raw audio.
    private func speechBandRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let setup = vadSetup,
              let samples = buffer.floatChannelData?[0],
              buffer.frameLength > 0 else { return rms(buffer) }

        let count = Int(buffer.frameLength)
        var output = [Float](repeating: 0, count: count)

        // High-pass biquad filter — all Float. vDSP_biquad_CreateSetup takes
        // Double coefficients for precision, but filtering operates on Float.
        vDSP_biquad(setup, &vadState, samples, 1, &output, 1, vDSP_Length(count))

        var result: Float = 0
        vDSP_rmsqv(&output, 1, &result, vDSP_Length(count))
        return result
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(buffer.frameLength))
        return result
    }

    // MARK: - Flush

    private func flushClip() {
        captureTimer?.invalidate()
        captureTimer = nil
        guard isCapturing, !postCaptureBuffer.isEmpty else {
            if isCapturing { BabbleLog.capture.warning("\(BabbleLog.ts) ⚠️ Flush: buffer empty — discarding") }
            isCapturing = false
            return
        }

        let samples = postCaptureBuffer
        let time = triggerTime ?? Date()
        let transcript = accumulatedTranscript.trimmingCharacters(in: .whitespaces)
        let durationSecs = Double(samples.count) / 48_000.0
        let wordCount = transcript.split(separator: " ").count
        let captureElapsed = Date().timeIntervalSince(captureStartTime)

        BabbleLog.capture.info("\(BabbleLog.ts) ✅ Flush — audio=\(String(format: "%.1f", durationSecs), privacy: .public)s window=\(String(format: "%.1f", captureElapsed), privacy: .public)s words=\(wordCount, privacy: .public) transcript='\(transcript.prefix(80), privacy: .public)'")
        BabbleLog.capture.info("\(BabbleLog.ts) 📤 → backend | cooldown \(Int(Constants.triggerCooldownSeconds), privacy: .public)s starts")

        postCaptureBuffer = []
        triggerTime = nil
        accumulatedTranscript = ""
        captureTranscriptBase = ""
        transcriptAtTrigger = ""
        lastInterimTranscript = ""
        lastEarlyAbortContent = ""
        lastTranscriptTime = .distantPast
        isCapturing = false
        captureStartTime = .distantPast
        cooldownUntil = Date().addingTimeInterval(Constants.triggerCooldownSeconds)

        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 48_000)
        onClipReady?(wavData, time, transcript)
    }

    // MARK: - Engine reconfiguration

    @objc private func engineConfigChanged(_ notification: Notification) {
        if isListening {
            try? restartEngine()
        }
    }

    private func restartEngine() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        cryDetector?.stop()
        isListening = false
        try startListening()
    }
}
