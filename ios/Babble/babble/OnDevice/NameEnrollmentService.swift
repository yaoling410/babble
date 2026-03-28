import Foundation
import AVFoundation
import Accelerate

// ============================================================
//  NameEnrollmentService — Discover all ASR variants of the baby's name
// ============================================================
//
//  Records the user saying the baby's name, then runs WhisperKit
//  once per configured language to harvest all plausible text
//  interpretations. These variants are used as:
//    - WhisperKit prompt bias (so it recognizes the name)
//    - Foundation Models correction hints (so it maps mishearings)
//    - RelevanceGate aliases (so it triggers on any variant)
//
//  When the user changes language settings, the saved audio is
//  re-decoded with the new languages to regenerate variants.

#if BABBLE_ON_DEVICE
#if canImport(WhisperKit)
import WhisperKit
#endif

@available(iOS 26.0, *)
enum NameEnrollmentService {

    /// Run WhisperKit on enrollment audio once per language to discover name variants.
    /// Returns deduplicated, cleaned list of all text interpretations.
    ///
    /// Strategy: one transcription per language (not per temperature).
    /// Different languages produce different character interpretations of the
    /// same audio — that's exactly what we want.
    /// For a bilingual en+zh user: 3 runs (en, zh, auto) on a 2-3s clip ≈ <2s total.
    static func discoverVariants(
        audioSamples: [Float],    // 16 kHz Float32 mono
        whisperKit: WhisperKit,
        languages: [String],      // e.g. ["en", "zh"]
        typedName: String         // the name as typed by the user
    ) async -> [String] {
        var allTexts: [String] = []

        // Run once per language + once with auto-detect
        var languagesToTry = languages
        if !languagesToTry.contains("auto") {
            languagesToTry.append("auto")
        }

        for lang in languagesToTry {
            let fixedLang: String? = (lang == "auto") ? nil : lang
            let detect = (lang == "auto")

            let options = DecodingOptions(
                language: fixedLang,
                temperature: 0.2,       // slight variation for diverse outputs
                topK: 5,
                usePrefillPrompt: false, // no prompt bias — we want raw interpretations
                detectLanguage: detect,
                skipSpecialTokens: true,
                wordTimestamps: false,   // not needed for enrollment
                compressionRatioThreshold: 5.0, // very relaxed — short name clips are repetitive
                noSpeechThreshold: 0.9
            )

            do {
                let results = try await whisperKit.transcribe(
                    audioArray: audioSamples,
                    decodeOptions: options
                )
                for result in results {
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        allTexts.append(text)
                        NSLog("[NameEnroll] lang=\(lang) → '\(text)'")
                    }
                }
            } catch {
                NSLog("[NameEnroll] lang=\(lang) failed: \(error.localizedDescription)")
            }
        }

        return cleanVariants(allTexts, typedName: typedName)
    }

    /// Re-decode a saved enrollment WAV with new languages.
    static func regenerateVariants(
        audioPath: URL,
        whisperKit: WhisperKit,
        languages: [String],
        typedName: String
    ) async -> [String] {
        // Load WAV and convert to 16 kHz Float32
        let samples = AudioResampler.resample48to16(wavData: (try? Data(contentsOf: audioPath)) ?? Data())
        guard !samples.isEmpty else {
            NSLog("[NameEnroll] Failed to load audio from \(audioPath.lastPathComponent)")
            return []
        }
        return await discoverVariants(
            audioSamples: samples,
            whisperKit: whisperKit,
            languages: languages,
            typedName: typedName
        )
    }

    /// Expand a whisperLanguage setting into individual language codes.
    /// "en+zh" → ["en", "zh"], "auto" → ["en", "zh"], "en" → ["en"]
    static func languageCodes(from whisperLanguage: String) -> [String] {
        switch whisperLanguage {
        case "en":      return ["en"]
        case "zh":      return ["zh"]
        case "yue":     return ["yue"]
        case "en+zh":   return ["en", "zh"]
        case "auto":    return ["en", "zh"]  // default to both for max coverage
        default:        return ["en"]
        }
    }

    // MARK: - Persistence

    /// Save enrollment audio to a permanent location.
    /// Returns the file URL.
    static func saveEnrollmentAudio(_ audioData: Data) -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Babble/enrollment", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("name.wav")
        do {
            try audioData.write(to: url, options: .atomic)
            NSLog("[NameEnroll] Saved enrollment audio to \(url.lastPathComponent)")
            return url
        } catch {
            NSLog("[NameEnroll] Failed to save: \(error)")
            return nil
        }
    }

    // MARK: - Cleaning

    /// Deduplicate, normalize, and filter variants.
    private static func cleanVariants(_ texts: [String], typedName: String) -> [String] {
        let typedLower = typedName.lowercased()

        var seen: Set<String> = [typedLower]  // exclude the typed name itself (already known)
        var result: [String] = []

        for text in texts {
            // Normalize: lowercase, trim, remove trailing punctuation
            let cleaned = text
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

            guard cleaned.count >= 2 else { continue }       // too short
            guard !seen.contains(cleaned) else { continue }  // duplicate
            guard !isGarbage(cleaned) else { continue }       // noise

            seen.insert(cleaned)
            result.append(cleaned)
        }

        NSLog("[NameEnroll] Discovered \(result.count) variants for '\(typedName)': \(result)")
        return result
    }

    /// Filter obvious garbage from enrollment results.
    private static func isGarbage(_ text: String) -> Bool {
        // Pure punctuation/symbols
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.isEmpty { return true }

        // Repetitive characters
        let unique = Set(text)
        if Double(unique.count) / Double(text.count) < 0.2 { return true }

        return false
    }
}
#endif
