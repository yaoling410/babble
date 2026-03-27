import SwiftUI

// ============================================================
//  BabbleApp.swift — App entry point and dependency wiring
// ============================================================
//
//  This file does two things:
//
//  1. Creates ALL shared objects exactly once in `init()`.
//     SwiftUI's @StateObject guarantees the object lives as long as
//     the app is alive and is never recreated on view updates.
//     If you created objects inside a child view's body, each
//     view refresh would make a new instance — events would be lost.
//
//  2. Injects every object into the SwiftUI environment via
//     `.environmentObject()` so any view in the hierarchy can
//     access it with `@EnvironmentObject` without prop-drilling.
//
//  Dependency graph (who needs what):
//
//    BabyProfile      ←  MonitorViewModel, EventListViewModel, AnalysisService
//    EventStore       ←  MonitorViewModel, EventListViewModel
//    SpeakerStore     ←  MonitorViewModel
//    AnalysisService  ←  MonitorViewModel, EventListViewModel, SummaryViewModel
//    MonitorViewModel →  owns AudioCaptureService + WakeWordService + CryDetector
//
//  All views receive objects through the environment — no one holds
//  a direct reference to another view.

@main
struct BabbleApp: App {
    // AppDelegate handles background audio session configuration
    // (keeps microphone active when screen is locked).
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // @StateObject — SwiftUI manages the lifetime of these objects.
    // They are created once in init() and survive view re-renders.
    @StateObject private var profile: BabyProfile
    @StateObject private var eventStore: EventStore
    @StateObject private var speakerStore: SpeakerStore
    @StateObject private var monitorVM: MonitorViewModel
    @StateObject private var eventListVM: EventListViewModel
    @StateObject private var summaryVM: SummaryViewModel

    init() {
        // Build the object graph manually so we can share instances.
        // Example: both MonitorViewModel and EventListViewModel need the
        // SAME EventStore — we pass `s` (not `EventStore()`) to both.
        let p  = BabyProfile()       // baby name, age, backend URL, speech locales
        let s  = EventStore()        // reads today's JSON file from disk
        let sp = SpeakerStore()      // known speaker names (Mom, Dad, Nanny…)
        let svc = AnalysisService(backendURL: p.backendURL)  // Gemini HTTP client

        _profile      = StateObject(wrappedValue: p)
        _eventStore   = StateObject(wrappedValue: s)
        _speakerStore = StateObject(wrappedValue: sp)
        // MonitorViewModel owns the audio pipeline; it needs profile + eventStore
        _monitorVM    = StateObject(wrappedValue: MonitorViewModel(profile: p, eventStore: s, speakerStore: sp))
        // EventListViewModel handles the event list screen (edit, delete, filter)
        _eventListVM  = StateObject(wrappedValue: EventListViewModel(eventStore: s, analysisService: svc))
        // SummaryViewModel generates the daily report card
        _summaryVM    = StateObject(wrappedValue: SummaryViewModel(analysisService: svc))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Inject every object so child views can access them with @EnvironmentObject
                .environmentObject(profile)
                .environmentObject(eventStore)
                .environmentObject(speakerStore)
                .environmentObject(monitorVM)
                .environmentObject(eventListVM)
                .environmentObject(summaryVM)
        }
    }
}

// ============================================================
//  RootView — first-run gating
// ============================================================
//  Shows SetupView until the caregiver has entered a baby name.
//  Once a name is saved (persisted to UserDefaults by BabyProfile),
//  every subsequent launch goes straight to HomeView.
struct RootView: View {
    @EnvironmentObject var profile: BabyProfile

    var body: some View {
        if profile.babyName.isEmpty {
            // First run: ask for baby name, age, backend URL
            SetupView()
        } else {
            // Normal run: main monitoring screen
            HomeView()
        }
    }
}
