import SwiftUI

struct HomeView: View {
    @EnvironmentObject var profile: BabyProfile
    @EnvironmentObject var eventStore: EventStore
    @EnvironmentObject var speakerStore: SpeakerStore

    @StateObject private var monitorVM: MonitorViewModel
    @StateObject private var eventListVM: EventListViewModel
    @State private var showSummary = false
    @State private var showSettings = false
    @State private var isHoldingRecord = false
    @State private var recordMode: String = "edit"   // "edit" | "support"
    @State private var showReply = false

    init() {
        // These will be replaced with proper injection via .onAppear
        // SwiftUI doesn't allow EnvironmentObject in @StateObject initializer,
        // so we use a placeholder — overwritten in onAppear.
        _monitorVM = StateObject(wrappedValue: MonitorViewModel(
            profile: BabyProfile(), eventStore: EventStore(), speakerStore: SpeakerStore()
        ))
        _eventListVM = StateObject(wrappedValue: EventListViewModel(
            eventStore: EventStore(), analysisService: AnalysisService()
        ))
    }

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
                        Task {
                            // For support mode: send as voice note
                            // (ManualRecording handled inside MonitorVM)
                        }
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
                ForEach(eventListVM.events.reversed()) { event in
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
        .listStyle(.plain)
        .refreshable {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            await eventListVM.refreshFromBackend(dateStr: fmt.string(from: Date()))
        }
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
