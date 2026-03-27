import AVFoundation
import Speech
import SwiftUI

// ============================================================
//  SpeakersView.swift — Enrolled speaker management
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  Accessed from SettingsView. Lists all enrolled voice profiles
//  (Mom, Dad, Nanny, etc.) and lets caregivers:
//    - Add a new speaker by recording a short audio sample
//    - Rename an existing speaker
//    - Delete a speaker (removes voice embedding from backend)
//
//  ENROLLMENT
//  ----------
//  The user holds a record button and speaks (ideally saying the
//  baby's name). The audio is sent to POST /speakers/enroll on
//  the backend, which extracts a pyannote voice embedding and
//  stores it. Future /diarize calls match incoming audio against
//  all stored embeddings to label speakers.

struct SpeakersView: View {
    @EnvironmentObject var speakerStore: SpeakerStore
    @EnvironmentObject var profile: BabyProfile
    @Environment(\.dismiss) var dismiss
    @State private var editingLabel: String = ""
    @State private var editingSpeakerId: String? = nil
    @State private var showRename = false
    @State private var showEnroll = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            List {
                if speakerStore.speakers.isEmpty {
                    ContentUnavailableView(
                        "No speakers enrolled",
                        systemImage: "person.wave.2",
                        description: Text("Tap + to record and register a speaker's voice.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(speakerStore.speakers) { speaker in
                        HStack {
                            Image(systemName: "person.circle")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                // Tapping the label opens a quick-pick menu
                                Menu {
                                    ForEach(["Mom", "Dad", "Grandma", "Grandpa"], id: \.self) { role in
                                        Button(role) {
                                            Task {
                                                await speakerStore.rename(speakerId: speaker.id, newLabel: role, backendURL: profile.backendURL)
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("Custom…") {
                                        editingLabel = speaker.label
                                        editingSpeakerId = speaker.id
                                        showRename = true
                                    }
                                    Divider()
                                    Button("Remove Speaker", role: .destructive) {
                                        Task {
                                            await speakerStore.delete(speakerId: speaker.id, backendURL: profile.backendURL)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(speaker.label)
                                            .font(.body.weight(.medium))
                                            .foregroundColor(.primary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                if let count = speaker.sampleCount {
                                    Text("\(count) sample\(count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await speakerStore.delete(speakerId: speaker.id, backendURL: profile.backendURL)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            // Add Speaker button — placed in SwiftUI VStack, not UIKit bottom bar
            Button {
                showEnroll = true
            } label: {
                Label("Add Speaker", systemImage: "person.badge.plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            } // end VStack
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await speakerStore.syncFromBackend(backendURL: profile.backendURL) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await speakerStore.syncFromBackend(backendURL: profile.backendURL)
            }
            .alert("Rename Speaker", isPresented: $showRename) {
                TextField("Name", text: $editingLabel)
                Button("Save") {
                    guard let id = editingSpeakerId, !editingLabel.isEmpty else { return }
                    Task {
                        await speakerStore.rename(speakerId: id, newLabel: editingLabel, backendURL: profile.backendURL)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a new name for this speaker.")
            }
            .sheet(isPresented: $showEnroll) {
                Task { await speakerStore.syncFromBackend(backendURL: profile.backendURL) }
            } content: {
                EnrollSpeakerView()
                    .environmentObject(speakerStore)
                    .environmentObject(profile)
            }
        }
    }
}

// ============================================================
//  EnrollSpeakerView — record 15s clip and send to backend
// ============================================================

private struct EnrollSpeakerView: View {
    @EnvironmentObject var speakerStore: SpeakerStore
    @EnvironmentObject var profile: BabyProfile
    @Environment(\.dismiss) var dismiss

    // Detected / confirmed speaker label
    @State private var selectedLabel: String = ""      // chosen role chip or custom text
    @State private var customName: String = ""          // text field when "Custom" chosen
    @State private var showCustomField: Bool = false    // expand custom text field

    @State private var phase: Phase = .idle
    @State private var secondsLeft: Int = 15
    @State private var recordingTimer: Timer?
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var nameVariants: [String] = []   // extracted from enrollment ASR
    @State private var errorMessage: String?
    @State private var analysisTask: Task<Void, Never>?

    // idle → recording → analysing → confirm → enrolling
    private enum Phase { case idle, recording, analysing, confirm, enrolling }

    private static let roleChips = ["Mom", "Dad", "Grandma", "Grandpa"]

    private var finalLabel: String {
        showCustomField ? customName.trimmingCharacters(in: .whitespaces) : selectedLabel
    }

    private let minSeconds = 5
    private let totalSeconds = 15

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                switch phase {
                case .idle, .recording:
                    recordingSection
                case .analysing:
                    analysingSection
                case .confirm:
                    confirmSection
                case .enrolling:
                    enrollingSection
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.3), value: phase)
            .navigationTitle("Add Speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        stopRecording()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                // Clean up if the sheet is dismissed via swipe without tapping Cancel
                stopRecording()
                analysisTask?.cancel()
                analysisTask = nil
            }
        }
    }

    // MARK: - Sub-views

    /// Idle + recording: script card + big mic button
    private var recordingSection: some View {
        let babyName = profile.babyName.isEmpty ? "Baby" : profile.babyName
        return VStack(spacing: 24) {

            // ── Script card ─────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                Text("Say this phrase")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Text("\"Hi \(babyName), this is ")
                    .font(.body)
                    .foregroundColor(.primary)
                + Text("Mom / Dad / Grandma / Grandpa")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.accentColor)
                + Text(", I love you and wish you happy every day.\"")
                    .font(.body)
                    .foregroundColor(.primary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            // ── Mic button ──────────────────────────────────────────
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(circleColor.opacity(0.15))
                        .frame(width: 130, height: 130)
                    Circle()
                        .fill(circleColor)
                        .frame(width: 96, height: 96)
                    Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.white)
                }
                .onTapGesture { handleTap() }

                if phase == .recording {
                    Text("\(secondsLeft)s")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundColor(secondsLeft <= minSeconds ? .orange : .primary)
                    Text(secondsLeft > minSeconds ? "Recording…" : "Tap to stop early.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Tap to start")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Brief spinner while transcribing + pitch analysis runs
    private var analysingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Identifying speaker…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    /// Role picker — tap a chip or type a custom name, then save.
    private var confirmSection: some View {
        VStack(spacing: 24) {

            VStack(spacing: 12) {
                Text("Who is this?")
                    .font(.headline)

                // 2×2 role chip grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Self.roleChips, id: \.self) { role in
                        Button {
                            selectedLabel = role
                            showCustomField = false
                            customName = ""
                        } label: {
                            Text(role)
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(selectedLabel == role && !showCustomField
                                            ? Color.accentColor
                                            : Color(.secondarySystemBackground))
                                .foregroundColor(selectedLabel == role && !showCustomField
                                                 ? .white : .primary)
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Custom name option
                Button {
                    showCustomField = true
                    selectedLabel = ""
                } label: {
                    Label("Custom name…", systemImage: "pencil")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(showCustomField
                                    ? Color.accentColor.opacity(0.12)
                                    : Color(.secondarySystemBackground))
                        .foregroundColor(showCustomField ? .accentColor : .secondary)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                if showCustomField {
                    TextField("e.g. Linda, Auntie, Nanny", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
            }

            Button {
                Task { await enroll() }
            } label: {
                Text("Save")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(finalLabel.isEmpty)

            Button("Re-record") {
                phase = .idle
                selectedLabel = ""
                customName = ""
                showCustomField = false
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }

    /// Second recording step — speaker says the baby's name in different ways.
    /// ASR output becomes name_variants for personalized wake word detection.


    private var enrollingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Saving voice profile…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private var circleColor: Color {
        phase == .recording ? .red : .accentColor
    }

    // MARK: - Actions

    private func handleTap() {
        switch phase {
        case .idle:
            startRecording()
        case .recording:
            if secondsLeft <= totalSeconds - minSeconds {
                stopRecording()
                analysisTask = Task { await analyseRecording() }
            }
        default:
            break
        }
    }

    private func startRecording() {
        errorMessage = nil
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrollment_\(UUID().uuidString).wav")
        recordingURL = tmpURL

        let settings: [String: Any] = [
            AVFormatIDKey:             Int(kAudioFormatLinearPCM),
            AVSampleRateKey:           16000,
            AVNumberOfChannelsKey:     1,
            AVLinearPCMBitDepthKey:    16,
            AVLinearPCMIsFloatKey:     false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let rec = try AVAudioRecorder(url: tmpURL, settings: settings)
            guard rec.record() else {
                errorMessage = "Failed to start recording. Check microphone permissions."
                try? AVAudioSession.sharedInstance().setActive(false)
                return
            }
            recorder = rec
            phase = .recording
            secondsLeft = totalSeconds
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak rec] _ in
                // rec is unused here; we only reference it to avoid capturing self strongly.
                // Actual state mutations go through @State, dispatched to main actor.
                Task { @MainActor in tick() }
            }
        } catch {
            errorMessage = "Microphone error: \(error.localizedDescription)"
        }
    }

    private func tick() {
        secondsLeft -= 1
        if secondsLeft <= 0 {
            stopRecording()
            analysisTask = Task { await analyseRecording() }
        }
    }

    private func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // Transcribe + run SpeakerRoleDetector, then move to confirm.
    // Always lands on confirm regardless of whether detection succeeded.
    private func analyseRecording() async {
        phase = .analysing
        defer { phase = .confirm }
        guard let url = recordingURL else { return }

        // Request speech recognition authorization if needed
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }

        let recognizer = SFSpeechRecognizer()
        guard recognizer?.isAvailable == true else { return }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        var detection: SpeakerRoleDetector.Detection? = nil

        do {
            let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { cont in
                // Use a class box so the flag is shared — not copied — across concurrent callbacks.
                final class Once: @unchecked Sendable { var done = false }
                let once = Once()
                recognizer?.recognitionTask(with: request) { result, error in
                    guard !once.done else { return }
                    if let error { once.done = true; cont.resume(throwing: error); return }
                    if let result, result.isFinal { once.done = true; cont.resume(returning: result) }
                }
            }
            detection = SpeakerRoleDetector.detect(from: result, babyName: profile.babyName)

            // Extract name variants from the same transcript — the speaker said
            // the baby's name in the script, so whatever ASR produced for it is
            // how their voice sounds to the recognizer. Keep only words starting
            // with the same letter as the baby's name to filter out noise words.
            let firstChar = profile.babyName.prefix(1).lowercased()
            if !firstChar.isEmpty {
                let words = result.bestTranscription.formattedString
                    .lowercased()
                    .components(separatedBy: .whitespacesAndNewlines)
                    .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                    .filter { $0.hasPrefix(firstChar) && $0.count >= 2 }
                nameVariants = Array(Set(words)).sorted()
            }
        } catch {
            // ASR failed — will fall through to file-based pitch below
        }

        // Fallback: compute pitch directly from raw WAV if ASR gave nothing
        if detection == nil, let url = recordingURL {
            detection = await SpeakerRoleDetector.detectFromFile(url)
        }

        if let detection {
            if Self.roleChips.contains(detection.label) {
                selectedLabel = detection.label
            } else {
                // Custom name (e.g. "Linda") → put in the text field
                customName = detection.label
                showCustomField = true
            }
        }
    }

    private func enroll() async {
        guard let url = recordingURL,
              let data = try? Data(contentsOf: url) else {
            errorMessage = "Recording not found."
            return
        }
        let label = finalLabel
        guard !label.isEmpty else { return }

        phase = .enrolling
        #if BABBLE_ON_DEVICE
        if #available(iOS 26.0, *) {
            if let err = await speakerStore.enrollOnDevice(label: label, audioData: data, nameVariants: nameVariants) {
                errorMessage = err
                phase = .confirm
            } else {
                try? FileManager.default.removeItem(at: url)
                dismiss()
            }
        } else {
            // Fallback to backend enroll on older OS
            if let err = await speakerStore.enroll(label: label, audioData: data, nameVariants: nameVariants, backendURL: profile.backendURL) {
                errorMessage = err
                phase = .confirm
            } else {
                try? FileManager.default.removeItem(at: url)
                dismiss()
            }
        }
        #else
        if let err = await speakerStore.enroll(label: label, audioData: data, nameVariants: nameVariants, backendURL: profile.backendURL) {
            errorMessage = err
            phase = .confirm
        } else {
            try? FileManager.default.removeItem(at: url)
            dismiss()
        }
        #endif
    }
}
