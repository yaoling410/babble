import SwiftUI

struct SummaryView: View {
    @EnvironmentObject var profile: BabyProfile
    @EnvironmentObject var eventStore: EventStore
    @StateObject private var vm: SummaryViewModel

    init() {
        // placeholder — overwritten via onAppear
        _vm = StateObject(wrappedValue: SummaryViewModel(
            profile: BabyProfile(),
            analysisService: AnalysisService()
        ))
    }

    private var dateStr: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isGenerating {
                    ProgressView("Generating summary...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let summary = vm.summary {
                    SummaryContent(summary: summary, babyName: profile.babyName)
                } else {
                    ContentUnavailableView(
                        "No summary yet",
                        systemImage: "doc.text",
                        description: Text("Tap Generate to create today's summary.")
                    )
                }
            }
            .navigationTitle("Today's Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Generate") {
                        Task { await vm.generateSummary(dateStr: dateStr) }
                    }
                    .disabled(vm.isGenerating)
                }
            }
            .task {
                await vm.fetchCachedSummary(dateStr: dateStr)
            }
        }
    }
}

struct SummaryContent: View {
    let summary: DaySummary
    let babyName: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Glance pills
                if let glance = summary.structured?.glance, !glance.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(glance, id: \.self) { item in
                                Text(item)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                // Narrative
                if let narrative = summary.narrative {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Narrative", systemImage: "text.bubble")
                            .font(.headline)
                        Text(narrative)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal)
                }

                // Sections
                if let eating = summary.structured?.eating {
                    SummarySection(title: "Feeding", emoji: "🍼", text: eating.summary ?? "", count: eating.count)
                }
                if let nap = summary.structured?.nap {
                    SummarySection(title: "Nap", emoji: "😴", text: nap.summary ?? "", count: nil, minutes: nap.totalMinutes)
                }
                if let diaper = summary.structured?.diaper {
                    SummarySection(title: "Diaper", emoji: "🚼", text: diaper.summary ?? "", count: diaper.count)
                }
                if let play = summary.structured?.playMood {
                    SummarySection(title: "Play & Mood", emoji: "🎮", text: play.summary ?? "")
                }
                if let milestone = summary.structured?.milestone, let items = milestone.items, !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Milestones ⭐", systemImage: "star").font(.headline)
                        ForEach(items, id: \.self) { item in
                            Text("• \(item)")
                        }
                    }
                    .padding(.horizontal)
                }

                // Tweet
                if let tweet = summary.socialTweet {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Share", systemImage: "square.and.arrow.up").font(.headline)
                        Text(tweet)
                            .font(.body)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        ShareLink(item: tweet) {
                            Label("Share Tweet", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }
}

struct SummarySection: View {
    let title: String
    let emoji: String
    let text: String
    var count: Int? = nil
    var minutes: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(emoji) \(title)").font(.headline)
                Spacer()
                if let c = count { Text("\(c)x").foregroundColor(.secondary).font(.caption) }
                if let m = minutes { Text("\(m) min").foregroundColor(.secondary).font(.caption) }
            }
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }
}
