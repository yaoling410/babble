import SwiftUI

// ============================================================
//  EventRowView.swift — Single event row in the event list
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  Used inside EventListView (HomeView.swift). One row per BabyEvent.
//
//  FEATURES
//  --------
//  - Emoji icon from event type (feeding, sleep, etc.)
//  - Notable star badge, edited pencil badge
//  - Speaker label ("Mom", "Dad") from diarization
//  - Tap to expand: shows full detail + edit history
//  - Row background color: green flash = new event, blue = corrected
//    (driven by EventStore.newEventIDs / correctedEventIDs)

struct EventRowView: View {
    let event: BabyEvent
    let isNew: Bool
    let isCorrected: Bool
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(event.type.emoji)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(event.type.displayName)
                            .font(.subheadline.weight(.semibold))

                        if event.notable {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                        }

                        if event.wasEdited {
                            Image(systemName: "pencil.circle.fill")
                                .foregroundColor(.blue.opacity(0.7))
                                .font(.caption)
                        }

                        Spacer()

                        Text(event.timestamp, style: .time)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }

                    Text(event.detail)
                        .font(.body)
                        .lineLimit(isExpanded ? nil : 2)
                        .foregroundColor(.primary)

                    if let speaker = event.speaker, !speaker.isEmpty {
                        Text(speaker)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Edit history — shown when expanded
                    if isExpanded, let history = event.editHistory, !history.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(history.indices, id: \.self) { i in
                                let entry = history[i]
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.editedAt, style: .relative)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(entry.previousDetail ?? "")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .strikethrough(true, color: .secondary.opacity(0.6))
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { isExpanded.toggle() } }
    }

    var rowBackground: some View {
        Group {
            if isNew {
                Color.green.opacity(0.12)
            } else if isCorrected {
                Color.blue.opacity(0.10)
            } else {
                Color.clear
            }
        }
        .animation(.easeOut(duration: 0.6), value: isNew)
        .animation(.easeOut(duration: 0.6), value: isCorrected)
    }
}
