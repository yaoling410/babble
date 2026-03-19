import SwiftUI

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

                        Spacer()

                        Text(event.timestamp, style: .time)
                            .font(.caption)
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
