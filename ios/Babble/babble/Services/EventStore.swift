import Foundation
import Combine

// ============================================================
//  EventStore.swift — Persists BabyEvents to JSON files
// ============================================================
//
//  PURPOSE
//  -------
//  The single source of truth for all logged baby events.
//  Every time Gemini returns a response, EventStore applies the
//  new events and corrections, then saves the updated list to disk.
//
//  STORAGE FORMAT
//  --------------
//  One JSON file per calendar day:
//    ~/Library/Application Support/Babble/events-YYYY-MM-DD.json
//
//  Each file is a JSON array of BabyEvent objects, sorted by timestamp.
//  Dates are stored as ISO-8601 strings (e.g. "2026-03-19T14:30:00Z")
//  so they survive app restarts and time zone changes.
//
//  Example path:
//    …/Babble/events-2026-03-19.json
//
//  WHY ONE FILE PER DAY?
//  ----------------------
//  Daily files are small (typically < 50 KB), easy to browse,
//  and safe to email or share with a pediatrician. The EventList
//  screen loads only today's file; the SummaryView can load older
//  files when the user swipes back in time.
//
//  UI ANIMATIONS
//  -------------
//  When new events arrive, their IDs are added to `newEventIDs`
//  for 2.5 seconds — the EventRowView renders these with a green
//  flash. Corrected events use `correctedEventIDs` (blue flash).

@MainActor   // All mutations happen on the main thread — safe for @Published
final class EventStore: ObservableObject {

    /// Today's events, sorted by timestamp. SwiftUI views observe this directly.
    @Published var events: [BabyEvent] = []

    /// IDs of events that just arrived from Gemini — green flash in UI for 2.5 s.
    @Published var newEventIDs: Set<String> = []

    /// IDs of events just corrected by Gemini — blue flash in UI for 2.5 s.
    @Published var correctedEventIDs: Set<String> = []

    /// Root directory: ~/Library/Application Support/Babble/
    private let storageDir: URL

    /// Today's date string, set in init() and used as the default `dateStr` parameter.
    /// Events from a different day (e.g. a late-night voice note) can specify their own.
    private(set) var currentDateStr: String = ""

    /// Invalidated after each flash animation to clear the highlighted IDs.
    private var flashTimer: Timer?

    // ----------------------------------------------------------------
    //  init
    // ----------------------------------------------------------------
    init() {
        // Build the storage directory path and create it if it doesn't exist.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDir = appSupport.appendingPathComponent("Babble", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        loadToday()  // populate `events` from today's JSON file on launch
    }

    // ================================================================
    //  MARK: - Load
    // ================================================================

    /// Load today's events into `events` and update `currentDateStr`.
    /// Called on init and whenever the app comes back from the background
    /// after midnight (a new day has started).
    func loadToday() {
        let dateStr = Self.todayStr()
        currentDateStr = dateStr
        events = load(dateStr: dateStr)
    }

    /// Load events for any given day from disk. Returns [] if no file exists yet.
    /// Used by SummaryViewModel to load historical data.
    func load(dateStr: String) -> [BabyEvent] {
        let url = fileURL(for: dateStr)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601  // must match the encoder
        return (try? decoder.decode([BabyEvent].self, from: data)) ?? []
    }

    // ================================================================
    //  MARK: - Apply analysis response
    // ================================================================

    /// Insert new events and apply corrections from a Gemini /analyze response.
    ///
    /// - Parameters:
    ///   - response: The full AnalyzeResponse from the backend.
    ///   - dateStr:  The day this audio belongs to (usually today).
    ///               Pass a specific date if the transcript refers to yesterday.
    ///
    /// After applying:
    ///   - The updated list is sorted by timestamp and saved to disk.
    ///   - If the date matches today, `events` is updated and the UI flashes.
    func apply(response: AnalyzeResponse, dateStr: String? = nil) {
        let date = dateStr ?? currentDateStr

        // Load the target day's events (may differ from today if analyzing late-night audio)
        var updated = (date == currentDateStr) ? events : load(dateStr: date)
        var addedIDs = Set<String>()

        // --- Insert new events ---
        for var event in response.newEvents {
            // Gemini should always provide an ID, but generate one locally as fallback
            if event.id.isEmpty { event.id = UUID().uuidString }
            updated.append(event)
            addedIDs.insert(event.id)
        }

        // --- Apply corrections ---
        var correctedIDs = Set<String>()
        for correction in response.corrections {
            switch correction.action {
            case .delete:
                // Remove the event entirely (e.g. Gemini realizes it was a false positive)
                updated.removeAll { $0.id == correction.eventId }

            case .update:
                // Update the detail field of an existing event.
                // Currently only "detail" corrections are supported.
                if let idx = updated.firstIndex(where: { $0.id == correction.eventId }) {
                    if let newDetail = correction.fields?["detail"] {
                        updated[idx].detail = newDetail
                    }
                    correctedIDs.insert(correction.eventId)
                }
            }
        }

        // Sort chronologically — new events may have timestamps before existing ones
        // (e.g. Gemini infers "she ate at 2pm" from a 2:15pm clip)
        updated.sort { $0.timestamp < $1.timestamp }
        save(updated, dateStr: date)

        // Only update the in-memory list if this is today's data
        if date == currentDateStr {
            events = updated
            flash(newIDs: addedIDs, correctedIDs: correctedIDs)
        }
    }

    // ================================================================
    //  MARK: - Manual CRUD (caregiver edits from the event list)
    // ================================================================

    /// Insert a single manually created event.
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

    /// Update an existing event. Appends the old detail to `editHistory` first
    /// so the caregiver can see what was changed and when.
    func update(_ event: BabyEvent, dateStr: String? = nil) {
        let date = dateStr ?? currentDateStr
        var updated = (date == currentDateStr) ? events : load(dateStr: date)
        if let idx = updated.firstIndex(where: { $0.id == event.id }) {
            var newEvent = event
            // Record the previous version in edit history before overwriting
            if updated[idx].detail != event.detail {
                let entry = BabyEvent.EditEntry(
                    editedAt: Date(),
                    previousDetail: updated[idx].detail
                )
                newEvent.editHistory = (updated[idx].editHistory ?? []) + [entry]
            }
            updated[idx] = newEvent
        }
        save(updated, dateStr: date)
        if date == currentDateStr { events = updated }
    }

    /// Delete an event by ID. Irreversible (no soft-delete).
    func delete(id: String, dateStr: String? = nil) {
        let date = dateStr ?? currentDateStr
        var updated = (date == currentDateStr) ? events : load(dateStr: date)
        updated.removeAll { $0.id == id }
        save(updated, dateStr: date)
        if date == currentDateStr { events = updated }
    }

    // ================================================================
    //  MARK: - Persistence (private)
    // ================================================================

    /// Encode events to JSON and write atomically to the day's file.
    /// `.atomic` write ensures no partial file if the app is killed mid-write.
    private func save(_ events: [BabyEvent], dateStr: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601     // human-readable dates in the file
        encoder.outputFormatting = .prettyPrinted   // easy to read and debug
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL(for: dateStr), options: .atomic)
    }

    /// Build the file URL for a given day. Example: …/Babble/events-2026-03-19.json
    private func fileURL(for dateStr: String) -> URL {
        storageDir.appendingPathComponent("events-\(dateStr).json")
    }

    /// Current local date as YYYY-MM-DD string.
    private static let _dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()
    private static func todayStr() -> String { _dateFmt.string(from: Date()) }

    // ================================================================
    //  MARK: - Flash animation helpers
    // ================================================================

    /// Add IDs to the highlighted sets and clear them after 2.5 seconds.
    ///
    /// Using a union (not replace) handles the case where a second Gemini
    /// response arrives before the first flash finishes — all highlighted
    /// IDs stay visible until the timer fires.
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
