import Foundation

// ============================================================
//  DaySummary.swift — Data model for the daily report card
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  SummaryViewModel calls POST /summary/generate → Gemini reads all of
//  today's BabyEvents and writes a structured summary. The backend
//  returns JSON that decodes into this struct. SummaryView renders it.
//
//  Data flow:
//    EventStore (today's events) → backend /summary/generate → Gemini
//    → DaySummary JSON → SummaryViewModel.summary → SummaryView
//
//  STRUCTURE
//  ---------
//  The "rich" fields (oneLiner, statsBar, feeding, sleep, …) are the
//  current format. The "legacy" fields (structured, narrative) are kept
//  for backward compatibility with older backend versions that returned
//  a flat narrative string instead of structured sections.
//
//  All fields are optional — Gemini only populates sections when relevant
//  events exist. For example, `health` is nil on a normal day but
//  present when a fever or medication was logged.
//
//  ALSO CONTAINS
//  -------------
//  SpeakerProfile — data model for enrolled voice profiles (Mom, Dad, etc.)
//  Lives here because it's a small shared model used by both SpeakerStore
//  and the diarization pipeline.

struct DaySummary: Codable {
    // MARK: - New rich structure (per daily-report-design.md)
    var oneLiner: String?               // warm one-sentence day summary
    var statsBar: StatsBar?             // quick-scan totals row
    var feeding: FeedingSection?        // timeline + totals
    var sleep: SleepSection?            // timeline + totals
    var diapers: DiapersSection?        // counts + anomaly note
    var health: HealthSection?          // only present when something was logged
    var milestones: [String]?           // notable moments / first times
    var moodArc: String?                // mood & behavior paragraph
    var pediatricianSummary: String?    // structured text for the doctor
    var socialTweet: String?            // <280 char shareable line with emoji

    // MARK: - Legacy fields (kept for backward-compat with old backend responses)
    var structured: Structured?
    var narrative: String?
    var usage: UsageInfo?

    // MARK: - Stats bar

    struct StatsBar: Codable {
        var feedCount: Int?
        var sleepHoursTotal: Double?
        var wetCount: Int?
        var dirtyCount: Int?
        var healthStatus: String?   // "normal" | "flagged"
    }

    // MARK: - Feeding

    struct FeedingSection: Codable {
        var totalCount: Int?
        var totalVolume: String?    // "~22 oz" or nil
        var entries: [FeedingEntry]?
        var flags: [String]?        // warnings (refused feeds, new allergen, etc.)
    }

    struct FeedingEntry: Codable {
        var time: String            // "7:10 am"
        var type: String            // "Bottle", "Breast L/R", "Solids"
        var detail: String?         // "4 oz", "first time", etc.
    }

    // MARK: - Sleep

    struct SleepSection: Codable {
        var totalMinutes: Int?
        var dayMinutes: Int?
        var nightMinutes: Int?
        var entries: [SleepEntry]?
        var flags: [String]?
    }

    struct SleepEntry: Codable {
        var label: String           // "Nap 1", "Night"
        var start: String           // "9:05 am"
        var end: String?            // "10:50 am"
        var durationMinutes: Int?
        var notes: String?          // "woke 2x: 12:40am, 3:55am"
    }

    // MARK: - Diapers

    struct DiapersSection: Codable {
        var wetCount: Int?
        var dirtyCount: Int?
        var note: String?           // color / consistency anomalies
    }

    // MARK: - Health

    struct HealthSection: Codable {
        var entries: [HealthEntry]?
        var summary: String?
    }

    struct HealthEntry: Codable {
        var time: String
        var detail: String
    }

    // MARK: - Legacy structured (kept for backend version compat)

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
    var nameVariants: [String]?   // ASR transcriptions of this speaker saying the baby's name
    var createdAt: String?
    var updatedAt: String?
}
