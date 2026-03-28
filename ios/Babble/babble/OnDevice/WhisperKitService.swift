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
        /// Gaps > 1s within the window — [(offset in seconds from startTime, gap duration)]
        var gaps: [(offsetSeconds: Double, gapSeconds: Double)] = []
    }

    var onTranscription: ((TranscriptionWindow) -> Void)?
    var lastTranscription: String = ""

    /// Name variants from enrollment — used in prompt biasing.
    var nameVariants: [String] = []

    /// Expose WhisperKit instance for name enrollment (read-only).
    #if canImport(WhisperKit)
    var whisperKitInstance: WhisperKit? { whisperKit }
    #endif

    /// Language setting from BabyProfile.whisperLanguage.
    /// "auto" = auto-detect, "en" = English, "zh" = Chinese, "en+zh" = bilingual, "yue" = Cantonese.
    var language: String = "auto"

    /// Baby's name — used to build the initial prompt that biases WhisperKit
    /// toward correct name transcription and baby-care vocabulary.
    var babyName: String = ""

    /// Baby's age in months — selects age-appropriate vocabulary for prompt biasing.
    var ageMonths: Int = 0

    // ── Configuration ──────────────────────────────────────────────

    /// Seconds of silence before flushing the buffer to WhisperKit.
    /// Shorter = less trailing silence for Whisper to hallucinate on.
    /// 4s still gives speakers time to pause mid-thought.
    private let silenceFlushSeconds: Double = 4.0

    /// Hard cap — flush regardless after this many seconds of audio.
    /// Whisper's internal context window is 30s. Longer audio gets chunked
    /// and the base model loses content at chunk boundaries.
    /// 30s ensures one clean pass with no truncation.
    private let maxWindowSeconds: Double = 30.0

    /// Minimum audio to transcribe.
    private let minWindowSeconds: Double = 0.5

    /// RMS energy threshold for speech detection at 16 kHz.
    /// Tuning history:
    ///   0.01 — Whisper hallucinated on fan/AC noise
    ///   0.02 — missed quiet speech entirely
    ///   0.008 — missed quiet speech (energy 0.005-0.008 during normal talking)
    ///   0.004 — missed quieter speech
    ///   0.002 — missed some speech
    ///   0.001 — current, extremely sensitive, LLM filters out noise
    private let speechThreshold: Float = 0.001
    /// Exposed for logging by OnDevicePipeline.
    var speechThresholdForLogging: Float { speechThreshold }

    private let sampleRate: Double = 16000

    // ── Three-layer VAD state machine ─────────────────────────────
    //
    // Industry-standard asymmetric hysteresis: fast to start, slow to stop.
    //
    //   Layer 1 — Onset:    2 consecutive buffers (~170ms) above threshold
    //                       → transition from SILENT to SPEAKING
    //   Layer 2 — Hold-open: once SPEAKING, stay active for at least 500ms
    //                       regardless of energy dips (bridges inter-word gaps)
    //   Layer 3 — Offset:   after hold-open, 500ms of continuous silence
    //                       → transition from SPEAKING to TRAILING
    //             Flush:    4s of silence in TRAILING → flush to WhisperKit
    //
    //   SILENT ──(onset 170ms)──→ SPEAKING ──(offset 500ms)──→ TRAILING ──(flush 4s)──→ SILENT
    //                               ↑                              │
    //                               └──── (speech resumes) ────────┘

    private enum VADState {
        case silent     // no speech detected
        case speaking   // confirmed speech, accumulating audio
        case trailing   // speech ended, waiting to see if more comes
    }

    // ── Audio buffer ────────────────────────────────────────────

    private var buffer: [Float] = []
    private var bufferStartTime: Date = Date()

    // ── VAD state ───────────────────────────────────────────────

    private var vadState: VADState = .silent
    private var isTranscribing: Bool = false

    // Layer 1: Onset — consecutive frames above threshold to confirm speech
    private let onsetBuffers = 2                // ~170ms (minimum syllable)
    private var consecutiveSpeechCount = 0

    // Layer 2: Hold-open — minimum speaking duration, bridges inter-word gaps
    private let holdOpenSeconds: Double = 0.5   // 500ms (WebRTC-style)
    private var speechStartedAt: Date = .distantPast

    // Layer 3: Offset — continuous silence to end speech segment
    private let offsetSeconds: Double = 0.5     // 500ms before declaring speech ended
    private var consecutiveSilenceCount = 0
    private var offsetBuffersNeeded: Int { Int(offsetSeconds / 0.085) }

    // Flush: long silence to send buffer to WhisperKit
    private var silenceBuffersNeeded: Int { Int(silenceFlushSeconds / 0.085) }

    // ── Gap tracking ────────────────────────────────────────────

    private var gapMarkers: [(sampleOffset: Int, gapSeconds: Double)] = []
    private let gapThresholdSeconds: Double = 1.0
    private var gapBuffersNeeded: Int { Int(gapThresholdSeconds / 0.085) }

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
            model: "base",           // multilingual, ~142 MB, good accuracy + speed balance
            verbose: false,
            download: true           // download from Hugging Face if not cached
        )
        NSLog("[WhisperKit] Downloading/loading 'base' multilingual model (~142 MB on first launch)...")
        let kit = try await WhisperKit(config)
        whisperKit = kit
        isModelReady = true
        NSLog("[WhisperKit] ✅ Model loaded — multilingual (en, zh, + 97 languages)")
        #endif
    }

    func reset() {
        buffer.removeAll()
        lastTranscription = ""
        vadState = .silent
        consecutiveSpeechCount = 0
        consecutiveSilenceCount = 0
        speechStartedAt = .distantPast
        gapMarkers.removeAll()
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

        // ── Three-layer VAD ──────────────────────────────────────
        let energy = rmsEnergy(resampled)
        let hasSpeech = energy >= speechThreshold

        if hasSpeech {
            consecutiveSpeechCount += 1
            consecutiveSilenceCount = 0
        } else {
            consecutiveSpeechCount = 0
            consecutiveSilenceCount += 1
        }

        switch vadState {
        case .silent:
            // Layer 1 — Onset: need N consecutive speech buffers to confirm
            if consecutiveSpeechCount >= onsetBuffers {
                vadState = .speaking
                speechStartedAt = Date()
                bufferStartTime = Date()
                gapMarkers.removeAll()
                buffer.append(contentsOf: resampled)
                NSLog("[WhisperKit] 🟢 Speech started — energy=\(String(format: "%.4f", energy)) (threshold=\(String(format: "%.4f", speechThreshold)))")
            }
            // In .silent, do NOT append to buffer — saves memory

        case .speaking:
            // Always append audio while speaking (even silence dips)
            buffer.append(contentsOf: resampled)

            // Layer 2 — Hold-open: stay in .speaking for at least holdOpenSeconds
            let elapsed = Date().timeIntervalSince(speechStartedAt)
            if elapsed < holdOpenSeconds {
                // Within hold-open window — ignore silence, keep accumulating
                break
            }

            // Past hold-open: check Layer 3 — Offset
            if !hasSpeech && consecutiveSilenceCount >= offsetBuffersNeeded {
                // 500ms of silence after hold-open → transition to trailing
                vadState = .trailing
                NSLog("[WhisperKit] 🟡 Speech paused — \(String(format: "%.1f", elapsed))s spoken, entering trailing silence")
            }

        case .trailing:
            // Still append audio (captures tail end + any resumed speech)
            buffer.append(contentsOf: resampled)

            if hasSpeech && consecutiveSpeechCount >= onsetBuffers {
                // Speech resumed! Record a gap marker if silence was > 1s
                if consecutiveSilenceCount >= gapBuffersNeeded {
                    let gapDuration = Double(consecutiveSilenceCount) * 0.085
                    gapMarkers.append((sampleOffset: buffer.count, gapSeconds: gapDuration))
                }
                // Back to speaking
                vadState = .speaking
                speechStartedAt = Date()  // reset hold-open for this new segment
                NSLog("[WhisperKit] 🟢 Speech resumed after \(String(format: "%.1f", Double(consecutiveSilenceCount) * 0.085))s gap")
            } else if consecutiveSilenceCount >= silenceBuffersNeeded {
                // Flush timer expired — send to WhisperKit
                let dur = String(format: "%.1f", Double(buffer.count) / sampleRate)
                NSLog("[WhisperKit] 🔴 Speech ended — \(dur)s accumulated, \(gapMarkers.count) gaps, flushing after \(String(format: "%.1f", silenceFlushSeconds))s silence")
                flushIfReady()
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

        // Reset VAD state
        vadState = .silent
        consecutiveSpeechCount = 0
        consecutiveSilenceCount = 0

        guard bufferDuration >= minWindowSeconds else {
            NSLog("[WhisperKit] ⏭️ Skipped — too short (\(String(format: "%.1f", bufferDuration))s < \(minWindowSeconds)s min)")
            buffer.removeAll()
            gapMarkers.removeAll()
            return
        }

        guard !isTranscribing else {
            // Buffer is kept. Inject 0.5s of silence so WhisperKit sees a
            // natural pause between the two speech segments, and record a
            // gap marker with timestamp for downstream processing.
            let silenceSamples = Int(0.5 * sampleRate)
            let silence = [Float](repeating: 0, count: silenceSamples)
            gapMarkers.append((sampleOffset: buffer.count, gapSeconds: silenceFlushSeconds))
            buffer.append(contentsOf: silence)
            NSLog("[WhisperKit] ⏳ Skipped — already transcribing. Injected 0.5s silence + gap marker at \(String(format: "%.1f", Double(buffer.count) / sampleRate))s. Buffer kept for next flush.")
            return
        }

        // Trim trailing silence so Whisper gets a dense speech signal.
        let trimmed = trimTrailingSilence(buffer)

        // Peak-normalize to -3 dB so quiet speech (whispering to baby)
        // hits Whisper at a consistent level.
        let windowSamples = peakNormalize(trimmed, targetDB: -3.0)
        let windowStart = bufferStartTime
        let windowEnd = Date()
        let windowGaps = gapMarkers.map { marker -> (offsetSeconds: Double, gapSeconds: Double) in
            (offsetSeconds: Double(marker.sampleOffset) / sampleRate, gapSeconds: marker.gapSeconds)
        }
        buffer.removeAll()
        gapMarkers.removeAll()

        isTranscribing = true
        let dur = String(format: "%.1f", Double(windowSamples.count) / sampleRate)
        NSLog("[WhisperKit] 🎯 Transcribing \(dur)s of audio (\(windowSamples.count) samples)...")

        Task.detached { [weak self] in
            guard let self else {
                NSLog("[WhisperKit] ⚠️ self deallocated — transcription dropped")
                return
            }
            await self.transcribe(
                samples: windowSamples,
                startTime: windowStart,
                endTime: windowEnd,
                gaps: windowGaps
            )
            await MainActor.run {
                self.isTranscribing = false
                NSLog("[WhisperKit] 🔓 isTranscribing reset to false")
            }
        }
    }

    private func transcribe(
        samples: [Float],
        startTime: Date,
        endTime: Date,
        gaps: [(offsetSeconds: Double, gapSeconds: Double)] = []
    ) async {
        #if canImport(WhisperKit)
        guard let kit = whisperKit else {
            NSLog("[WhisperKit] ❌ Model not loaded (whisperKit is nil) — skipping transcription")
            return
        }
        NSLog("[WhisperKit] 🔄 Starting WhisperKit.transcribe()...")

        do {
            // Language handling:
            //   "en" / "zh" / "yue" → fixed language (fastest, most accurate for monolingual)
            //   "en+zh" / "auto" → auto-detect per window
            //
            // For bilingual (en+zh), we use auto-detect instead of forcing "zh" because:
            //   - Forcing "zh" garbles pure English sentences ("she had a bottle" → garbage)
            //   - Auto-detect picks the dominant language per window — good enough for
            //     short baby-care utterances that are mostly one language
            //   - The LLM correction step fixes whatever auto-detect gets wrong
            //   - Code-switching within one sentence ("Luca拉屎了") may lose one part,
            //     but the LLM corrector has context to reconstruct it
            let fixedLang: String?
            let detect: Bool
            switch language {
            case "en":       fixedLang = "en"; detect = false
            case "zh":       fixedLang = "zh"; detect = false
            case "yue":      fixedLang = "yue"; detect = false
            default:         fixedLang = nil; detect = true     // "en+zh" and "auto"
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
                temperature: 0.0,
                temperatureIncrementOnFallback: 0.2,
                temperatureFallbackCount: 2,
                usePrefillPrompt: true,
                detectLanguage: detect,
                skipSpecialTokens: true,  // strip <|startoftranscript|> etc. from output
                wordTimestamps: true,
                promptTokens: tokens,
                compressionRatioThreshold: 3.5,
                noSpeechThreshold: 0.8
            )
            // Timeout: if transcription takes > 30s, something is wrong
            let results: [TranscriptionResult] = try await withThrowingTaskGroup(of: [TranscriptionResult].self) { group in
                group.addTask {
                    try await kit.transcribe(audioArray: samples, decodeOptions: options)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                    throw WhisperKitTimeout()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            // ── Segment-level confidence filter ──────────────────
            // Drop segments where Whisper is guessing. This prevents
            // garbage from reaching the FM correction step.
            let filteredResults = filterLowConfidenceSegments(results)

            let text = filteredResults
                .compactMap { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            NSLog("[WhisperKit] ✅ Transcription complete — \(results.count) result(s), text='\(text.prefix(100))'")
            guard !text.isEmpty else {
                NSLog("[WhisperKit] ℹ️ Empty transcription — likely noise or music")
                return
            }

            // Quick sanity check — block pure garbage (repetitive chars, no real script).
            // The Foundation Models correction step handles subtle errors;
            // this only catches the most obvious nonsense to save LLM processing time.
            guard !isObviousGarbage(text) else {
                NSLog("[WhisperKit] 🚫 Obvious garbage filtered — skipping LLM correction")
                return
            }

            // Inject timestamp markers at gaps > 1s
            // e.g. "Luca拉屎了 [+3s] 来吧换尿布" — shows 3s pause between utterances
            let annotatedText: String
            if gaps.isEmpty {
                annotatedText = text
            } else {
                annotatedText = insertGapMarkers(
                    text: text,
                    results: filteredResults,
                    gaps: gaps,
                    windowStart: startTime
                )
                if annotatedText != text {
                    NSLog("[WhisperKit] ⏱️ Gaps annotated: '\(annotatedText.prefix(120))'")
                }
            }

            let tw = TranscriptionWindow(
                text: annotatedText,
                startTime: startTime,
                endTime: endTime,
                audioSamples: samples,
                gaps: gaps
            )
            await MainActor.run { [weak self] in
                self?.lastTranscription = annotatedText
                self?.onTranscription?(tw)
            }
        } catch {
            NSLog("[WhisperKit] ❌ Transcription FAILED: \(error)")
            NSLog("[WhisperKit]    Type: \(type(of: error))")
            NSLog("[WhisperKit]    Description: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Prompt biasing

    /// Build a short conditioning prompt for the Whisper decoder.
    /// IMPORTANT: Keep under 50 tokens. Long prompts (100+) cause Whisper
    /// to emit end-of-text immediately on short utterances, producing empty
    /// transcriptions.
    private func buildPrompt() -> String {
        // ── Token budget ─────────────────────────────────────────
        // IMPORTANT: Total prompt must stay under ~50 tokens.
        // Long prompts (100+) cause Whisper to emit end-of-text
        // immediately on short utterances → empty transcriptions.
        //
        // Budget allocation:
        //   ~3 tokens  — baby name
        //   ~20 tokens — age-specific vocab (language-dependent)
        //   ~20 tokens — previous transcription tail (context)
        //   ≈43 tokens total

        var parts: [String] = []

        // 1. Baby name + enrollment variants.
        //    Include the typed name and top 3 discovered variants so the
        //    decoder is biased toward all known interpretations.
        if !babyName.isEmpty {
            var nameTerms = [babyName]
            nameTerms.append(contentsOf: nameVariants.prefix(3))
            parts.append(nameTerms.joined(separator: ", "))
        }

        // 2. Age-specific vocabulary from AgeDefaults (single source of truth).
        let config = AgeDefaults.eventConfig(ageMonths: ageMonths)
        let zhVocab = config.whisperVocabZh
        let enVocab = config.whisperVocabEn

        switch language {
        case "en":
            parts.append(enVocab)
        case "zh", "yue":
            parts.append(zhVocab)
        case "en+zh", "auto":
            parts.append(zhVocab)
            parts.append(enVocab)
        default:
            parts.append(zhVocab)
        }

        // 3. Previous transcription tail — free accuracy boost.
        //    Cap at 60 chars (~15-20 tokens) to stay within budget.
        if !lastTranscription.isEmpty {
            let tail = String(lastTranscription.suffix(60))
            parts.append(tail)
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Gap marker insertion

    /// Insert "[+Ns]" markers into the transcribed text at positions
    /// where silence gaps > 1s occurred during recording.
    /// Uses WhisperKit's word timestamps to find the right text position.
    private func insertGapMarkers(
        text: String,
        results: [TranscriptionResult],
        gaps: [(offsetSeconds: Double, gapSeconds: Double)],
        windowStart: Date
    ) -> String {
        // Collect all word timings from WhisperKit results
        var wordTimings: [(word: String, start: Float, end: Float)] = []
        for result in results {
            for segment in result.segments {
                for word in segment.words ?? [] {
                    wordTimings.append((word: word.word, start: word.start, end: word.end))
                }
            }
        }

        guard !wordTimings.isEmpty else {
            // No word timings available — insert markers by splitting text proportionally
            return text
        }

        // For each gap, find the word whose end time is closest to the gap offset
        // and insert the marker after that word
        var insertions: [(wordIndex: Int, marker: String)] = []
        for gap in gaps {
            let gapTime = Float(gap.offsetSeconds)
            var bestIndex = 0
            var bestDist: Float = .greatestFiniteMagnitude
            for (i, wt) in wordTimings.enumerated() {
                let dist = abs(wt.end - gapTime)
                if dist < bestDist {
                    bestDist = dist
                    bestIndex = i
                }
            }
            let secs = Int(gap.gapSeconds.rounded())
            if secs >= 1 {
                insertions.append((wordIndex: bestIndex, marker: " [+\(secs)s] "))
            }
        }

        // Build annotated text by reconstructing from word timings with markers
        guard !insertions.isEmpty else { return text }

        let insertionMap = Dictionary(grouping: insertions, by: \.wordIndex)
        var parts: [String] = []
        for (i, wt) in wordTimings.enumerated() {
            parts.append(wt.word)
            if let markers = insertionMap[i] {
                parts.append(markers.first!.marker)
            }
        }
        return parts.joined().trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Errors

    private struct WhisperKitTimeout: Error {
        var localizedDescription: String { "WhisperKit transcription timed out after 30s" }
    }

    // MARK: - Segment confidence filter
    //
    // Whisper assigns each segment an avgLogprob (how confident the decoder
    // is in its token choices) and noSpeechProb (probability the audio is
    // silence/noise). We use both to drop segments Whisper is unsure about
    // BEFORE they reach the FM 3B correction step.
    //
    // Thresholds:
    //   avgLogprob < -1.0  → decoder is guessing (WhisperKit default)
    //   noSpeechProb > 0.6 → likely not speech
    //
    // We filter at the segment level (not result level) so a single bad
    // segment in a multi-segment result doesn't kill the whole window.
    // The surviving segments are reassembled into new TranscriptionResults.

    #if canImport(WhisperKit)
    private func filterLowConfidenceSegments(_ results: [TranscriptionResult]) -> [TranscriptionResult] {
        let logprobThreshold: Float = -1.0
        let noSpeechThreshold: Float = 0.6

        var totalSegments = 0
        var droppedSegments = 0

        for result in results {
            let segments = result.segments
            totalSegments += segments.count

            let kept = segments.filter { seg in
                if seg.avgLogprob < logprobThreshold {
                    NSLog("[WhisperKit] 🚫 Dropped segment (logprob=\(String(format: "%.2f", seg.avgLogprob))): '\(seg.text.prefix(50))'")
                    droppedSegments += 1
                    return false
                }
                if seg.noSpeechProb > noSpeechThreshold {
                    NSLog("[WhisperKit] 🚫 Dropped segment (noSpeech=\(String(format: "%.2f", seg.noSpeechProb))): '\(seg.text.prefix(50))'")
                    droppedSegments += 1
                    return false
                }
                return true
            }

            // Mutate the result's segments and text to only include kept segments
            result.segments = kept
            result.text = kept.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        if droppedSegments > 0 {
            NSLog("[WhisperKit] 🧹 Confidence filter: kept \(totalSegments - droppedSegments)/\(totalSegments) segments")
        }

        return results.filter { !$0.text.isEmpty }
    }
    #endif

    // MARK: - Garbage filter (minimal — LLM correction handles the rest)

    /// Block only the most obvious garbage to avoid wasting LLM processing time.
    /// Subtle errors (wrong characters, hallucinated phrases, name misspellings)
    /// are handled by the Foundation Models correction step in the pipeline.
    private func isObviousGarbage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return true }

        // Repetitive characters: "ლლლლლ", "aaaaaaa"
        let uniqueChars = Set(trimmed)
        if Double(uniqueChars.count) / Double(trimmed.count) < 0.1 { return true }

        // No letters at all (only punctuation/symbols)
        let hasAnyLetter = trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if !hasAnyLetter { return true }

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

    /// Peak-normalize audio to a target dB level using vDSP.
    /// Quiet speech (whispering) gets boosted so Whisper sees consistent levels.
    private func peakNormalize(_ samples: [Float], targetDB: Float) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 1e-6 else { return samples } // silence — skip

        let targetLinear = powf(10.0, targetDB / 20.0) // -3 dB ≈ 0.708
        var gain = targetLinear / peak
        var result = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &gain, &result, 1, vDSP_Length(samples.count))
        if abs(gain - 1.0) > 0.1 {
            NSLog("[WhisperKit] 🔊 Normalized: peak=\(String(format: "%.4f", peak)) gain=\(String(format: "%.2f", gain))x")
        }
        return result
    }

    /// Trim trailing silence from a buffer by scanning backwards in 80ms chunks.
    /// Keeps at least 0.3s of trailing silence as a natural endpoint marker.
    private func trimTrailingSilence(_ samples: [Float]) -> [Float] {
        let chunkSize = Int(0.08 * sampleRate) // 80ms chunks
        let minKeep = Int(0.3 * sampleRate)    // keep at least 0.3s tail
        guard samples.count > minKeep + chunkSize else { return samples }

        var end = samples.count
        // Scan backwards using vDSP directly on the slice — no Array copy per chunk.
        while end > minKeep + chunkSize {
            let chunkStart = end - chunkSize
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buf in
                vDSP_rmsqv(buf.baseAddress! + chunkStart, 1, &rms, vDSP_Length(chunkSize))
            }
            if rms >= speechThreshold { break }
            end = chunkStart
        }
        let trimmedEnd = min(end + minKeep, samples.count)
        if trimmedEnd < samples.count {
            NSLog("[WhisperKit] ✂️ Trimmed \(String(format: "%.1f", Double(samples.count - trimmedEnd) / sampleRate))s trailing silence")
        }
        return Array(samples[0..<trimmedEnd])
    }
}
#endif
