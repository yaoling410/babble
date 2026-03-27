import XCTest
@testable import babble

/// Unit tests for EventStore persistence and AnalyzeResponse application logic.
@MainActor
final class EventStoreTests: XCTestCase {

    var store: EventStore!
    // Far-future date: no real events exist here, easy to isolate
    let testDate = "2099-01-01"

    override func setUp() async throws {
        store = EventStore()
        clearTestFile()
    }

    override func tearDown() async throws {
        clearTestFile()
    }

    private func clearTestFile() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("Babble/events-\(testDate).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - BabyEvent Codable round-trip

    func testBabyEventCodableRoundTrip() throws {
        let event = BabyEvent(
            id: "abc123",
            type: .feeding,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            detail: "Bottle 4 oz",
            notable: false,
            speaker: "Mom",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BabyEvent.self, from: data)

        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.type, event.type)
        XCTAssertEqual(decoded.detail, event.detail)
        XCTAssertEqual(decoded.notable, event.notable)
        XCTAssertEqual(decoded.speaker, event.speaker)
    }

    func testAllEventTypesCodable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for eventType in BabyEvent.EventType.allCases {
            let event = BabyEvent(id: eventType.rawValue, type: eventType,
                                  timestamp: Date(), detail: "test", notable: false)
            let data = try encoder.encode(event)
            let decoded = try decoder.decode(BabyEvent.self, from: data)
            XCTAssertEqual(decoded.type, eventType,
                           "Round-trip failed for event type: \(eventType.rawValue)")
        }
    }

    // MARK: - EventStore insert + load

    func testInsertAndLoad() {
        let event = makeEvent(id: "insert-1", type: .feeding, detail: "Nursing 12 min")
        store.insert(event, dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertTrue(loaded.contains(where: { $0.id == "insert-1" }))
        XCTAssertEqual(loaded.first(where: { $0.id == "insert-1" })?.detail, "Nursing 12 min")
    }

    func testInsertSortsByTimestamp() {
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)

        // Insert out of order
        store.insert(makeEvent(id: "c", type: .observation, timestamp: t3), dateStr: testDate)
        store.insert(makeEvent(id: "a", type: .observation, timestamp: t1), dateStr: testDate)
        store.insert(makeEvent(id: "b", type: .observation, timestamp: t2), dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        let ids = loaded.map { $0.id }
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    func testMultipleInsertsAccumulate() {
        store.insert(makeEvent(id: "e1", type: .feeding), dateStr: testDate)
        store.insert(makeEvent(id: "e2", type: .napStart), dateStr: testDate)
        store.insert(makeEvent(id: "e3", type: .diaper), dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertEqual(loaded.count, 3)
    }

    // MARK: - EventStore update

    func testUpdateChangesDetail() {
        var event = makeEvent(id: "update-1", type: .diaper, detail: "Wet diaper")
        store.insert(event, dateStr: testDate)

        event.detail = "Dirty diaper"
        store.update(event, dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertEqual(loaded.first(where: { $0.id == "update-1" })?.detail, "Dirty diaper")
    }

    func testUpdateNonExistentIdIsNoOp() {
        store.insert(makeEvent(id: "real-event", type: .activity, detail: "Tummy time"), dateStr: testDate)
        let ghost = makeEvent(id: "ghost", type: .activity, detail: "Never inserted")
        store.update(ghost, dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertFalse(loaded.contains(where: { $0.id == "ghost" }))
        XCTAssertEqual(loaded.count, 1)
    }

    // MARK: - EventStore delete

    func testDeleteRemovesEvent() {
        store.insert(makeEvent(id: "delete-1", type: .cry, detail: "Crying"), dateStr: testDate)
        store.delete(id: "delete-1", dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertFalse(loaded.contains(where: { $0.id == "delete-1" }))
    }

    func testDeleteNonExistentIdIsNoOp() {
        store.insert(makeEvent(id: "keep-1", type: .activity, detail: "Tummy time"), dateStr: testDate)
        store.delete(id: "does-not-exist", dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertTrue(loaded.contains(where: { $0.id == "keep-1" }))
    }

    func testDeleteLeavesOtherEventsIntact() {
        store.insert(makeEvent(id: "a", type: .feeding), dateStr: testDate)
        store.insert(makeEvent(id: "b", type: .napStart), dateStr: testDate)
        store.insert(makeEvent(id: "c", type: .diaper), dateStr: testDate)

        store.delete(id: "b", dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertFalse(loaded.contains(where: { $0.id == "b" }))
        XCTAssertTrue(loaded.contains(where: { $0.id == "a" }))
        XCTAssertTrue(loaded.contains(where: { $0.id == "c" }))
    }

    // MARK: - Apply AnalyzeResponse

    func testApplyAddsNewEvents() {
        let response = AnalyzeResponse(
            newEvents: [makeEvent(id: "new-1", type: .milestone, detail: "First smile")],
            corrections: [],
            correctionsApplied: nil,
            usage: nil
        )
        store.apply(response: response, dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertTrue(loaded.contains(where: { $0.id == "new-1" }))
    }

    func testApplyCorrectionsUpdateDetail() {
        store.insert(makeEvent(id: "existing-1", type: .feeding, detail: "Old detail"),
                     dateStr: testDate)

        let correction = EventCorrection(
            eventId: "existing-1",
            action: .update,
            fields: ["detail": "Corrected detail"]
        )
        store.apply(response: AnalyzeResponse(newEvents: [], corrections: [correction],
                                               correctionsApplied: nil, usage: nil),
                    dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertEqual(loaded.first(where: { $0.id == "existing-1" })?.detail, "Corrected detail")
    }

    func testApplyCorrectionsDeleteEvent() {
        store.insert(makeEvent(id: "to-delete", type: .diaper, detail: "Mistake"),
                     dateStr: testDate)

        let correction = EventCorrection(eventId: "to-delete", action: .delete, fields: nil)
        store.apply(response: AnalyzeResponse(newEvents: [], corrections: [correction],
                                               correctionsApplied: nil, usage: nil),
                    dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertFalse(loaded.contains(where: { $0.id == "to-delete" }))
    }

    func testApplyEmptyResponseIsNoOp() {
        store.insert(makeEvent(id: "stable", type: .observation, detail: "Unchanged"),
                     dateStr: testDate)
        store.apply(response: AnalyzeResponse(newEvents: [], corrections: [],
                                               correctionsApplied: nil, usage: nil),
                    dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        XCTAssertTrue(loaded.contains(where: { $0.id == "stable" }))
    }

    func testApplyAssignsIdIfEmpty() {
        // Backend can omit id; EventStore should assign one
        var event = makeEvent(id: "", type: .feeding, detail: "Auto-id feed")
        let response = AnalyzeResponse(newEvents: [event], corrections: [],
                                       correctionsApplied: nil, usage: nil)
        store.apply(response: response, dateStr: testDate)

        let loaded = store.load(dateStr: testDate)
        let found = loaded.first(where: { $0.detail == "Auto-id feed" })
        XCTAssertNotNil(found)
        XCTAssertFalse(found!.id.isEmpty, "EventStore should assign UUID when id is empty")
        _ = event // suppress unused warning
    }

    // MARK: - Helpers

    private func makeEvent(
        id: String = UUID().uuidString,
        type: BabyEvent.EventType,
        detail: String = "",
        timestamp: Date = Date()
    ) -> BabyEvent {
        BabyEvent(id: id, type: type, timestamp: timestamp, detail: detail, notable: false)
    }
}
