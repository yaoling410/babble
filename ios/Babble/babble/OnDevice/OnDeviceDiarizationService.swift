import Foundation

// ============================================================
//  OnDeviceDiarizationService.swift — On-device speaker diarization
// ============================================================
//
//  Uses SpeakerKit (pyannote CoreML) to identify who spoke when,
//  then matches speaker embeddings against enrolled profiles.

#if BABBLE_ON_DEVICE
import SpeakerKit
import WhisperKit
import Accelerate

@available(iOS 26.0, *)
enum OnDeviceDiarizationService {

    struct DiarizationResult {
        var annotatedTranscript: String
        var segments: [(speaker: String, start: Double, end: Double, text: String)]
        var unknownSpeakers: [(tempLabel: String, start: Double, end: Double)]
    }

    /// Shared SpeakerKit instance — lazy-loaded on first diarization.
    private static var speakerKit: SpeakerKit?

    static func diarize(
        window: WhisperKitService.TranscriptionWindow
    ) async throws -> DiarizationResult {
        // 1. Initialize SpeakerKit if needed
        if speakerKit == nil {
            let config = PyannoteConfig()
            speakerKit = try await SpeakerKit(config)
        }
        guard let kit = speakerKit else {
            return fallbackResult(window: window)
        }

        // 2. Run diarization on 16 kHz audio
        let diarResult = try await kit.diarize(audioArray: window.audioSamples)

        // 3. Build annotated transcript from segments
        var outputSegments: [(speaker: String, start: Double, end: Double, text: String)] = []
        var unknowns: [(tempLabel: String, start: Double, end: Double)] = []
        var transcriptParts: [String] = []

        for segment in diarResult.segments {
            let label = segment.speaker.description
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            transcriptParts.append("[\(label)]: \(text)")
            outputSegments.append((
                speaker: label,
                start: Double(segment.startTime),
                end: Double(segment.endTime),
                text: text
            ))

            unknowns.append((
                tempLabel: label,
                start: Double(segment.startTime),
                end: Double(segment.endTime)
            ))
        }

        let annotated = transcriptParts.joined(separator: " ")

        return DiarizationResult(
            annotatedTranscript: annotated.isEmpty ? window.text : annotated,
            segments: outputSegments,
            unknownSpeakers: unknowns
        )
    }

    // MARK: - Utilities

    /// Cosine similarity between two float vectors (vDSP-accelerated).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Fallback

    private static func fallbackResult(window: WhisperKitService.TranscriptionWindow) -> DiarizationResult {
        let duration = window.endTime.timeIntervalSince(window.startTime)
        return DiarizationResult(
            annotatedTranscript: window.text,
            segments: [(speaker: "unknown", start: 0, end: duration, text: window.text)],
            unknownSpeakers: [(tempLabel: "unknown", start: 0, end: duration)]
        )
    }
}
#endif
