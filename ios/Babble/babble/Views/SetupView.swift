import SwiftUI
import UIKit
import AVFoundation
import Speech

// ============================================================
//  SetupView.swift — First-run onboarding screen
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  Shown by RootView when profile.babyName is empty (first launch).
//  Collects baby name, age, language preference, and backend URL.
//  Requests microphone + speech recognition permissions.
//
//  After the user taps "Start Monitoring":
//    1. Request mic permission → denied = show error + Settings link
//    2. Request speech recognition → denied = show error
//    3. Check on-device recognition support → warn if cloud-only
//    4. Save all values to BabyProfile (UserDefaults)
//    5. RootView sees babyName is non-empty → switches to HomeView
//
//  LANGUAGE OPTIONS
//  ----------------
//  SpeechLanguage enum maps UI choices to SFSpeechRecognizer locale IDs.
//  Each locale creates one parallel recognition session in WakeWordService.
//  "English + Chinese" runs two sessions → ~2x CPU during speech.

// Language options shown in the setup form.
// Each case maps to one or more SFSpeechRecognizer locale identifiers.
private enum SpeechLanguage: String, CaseIterable, Identifiable {
    case english    = "en"
    case mandarin   = "zh-CN"
    case cantonese  = "zh-HK"
    case bilingual  = "bilingual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english:   return "English"
        case .mandarin:  return "普通话 (Mandarin)"
        case .cantonese: return "粤语 (Cantonese)"
        case .bilingual: return "English + 中文"
        }
    }

    var locales: [String] {
        switch self {
        case .english:   return ["en-US"]
        case .mandarin:  return ["zh-CN"]
        case .cantonese: return ["zh-HK"]
        case .bilingual: return ["en-US", "zh-CN"]
        }
    }

    static func from(locales: [String]) -> SpeechLanguage {
        switch locales {
        case ["zh-CN"]:         return .mandarin
        case ["zh-HK"]:         return .cantonese
        case ["en-US", "zh-CN"]: return .bilingual
        default:                return .english
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var profile: BabyProfile
    @State private var name: String = ""
    @State private var ageMonths: Int = 6
    @State private var backendURL: String = "http://localhost:8000"
    @State private var language: SpeechLanguage = .english
    @State private var isRequestingPermissions: Bool = false
    @State private var permissionError: String? = nil
    @State private var showOnDeviceWarning: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Baby Profile") {
                    TextField("Baby's name", text: $name)
                        .textInputAutocapitalization(.words)
                    Stepper("Age: \(ageMonths) month\(ageMonths == 1 ? "" : "s")", value: $ageMonths, in: 0...48)
                    Picker("Language", selection: $language) {
                        ForEach(SpeechLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                }

                Section("Backend") {
                    TextField("Backend URL", text: $backendURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                if showOnDeviceWarning {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Audio processed in cloud")
                                    .font(.caption.weight(.semibold))
                                Text("Your device doesn't support on-device speech recognition. Wake word detection will use Apple's servers. Update to iOS 16 or later for full privacy and offline support.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Link("Go to Settings > General > Software Update",
                                     destination: URL(string: UIApplication.openSettingsURLString)!)
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
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
            .onAppear {
                name = profile.babyName
                ageMonths = profile.babyAgeMonths
                backendURL = profile.backendURL
                language = SpeechLanguage.from(locales: profile.speechLocales)
            }
        }
    }

    private func setup() {
        isRequestingPermissions = true
        permissionError = nil

        Task {
            // Request microphone
            let micGranted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
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

            // Check on-device recognition support for all selected locales — warn if any need cloud
            let onDeviceAvailable = WakeWordService.isOnDeviceRecognitionAvailable(for: language.locales)

            await MainActor.run {
                showOnDeviceWarning = !onDeviceAvailable
                profile.babyName = name.trimmingCharacters(in: .whitespaces)
                profile.babyAgeMonths = ageMonths
                profile.backendURL = backendURL.trimmingCharacters(in: .whitespaces)
                profile.speechLocales = language.locales
                isRequestingPermissions = false
            }
        }
    }
}
