import SwiftUI

// ============================================================
//  SettingsView.swift — App configuration screen
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  Presented as a sheet from HomeView's gear icon. Lets caregivers
//  edit baby profile, backend URL, speech locales, and name aliases.
//
//  FEATURES
//  --------
//  - Baby name + age editing (persisted to BabyProfile → UserDefaults)
//  - Name aliases: words the ASR commonly outputs instead of the baby's
//    name. Fed to WakeWordService as both contextualStrings (biases
//    the acoustic model) and exact-match triggers.
//  - Backend URL editing
//  - Speech locale picker (English, Mandarin, Cantonese, bilingual)
//  - Navigation to SpeakersView for voice enrollment
//  - Reset button (clears UserDefaults, returns to SetupView)
//  - Share Logs button (AirDrops babble.log from LogFileWriter)

struct SettingsView: View {
    @EnvironmentObject var profile: BabyProfile
    @EnvironmentObject var speakerStore: SpeakerStore
    @Environment(\.dismiss) var dismiss
    @State private var showSpeakers = false
    @State private var showResetAlert = false
    @State private var aliasesText: String = ""

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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name Aliases")
                            .font(.subheadline)
                        Text("Words the mic hears instead of \(profile.babyName.isEmpty ? "the name" : profile.babyName), e.g. \"luka, luke, look, looka\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("luka, luke, look, looka, lou, lucas", text: $aliasesText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: aliasesText) { val in
                                profile.nameAliases = val
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                                    .filter { !$0.isEmpty }
                            }
                    }
                    .padding(.vertical, 2)

                    Toggle(isOn: $profile.isOnlyBaby) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Only Baby at Home")
                            Text("Track all baby-related talk as \(profile.babyName.isEmpty ? "this baby" : profile.babyName)'s — no need to say the name. Turn off if multiple children live here.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Speech") {
                    #if BABBLE_ON_DEVICE
                    Picker("Language", selection: $profile.whisperLanguage) {
                        Text("Auto-detect").tag("auto")
                        Text("English").tag("en")
                        Text("Chinese (Mandarin)").tag("zh")
                        Text("English + Chinese").tag("en+zh")
                        Text("Cantonese").tag("yue")
                    }
                    #else
                    LabeledContent("Backend URL") {
                        TextField("http://localhost:8000", text: $profile.backendURL)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    #endif
                }

                Section("Speakers") {
                    if speakerStore.speakers.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "person.fill.questionmark")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No speakers enrolled")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.primary)
                                Text("Enroll caregivers so the app knows who is speaking. Without voice profiles, all speech is logged as unknown.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(speakerStore.speakers) { speaker in
                            Label(speaker.label, systemImage: "person.circle")
                        }
                    }
                    Button("Manage Speakers") {
                        showSpeakers = true
                    }
                }

                Section("Debug") {
                    ShareLink(
                        item: LogFileWriter.shared.fileURL,
                        preview: SharePreview("babble.log", image: Image(systemName: "doc.text"))
                    ) {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    Button("Reset Profile", role: .destructive) {
                        showResetAlert = true
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                aliasesText = profile.nameAliases.joined(separator: ", ")
            }
            .task {
                await speakerStore.syncFromBackend(backendURL: profile.backendURL)
            }
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
