import Foundation
import Combine

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
        let url = speakersDir.appendingPathComponent("\(speakerId).embedding")
        try? embedding.write(to: url, options: .atomic)
    }

    func loadEmbedding(speakerId: String) -> Data? {
        let url = speakersDir.appendingPathComponent("\(speakerId).embedding")
        return try? Data(contentsOf: url)
    }

    // MARK: - Sync with backend

    func syncFromBackend(backendURL: String) async {
        guard let url = URL(string: "\(backendURL)/speakers") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Response: Codable { var speakers: [SpeakerProfile] }
            let response = try JSONDecoder().decode(Response.self, from: data)
            speakers = response.speakers
            saveIndex()
        } catch {
            print("[SpeakerStore] sync failed: \(error)")
        }
    }

    func enroll(label: String, audioData: Data, existingSpeakerId: String? = nil, backendURL: String) async {
        guard let url = URL(string: "\(backendURL)/speakers/enroll") else { return }

        struct EnrollRequest: Encodable {
            var audioBase64: String
            var label: String
            var speakerId: String?
        }
        let body = EnrollRequest(
            audioBase64: audioData.base64EncodedString(),
            label: label,
            speakerId: existingSpeakerId
        )
        guard let bodyData = try? JSONEncoder().encode(body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct EnrollResponse: Codable { var id: String; var label: String; var updatedAt: String }
            let resp = try JSONDecoder().decode(EnrollResponse.self, from: data)

            // Update or insert speaker in local index
            if let idx = speakers.firstIndex(where: { $0.id == resp.id }) {
                speakers[idx] = SpeakerProfile(id: resp.id, label: resp.label, updatedAt: resp.updatedAt)
            } else {
                speakers.append(SpeakerProfile(id: resp.id, label: resp.label, updatedAt: resp.updatedAt))
            }
            saveIndex()
        } catch {
            print("[SpeakerStore] enroll failed: \(error)")
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
            let embedURL = speakersDir.appendingPathComponent("\(speakerId).embedding")
            try? FileManager.default.removeItem(at: embedURL)
            saveIndex()
        } catch {
            print("[SpeakerStore] delete failed: \(error)")
        }
    }

    // MARK: - Unknown speaker prompt

    func promptForName(tempLabel: String, audioData: Data) {
        unknownSpeakerPrompt = UnknownSpeakerPrompt(tempLabel: tempLabel, audioData: audioData)
    }

    func dismissPrompt() {
        unknownSpeakerPrompt = nil
    }
}
