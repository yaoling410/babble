import Foundation
import AVFoundation
import Accelerate
#if canImport(WhisperKit)
import WhisperKit
#endif

// ============================================================
//  WhisperKitService.swift — Continuous on-device transcription
// ============================================================
//
//  PURPOSE
//  -------
//  Replaces SFSpeechRecognizer for the on-device build.
//  Audio buffers arrive continuously at 48 kHz. This service:
//    1. Resamples to 16 kHz Float32 via AudioResampler
//    2. Runs a lightweight VAD (RMS energy check)
//    3. Accumulates audio while speech is detected
//    4. Flushes to WhisperKit when silence exceeds ~4s
//
//  SPEECH-BOUNDED WINDOWS
//  ----------------------
//  Instead of fixed 30s windows (which cut sentences mid-word),
//  we use silence detection to find natural speech boundaries:
//
//    Speech starts → accumulate
//    Speech continues → keep accumulating
//    Silence > 4s → flush & transcribe
//    Hard cap 90s → flush regardless (prevents unbounded growth)
//    Minimum 3s → don't transcribe tiny fragments
//
//  The VAD reuses the same thresholds as AudioCaptureService
//  (AppConfig.silenceThreshold) for consistency.

#if BABBLE_ON_DEVICE
@available(iOS 26.0, *)
final class WhisperKitService {

    struct TranscriptionWindow {
        var text: String
        var segments: [Any] = []
        var startTime: Date
        var endTime: Date
        var audioSamples: [Float]  // 16 kHz Float32, shared with SpeakerKit
    }

    var onTranscription: ((TranscriptionWindow) -> Void)?
    var lastTranscription: String = ""

    // ── Configuration ──────────────────────────────────────────────

    /// Seconds of silence before flushing the buffer to WhisperKit.
    /// Matches AudioCaptureService's silenceFlushSeconds for consistency.
    private let silenceFlushSeconds: Double = 4.0

    /// Hard cap — flush regardless after this many seconds of audio.
    private let maxWindowSeconds: Double = 90.0

    /// Minimum audio to transcribe. Short utterances (0.5–3s) like
    /// "she pooped" or "he's awake" are still valid baby events.
    private let minWindowSeconds: Double = 0.5

    /// RMS energy threshold for speech detection at 16 kHz.
    /// Mapped from AppConfig.silenceThreshold (tuned for 48 kHz speech band).
    private let speechThreshold: Float = 0.01
    /// Exposed for logging by OnDevicePipeline.
    var speechThresholdForLogging: Float { speechThreshold }

    private let sampleRate: Double = 16000

    // ── State ──────────────────────────────────────────────────────

    /// Accumulated 16 kHz Float32 audio samples during speech.
    private var buffer: [Float] = []

    /// When the current buffer started accumulating.
    private var bufferStartTime: Date = Date()

    /// Whether we're currently in a speech region.
    private var isSpeechActive: Bool = false

    /// How many consecutive silent buffers we've seen.
    /// Each feedAudio call is one "buffer" (~85ms at 48 kHz → ~28ms at 16 kHz after resample).
    private var silentBufferCount: Int = 0

    /// Buffers of silence needed to trigger flush.
    /// silenceFlushSeconds / bufferDuration ≈ 4.0 / 0.028 ≈ 143 buffers
    /// But we check per feedAudio call which is ~85ms → 4.0 / 0.085 ≈ 47
    private var silenceBuffersNeeded: Int { Int(silenceFlushSeconds / 0.085) }

    /// Is a transcription task already running? Prevents overlap.
    private var isTranscribing: Bool = false

    #if canImport(WhisperKit)
    /// The WhisperKit instance — initialized once via loadModel().
    private var whisperKit: WhisperKit?
    #endif

    /// Whether the model is loaded and ready to transcribe.
    var isModelReady: Bool = false

    // MARK: - Lifecycle

    init() {}

    /// Download (if needed) and load the Whisper model. Call once on pipeline start.
    func loadModel() async throws {
        #if canImport(WhisperKit)
        let config = WhisperKitConfig(
            model: "base",           // ~75 MB, good balance of speed/accuracy
            verbose: false,
            download: true           // download from Hugging Face if not cached
        )
        let kit = try await WhisperKit(config)
        whisperKit = kit
        isModelReady = true
        NSLog("[WhisperKit] Model loaded successfully")
        #endif
    }

    func reset() {
        buffer.removeAll()
        lastTranscription = ""
        isSpeechActive = false
        silentBufferCount = 0
        bufferStartTime = Date()
    }

    // MARK: - Audio input

    /// Feed a raw audio buffer from AVAudioEngine (48 kHz Float32 mono).
    func feedAudio(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }
        let frameLength = Int(pcmBuffer.frameLength)
        let rawSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        // Resample 48 kHz → 16 kHz
        // Convert Float32 → Int16 → resample (AudioResampler expects Int16)
        let int16Samples = rawSamples.map { Int16(max(-1.0, min(1.0, $0)) * 32767) }
        let resampled = AudioResampler.resample48to16(samples: int16Samples)
        guard !resampled.isEmpty else { return }

        // Check energy (simple RMS on 16 kHz samples)
        let energy = rmsEnergy(resampled)
        let hasSpeech = energy >= speechThreshold

        if hasSpeech {
            silentBufferCount = 0

            if !isSpeechActive {
                isSpeechActive = true
                bufferStartTime = Date()
                NSLog("[WhisperKit] 🟢 Speech started — energy=\(String(format: "%.4f", energy)) (threshold=\(String(format: "%.4f", speechThreshold)))")
            }

            buffer.append(contentsOf: resampled)
        } else {
            if isSpeechActive {
                buffer.append(contentsOf: resampled)
                silentBufferCount += 1

                if silentBufferCount >= silenceBuffersNeeded {
                    let dur = String(format: "%.1f", Double(buffer.count) / sampleRate)
                    NSLog("[WhisperKit] 🔴 Speech ended — \(dur)s accumulated, flushing after \(String(format: "%.1f", silenceFlushSeconds))s silence")
                    flushIfReady()
                }
            }
        }

        let bufferDuration = Double(buffer.count) / sampleRate
        if bufferDuration >= maxWindowSeconds {
            NSLog("[WhisperKit] ⚠️ Hard cap reached — \(String(format: "%.0f", maxWindowSeconds))s, force flushing")
            flushIfReady()
        }
    }

    // MARK: - Flush & transcribe

    private func flushIfReady() {
        let bufferDuration = Double(buffer.count) / sampleRate

        // Reset speech state
        isSpeechActive = false
        silentBufferCount = 0

        guard bufferDuration >= minWindowSeconds else {
            NSLog("[WhisperKit] ⏭️ Skipped — too short (\(String(format: "%.1f", bufferDuration))s < \(minWindowSeconds)s min)")
            buffer.removeAll()
            return
        }

        guard !isTranscribing else {
            NSLog("[WhisperKit] ⏳ Skipped — already transcribing, will retry next flush")
            return
        }

        let windowSamples = buffer
        let windowStart = bufferStartTime
        let windowEnd = Date()
        buffer.removeAll()

        isTranscribing = true
        let dur = String(format: "%.1f", Double(windowSamples.count) / sampleRate)
        NSLog("[WhisperKit] 🎯 Transcribing \(dur)s of audio (\(windowSamples.count) samples)...")

        Task.detached { [weak self] in
            guard let self else { return }
            await self.transcribe(
                samples: windowSamples,
                startTime: windowStart,
                endTime: windowEnd
            )
            await MainActor.run { self.isTranscribing = false }
        }
    }

    private func transcribe(
        samples: [Float],
        startTime: Date,
        endTime: Date
    ) async {
        #if canImport(WhisperKit)
        guard let kit = whisperKit else {
            NSLog("[WhisperKit] Model not loaded — skipping transcription")
            return
        }

        do {
            let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples)
            let text = results
                .compactMap { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            NSLog("[WhisperKit] ✅ Transcription complete — \(results.count) segments, text='\(text.prefix(100))'")
            guard !text.isEmpty else {
                NSLog("[WhisperKit] ℹ️ Empty transcription — likely noise or music")
                return
            }

            let tw = TranscriptionWindow(
                text: text,
                startTime: startTime,
                endTime: endTime,
                audioSamples: samples
            )
            await MainActor.run { [weak self] in
                self?.lastTranscription = text
                self?.onTranscription?(tw)
            }
        } catch {
            NSLog("[WhisperKit] Transcription failed: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - VAD helper

    /// Compute RMS energy of a Float32 audio buffer.
    private func rmsEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }
}
#endif
