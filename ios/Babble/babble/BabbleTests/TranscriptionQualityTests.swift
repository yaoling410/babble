import XCTest
import AVFoundation
import Speech
@testable import babble

/// Integration tests that synthesize speech → save WAV → transcribe → check keyword coverage.
///
/// WAV files are saved to ~/Documents/BabbleTestAudio/ so you can listen to them
/// and verify the voice quality used for transcription testing.
///
/// Run on a real device or simulator with Speech Recognition permission granted.
final class TranscriptionQualityTests: XCTestCase {

    // MARK: - Test cases

    private let testPhrases: [(phrase: String, mustContain: [String])] = [
        ("Luca just finished his bottle", ["luca", "bottle"]),
        ("She is nursing right now", ["nursing"]),
        ("He is hungry and crying", ["hungry", "crying"]),
        ("Time to give the formula", ["formula"]),
        ("He spit up after eating", ["spit", "eating"]),
        ("Luca fell asleep in the crib", ["luca", "asleep", "crib"]),
        ("She just woke up from her nap", ["woke", "nap"]),
        ("He seems really tired and drowsy", ["tired"]),
        ("Put her down for bedtime", ["bedtime"]),
        ("Need to change his diaper", ["diaper"]),
        ("He just pooped", ["pooped"]),
        ("She has a fever", ["fever"]),
        ("Gave him some Tylenol", ["tylenol"]),
        ("Teething again won't stop crying", ["teething", "crying"]),
        ("Runny nose and congestion", ["nose", "congestion"]),
        ("Luca smiled at me today", ["luca", "smiled"]),
        ("He started crawling this morning", ["crawling"]),
        ("She took her first steps", ["steps"]),
        ("He waved goodbye for the first time", ["waved", "first"]),
        ("Doing tummy time right now", ["tummy"]),
        ("Playing with her toys outside", ["playing", "toys"]),
    ]

    // MARK: - Generate audio files

    /// Synthesizes all test phrases and saves them as WAV files.
    /// Check ~/Documents/BabbleTestAudio/ after running this test.
    func testGenerateAudioFiles() async throws {
        let outputDir = audioOutputDir()
        print("\n📁 Audio files saved to: \(outputDir.path)\n")

        for (index, testCase) in testPhrases.enumerated() {
            let buffers = try await synthesize(phrase: testCase.phrase)
            guard !buffers.isEmpty, let format = buffers.first?.format else {
                print("  ⚠️ No audio for: \"\(testCase.phrase)\"")
                continue
            }

            let safeName = testCase.phrase
                .lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .filter { $0.isLetter || $0 == "_" }
                .prefix(40)
            let filename = String(format: "%02d_%@.wav", index + 1, safeName)
            let fileURL = outputDir.appendingPathComponent(filename)

            try saveBuffers(buffers, format: format, to: fileURL)
            print("  ✅ \(filename)")
        }

        print("\nDone. Open the folder in Finder to listen:\n  open \"\(outputDir.path)\"\n")
    }

    // MARK: - Transcription coverage

    func testTranscriptionCoverage() async throws {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw XCTSkip("Speech recognition not authorized — grant in Settings > Privacy > Speech Recognition")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw XCTSkip("SFSpeechRecognizer not available")
        }

        var passed = 0
        var failed: [(phrase: String, transcript: String, missing: [String])] = []

        for testCase in testPhrases {
            let buffers = try await synthesize(phrase: testCase.phrase)
            let transcript = try await transcribe(buffers: buffers, recognizer: recognizer)
            let lower = transcript.lowercased()
            let missing = testCase.mustContain.filter { !lower.contains($0) }

            if missing.isEmpty {
                passed += 1
                print("  ✅ \"\(testCase.phrase)\"")
                print("     → \"\(transcript)\"")
            } else {
                failed.append((testCase.phrase, transcript, missing))
                print("  ❌ \"\(testCase.phrase)\"")
                print("     → \"\(transcript)\"")
                print("     Missing: \(missing.joined(separator: ", "))")
            }
        }

        let coverage = Double(passed) / Double(testPhrases.count) * 100
        print("\n──────────────────────────────────────────")
        print("Coverage: \(passed)/\(testPhrases.count) (\(String(format: "%.0f", coverage))%)")
        print("──────────────────────────────────────────\n")

        XCTAssertGreaterThanOrEqual(
            coverage, 70.0,
            "Transcription coverage \(String(format: "%.0f", coverage))% is below 70%. See console for failed cases."
        )
    }

    // MARK: - Single-keyword solo test

    func testKeywordSoloRecognition() async throws {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw XCTSkip("Not authorized") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw XCTSkip("Not available") }

        let keywords = ["bottle", "nursing", "formula", "nap", "diaper",
                        "fever", "teething", "crawling", "milestone", "tummy time", "fussy"]

        print("\n── Keyword solo recognition ──")
        for kw in keywords {
            let buffers = try await synthesize(phrase: kw)
            let transcript = try await transcribe(buffers: buffers, recognizer: recognizer)
            let recognized = transcript.lowercased().contains(kw.lowercased())
            print("  \(recognized ? "✅" : "❌")  \"\(kw)\"  →  \"\(transcript)\"")
        }
        print("─────────────────────────────\n")
    }

    // MARK: - Synthesize helper

    private func synthesize(phrase: String) async throws -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.45
        utterance.volume = 1.0

        let synthesizer = AVSpeechSynthesizer()
        var buffers: [AVAudioPCMBuffer] = []
        let done = DispatchSemaphore(value: 0)

        synthesizer.write(utterance) { buffer in
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                buffers.append(pcm)
            } else if buffer is AVAudioPCMBuffer {
                // Empty buffer signals end of synthesis
                done.signal()
            }
        }

        // Wait up to 5s for synthesis to complete
        _ = done.wait(timeout: .now() + 5)
        return buffers
    }

    // MARK: - Transcribe helper

    private func transcribe(buffers: [AVAudioPCMBuffer], recognizer: SFSpeechRecognizer) async throws -> String {
        guard !buffers.isEmpty else { return "" }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        for buffer in buffers { request.append(buffer) }
        request.endAudio()

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    let partial = result?.bestTranscription.formattedString ?? ""
                    if partial.isEmpty {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: partial)
                    }
                }
            }
        }
    }

    // MARK: - Save WAV helper

    private func saveBuffers(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for buffer in buffers {
            try file.write(from: buffer)
        }
    }

    private func audioOutputDir() -> URL {
        // Try Desktop first (works on simulator), fall back to Documents (device)
        let desktop = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/BabbleTestAudio")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BabbleTestAudio")
        let dir = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Desktop") ? desktop : docs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
