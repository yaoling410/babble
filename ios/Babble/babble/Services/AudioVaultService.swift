import AVFoundation
import Combine
import Foundation
import os

// ============================================================
//  AudioVaultService — 1-hour audio batch analysis
// ============================================================
//
//  PURPOSE
//  -------
//  The real-time pipeline (WakeWord → transcript → Gemini text) is fast
//  but misses nuance: emotional tone, quiet speech below VAD, and sounds
//  the ASR mis-transcribed. AudioVaultService runs a second pass:
//
//    Every ~1 hour → bundle all saved audio clips → send to /analyze-audio-vault
//    → Gemini listens to the actual audio → returns events the text pipeline missed
//
//  WHAT GETS SAVED
//  ---------------
//  Only clips that passed the VAD + speech gate (i.e. every clip already
//  handed to handleClip in MonitorViewModel). We piggyback on that quality
//  filter — no extra CPU needed here.
//
//  STORAGE
//  -------
//  ~/Library/Application Support/Babble/vault/
//    <uuid>.wav          — raw PCM audio
//    <uuid>.meta.json    — ClipMetadata (timestamp, duration, transcript, …)
//    index.json          — list of pending clip IDs (not yet batch-analyzed)
//
//  After a batch is submitted, the files are deleted.
//  Clips older than 2 hours are pruned regardless (guard against orphaned files).

@MainActor
final class AudioVaultService: ObservableObject {

    // ── Public state ──────────────────────────────────────────────────

    /// Number of clips currently waiting for batch analysis.
    @Published var pendingCount: Int = 0

    // ── Clip metadata ─────────────────────────────────────────────────

    struct ClipMetadata: Codable {
        let id: String
        let timestamp: Date
        let durationSeconds: Double
        let triggerKind: String     // "name" | "cry" | "manual"
        let transcript: String      // ASR hint for Gemini context
        let savedAt: Date
    }

    // ── Dependencies set by MonitorViewModel ──────────────────────────

    var backendURL: String = ""
    var babyName: String = ""
    var babyAgeMonths: Int = 0

    /// Called when the vault batch finds an emotional-support event.
    /// MonitorViewModel can use this to show an alert.
    var onEmotionalSupportDetected: (() -> Void)?

    // ── Private state ─────────────────────────────────────────────────

    private let vaultDir: URL
    private let indexURL: URL
    private var pendingIDs: [String] = []   // IDs not yet submitted
    private var batchTask: Task<Void, Never>?

    /// How often to run the batch analysis (default 1 hour).
    private static let batchIntervalSeconds: TimeInterval = 3600
    /// Discard clips older than this without analyzing (avoids stale uploads).
    private static let maxClipAgeSeconds: TimeInterval = 7200
    /// Maximum clips per batch (cost guard — at ~$0.006/clip this is ~$0.18 max/batch).
    private static let maxClipsPerBatch: Int = 30

    private let log = Logger(subsystem: "com.babble.app", category: "VAULT")

    // ── Init ──────────────────────────────────────────────────────────

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        vaultDir = appSupport.appendingPathComponent("Babble/vault", isDirectory: true)
        indexURL = vaultDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        loadIndex()
        pruneOldClips()
    }

    // MARK: - Public API

    /// Save a clip to the vault for later batch analysis.
    /// Call from MonitorViewModel after handleClip succeeds.
    func store(audioData: Data, triggerKind: String, transcript: String, capturedAt: Date) {
        let id = UUID().uuidString
        let wavURL = vaultDir.appendingPathComponent("\(id).wav")
        let metaURL = vaultDir.appendingPathComponent("\(id).meta.json")

        guard (try? audioData.write(to: wavURL, options: .atomic)) != nil else {
            log.error("Failed to write vault clip \(id, privacy: .public)")
            return
        }

        // Estimate duration from WAV byte count: 16kHz mono 16-bit → 32000 bytes/sec
        // (actual value used only for Gemini's time-reference label — not safety-critical)
        let durationSecs = Double(audioData.count) / 32_000.0

        let meta = ClipMetadata(
            id: id,
            timestamp: capturedAt,
            durationSeconds: durationSecs,
            triggerKind: triggerKind,
            transcript: transcript,
            savedAt: Date()
        )
        if let encoded = try? JSONEncoder().encode(meta) {
            try? encoded.write(to: metaURL, options: .atomic)
        }

        pendingIDs.append(id)
        saveIndex()
        pendingCount = pendingIDs.count
        log.info("💾 Vault stored clip \(id.prefix(8), privacy: .public) trigger=\(triggerKind, privacy: .public) dur=\(durationSecs, format: .fixed(precision: 1), privacy: .public)s | pending=\(self.pendingIDs.count, privacy: .public)")
    }

    /// Schedule a one-hour repeating batch timer. Call once on app launch.
    func scheduleBatchTimer() {
        batchTask?.cancel()
        batchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.batchIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await runBatch()
            }
        }
    }

    /// Run the batch immediately (also used for testing / on-demand).
    func runBatch() async {
        guard !pendingIDs.isEmpty else {
            log.info("⏭ Vault batch: no pending clips")
            return
        }
        guard !backendURL.isEmpty, !babyName.isEmpty else {
            log.warning("⚠️ Vault batch skipped — backendURL or babyName not set")
            return
        }

        let batchIDs = Array(pendingIDs.prefix(Self.maxClipsPerBatch))
        log.info("🔄 Vault batch starting — \(batchIDs.count, privacy: .public) clips")

        // Load audio + metadata for each clip
        var clips: [[String: Any]] = []
        var loadedIDs: [String] = []
        for id in batchIDs {
            let wavURL = vaultDir.appendingPathComponent("\(id).wav")
            let metaURL = vaultDir.appendingPathComponent("\(id).meta.json")
            guard let audioData = try? Data(contentsOf: wavURL),
                  let metaData = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(ClipMetadata.self, from: metaData)
            else {
                log.warning("⚠️ Vault clip \(id.prefix(8), privacy: .public) missing files — skipping")
                loadedIDs.append(id)  // remove from pending so we don't retry forever
                continue
            }
            clips.append([
                "audio_base64":     audioData.base64EncodedString(),
                "mime_type":        "audio/wav",
                "timestamp":        ISO8601DateFormatter().string(from: meta.timestamp),
                "duration_seconds": meta.durationSeconds,
                "trigger_kind":     meta.triggerKind,
                "transcript":       meta.transcript,
            ])
            loadedIDs.append(id)
        }

        guard !clips.isEmpty else {
            removePendingIDs(loadedIDs)
            return
        }

        // Submit to backend
        guard let url = URL(string: "\(backendURL)/analyze-audio-vault") else { return }
        let body: [String: Any] = [
            "clips":            clips,
            "baby_name":        babyName,
            "baby_age_months":  babyAgeMonths,
            "date_str":         todayStr(),
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 120  // audio uploads can be large

        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                log.error("Vault batch HTTP \(status, privacy: .public)")
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let evCount = (json["new_events"] as? [[String: Any]])?.count ?? 0
                let emotional = json["emotional_support_needed"] as? Bool ?? false
                let summary = json["summary"] as? String ?? ""
                log.info("✅ Vault batch done — events=\(evCount, privacy: .public) emotional=\(emotional, privacy: .public) | \(summary.prefix(80), privacy: .public)")
                if emotional {
                    onEmotionalSupportDetected?()
                }
            }
            // Clean up successfully submitted clips
            removePendingIDs(loadedIDs)
            deleteClipFiles(ids: loadedIDs)
        } catch {
            log.error("Vault batch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        batchTask?.cancel()
        batchTask = nil
    }

    deinit {
        batchTask?.cancel()
    }

    // MARK: - Private

    private func removePendingIDs(_ ids: [String]) {
        let removed = Set(ids)
        pendingIDs.removeAll { removed.contains($0) }
        saveIndex()
        pendingCount = pendingIDs.count
    }

    private func deleteClipFiles(ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: vaultDir.appendingPathComponent("\(id).wav"))
            try? FileManager.default.removeItem(at: vaultDir.appendingPathComponent("\(id).meta.json"))
        }
    }

    private func pruneOldClips() {
        let cutoff = Date().addingTimeInterval(-Self.maxClipAgeSeconds)
        let stale = pendingIDs.filter { id in
            let metaURL = vaultDir.appendingPathComponent("\(id).meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(ClipMetadata.self, from: data)
            else { return true }  // missing meta → prune
            return meta.savedAt < cutoff
        }
        if !stale.isEmpty {
            log.info("🗑 Pruning \(stale.count, privacy: .public) stale vault clips")
            removePendingIDs(stale)
            deleteClipFiles(ids: stale)
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        pendingIDs = ids
        pendingCount = ids.count
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(pendingIDs) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static let _dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()
    private func todayStr() -> String { Self._dateFmt.string(from: Date()) }
}
