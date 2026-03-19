import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var profile: BabyProfile
    @EnvironmentObject var speakerStore: SpeakerStore
    @Environment(\.dismiss) var dismiss
    @State private var showSpeakers = false
    @State private var showResetAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Baby Profile") {
                    LabeledContent("Name") {
                        TextField("Baby name", text: $profile.babyName)
                            .multilineTextAlignment(.trailing)
                    }
                    Stepper(
                        "Age: \(profile.babyAgeMonths) month\(profile.babyAgeMonths == 1 ? "" : "s")",
                        value: $profile.babyAgeMonths,
                        in: 0...48
                    )
                }

                Section("Backend") {
                    LabeledContent("URL") {
                        TextField("http://localhost:8000", text: $profile.backendURL)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                }

                Section("Speakers") {
                    Button("Manage Speakers") {
                        showSpeakers = true
                    }
                    Text("\(speakerStore.speakers.count) speaker\(speakerStore.speakers.count == 1 ? "" : "s") enrolled")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                Section {
                    Button("Reset Profile", role: .destructive) {
                        showResetAlert = true
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSpeakers) {
                SpeakersView()
                    .environmentObject(speakerStore)
                    .environmentObject(profile)
            }
            .alert("Reset Profile?", isPresented: $showResetAlert) {
                Button("Reset", role: .destructive) {
                    profile.babyName = ""
                    profile.babyAgeMonths = 0
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will return to the setup screen.")
            }
        }
    }
}
