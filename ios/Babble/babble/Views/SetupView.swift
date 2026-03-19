import SwiftUI
import AVFoundation
import Speech

struct SetupView: View {
    @EnvironmentObject var profile: BabyProfile
    @State private var name: String = ""
    @State private var ageMonths: Int = 6
    @State private var backendURL: String = "http://localhost:8000"
    @State private var isRequestingPermissions: Bool = false
    @State private var permissionError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Baby Profile") {
                    TextField("Baby's name", text: $name)
                        .textInputAutocapitalization(.words)
                    Stepper("Age: \(ageMonths) month\(ageMonths == 1 ? "" : "s")", value: $ageMonths, in: 0...48)
                }

                Section("Backend") {
                    TextField("Backend URL", text: $backendURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section {
                    if let error = permissionError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Button(action: setup) {
                        if isRequestingPermissions {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Start Monitoring")
                                .frame(maxWidth: .infinity)
                                .bold()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isRequestingPermissions)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Welcome to Babble")
        }
    }

    private func setup() {
        isRequestingPermissions = true
        permissionError = nil

        Task {
            // Request microphone
            let micGranted = await AVAudioSession.sharedInstance().requestRecordPermission()
            guard micGranted else {
                await MainActor.run {
                    permissionError = "Microphone access is required. Enable in Settings > Privacy > Microphone."
                    isRequestingPermissions = false
                }
                return
            }

            // Request speech recognition
            let speechStatus = await WakeWordService.requestAuthorization()
            guard speechStatus == .authorized else {
                await MainActor.run {
                    permissionError = "Speech recognition is required. Enable in Settings > Privacy > Speech Recognition."
                    isRequestingPermissions = false
                }
                return
            }

            await MainActor.run {
                profile.babyName = name.trimmingCharacters(in: .whitespaces)
                profile.babyAgeMonths = ageMonths
                profile.backendURL = backendURL.trimmingCharacters(in: .whitespaces)
                isRequestingPermissions = false
            }
        }
    }
}
