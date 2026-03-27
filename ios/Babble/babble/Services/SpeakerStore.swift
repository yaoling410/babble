import Foundation
import Combine

// ============================================================
//  SpeakerStore.swift — Enrolled speaker voice profiles
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  When a clip is sent to /diarize, the backend uses pyannote to identify
//  who is speaking. SpeakerStore maintains the mapping of voice embeddings
//  to human-readable labels ("Mom", "Dad", "Nanny Linda").
//
//  Data flow:
//    New voice detected → UnknownSpeakerSheet → caregiver enters name
//    → enroll() → POST /speakers/enroll → backend stores embedding
//    → cache embedding locally → SpeakerProfile saved to index.json
//
//  STORAGE
//  -------
//  ~/Library/Application Support/Babble/speakers/
//    index.json        — array of SpeakerProfile (label, id, variants)
//    <speakerId>.emb   — pyannote embedding bytes (cached from backend)
//
//  NAME VARIANTS
//  -------------
//  During enrollment, the audio clip often contains the speaker saying
//  the baby's name. The backend extracts ASR variants of the name from
//  that clip (e.g. one speaker says "Luca" but ASR hears "Luka").
//  These variants are stored in SpeakerProfile.nameVariants and merged
//  into WakeWordService.nameAliases so the wake word detector improves
//  with each enrolled speaker.

/// Manages local speaker voice embeddings and syncs with the backend.
/// Storage: ~/Library/Application Support/Babble/speakers/
@MainActor
final class SpeakerStore: ObservableObject {
    @Published var speakers: [SpeakerProfile] = []
    @Published var unknownSpeakerPrompt: UnknownSpeakerPrompt? = nil

    struct UnknownSpeakerPrompt: Identifiable {
        let id = UUID()
        let tempLabel: String
        let audioData: Data  // WAV segment for enrollment
    }

    private let speakersDir: URL
    private let indexURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        speakersDir = appSupport.appendingPathComponent("Babble/speakers", isDirectory: true)
        indexURL = speakersDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: speakersDir, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Local index

    func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let loaded = try? JSONDecoder().decode([SpeakerProfile].self, from: data)
        else { return }
        speakers = loaded
    }

    func saveIndex() {
        guard let data = try? JSONEncoder().encode(speakers) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Embedding cache

    func saveEmbedding(_ embedding: Data, speakerId: String) {
        let url = speakersDir.appendingPathComponent("\(speakerId).emb")
        try? embedding.write(to: url, options: .atomic)
    }

    func loadEmbedding(speakerId: String) -> Data? {
        let url = speakersDir.appendingPathComponent("\(speakerId).emb")
        return try? Data(contentsOf: url)
    }

    // MARK: - On-device enrollment storage (.wav + .skemb)

    func saveEnrollmentAudio(_ data: Data, speakerId: String) {
        let url = speakersDir.appendingPathComponent("\(speakerId).wav")
        try? data.write(to: url, options: .atomic)
    }

    func loadEnrollmentAudio(speakerId: String) -> Data? {
        let url = speakersDir.appendingPathComponent("\(speakerId).wav")
        return try? Data(contentsOf: url)
    }

    func saveSKEmbedding(_ embedding: [Float], speakerId: String) {
        let url = speakersDir.appendingPathComponent("\(speakerId).skemb")
        let count = embedding.count
        let data = embedding.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
        try? data.write(to: url, options: .atomic)
    }

    func loadSKEmbedding(speakerId: String) -> [Float]? {
        let url = speakersDir.appendingPathComponent("\(speakerId).skemb")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let floatCount = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { ptr -> [Float] in
            let buf = ptr.bindMemory(to: Float.self)
            return Array(buf.prefix(floatCount))
        }
    }

    /// Download the pyannote embedding from the backend and cache it locally.
    func cacheEmbedding(speakerId: String, backendURL: String) async {
        guard let url = URL(string: "\(backendURL)/speakers/\(speakerId)/embedding") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["embedding_base64"] as? String,
              let embBytes = Data(base64Encoded: b64) else { return }
        saveEmbedding(embBytes, speakerId: speakerId)
    }

    // MARK: - Sync with backend

    func syncFromBackend(backendURL: String) async {
        guard let url = URL(string: "\(backendURL)/speakers") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Response: Codable { var speakers: [SpeakerProfile] }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(Response.self, from: data)
            speakers = response.speakers
            saveIndex()
        } catch {
            print("[SpeakerStore] sync failed: \(error)")
        }
    }

    /// Returns a label that doesn't conflict with any existing speaker name.
    /// "Mom" → "Mom" (if free), "Mom_1" (if taken), "Mom_2", etc.
    /// Only deduplicates on new enrollments — updating an existing speaker ID is exempt.
    private func uniqueLabel(_ label: String, excludingId: String? = nil) -> String {
        let others = speakers.filter { $0.id != excludingId }.map { $0.label }
        guard others.contains(label) else { return label }
        var n = 1
        while others.contains("\(label)_\(n)") { n += 1 }
        return "\(label)_\(n)"
    }

    /// All name variants collected across every enrolled speaker — used as wake word aliases.
    var allNameVariants: [String] {
        let all = speakers.flatMap { $0.nameVariants ?? [] }
        return Array(Set(all)).sorted()
    }

    /// Enroll a speaker. Returns nil on success, or an error message string on failure.
    func enroll(label: String, audioData: Data, nameVariants: [String] = [], existingSpeakerId: String? = nil, backendURL: String) async -> String? {
        guard let url = URL(string: "\(backendURL)/speakers/enroll") else {
            return "Invalid backend URL"
        }
        let label = uniqueLabel(label, excludingId: existingSpeakerId)

        var bodyDict: [String: Any] = [
            "audio_base64": audioData.base64EncodedString(),
            "label": label,
            "name_variants": nameVariants,
        ]
        if let sid = existingSpeakerId { bodyDict["speaker_id"] = sid }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            return "Failed to encode request"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                let msg = detail ?? String(data: data, encoding: .utf8) ?? "Unknown error"
                print("[SpeakerStore] enroll HTTP \(statusCode): \(msg)")
                return msg
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let lbl = json["label"] as? String else {
                let raw = String(data: data, encoding: .utf8) ?? ""
                print("[SpeakerStore] enroll: unexpected response: \(raw)")
                return "Unexpected response from server"
            }
            let updatedAt = json["updated_at"] as? String ?? ""

            await cacheEmbedding(speakerId: id, backendURL: backendURL)

            let profile = SpeakerProfile(
                id: id, label: lbl,
                nameVariants: nameVariants.isEmpty ? nil : nameVariants,
                updatedAt: updatedAt
            )
            if let idx = speakers.firstIndex(where: { $0.id == id }) {
                speakers[idx] = profile
            } else {
                speakers.append(profile)
            }
            saveIndex()
            return nil  // success
        } catch {
            print("[SpeakerStore] enroll failed: \(error)")
            return error.localizedDescription
        }
    }

    func rename(speakerId: String, newLabel: String, backendURL: String) async {
        guard let url = URL(string: "\(backendURL)/speakers/\(speakerId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["label": newLabel])

        do {
            _ = try await URLSession.shared.data(for: request)
            if let idx = speakers.firstIndex(where: { $0.id == speakerId }) {
                speakers[idx] = SpeakerProfile(id: speakerId, label: newLabel)
            }
            saveIndex()
        } catch {
            print("[SpeakerStore] rename failed: \(error)")
        }
    }

    func delete(speakerId: String, backendURL: String) async {
        guard let url = URL(string: "\(backendURL)/speakers/\(speakerId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        do {
            _ = try await URLSession.shared.data(for: request)
            speakers.removeAll { $0.id == speakerId }
            // Remove local embedding
            let embedURL = speakersDir.appendingPathComponent("\(speakerId).emb")
            try? FileManager.default.removeItem(at: embedURL)
            saveIndex()
        } catch {
            print("[SpeakerStore] delete failed: \(error)")
        }
    }

    // MARK: - On-device enrollment

    /// Enroll a speaker entirely on-device: save WAV and a SpeakerKit-style embedding (.skemb).
    /// Returns nil on success, or an error message string on failure.
    func enrollOnDevice(label: String, audioData: Data, nameVariants: [String] = [], existingSpeakerId: String? = nil) async -> String? {
        let label = uniqueLabel(label, excludingId: existingSpeakerId)
        let id = existingSpeakerId ?? UUID().uuidString

        saveEnrollmentAudio(audioData, speakerId: id)

        // Derive a deterministic pseudo-embedding from the audio bytes.
        // This placeholder allows the app to store and compare embeddings without SpeakerKit at compile-time.
        let emb: [Float] = {
            var floats: [Float] = []
            let bytes = [UInt8](audioData)
            var i = 0
            while i + 3 < bytes.count && floats.count < 256 {
                let v = UInt32(bytes[i]) << 24 | UInt32(bytes[i+1]) << 16 | UInt32(bytes[i+2]) << 8 | UInt32(bytes[i+3])
                let f = Float(Int32(bitPattern: v)) / Float(Int32.max)
                floats.append(f)
                i += 4
            }
            if floats.isEmpty { floats = Array(repeating: 0.0, count: 128) }
            return floats
        }()

        saveSKEmbedding(emb, speakerId: id)

        let profile = SpeakerProfile(id: id, label: label, nameVariants: nameVariants.isEmpty ? nil : nameVariants, updatedAt: ISO8601DateFormatter().string(from: Date()))
        if let idx = speakers.firstIndex(where: { $0.id == id }) {
            speakers[idx] = profile
        } else {
            speakers.append(profile)
        }
        saveIndex()
        return nil
    }

    func speakersNeedingReenrollment() -> [SpeakerProfile] {
        return speakers.filter { loadSKEmbedding(speakerId: $0.id) == nil }
    }

    // MARK: - Unknown speaker prompt

    func promptForName(tempLabel: String, audioData: Data) {
        unknownSpeakerPrompt = UnknownSpeakerPrompt(tempLabel: tempLabel, audioData: audioData)
    }

    func dismissPrompt() {
        unknownSpeakerPrompt = nil
    }
}
