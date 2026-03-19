import SwiftUI

@main
struct BabbleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var profile = BabyProfile()
    @StateObject private var eventStore = EventStore()
    @StateObject private var speakerStore = SpeakerStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(profile)
                .environmentObject(eventStore)
                .environmentObject(speakerStore)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var profile: BabyProfile

    var body: some View {
        if profile.babyName.isEmpty {
            SetupView()
        } else {
            HomeView()
        }
    }
}
