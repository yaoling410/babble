import Foundation

// ============================================================
//  AnalysisService.swift — HTTP client for the Gemini backend
// ============================================================
//
//  PURPOSE
//  -------
//  All network calls to the FastAPI backend go through this class.
//  It handles JSON encoding/decoding (snake_case ↔ camelCase) and
//  presents a clean async/throws Swift API to the rest of the app.
//
//  ENDPOINTS
//  ---------
//  POST /diarize         — Identify speakers in the audio clip.
//                          Returns annotated transcript with speaker labels.
//
//  POST /analyze         — Main Gemini call. Extract baby events + corrections
//                          from a diarized transcript. Returns AnalyzeResponse.
//
//  POST /voice-note      — Caregiver speaks a note directly. Two modes:
//                            "add"  → extract new events
//                            "edit" → correct previous events
//
//  GET  /events          — Fetch events for a specific day from the backend.
//  DELETE /events/:id    — Remove an event.
//  PATCH /events/:id     — Update specific fields of an event.
//
//  POST /summary/generate — Ask Gemini to write a daily summary narrative.
//  GET  /summary          — Fetch a previously generated summary.
//
//  JSON CONVENTIONS
//  ----------------
//  The backend uses snake_case. Swift uses camelCase.
//  The encoder sets .convertToSnakeCase (Swift → backend).
//  The decoder sets .convertFromSnakeCase (backend → Swift).
//  Dates are ISO-8601 strings on the wire.
//
//  AUDIO ENCODING
//  --------------
//  Audio is sent as base64-encoded WAV (not multipart/form-data).
//  The backend decodes the base64 string back to bytes before processing.
//  MIME type is always "audio/wav".

/// HTTP client for all backend API calls.
final class AnalysisService {

    /// Base URL of the FastAPI backend (no trailing slash).
    /// Updated when the user changes it in Settings.
    var backendURL: String

    // Shared JSONDecoder — converts snake_case keys and ISO-8601 dates.
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase  // audio_base64 → audioBase64
        d.dateDecodingStrategy = .iso8601              // "2026-03-19T14:30:00Z" → Date
        return d
    }()

    // Shared JSONEncoder — converts camelCase keys and ISO-8601 dates.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase    // audioBase64 → audio_base64
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(backendURL: String = "http://localhost:8000") {
        self.backendURL = backendURL
    }

    // ================================================================
    //  MARK: - Diarize
    // ================================================================
    //  Sends audio to the backend for speaker diarization.
    //  The backend uses Gemini to label which speaker said what,
    //  returning an annotated transcript like:
    //    "[Mom]: She ate pretty well. [Dad]: How much did she take?"

    /// Request payload for /diarize.
    struct DiarizeRequest: Encodable {
        /// WAV audio encoded as base64 string. Gemini accepts audio inline.
        var audioBase64: String
        /// Always "audio/wav" — tells the backend how to decode the bytes.
        var audioMimeType: String = "audio/wav"
        /// Raw transcript from SFSpeechRecognizer — used as a transcription hint.
        var rawTranscript: String
        /// Optional per-word timestamps (not currently populated by this client).
        var wordTimestamps: [WordTimestamp]?
    }

    /// Per-word timing data for alignment (future use).
    struct WordTimestamp: Codable {
        var word: String
        var start: Double   // seconds from clip start
        var end: Double
    }

    /// Response from /diarize.
    struct DiarizeResponse: Decodable {
        /// Full transcript with speaker labels inserted.
        /// Example: "[Mom]: She slept well. [Dad]: How long?"
        var annotatedTranscript: String
        /// Time-coded speaker segments for the event list display.
        var segments: [Segment]
        /// Speakers that couldn't be matched to known caregivers.
        var unknownSpeakers: [UnknownSpeaker]

        /// One continuous block of speech from one speaker.
        struct Segment: Decodable {
            var speakerLabel: String   // "Mom", "Dad", or temp label like "SPEAKER_0"
            var start: Double          // seconds from clip start
            var end: Double
            var text: String           // what this speaker said
        }

        /// A speaker the backend couldn't identify — shown to caregiver for labeling.
        struct UnknownSpeaker: Decodable {
            var tempLabel: String   // e.g. "SPEAKER_0" — used until caregiver labels them
            var start: Double
            var end: Double
        }
    }

    /// Send audio for speaker diarization.
    func diarize(audioData: Data, rawTranscript: String) async throws -> DiarizeResponse {
        let body = DiarizeRequest(audioBase64: audioData.base64EncodedString(), rawTranscript: rawTranscript)
        return try await post(path: "/diarize", body: body)
    }

    // ================================================================
    //  MARK: - Relevance check (legacy — replaced by TranscriptFilter)
    // ================================================================
    //  This endpoint is no longer called in the main clip pipeline.
    //  TranscriptFilter handles relevance checking on-device for free.
    //  The endpoint is kept here for potential future use (e.g. re-checking
    //  edge cases that TranscriptFilter is unsure about).

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

    // ================================================================
    //  MARK: - Analyze
    // ================================================================
    //  Main Gemini call. Given an annotated transcript (from /diarize)
    //  and rolling context, extract baby events and correct prior events.

    /// Request payload for /analyze.
    struct AnalyzeRequest: Encodable {
        /// Speaker-annotated transcript from /diarize.
        var transcript: String
        /// Up to 10 minutes of prior transcripts — helps Gemini correct older events.
        var transcriptLast10min: String
        /// What triggered this clip: "name" | "cry" | "manual".
        var triggerHint: String
        var babyName: String
        var babyAgeMonths: Int
        /// ISO-8601 timestamp of when the trigger fired.
        var clipTimestamp: String
        /// YYYY-MM-DD — tells the backend which day's event file to update.
        var dateStr: String
    }

    /// Send a transcript to Gemini for event extraction.
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

    // ================================================================
    //  MARK: - Voice note
    // ================================================================
    //  Caregiver taps the microphone button and speaks directly.
    //  Two modes:
    //    "add"  → extract new events from what was said
    //    "edit" → interpret as a correction to recent events
    //             (e.g. "actually she only ate for 5 minutes")

    struct VoiceNoteRequest: Encodable {
        var audioBase64: String
        var audioMimeType: String = "audio/wav"
        /// "add" or "edit"
        var mode: String
        var babyName: String
        var babyAgeMonths: Int
        var dateStr: String
    }

    struct VoiceNoteResponse: Decodable {
        var newEvents: [BabyEvent]?       // populated in "add" mode
        var corrections: [EventCorrection]? // populated in "edit" mode
        var reply: String?                // populated in "support" mode (conversational)
    }

    /// Send a manually recorded voice note to the backend.
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

    // ================================================================
    //  MARK: - Events CRUD
    // ================================================================
    //  Sync operations for when the backend and app need to stay in sync.
    //  The app primarily stores events locally (EventStore.swift) — these
    //  endpoints are used when the backend's copy needs to be updated too.

    /// Fetch all events for a given day from the backend.
    func fetchEvents(dateStr: String) async throws -> [BabyEvent] {
        struct Response: Decodable { var events: [BabyEvent] }
        let response: Response = try await get(path: "/events?date=\(dateStr)")
        return response.events
    }

    /// Delete an event from the backend by its ID.
    func deleteEvent(id: String) async throws {
        guard let url = URL(string: "\(backendURL)/events/\(id)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: request)
    }

    /// Update specific fields of an event on the backend (PATCH semantics).
    func updateEvent(id: String, fields: [String: String]) async throws {
        guard let url = URL(string: "\(backendURL)/events/\(id)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(["fields": fields])
        _ = try await URLSession.shared.data(for: request)
    }

    // ================================================================
    //  MARK: - Summary
    // ================================================================
    //  Daily summary narrative — Gemini writes a human-readable summary
    //  of the day's events (feeding totals, sleep, health highlights).

    struct SummaryRequest: Encodable {
        var babyName: String
        var babyAgeMonths: Int
        var dateStr: String
    }

    struct SummaryResponse: Decodable {
        /// The generated summary, or nil if no events exist for that day.
        var summary: DaySummary?
        var date: String?
    }

    /// Ask Gemini to generate a new daily summary from today's events.
    func generateSummary(babyName: String, ageMonths: Int, dateStr: String) async throws -> DaySummary? {
        let body = SummaryRequest(babyName: babyName, babyAgeMonths: ageMonths, dateStr: dateStr)
        let response: SummaryResponse = try await post(path: "/summary/generate", body: body)
        return response.summary
    }

    /// Fetch a previously generated summary for a specific day.
    func fetchSummary(dateStr: String) async throws -> DaySummary? {
        let response: SummaryResponse = try await get(path: "/summary?date=\(dateStr)")
        return response.summary
    }

    // ================================================================
    //  MARK: - Networking helpers
    // ================================================================

    /// POST JSON body to `path` and decode the response as `Res`.
    /// - 30-second timeout handles slow Gemini responses.
    /// - Throws `APIError.invalidURL` if the URL can't be constructed.
    private func post<Req: Encodable, Res: Decodable>(path: String, body: Req, timeout: TimeInterval = 60) async throws -> Res {
        guard let url = URL(string: "\(backendURL)\(path)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: request)
        return try decoder.decode(Res.self, from: data)
    }

    /// GET from `path` and decode the response as `Res`.
    private func get<Res: Decodable>(path: String) async throws -> Res {
        guard let url = URL(string: "\(backendURL)\(path)") else {
            throw APIError.invalidURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(Res.self, from: data)
    }
}

// ============================================================
//  APIError — why a network call failed
// ============================================================
enum APIError: Error {
    /// The backend URL string could not be parsed into a valid URL.
    /// Check `backendURL` in BabyProfile — it may be empty or malformed.
    case invalidURL

    /// The server returned an unexpected HTTP status code.
    case httpError(Int)
}
