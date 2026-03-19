import Foundation
import Combine

/// Persists BabyEvents as JSON files, one file per day.
/// Path: ~/Library/Application Support/Babble/events-YYYY-MM-DD.json
@MainActor
final class EventStore: ObservableObject {
    @Published var events: [BabyEvent] = []
    @Published var newEventIDs: Set<String> = []       // for green flash animation
    @Published var correctedEventIDs: Set<String> = [] // for blue flash animation

    private let storageDir: URL
    private var currentDateStr: String = ""
    private var flashTimer: Timer?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDir = appSupport.appendingPathComponent("Babble", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        loadToday()
    }

    // MARK: - Load

    func loadToday() {
        let dateStr = Self.todayStr()
        currentDateStr = dateStr
        events = load(dateStr: dateStr)
    }

    func load(dateStr: String) -> [BabyEvent] {
        let url = fileURL(for: dateStr)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BabyEvent].self, from: data)) ?? []
    }

    // MARK: - Apply analysis response

    func apply(response: AnalyzeResponse, dateStr: String? = nil) {
        let date = dateStr ?? currentDateStr

        // Insert new events
        var updated = (date == currentDateStr) ? events : load(dateStr: date)
        var addedIDs = Set<String>()
        for var event in response.newEvents {
            if event.id.isEmpty { event.id = UUID().uuidString }
            updated.append(event)
            addedIDs.insert(event.id)
        }

        // Apply corrections
        var correctedIDs = Set<String>()
        for correction in response.corrections {
            switch correction.action {
            case .delete:
                updated.removeAll { $0.id == correction.eventId }
            case .update:
                if let idx = updated.firstIndex(where: { $0.id == correction.eventId }) {
                    if let newDetail = correction.fields?["detail"] {
                        updated[idx].detail = newDetail
                    }
                    correctedIDs.insert(correction.eventId)
                }
            }
        }

        // Sort by timestamp
        updated.sort { $0.timestamp < $1.timestamp }
        save(updated, dateStr: date)

        if date == currentDateStr {
            events = updated
            flash(newIDs: addedIDs, correctedIDs: correctedIDs)
        }
    }

    // MARK: - Manual CRUD

    func insert(_ event: BabyEvent, dateStr: String? = nil) {
        let date = dateStr ?? currentDateStr
        var updated = (date == currentDateStr) ? events : load(dateStr: date)
        updated.append(event)
        updated.sort { $0.timestamp < $1.timestamp }
        save(updated, dateStr: date)
        if date == currentDateStr {
            events = updated
            flash(newIDs: [event.id], correctedIDs: [])
        }
    }

    func update(_ event: BabyEvent, dateStr: String? = nil) {
        let date = dateStr ?? currentDateStr
        var updated = (date == currentDateStr) ? events : load(dateStr: date)
        if let idx = updated.firstIndex(where: { $0.id == event.id }) {
            updated[idx] = event
        }
        save(updated, dateStr: date)
        if date == currentDateStr { events = updated }
    }

    func delete(id: String, dateStr: String? = nil) {
        let date = dateStr ?? currentDateStr
        var updated = (date == currentDateStr) ? events : load(dateStr: date)
        updated.removeAll { $0.id == id }
        save(updated, dateStr: date)
        if date == currentDateStr { events = updated }
    }

    // MARK: - Persistence

    private func save(_ events: [BabyEvent], dateStr: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL(for: dateStr), options: .atomic)
    }

    private func fileURL(for dateStr: String) -> URL {
        storageDir.appendingPathComponent("events-\(dateStr).json")
    }

    private static func todayStr() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: Date())
    }

    // MARK: - Flash animation helpers

    private func flash(newIDs: Set<String>, correctedIDs: Set<String>) {
        newEventIDs.formUnion(newIDs)
        correctedEventIDs.formUnion(correctedIDs)
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.newEventIDs.removeAll()
                self?.correctedEventIDs.removeAll()
            }
        }
    }
}
