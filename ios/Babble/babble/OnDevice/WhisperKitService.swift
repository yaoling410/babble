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

    /// Language setting from BabyProfile.whisperLanguage.
    /// "auto" = auto-detect, "en" = English, "zh" = Chinese, "en+zh" = bilingual, "yue" = Cantonese.
    var language: String = "auto"

    /// Baby's name — used to build the initial prompt that biases WhisperKit
    /// toward correct name transcription and baby-care vocabulary.
    var babyName: String = ""

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
    /// Tuning history:
    ///   0.01 — too low, Whisper hallucinated on fan/AC noise
    ///   0.02 — too high, missed quiet speech
    ///   0.008 — current, catches normal speech, hallucination filter handles edge cases
    private let speechThreshold: Float = 0.008
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
    /// Uses the multilingual "small" model (~244 MB) which supports English + Chinese + 97 other languages.
    /// The "base" model is English-only and won't transcribe Chinese.
    func loadModel() async throws {
        #if canImport(WhisperKit)
        let config = WhisperKitConfig(
            model: "small",          // multilingual, ~244 MB, supports zh/en/etc.
            verbose: false,
            download: true           // download from Hugging Face if not cached
        )
        NSLog("[WhisperKit] Downloading/loading 'small' multilingual model (~244 MB on first launch)...")
        let kit = try await WhisperKit(config)
        whisperKit = kit
        isModelReady = true
        NSLog("[WhisperKit] ✅ Model loaded — multilingual (en, zh, + 97 languages)")
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
            // Language handling for code-switching (e.g. "Luca 拉屎了"):
            //
            // Whisper's detectLanguage picks ONE language per window, then garbles
            // the other. For bilingual households (en+zh), the best strategy is
            // to fix language to "zh" — Whisper handles English names embedded in
            // Chinese sentences much better than the reverse, because:
            //   - English names are common in Chinese speech (proper nouns)
            //   - Chinese words in English context get romanized and lost
            //
            // For pure English or pure Chinese, fix the language for speed + accuracy.
            let fixedLang: String?
            let detect: Bool
            switch language {
            case "en":       fixedLang = "en"; detect = false
            case "zh":       fixedLang = "zh"; detect = false
            case "yue":      fixedLang = "yue"; detect = false
            case "en+zh":    fixedLang = "zh"; detect = false  // Chinese mode handles English names better
            default:         fixedLang = nil; detect = true     // "auto"
            }

            // Build prompt tokens to bias Whisper toward the baby's name and
            // common baby-care vocabulary. This is Whisper's "initial prompt"
            // mechanism — it conditions the decoder so that:
            //   - "路卡" → "Luca" (correct name spelling)
            //   - "拉死了" → "拉屎了" (pooping, not dying)
            //   - Common homophones resolve to baby-care meanings
            let prompt = buildPrompt()
            let tokens: [Int]? = prompt.isEmpty ? nil : kit.tokenizer?.encode(text: prompt)
            if let tokens, !tokens.isEmpty {
                NSLog("[WhisperKit] 📝 Prompt: '\(prompt.prefix(80))' (\(tokens.count) tokens)")
            }

            let options = DecodingOptions(
                language: fixedLang,
                usePrefillPrompt: true,
                detectLanguage: detect,
                wordTimestamps: true,     // needed for SpeakerKit alignment
                promptTokens: tokens
            )
            let results: [TranscriptionResult] = try await kit.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            let text = results
                .compactMap { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            NSLog("[WhisperKit] ✅ Transcription complete — \(results.count) segments, text='\(text.prefix(100))'")
            guard !text.isEmpty else {
                NSLog("[WhisperKit] ℹ️ Empty transcription — likely noise or music")
                return
            }

            // Filter Whisper hallucinations — repetitive garbage characters
            // produced when the model receives noise that passed VAD.
            guard !isHallucination(text) else {
                NSLog("[WhisperKit] 🚫 Hallucination filtered — repetitive/garbage output")
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

    // MARK: - Prompt biasing

    /// Build a conditioning prompt for the Whisper decoder.
    /// Whisper uses this as "previous context" — it biases the model toward
    /// these exact spellings and vocabulary without restricting output.
    ///
    /// Why this works: Whisper's decoder is autoregressive. The prompt tokens
    /// act as if they were transcribed just before this audio segment, so the
    /// model's language model strongly prefers continuations that match the
    /// prompt's vocabulary and style.
    private func buildPrompt() -> String {
        var parts: [String] = []

        // Baby's name — anchor the correct spelling.
        // For bilingual (en+zh), include example code-switching sentences
        // so Whisper learns the pattern "English name + Chinese phrase".
        if !babyName.isEmpty {
            parts.append(babyName)

            // Code-switching examples teach Whisper the common pattern:
            // caregiver says English name then continues in Chinese.
            if language == "en+zh" || language == "auto" || language == "zh" {
                parts.append("\(babyName)拉屎了")
                parts.append("\(babyName)喝奶了")
                parts.append("\(babyName)睡觉了")
                parts.append("\(babyName)哭了")
            }
        }

        // Baby-care vocabulary — biases decoder toward correct homophones.
        //   拉屎 (poop) not 拉死 (pull-dead)
        //   喂奶 (breastfeed) not 喂来
        //   打嗝 (burp) not 打个
        let babyCareZh = "拉屎 拉臭臭 拉粑粑 喂奶 吃奶 打嗝 哄睡 换尿布 尿布 辅食 吐奶 放屁 大便 小便 睡觉 醒了 哭了 发烧 洗澡"
        let babyCareEn = "pooping diaper feeding nap burp crying formula breastfeeding sleeping woke up"

        switch language {
        case "en":
            parts.append(babyCareEn)
        case "zh", "yue":
            parts.append(babyCareZh)
        default: // "auto", "en+zh"
            parts.append(babyCareZh)
            parts.append(babyCareEn)
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Hallucination filter

    /// Detect Whisper hallucinations: repetitive characters, garbage output,
    /// bracket-wrapped tokens like "[끝]", or text in a wrong script.
    private func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }

        // Check 1: Bracket-wrapped tokens — "[끝]", "[음악]", "(music)", etc.
        // Whisper emits these as non-speech markers; they're never real transcription.
        let stripped = trimmed
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)
        if stripped.count <= 4 && trimmed.contains("[") { return true }

        // Check 2: Character diversity — hallucinations repeat the same few chars.
        let uniqueChars = Set(trimmed)
        let diversityRatio = Double(uniqueChars.count) / Double(trimmed.count)
        if diversityRatio < 0.15 { return true }

        // Check 3: Runs of 5+ identical characters — "aaaaa" or "ლლლლლ"
        var maxRun = 1
        var currentRun = 1
        var prev: Character = " "
        for ch in trimmed {
            if ch == prev { currentRun += 1 } else { currentRun = 1 }
            maxRun = max(maxRun, currentRun)
            prev = ch
        }
        if maxRun >= 5 { return true }

        // Check 4: Script validation — only count actual letters, not punctuation/brackets.
        // Punctuation like "[" is ASCII but shouldn't make Korean text "pass" as Latin.
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let hasLatin = letters.contains { ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) }
        let hasCJK = letters.contains { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) }

        switch language {
        case "en":
            if !hasLatin { return true }
        case "zh", "yue":
            if !hasCJK { return true }
        case "en+zh", "auto":
            if !hasLatin && !hasCJK { return true }
        default:
            if !hasLatin && !hasCJK { return true }
        }

        return false
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
