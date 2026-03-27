import Foundation
import Combine

// ============================================================
//  EventListViewModel.swift — Event list screen logic
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  Bridges EventStore (raw data) and EventListView (UI).
//  Provides grouped, sorted events and handles user actions
//  (delete, edit) by forwarding to both local EventStore and
//  the remote backend for sync.
//
//  TIME GROUPING
//  -------------
//  Events are bucketed by time of day for visual clarity:
//    Night (early): 00–05    Morning: 06–11
//    Afternoon: 12–17        Evening: 18–21
//    Night: 22–23
//
//  Groups are sorted by most-recent event (newest group first).
//  Regrouping runs once per EventStore update (O(n log n)),
//  not on every SwiftUI render pass.
//
//  SYNC
//  ----
//  refreshFromBackend() pulls events from the backend and replaces
//  the local file. This is a simple "backend wins" strategy — the
//  backend is authoritative because it applies Gemini corrections.

@MainActor
final class EventListViewModel: ObservableObject {
    @Published var events: [BabyEvent] = []
    @Published var groupedEvents: [EventGroup] = []
    @Published var isRefreshing: Bool = false

    private let eventStore: EventStore
    private let analysisService: AnalysisService
    private var cancellables = Set<AnyCancellable>()

    init(eventStore: EventStore, analysisService: AnalysisService) {
        self.eventStore = eventStore
        self.analysisService = analysisService

        // Mirror EventStore's published events and regroup only when the list changes.
        // Grouping is O(n log n) — doing it here means it runs once per Gemini response,
        // not on every SwiftUI render pass (which also fires for flash-timer updates).
        eventStore.$events
            .receive(on: RunLoop.main)
            .sink { [weak self] newEvents in
                self?.events = newEvents
                self?.groupedEvents = Self.makeGroups(from: newEvents)
            }
            .store(in: &cancellables)
    }

    private static func makeGroups(from events: [BabyEvent]) -> [EventGroup] {
        var dict: [EventGroup.Bucket: [BabyEvent]] = [:]
        let cal = Calendar.current
        for event in events {
            let hour = cal.component(.hour, from: event.timestamp)
            dict[EventGroup.Bucket(hour: hour), default: []].append(event)
        }
        return dict.map { EventGroup(bucket: $0.key, events: $0.value) }
            .sorted {
                ($0.events.map(\.timestamp).max() ?? .distantPast) >
                ($1.events.map(\.timestamp).max() ?? .distantPast)
            }
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
