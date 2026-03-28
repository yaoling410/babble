import Foundation
import Combine

// ============================================================
//  BabyProfile.swift — Baby and caregiver configuration
// ============================================================
//
//  PURPOSE
//  -------
//  Stores all user-configurable settings about the baby and the
//  app environment. All values are persisted to UserDefaults so
//  they survive app restarts without any separate save step.
//
//  Properties are @Published so SwiftUI views rebuild automatically
//  when any value changes (e.g. parent updates baby age in Settings).
//
//  USAGE
//  -----
//  BabyProfile is created once in BabbleApp.init() and injected
//  into the environment. Access it in any view with:
//    @EnvironmentObject var profile: BabyProfile
//
//  SPEECH LOCALES
//  --------------
//  Each locale creates one SFSpeechRecognizer session in WakeWordService.
//  Common configurations:
//    ["en-US"]           — English only (default)
//    ["zh-CN"]           — Mandarin only
//    ["zh-HK"]           — Cantonese only
//    ["en-US", "zh-CN"]  — English + Mandarin (bilingual household)
//    ["en-US", "zh-HK"]  — English + Cantonese
//
//  Adding more locales increases CPU usage proportionally — each locale
//  runs its own independent recognition session.

/// Baby profile stored in UserDefaults, publishing changes to SwiftUI.
final class BabyProfile: ObservableObject {

    /// The baby's primary name as typed by the caregiver.
    /// Stored lowercase for case-insensitive wake word matching.
    /// Empty string = first-run state; shows SetupView instead of HomeView.
    @Published var babyName: String {
        didSet { UserDefaults.standard.set(babyName, forKey: "babyName") }
    }

    /// Baby's age in whole months. Used in Gemini prompts for age-appropriate
    /// context (e.g. "6 months old → starting solids is typical").
    @Published var babyAgeMonths: Int {
        didSet { UserDefaults.standard.set(babyAgeMonths, forKey: "babyAgeMonths") }
    }

    /// True if this is the only baby at home. When true, ALL baby-related
    /// conversation is attributed to this baby — no need to hear the name.
    /// "She pooped", "he's sleeping", "the baby ate" all count.
    /// When false, the name must appear to distinguish between children.
    @Published var isOnlyBaby: Bool {
        didSet { UserDefaults.standard.set(isOnlyBaby, forKey: "isOnlyBaby") }
    }

    /// Base URL of the FastAPI backend (no trailing slash).
    /// Default points to a local network host (common for home server setups).
    /// Example: "http://10.0.0.100:8000" or "https://babble.example.com"
    @Published var backendURL: String {
        didSet { UserDefaults.standard.set(backendURL, forKey: "backendURL") }
    }

    /// BCP-47 locale identifiers passed to WakeWordService.
    /// One SFSpeechRecognizer session is created per locale.
    /// See file header for common configurations.
    @Published var speechLocales: [String] {
        didSet { UserDefaults.standard.set(speechLocales, forKey: "speechLocales") }
    }

    /// Words the speech recognizer commonly outputs instead of the baby's name.
    /// Example: ["look", "luke", "looka"] for a baby named "Luca".
    /// These are treated as exact matches for wake word detection.
    @Published var nameAliases: [String] {
        didSet { UserDefaults.standard.set(nameAliases, forKey: "nameAliases") }
    }

    /// WhisperKit transcription language mode for the on-device build.
    /// "auto" = auto-detect per window (handles bilingual mid-sentence switching).
    /// "en" = English only, "zh" = Chinese only, "en+zh" = both (auto-detect between them).
    @Published var whisperLanguage: String {
        didSet { UserDefaults.standard.set(whisperLanguage, forKey: "whisperLanguage") }
    }

    /// When true and running iOS 26+, use Apple's on-device Foundation Models
    /// (3B LLM) for event extraction instead of the Gemini backend.
    @Published var useOnDeviceAnalysis: Bool {
        didSet { UserDefaults.standard.set(useOnDeviceAnalysis, forKey: "useOnDeviceAnalysis") }
    }

    /// All the ways WhisperKit might transcribe the baby's name, discovered
    /// by running enrollment audio through multiple language decoders.
    /// E.g. ["look a", "露卡", "陆卡", "looka"] for "Luca".
    /// Used as WhisperKit prompt bias, RelevanceGate aliases, and FM correction hints.
    @Published var nameVariants: [String] {
        didSet { UserDefaults.standard.set(nameVariants, forKey: "nameVariants") }
    }

    /// Path to the saved name enrollment WAV (relative to App Support).
    /// Kept so we can re-decode when the user changes language settings.
    @Published var nameEnrollmentAudioPath: String? {
        didSet { UserDefaults.standard.set(nameEnrollmentAudioPath, forKey: "nameEnrollmentAudioPath") }
    }

    /// Known ASR mishearings for common baby names.
    /// Used to seed the aliases field on first launch so the wake word
    /// recognizer is already biased toward the correct name.
    static func defaultAliases(for lowercasedName: String) -> [String] {
        switch lowercasedName {
        case "luca":
            // How en-US SFSpeechRecognizer commonly mishears "Luca":
            //   luka  — alternate Latin spelling, same sound
            //   luke  — similar vowel, common English name
            //   look  — short vowel collapse, very common mishearing
            //   looka — "look-a", trailing vowel preserved
            //   lou   — first syllable only
            //   lucas — trailing -s added by LM
            //   lucia — feminine form, LM sometimes prefers it
            return ["luka", "luke", "look", "looka", "lou", "lucas", "lucia"]
        default:
            return []
        }
    }

    init() {
        // Load from UserDefaults, falling back to sensible defaults for first run.
        self.babyName      = UserDefaults.standard.string(forKey: "babyName") ?? ""
        self.babyAgeMonths = UserDefaults.standard.integer(forKey: "babyAgeMonths")
        self.isOnlyBaby    = UserDefaults.standard.object(forKey: "isOnlyBaby") == nil ? true : UserDefaults.standard.bool(forKey: "isOnlyBaby")
        self.backendURL    = UserDefaults.standard.string(forKey: "backendURL") ?? "http://10.0.0.100:8000"
        self.speechLocales = UserDefaults.standard.stringArray(forKey: "speechLocales") ?? ["en-US"]
        self.whisperLanguage = UserDefaults.standard.string(forKey: "whisperLanguage") ?? "auto"
        self.useOnDeviceAnalysis = UserDefaults.standard.bool(forKey: "useOnDeviceAnalysis")
        self.nameVariants = UserDefaults.standard.stringArray(forKey: "nameVariants") ?? []
        self.nameEnrollmentAudioPath = UserDefaults.standard.string(forKey: "nameEnrollmentAudioPath")
        // Load saved aliases, or seed with known ASR mishearings for common names.
        // Seeds when the key is absent OR when it's an empty array (user hasn't
        // manually edited aliases yet — an empty array was stored by a previous
        // version before defaultAliases was added).
        let savedAliases = UserDefaults.standard.object(forKey: "nameAliases") as? [String]
        if let saved = savedAliases, !saved.isEmpty {
            self.nameAliases = saved
        } else {
            let name = (UserDefaults.standard.string(forKey: "babyName") ?? "").lowercased()
            let defaults = BabyProfile.defaultAliases(for: name)
            self.nameAliases = defaults
            // Persist so the next launch loads them directly
            if !defaults.isEmpty {
                UserDefaults.standard.set(defaults, forKey: "nameAliases")
            }
        }
    }
}
