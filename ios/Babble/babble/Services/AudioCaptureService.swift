import AVFoundation
import Combine

/// Manages the AVAudioEngine, maintains the 12-second ring buffer,
/// and handles the 30-second post-trigger capture window.
///
/// The EQ node (high-pass @ 80 Hz) is inserted inline — all downstream
/// consumers (WakeWordService, CryDetector, ring buffer) receive filtered audio.
@MainActor
final class AudioCaptureService: ObservableObject {
    @Published var isListening: Bool = false
    @Published var isCapturing: Bool = false    // true during post-trigger window

    // Called when a clip is ready: (wavData, triggerTime, rawTranscript)
    var onClipReady: ((Data, Date, String) -> Void)?

    private let engine = AVAudioEngine()
    private var eqNode: AVAudioUnitEQ?

    private let ringBuffer = AudioBuffer(sampleRate: Constants.sampleRate, windowSeconds: Constants.ringBufferSeconds)
    private var postCaptureBuffer: [Int16] = []
    private var captureTimer: Timer?
    private var triggerTime: Date?
    private var cooldownUntil: Date = .distantPast
    private var accumulatedTranscript: String = ""

    // Services that need audio tap
    var wakeWordService: WakeWordService?
    var cryDetector: CryDetector?

    // MARK: - Start / Stop

    func startListening() throws {
        guard !isListening else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // High-pass EQ node at 80 Hz — removes DC drift + sub-bass rumble
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 80
        eq.bands[0].bypass = false
        self.eqNode = eq

        engine.attach(eq)

        // Route: inputNode → EQ → mainMixer (not needed for output, but required for graph)
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Constants.sampleRate,
            channels: Constants.channelCount,
            interleaved: false
        )!

        engine.connect(inputNode, to: eq, format: inputFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: monoFormat)

        // Tap on EQ output
        eq.installTap(onBus: 0, bufferSize: Constants.tapBufferSize, format: monoFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        try engine.start()
        isListening = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(engineConfigChanged),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionResumed),
            name: .audioSessionResumed,
            object: nil
        )
    }

    func stopListening() {
        captureTimer?.invalidate()
        captureTimer = nil
        if isListening {
            eqNode?.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            if let eq = eqNode {
                engine.detach(eq)
            }
            eqNode = nil
        }
        isListening = false
        isCapturing = false
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Trigger

    /// Called by WakeWordService or CryDetector when a trigger fires.
    /// Resets the 30-second timer if already capturing (no data lost).
    func triggerCapture(at time: Date, transcriptSoFar: String) {
        guard Date() >= cooldownUntil else { return }

        if !isCapturing {
            // Fresh capture: snapshot pre-context from ring buffer
            postCaptureBuffer = ringBuffer.snapshot(lastSeconds: Constants.preCaptureSeconds)
            triggerTime = time
            accumulatedTranscript = transcriptSoFar
            isCapturing = true
        } else {
            // Already capturing — extend window, keep accumulated transcript
            accumulatedTranscript += " " + transcriptSoFar
        }

        // Reset (or start) the 30-second post-capture timer
        captureTimer?.invalidate()
        let maxSeconds = Constants.maxCaptureSeconds
        let postSeconds = Constants.postCaptureSeconds

        captureTimer = Timer.scheduledTimer(
            withTimeInterval: postSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.flushClip() }
        }

        // Hard cap at 90 seconds total from first trigger
        if let triggerTime {
            let elapsed = Date().timeIntervalSince(triggerTime)
            let remaining = maxSeconds - elapsed
            if remaining <= 0 {
                flushClip()
            }
        }
    }

    // MARK: - Buffer tap

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        // Always feed ring buffer
        ringBuffer.append(buffer)

        // During capture: accumulate post-trigger audio
        if isCapturing {
            let frameCount = Int(buffer.frameLength)
            if let samples = buffer.floatChannelData?[0] {
                for i in 0 ..< frameCount {
                    let clamped = max(-1.0, min(1.0, samples[i]))
                    postCaptureBuffer.append(Int16(clamped * 32767))
                }
            }
        }

        // Forward to trigger detectors
        wakeWordService?.appendBuffer(buffer)
        cryDetector?.appendBuffer(buffer)
    }

    // MARK: - Flush

    private func flushClip() {
        captureTimer?.invalidate()
        captureTimer = nil
        guard isCapturing, !postCaptureBuffer.isEmpty else {
            isCapturing = false
            return
        }

        let samples = postCaptureBuffer
        let time = triggerTime ?? Date()
        let transcript = accumulatedTranscript.trimmingCharacters(in: .whitespaces)

        // Reset state immediately
        postCaptureBuffer = []
        triggerTime = nil
        accumulatedTranscript = ""
        isCapturing = false

        // Set cool-down
        cooldownUntil = Date().addingTimeInterval(Constants.triggerCooldownSeconds)

        // Encode to WAV
        let wavData = WAVEncoder.encode(samples: samples)

        onClipReady?(wavData, time, transcript)
    }

    // MARK: - Engine reconfiguration

    @objc private func engineConfigChanged(_ notification: Notification) {
        // Restart after route change (BT headset plug/unplug, etc.)
        if isListening {
            try? restartEngine()
        }
    }

    @objc private func sessionResumed(_ notification: Notification) {
        if isListening {
            try? restartEngine()
        }
    }

    private func restartEngine() throws {
        eqNode?.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        if let eq = eqNode { engine.detach(eq) }
        eqNode = nil
        isListening = false
        try startListening()
    }
}
