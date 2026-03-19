import Foundation

/// HTTP client for all backend API calls.
final class AnalysisService {
    var backendURL: String

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(backendURL: String = "http://localhost:8000") {
        self.backendURL = backendURL
    }

    // MARK: - Diarize

    struct DiarizeRequest: Encodable {
        var audioBase64: String
        var audioMimeType: String = "audio/wav"
        var rawTranscript: String
        var wordTimestamps: [WordTimestamp]?
    }

    struct WordTimestamp: Codable {
        var word: String
        var start: Double
        var end: Double
    }

    struct DiarizeResponse: Decodable {
        var annotatedTranscript: String
        var segments: [Segment]
        var unknownSpeakers: [UnknownSpeaker]

        struct Segment: Decodable {
            var speakerLabel: String
            var start: Double
            var end: Double
            var text: String
        }

        struct UnknownSpeaker: Decodable {
            var tempLabel: String
            var start: Double
            var end: Double
        }
    }

    func diarize(audioData: Data, rawTranscript: String) async throws -> DiarizeResponse {
        let body = DiarizeRequest(audioBase64: audioData.base64EncodedString(), rawTranscript: rawTranscript)
        return try await post(path: "/diarize", body: body)
    }

    // MARK: - Relevance check

    struct RelevanceRequest: Encodable {
        var transcript: String
        var babyName: String
        var babyAgeMonths: Int
    }

    struct RelevanceResponse: Decodable {
        var relevant: Bool
        var reason: String?
    }

    func checkRelevance(transcript: String, babyName: String, ageMonths: Int) async throws -> RelevanceResponse {
        let body = RelevanceRequest(transcript: transcript, babyName: babyName, babyAgeMonths: ageMonths)
        return try await post(path: "/check-relevance", body: body)
    }

    // MARK: - Analyze

    struct AnalyzeRequest: Encodable {
        var transcript: String
        var transcriptLast10min: String
        var triggerHint: String
        var babyName: String
        var babyAgeMonths: Int
        var clipTimestamp: String
        var dateStr: String
    }

    func analyze(
        transcript: String,
        transcriptLast10min: String,
        triggerHint: String,
        babyName: String,
        ageMonths: Int,
        clipTimestamp: Date,
        dateStr: String
    ) async throws -> AnalyzeResponse {
        let isoFormatter = ISO8601DateFormatter()
        let body = AnalyzeRequest(
            transcript: transcript,
            transcriptLast10min: transcriptLast10min,
            triggerHint: triggerHint,
            babyName: babyName,
            babyAgeMonths: ageMonths,
            clipTimestamp: isoFormatter.string(from: clipTimestamp),
            dateStr: dateStr
        )
        return try await post(path: "/analyze", body: body)
    }

    // MARK: - Voice note

    struct VoiceNoteRequest: Encodable {
        var audioBase64: String
        var audioMimeType: String = "audio/wav"
        var mode: String
        var babyName: String
        var babyAgeMonths: Int
        var dateStr: String
    }

    struct VoiceNoteResponse: Decodable {
        var newEvents: [BabyEvent]?
        var corrections: [EventCorrection]?
        var reply: String?
    }

    func sendVoiceNote(
        audioData: Data,
        mode: String,
        babyName: String,
        ageMonths: Int,
        dateStr: String
    ) async throws -> VoiceNoteResponse {
        let body = VoiceNoteRequest(
            audioBase64: audioData.base64EncodedString(),
            mode: mode,
            babyName: babyName,
            babyAgeMonths: ageMonths,
            dateStr: dateStr
        )
        return try await post(path: "/voice-note", body: body)
    }

    // MARK: - Events CRUD

    func fetchEvents(dateStr: String) async throws -> [BabyEvent] {
        struct Response: Decodable { var events: [BabyEvent] }
        let response: Response = try await get(path: "/events?date=\(dateStr)")
        return response.events
    }

    func deleteEvent(id: String) async throws {
        guard let url = URL(string: "\(backendURL)/events/\(id)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: request)
    }

    func updateEvent(id: String, fields: [String: String]) async throws {
        guard let url = URL(string: "\(backendURL)/events/\(id)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(["fields": fields])
        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Summary

    struct SummaryRequest: Encodable {
        var babyName: String
        var babyAgeMonths: Int
        var dateStr: String
    }

    struct SummaryResponse: Decodable {
        var summary: DaySummary?
        var date: String?
    }

    func generateSummary(babyName: String, ageMonths: Int, dateStr: String) async throws -> DaySummary? {
        let body = SummaryRequest(babyName: babyName, babyAgeMonths: ageMonths, dateStr: dateStr)
        let response: SummaryResponse = try await post(path: "/summary/generate", body: body)
        return response.summary
    }

    func fetchSummary(dateStr: String) async throws -> DaySummary? {
        let response: SummaryResponse = try await get(path: "/summary?date=\(dateStr)")
        return response.summary
    }

    // MARK: - Networking helpers

    private func post<Req: Encodable, Res: Decodable>(path: String, body: Req) async throws -> Res {
        guard let url = URL(string: "\(backendURL)\(path)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        return try decoder.decode(Res.self, from: data)
    }

    private func get<Res: Decodable>(path: String) async throws -> Res {
        guard let url = URL(string: "\(backendURL)\(path)") else {
            throw APIError.invalidURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(Res.self, from: data)
    }
}

enum APIError: Error {
    case invalidURL
    case httpError(Int)
}
