import Foundation
import Combine

@MainActor
final class EventListViewModel: ObservableObject {
    @Published var events: [BabyEvent] = []
    @Published var isRefreshing: Bool = false

    private let eventStore: EventStore
    private let analysisService: AnalysisService
    private var cancellables = Set<AnyCancellable>()

    init(eventStore: EventStore, analysisService: AnalysisService) {
        self.eventStore = eventStore
        self.analysisService = analysisService

        // Mirror EventStore's published events
        eventStore.$events
            .receive(on: RunLoop.main)
            .assign(to: &$events)
    }

    // MARK: - Sync from backend

    func refreshFromBackend(dateStr: String) async {
        isRefreshing = true
        do {
            let remoteEvents = try await analysisService.fetchEvents(dateStr: dateStr)
            // Merge: backend is authoritative; write all remote events to store
            // Simple strategy: replace local with remote on refresh
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let url = appSupport.appendingPathComponent("Babble/events-\(dateStr).json")
            if let data = try? encoder.encode(remoteEvents) {
                try? data.write(to: url, options: .atomic)
            }
            eventStore.loadToday()
        } catch {
            print("[EventListVM] refresh failed: \(error)")
        }
        isRefreshing = false
    }

    // MARK: - CRUD forwarded to store + backend

    func delete(event: BabyEvent) async {
        eventStore.delete(id: event.id)
        do {
            try await analysisService.deleteEvent(id: event.id)
        } catch {
            print("[EventListVM] delete failed: \(error)")
        }
    }

    func update(event: BabyEvent) async {
        eventStore.update(event)
        do {
            try await analysisService.updateEvent(id: event.id, fields: ["detail": event.detail])
        } catch {
            print("[EventListVM] update failed: \(error)")
        }
    }

    // Helpers for UI

    var newEventIDs: Set<String> { eventStore.newEventIDs }
    var correctedEventIDs: Set<String> { eventStore.correctedEventIDs }
}
