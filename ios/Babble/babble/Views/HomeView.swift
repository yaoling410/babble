import SwiftUI

// ============================================================
//  HomeView.swift — Main monitoring screen
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  The primary screen after setup. Shown by RootView when
//  profile.babyName is non-empty. Contains:
//
//  1. StatusBadge — pulsing dot showing pipeline state
//     (idle → listening → wake detected → capturing → analyzing)
//
//  2. EventListView — today's events grouped by time of day,
//     with swipe-to-delete and pull-to-refresh from backend
//
//  3. BottomBar — hold-to-record button + mode toggle (edit/support)
//     + summary button
//
//  4. Sheets: SummaryView, SettingsView, UnknownSpeakerSheet
//
//  ALSO CONTAINS
//  -------------
//  - StatusBadge: visual state indicator (green=listening, orange=capturing, etc.)
//  - EventListView: list with time-bucketed sections
//  - EventGroup: time bucket model (morning/afternoon/evening/night)
//  - BottomBar: record button + mode toggle + summary shortcut
//  - HoldRecordButton: press-and-hold mic button for manual recording
//  - UnknownSpeakerSheet: prompt to name a new voice

struct HomeView: View {
    @EnvironmentObject var profile: BabyProfile
    @EnvironmentObject var eventStore: EventStore
    @EnvironmentObject var speakerStore: SpeakerStore
    @EnvironmentObject var monitorVM: MonitorViewModel
    @EnvironmentObject var eventListVM: EventListViewModel
    @EnvironmentObject var summaryVM: SummaryViewModel

    @State private var showSummary = false
    @State private var showSettings = false
    @State private var isHoldingRecord = false
    @State private var recordMode: String = "edit"   // "edit" | "support"
    @State private var showReply = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status badge
                StatusBadge(state: monitorVM.state, babyName: profile.babyName)
                    .padding(.top, 12)
                    .padding(.horizontal)

                // Event list
                EventListView(eventListVM: eventListVM)

                // Bottom bar
                BottomBar(
                    isHolding: $isHoldingRecord,
                    recordMode: $recordMode,
                    onHoldStart: { monitorVM.startManualRecording() },
                    onHoldEnd: { mode in
                        Task { await monitorVM.stopManualRecording(mode: mode) }
                    },
                    onSummaryTap: { showSummary = true }
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationTitle("\(profile.babyName)'s Day")
            .navigationBarTitleDisplayMode(.inline)
            // Unknown speaker prompt
            .sheet(item: $speakerStore.unknownSpeakerPrompt) { prompt in
                UnknownSpeakerSheet(prompt: prompt)
                    .environmentObject(speakerStore)
                    .environmentObject(profile)
            }
            // Support mode reply sheet
            .alert("Babble says...", isPresented: $showReply, presenting: monitorVM.replyText) { _ in
                Button("OK") { monitorVM.replyText = nil }
            } message: { text in
                Text(text)
            }
            .sheet(isPresented: $showSummary) {
                SummaryView()
                    .environmentObject(profile)
                    .environmentObject(eventStore)
                    .environmentObject(summaryVM)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(profile)
                    .environmentObject(speakerStore)
            }
        }
        .task {
            await monitorVM.startMonitoring()
            await eventListVM.refreshFromBackend(dateStr: todayStr())
        }
        .onChange(of: monitorVM.replyText) { text in
            if text != nil { showReply = true }
        }
        // Vault hourly pass detected caregiver emotional distress — gentle check-in
        .alert("💛 Just checking in", isPresented: $monitorVM.emotionalSupportDetected) {
            Button("I'm OK") { monitorVM.emotionalSupportDetected = false }
            Button("Talk to Babble") {
                recordMode = "support"
                monitorVM.startManualRecording()
            }
        } message: {
            Text("We noticed you might be having a tough moment. You're doing an amazing job. Would you like to talk?")
        }
    }

    private func todayStr() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let state: MonitorViewModel.State
    let babyName: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)

            Text(statusText)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
    }

    var dotColor: Color {
        switch state {
        case .listening: return .green
        case .wakeDetected, .capturing: return .orange
        case .analyzing: return .blue
        case .recording: return .red
        case .error: return .red
        case .idle: return .gray
        }
    }

    var isPulsing: Bool {
        switch state {
        case .listening, .capturing, .recording, .analyzing: return true
        default: return false
        }
    }

    var statusText: String {
        switch state {
        case .idle: return "Tap to start"
        case .listening: return "Listening for \(babyName)..."
        case .wakeDetected: return "Wake word detected!"
        case .capturing: return "Capturing..."
        case .analyzing: return "Analyzing..."
        case .recording: return "Recording — release to send"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

// MARK: - Event List

struct EventListView: View {
    @ObservedObject var eventListVM: EventListViewModel
    @EnvironmentObject var eventStore: EventStore

    var body: some View {
        List {
            if eventListVM.events.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "ear",
                    description: Text("Say \(Text("your baby's name").italic()) to start logging.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(eventListVM.groupedEvents, id: \.bucket) { group in
                    Section(header: TimeBucketHeader(label: group.bucket.displayLabel)) {
                        ForEach(group.events.reversed()) { event in
                            EventRowView(
                                event: event,
                                isNew: eventStore.newEventIDs.contains(event.id),
                                isCorrected: eventStore.correctedEventIDs.contains(event.id)
                            )
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await eventListVM.delete(event: event) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await eventListVM.refreshFromBackend(dateStr: Self.todayStr())
        }
    }

    private static let _dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static func todayStr() -> String { _dateFmt.string(from: Date()) }
}

struct EventGroup {
    enum Bucket: String, Hashable {
        case earlyNight = "Night (early)"
        case morning = "Morning"
        case afternoon = "Afternoon"
        case evening = "Evening"
        case lateNight = "Night"

        var displayLabel: String { rawValue }

        init(hour: Int) {
            switch hour {
            case 0...5:   self = .earlyNight
            case 6...11:  self = .morning
            case 12...17: self = .afternoon
            case 18...21: self = .evening
            default:      self = .lateNight
            }
        }
    }
    let bucket: Bucket
    let events: [BabyEvent]
}

struct TimeBucketHeader: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(nil)
    }
}

// MARK: - Bottom Bar

struct BottomBar: View {
    @Binding var isHolding: Bool
    @Binding var recordMode: String
    let onHoldStart: () -> Void
    let onHoldEnd: (String) -> Void
    let onSummaryTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // Summary button
                Button(action: onSummaryTap) {
                    VStack(spacing: 2) {
                        Image(systemName: "doc.text")
                        Text("Summary").font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)

                // Hold-to-record
                HoldRecordButton(
                    isHolding: $isHolding,
                    mode: $recordMode,
                    onHoldStart: onHoldStart,
                    onHoldEnd: onHoldEnd
                )
                .frame(maxWidth: .infinity)

                // Mode toggle (edit vs support)
                Button(action: {
                    recordMode = recordMode == "edit" ? "support" : "edit"
                }) {
                    VStack(spacing: 2) {
                        Image(systemName: recordMode == "edit" ? "pencil.circle" : "heart.circle")
                        Text(recordMode == "edit" ? "Edit" : "Support").font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }
}

struct HoldRecordButton: View {
    @Binding var isHolding: Bool
    @Binding var mode: String
    let onHoldStart: () -> Void
    let onHoldEnd: (String) -> Void

    // @GestureState automatically resets to false when the gesture ends or is cancelled —
    // far more reliable than DragGesture.onEnded for detecting finger lift.
    @GestureState private var isPressing = false

    var body: some View {
        Circle()
            .fill(isHolding ? Color.red : Color.accentColor)
            .frame(width: 60, height: 60)
            .overlay {
                Image(systemName: isHolding ? "stop.fill" : "mic.fill")
                    .foregroundColor(.white)
                    .font(.title2)
            }
            .scaleEffect(isHolding ? 1.15 : 1.0)
            .animation(.spring(response: 0.3), value: isHolding)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressing) { _, state, _ in state = true }
                    .onChanged { _ in
                        if !isHolding {
                            isHolding = true
                            onHoldStart()
                        }
                    }
                    .onEnded { _ in
                        isHolding = false
                        onHoldEnd(mode)
                    }
            )
            .onChange(of: isPressing) { pressing in
                // Fallback: if GestureState resets without onEnded firing
                if !pressing && isHolding {
                    isHolding = false
                    onHoldEnd(mode)
                }
            }
    }
}

// MARK: - Unknown Speaker Sheet

struct UnknownSpeakerSheet: View {
    let prompt: SpeakerStore.UnknownSpeakerPrompt
    @EnvironmentObject var speakerStore: SpeakerStore
    @EnvironmentObject var profile: BabyProfile
    @State private var name: String = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("A new voice was detected (\(prompt.tempLabel)). Who is this?")
                        .foregroundColor(.secondary)
                }
                Section {
                    TextField("Name (e.g. Mom, Dad, Grandma)", text: $name)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle("New Speaker")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Skip") {
                        speakerStore.dismissPrompt()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let label = name.trimmingCharacters(in: .whitespaces)
                        guard !label.isEmpty else { return }
                        Task {
                            await speakerStore.enroll(
                                label: label,
                                audioData: prompt.audioData,
                                backendURL: profile.backendURL
                            )
                            speakerStore.dismissPrompt()
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
