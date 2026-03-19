import Foundation

struct BabyEvent: Identifiable, Codable, Equatable {
    var id: String
    var type: EventType
    var timestamp: Date
    var detail: String
    var notable: Bool
    var speaker: String?
    var createdAt: Date?

    enum EventType: String, Codable, CaseIterable {
        case feeding
        case napStart = "nap_start"
        case napEnd = "nap_end"
        case cry
        case diaper
        case outing
        case healthNote = "health_note"
        case activity
        case newFood = "new_food"
        case milestone
        case observation

        var displayName: String {
            switch self {
            case .feeding: return "Feeding"
            case .napStart: return "Nap Start"
            case .napEnd: return "Nap End"
            case .cry: return "Crying"
            case .diaper: return "Diaper"
            case .outing: return "Outing"
            case .healthNote: return "Health Note"
            case .activity: return "Activity"
            case .newFood: return "New Food"
            case .milestone: return "Milestone"
            case .observation: return "Observation"
            }
        }

        var emoji: String {
            switch self {
            case .feeding: return "🍼"
            case .napStart: return "😴"
            case .napEnd: return "☀️"
            case .cry: return "😢"
            case .diaper: return "🚼"
            case .outing: return "🚗"
            case .healthNote: return "🩺"
            case .activity: return "🎮"
            case .newFood: return "🥕"
            case .milestone: return "⭐"
            case .observation: return "📝"
            }
        }
    }
}

// Correction applied by Gemini to a prior event
struct EventCorrection: Codable {
    var eventId: String
    var action: CorrectionAction
    var fields: [String: String]?

    enum CorrectionAction: String, Codable {
        case update
        case delete
    }
}

// Full response from /analyze
struct AnalyzeResponse: Codable {
    var newEvents: [BabyEvent]
    var corrections: [EventCorrection]
    var correctionsApplied: Int?
    var usage: UsageInfo?
}

struct UsageInfo: Codable {
    var inputTokens: Int?
    var outputTokens: Int?
}
