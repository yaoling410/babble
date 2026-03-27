import Accelerate
import AVFoundation
import Speech

// ============================================================
//  SpeakerRoleDetector — infer speaker label from voice recording
// ============================================================
//
//  Two-stage approach:
//
//  Stage 1 — KEYWORD  (high confidence, ~0.9)
//  Scan the transcript for explicit role mentions:
//    "this is Mom" / "I am Linda" / "I'm Grandpa" / "call me Nana"
//  Catches both role labels (Mom/Dad/Grandma/Grandpa) and first names
//  (Linda, Mike, …). Role keywords are matched before raw names so
//  "I'm Grandma Linda" → "Grandma", not "Linda".
//
//  Stage 2 — PITCH  (lower confidence, ~0.5)
//  Uses SFVoiceAnalytics (iOS 13+) to measure average fundamental
//  frequency across all voiced frames of the recording.
//    > 160 Hz  → female voice → "Mom"
//    ≤ 160 Hz  → male voice   → "Dad"
//  Pitch alone is used only when no keyword matched.
//
//  The two stages are combined in `detect(from:babyName:)`.
//  Callers get a `Detection` with the inferred label and confidence
//  so the UI can decide how prominently to show it.

struct SpeakerRoleDetector {

    struct Detection {
        let label: String
        /// 0–1: how confident we are (used by UI to colour the chip)
        let confidence: Float
        let source: Source

        enum Source {
            case roleKeyword    // "this is Mom", "I'm Grandma"
            case firstPerson    // "I am Linda", "my name is Mike"
            case pitch          // pitch only, no keyword found
        }
    }

    /// Main entry point — pass the final SFSpeechRecognitionResult.
    /// `babyName` is excluded from first-person name extraction.
    static func detect(from result: SFSpeechRecognitionResult, babyName: String = "") -> Detection? {
        let transcript = result.bestTranscription.formattedString
        let pitch = averagePitch(from: result)

        // --- Stage 1a: role keyword match ("this is Mom", standalone "Mom") ---
        if let role = roleKeywordMatch(in: transcript) {
            return Detection(label: role, confidence: 0.9, source: .roleKeyword)
        }

        // --- Stage 1b: first-person name ("I am Linda", "my name is Mike") ---
        if let name = firstPersonName(in: transcript, excluding: babyName) {
            return Detection(label: name, confidence: 0.75, source: .firstPerson)
        }

        // --- Stage 2: pitch fallback — male → Dad, female → Mom ---
        if let pitch {
            let label = pitch > 160 ? "Mom" : "Dad"
            return Detection(label: label, confidence: 0.5, source: .pitch)
        }

        return nil
    }

    // ----------------------------------------------------------------
    //  Stage 1a — role keyword matching
    // ----------------------------------------------------------------

    // Ordered by specificity (grandparents before parents to avoid
    // "grandma" being partially matched by a "mom" rule).
    private static let roleKeywords: [(keywords: [String], label: String)] = [
        (["grandma", "grandmother", "nana", "granny", "nonna", "baba", "abuela", "abuelita"], "Grandma"),
        (["grandpa", "grandfather", "grandad", "granddad", "gramps", "nonno", "abuelo"], "Grandpa"),
        (["mom", "mama", "mum", "mommy", "mummy", "mother"], "Mom"),
        (["dad", "daddy", "papa", "father", "baba"], "Dad"),
    ]

    private static func roleKeywordMatch(in transcript: String) -> String? {
        let lower = transcript.lowercased()

        // Phrased introductions first (most reliable)
        for (keywords, label) in roleKeywords {
            for kw in keywords {
                let introductions = [
                    "this is \(kw)", "i am \(kw)", "i'm \(kw)",
                    "my name is \(kw)", "call me \(kw)",
                ]
                for intro in introductions where lower.contains(intro) {
                    return label
                }
            }
        }

        // Standalone keyword — someone who just says "Hey Luca, it's Mom here"
        for (keywords, label) in roleKeywords {
            for kw in keywords where lower.contains(kw) {
                return label
            }
        }
        return nil
    }

    // ----------------------------------------------------------------
    //  Stage 1b — first-person name extraction
    // ----------------------------------------------------------------

    private static func firstPersonName(in transcript: String, excluding babyName: String) -> String? {
        let lower = transcript.lowercased()
        let triggers = ["this is ", "i am ", "i'm ", "my name is ", "call me "]
        var stopWords: Set<String> = ["the", "a", "your", "my", "our", "baby", "here", "just"]
        if !babyName.isEmpty { stopWords.insert(babyName.lowercased()) }

        for trigger in triggers {
            guard let range = lower.range(of: trigger) else { continue }
            let after = String(lower[range.upperBound...])
            let words = after
                .components(separatedBy: CharacterSet.whitespaces.union(.punctuationCharacters))
                .filter { !$0.isEmpty }
            // Reject if the first word is a role keyword (handled by Stage 1a)
            let allRoleKw = roleKeywords.flatMap(\.keywords)
            if let first = words.first, allRoleKw.contains(first) { continue }
            let nameWords = words.prefix(2).filter { !stopWords.contains($0) }
            guard !nameWords.isEmpty else { continue }
            return nameWords.map { $0.capitalized }.joined(separator: " ")
        }
        return nil
    }

    // ----------------------------------------------------------------
    //  Stage 2 — pitch analysis via SFVoiceAnalytics (iOS 13+)
    // ----------------------------------------------------------------

    private static func averagePitch(from result: SFSpeechRecognitionResult) -> Double? {
        var pitchValues: [Double] = []
        for segment in result.bestTranscription.segments {
            guard let analytics = segment.voiceAnalytics else { continue }
            let voicing = analytics.voicing.acousticFeatureValuePerFrame
            let pitches  = analytics.pitch.acousticFeatureValuePerFrame
            for (v, p) in zip(voicing, pitches) where v > 0.5 && p > 50 {
                pitchValues.append(p)
            }
        }
        guard !pitchValues.isEmpty else { return nil }
        return pitchValues.reduce(0, +) / Double(pitchValues.count)
    }

    // ----------------------------------------------------------------
    //  Fallback pitch — read raw WAV and run autocorrelation
    //  Used when ASR is unavailable or returns no voice analytics.
    //
    //  Algorithm: for each 64ms voiced frame, find the peak lag in the
    //  F0 range (80–300 Hz) using vDSP dot-product autocorrelation.
    //  Average F0 > 160 Hz → female ("Mom"), ≤ 160 Hz → male ("Dad").
    // ----------------------------------------------------------------

    /// Estimate average fundamental frequency from an audio file URL.
    /// Returns nil only if the file cannot be read or no voiced frames found.
    static func pitchFromFile(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = Float(format.sampleRate)
        let frameCount = AVAudioFrameCount(min(file.length, 16 * Int64(sampleRate)))  // cap at 16s
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? file.read(into: buffer)) != nil,
              let rawSamples = buffer.floatChannelData?[0] else { return nil }

        let totalSamples = Int(buffer.frameLength)
        let frameSize = 1024                                    // ~64ms at 16 kHz
        let hopSize   = 512
        let minLag    = Int(sampleRate / 300)                   // 300 Hz ceiling
        let maxLag    = Int(sampleRate / 80)                    // 80 Hz floor
        guard maxLag < frameSize else { return nil }

        var pitches: [Double] = []
        var offset = 0

        while offset + frameSize <= totalSamples {
            let frame = Array(UnsafeBufferPointer(start: rawSamples + offset, count: frameSize))

            // Skip silent frames
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frameSize))
            guard rms > 0.008 else { offset += hopSize; continue }

            // Find peak autocorrelation lag in the F0 range using vDSP dot product
            var zeroLagAC: Float = 0
            vDSP_dotpr(frame, 1, frame, 1, &zeroLagAC, vDSP_Length(frameSize))
            guard zeroLagAC > 0 else { offset += hopSize; continue }

            var peakAC: Float = 0
            var peakLag = minLag
            frame.withUnsafeBufferPointer { buf in
                let ptr = buf.baseAddress!
                for lag in minLag...maxLag {
                    var ac: Float = 0
                    vDSP_dotpr(ptr, 1, ptr + lag, 1, &ac, vDSP_Length(frameSize - lag))
                    if ac > peakAC { peakAC = ac; peakLag = lag }
                }
            }

            // Accept only clearly periodic (voiced) frames
            if peakAC > 0.25 * zeroLagAC {
                pitches.append(Double(sampleRate) / Double(peakLag))
            }
            offset += hopSize
        }

        guard !pitches.isEmpty else { return nil }
        // Median is more robust than mean against octave errors
        let sorted = pitches.sorted()
        return sorted[sorted.count / 2]
    }

    /// Pitch-only detection from a file — always returns Mom or Dad.
    static func detectFromFile(_ url: URL) -> Detection {
        let pitch = pitchFromFile(url)
        let label = (pitch ?? 0) > 160 ? "Mom" : "Dad"
        return Detection(label: label, confidence: 0.45, source: .pitch)
    }
}
