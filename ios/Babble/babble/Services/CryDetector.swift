import AVFoundation
import os
import SoundAnalysis

// ============================================================
//  CryDetector.swift — Detects infant crying using Apple SoundAnalysis
// ============================================================
//
//  PURPOSE
//  -------
//  Runs Apple's SNClassifySoundRequest (a Core ML neural network)
//  on the live audio stream to detect when the baby is crying.
//  When confidence crosses the threshold, fires `onCryDetected`
//  so MonitorViewModel can start recording a new clip.
//
//  ARCHITECTURE
//  ------------
//  SNAudioStreamAnalyzer is Apple's framework for continuous sound
//  classification. It accepts AVAudioPCMBuffers and calls our
//  CryObserver delegate on a background analysis queue.
//
//  The detector is intentionally stateless — it only cares about
//  infant crying (not music, speech, dogs, etc.). The full sound
//  classifier model can recognize 300+ sounds; we only read the
//  infant_cry identifier.
//
//  THROTTLING (CPU/heat)
//  ----------------------
//  SNAudioStreamAnalyzer runs a full neural network on every buffer.
//  At 48 kHz / 4096 frames, we get ~10 buffers/second. Running the
//  classifier at 10 Hz is far more than needed — a baby cry lasts
//  several seconds, so we only need to catch it at ~2 Hz.
//
//  `cryAnalysisInterval` (default 5) skips 4 out of every 5 buffers.
//  This cuts ML CPU cost by ~80% with no meaningful detection loss.
//  Tune in AppConfig if you find the detector too slow or too hot.
//
//  COOLDOWN
//  --------
//  Once a cry is detected, further detections are suppressed for
//  `triggerCooldownSeconds` (default 60 s). This prevents the same
//  crying episode from creating multiple events.

final class CryDetector: NSObject {

    /// Called on the main thread when infant crying is detected with sufficient confidence.
    /// MonitorViewModel wires this to start a capture clip.
    var onCryDetected: (() -> Void)?

    /// True when SoundAnalysis has recently seen human speech with sufficient confidence.
    /// AudioCaptureService reads this to gate SFSpeechRecognizer — if false, the
    /// expensive speech recognizer is not fed audio buffers.
    /// Uses a hold timer: stays true for `speechGateHoldSeconds` after the last
    /// confident speech frame, preventing choppy recognizer input during short pauses.
    private(set) var isSpeechActive: Bool = false

    // Timer that keeps isSpeechActive = true for a short tail after speech ends.
    private var speechHoldTimer: Timer?

    // The Apple sound classifier — nil until start() is called.
    private var streamAnalyzer: SNAudioStreamAnalyzer?

    // Reference to the observer object. Kept alive here because SNAudioStreamAnalyzer
    // holds a weak reference to observers — without this strong reference, the
    // observer would be deallocated and results would stop arriving.
    private var observerToken: SNResultsObserving?

    // Classification runs on a background thread to keep the audio tap non-blocking.
    // SNAudioStreamAnalyzer.analyze() is synchronous — if called on the main thread
    // it would stall the UI during heavy ML inference.
    private let analysisQueue = DispatchQueue(label: "com.babble.crydetector")

    // Last time a cry was reported to MonitorViewModel.
    // Guards against duplicate triggers from the same crying episode.
    private var lastTriggerTime: Date = .distantPast

    // Counts how many buffers have been received since start().
    // Every `cryAnalysisInterval`-th buffer is passed to the classifier;
    // the rest are dropped to save CPU.
    private var bufferCount = 0

    // ----------------------------------------------------------------
    //  start(format:)
    // ----------------------------------------------------------------
    /// Begin sound analysis using the audio format from AVAudioEngine's input node.
    ///
    /// Must be called with the exact same AVAudioFormat that the engine tap uses —
    /// passing a different format causes the classifier to produce garbage results
    /// or throw an error.
    ///
    /// - Parameter format: The AVAudioFormat reported by `engine.inputNode.outputFormat(forBus: 0)`.
    func start(format: AVAudioFormat) throws {
        streamAnalyzer = SNAudioStreamAnalyzer(format: format)

        // SNClassifySoundRequest.version1 is the built-in classifier shipped with iOS.
        // It can identify 300+ sounds including "infant_cry".
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)

        // CryObserver receives classification results and checks the confidence.
        // The same model run also produces a "speech" confidence at zero extra cost —
        // we use that to drive the isSpeechActive gate for SFSpeechRecognizer.
        let observer = CryObserver(
            cryThreshold: Constants.cryConfidenceThreshold,
            speechThreshold: Constants.speechGateConfidenceThreshold,
            onCry: { [weak self] in self?.handleCry() },
            onSpeech: { [weak self] in self?.handleSpeechDetected() }
        )
        self.observerToken = observer  // strong reference — see note above

        try streamAnalyzer?.add(request, withObserver: observer)
    }

    // ----------------------------------------------------------------
    //  stop()
    // ----------------------------------------------------------------
    /// Release the sound classifier and observer. Safe to call multiple times.
    func stop() {
        speechHoldTimer?.invalidate()
        speechHoldTimer = nil
        isSpeechActive = false
        streamAnalyzer = nil  // deallocation also cancels any in-flight analysis
        observerToken = nil
    }

    // ----------------------------------------------------------------
    //  appendBuffer(_:)
    // ----------------------------------------------------------------
    /// Feed an audio buffer to the classifier — but only every Nth buffer.
    ///
    /// Called from AudioCaptureService's handleBuffer(), which is already
    /// gated by the speech-band VAD. So this function only runs when the
    /// microphone is picking up something above silence — further throttling
    /// here is purely for CPU cost when there IS audio energy.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferCount += 1
        // Drop buffers not on the analysis interval (5 of every 6 by default)
        guard bufferCount % Constants.cryAnalysisInterval == 0 else { return }

        // analyze() blocks the calling thread while the neural net runs.
        // Dispatch to background to avoid stalling the audio tap callback.
        analysisQueue.async { [weak self] in
            guard let analyzer = self?.streamAnalyzer else { return }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(buffer.frameLength))
        }
    }

    // ----------------------------------------------------------------
    //  handleCry() — called by CryObserver on a background thread
    // ----------------------------------------------------------------
    /// Apply cooldown then dispatch `onCryDetected` to the main thread.
    private func handleCry() {
        guard Date().timeIntervalSince(lastTriggerTime) > Constants.triggerCooldownSeconds else { return }
        lastTriggerTime = Date()
        DispatchQueue.main.async { [weak self] in
            self?.onCryDetected?()
        }
    }

    // ----------------------------------------------------------------
    //  handleSpeechDetected() — called by CryObserver on a background thread
    // ----------------------------------------------------------------
    /// Opens the speech gate and resets the hold timer.
    /// Called at zero extra model cost — the same .version1 classifier run
    /// that checks for crying also emits a "speech" confidence score.
    private func handleSpeechDetected() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.isSpeechActive {
                BabbleLog.vad.info("🗣 Speech gate OPEN — feeding SFSpeechRecognizer")
                self.isSpeechActive = true
            }
            // Reset hold timer: keep gate open for speechGateHoldSeconds after
            // the last confident speech frame, so short pauses don't chop the input.
            self.speechHoldTimer?.invalidate()
            self.speechHoldTimer = Timer.scheduledTimer(
                withTimeInterval: AppConfig.speechGateHoldSeconds,
                repeats: false
            ) { [weak self] _ in
                self?.isSpeechActive = false
                BabbleLog.vad.info("🔕 Speech gate CLOSED — SFSpeechRecognizer paused")
            }
        }
    }
}

// ============================================================
//  CryObserver — SNResultsObserving delegate
// ============================================================
//  Apple calls `request(_:didProduce:)` with a classification result
//  for each audio buffer analyzed. We check specifically for
//  infant_cry / baby_cry and compare confidence to our threshold.

private final class CryObserver: NSObject, SNResultsObserving {

    private let cryThreshold: Double
    private let speechThreshold: Double
    private let onCry: () -> Void
    private let onSpeech: () -> Void

    init(cryThreshold: Double, speechThreshold: Double,
         onCry: @escaping () -> Void, onSpeech: @escaping () -> Void) {
        self.cryThreshold = cryThreshold
        self.speechThreshold = speechThreshold
        self.onCry = onCry
        self.onSpeech = onSpeech
    }

    /// Called by SNAudioStreamAnalyzer with classification results for each buffer.
    /// The .version1 model runs once — we read both "infant_cry" and "speech"
    /// from the same result at zero extra inference cost.
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }

        // Cry detection — try all known identifier variants across iOS versions.
        let cryIdentifiers = ["infant_cry", "baby_cry", "crying"]
        for id in cryIdentifiers {
            if let obs = r.classification(forIdentifier: id), obs.confidence >= cryThreshold {
                onCry()
                break
            }
        }

        // Speech gate — "speech" is a stable identifier in .version1 on iOS 15+.
        // Log the raw confidence every classification so missed detections are diagnosable:
        //   🗣 SoundAnalysis speech=0.42 ✅ PASS  → gate opens
        //   🗣 SoundAnalysis speech=0.18 ❌ below 0.30  → gate stays closed
        let speechConf = r.classification(forIdentifier: "speech")?.confidence ?? 0
        let pct = Int(speechConf * 100)
        let threshPct = Int(speechThreshold * 100)
        if speechConf >= speechThreshold {
            BabbleLog.vad.debug("🗣 SoundAnalysis speech=\(pct, privacy: .public)% ✅ PASS (threshold \(threshPct, privacy: .public)%)")
            onSpeech()
        } else {
            BabbleLog.vad.debug("🗣 SoundAnalysis speech=\(pct, privacy: .public)% ❌ below \(threshPct, privacy: .public)%")
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        BabbleLog.vad.error("⚠️ SoundAnalysis error: \(error.localizedDescription, privacy: .public)")
    }
}
