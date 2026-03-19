import SwiftUI

struct SpeakersView: View {
    @EnvironmentObject var speakerStore: SpeakerStore
    @EnvironmentObject var profile: BabyProfile
    @Environment(\.dismiss) var dismiss
    @State private var editingLabel: String = ""
    @State private var editingSpeakerId: String? = nil
    @State private var showRename = false

    var body: some View {
        NavigationStack {
            List {
                if speakerStore.speakers.isEmpty {
                    ContentUnavailableView(
                        "No speakers enrolled",
                        systemImage: "person.wave.2",
                        description: Text("Speakers are automatically detected and you'll be prompted to name them.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(speakerStore.speakers) { speaker in
                        HStack {
                            Image(systemName: "person.circle")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(speaker.label)
                                    .font(.body.weight(.medium))
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

                            Button {
                                editingLabel = speaker.label
                                editingSpeakerId = speaker.id
                                showRename = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        Task { await speakerStore.syncFromBackend(backendURL: profile.backendURL) }
                    }) {
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
        }
    }
}
