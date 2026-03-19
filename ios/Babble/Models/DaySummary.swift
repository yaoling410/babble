import Foundation

struct DaySummary: Codable {
    var structured: Structured?
    var narrative: String?
    var socialTweet: String?
    var usage: UsageInfo?

    struct Structured: Codable {
        var glance: [String]?
        var eating: Section?
        var nap: NapSection?
        var diaper: Section?
        var playMood: Section?
        var milestone: MilestoneSection?

        struct Section: Codable {
            var summary: String?
            var count: Int?
        }

        struct NapSection: Codable {
            var summary: String?
            var totalMinutes: Int?
        }

        struct MilestoneSection: Codable {
            var summary: String?
            var items: [String]?
        }
    }
}

struct SpeakerProfile: Identifiable, Codable {
    var id: String
    var label: String
    var sampleCount: Int?
    var createdAt: String?
    var updatedAt: String?
}
