import Foundation

// ============================================================
//  BabyEvent.swift — Core data model for all logged events
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  Every baby-related moment flows through this model:
//    Gemini /analyze → AnalyzeResponse → EventStore.apply() → BabyEvent[]
//    Manual entry     → EventStore.insert() → BabyEvent
//
//  On-disk format: JSON array of BabyEvent, one file per day.
//  Dates are stored as ISO-8601 strings so they survive time zone changes.
//
//  DESIGN PRINCIPLES (from event-schema.md)
//  -----------------------------------------
//  1. Typed details — each event type has its own structured payload,
//     not a flat bag of nullable strings.
//  2. Confidence always included — low-confidence events shown as "possibly".
//  3. Source quote always included — for debugging and parent corrections.
//  4. One event = one moment — don't merge or split.
//  5. Status tracking — events can be in-progress (e.g. nap started but
//     not yet ended) or completed.

// ============================================================
//  BabyEvent — a single logged moment in the baby's day
// ============================================================
struct BabyEvent: Identifiable, Codable, Equatable {

    // ── Identity ──────────────────────────────────────────────────────

    /// Unique identifier — UUID string assigned by backend or locally on insert.
    var id: String

    /// Category of the event (feeding, sleep, diaper, etc.).
    var type: EventType

    /// More specific classification within the category.
    /// Examples: "breast", "bottle", "solids" for feeding; "wet", "dirty" for diaper.
    var subtype: String?

    // ── Timing ────────────────────────────────────────────────────────

    /// When the event actually happened, as reported by Gemini from the transcript.
    /// May differ from `createdAt` — e.g. "she ate at 3 pm" said at 3:15 pm.
    var timestamp: Date

    /// How reliable the timestamp is. Gemini estimates times from context clues.
    var timestampConfidence: TimestampConfidence?

    /// Wall-clock time when the event was first written to disk.
    var createdAt: Date?

    // ── Content ───────────────────────────────────────────────────────

    /// Human-readable description from Gemini.
    /// Example: "Breastfed 15 min left side, 10 min right side."
    var detail: String

    /// True if Gemini flagged this as particularly important — unusual health note,
    /// developmental milestone, first time doing something.
    var notable: Bool

    /// Gemini's confidence in this event (0.0–1.0).
    /// Below 0.6 → show as "possibly" in UI. Below 0.4 → dimmed.
    var confidence: Float?

    /// The exact phrase from the transcript that produced this event.
    /// Used for debugging and letting parents correct misinterpretations.
    var sourceQuote: String?

    /// History of manual edits applied by caregivers (timestamp + previous detail).
    var editHistory: [EditEntry]?

    // ── People ────────────────────────────────────────────────────────

    /// Speaker label from diarization (e.g. "Mom", "Dad", "Nanny").
    var speaker: String?

    /// Additional labels: "first_time", "urgent", "cluster_feeding", "new_allergen".
    var tags: [String]?

    // ── Status ────────────────────────────────────────────────────────

    /// Whether this event is ongoing or finished.
    /// Examples: nap_start → .inProgress until nap_end → .completed.
    /// Feeding in progress → .inProgress until parent says "done" → .completed.
    var status: EventStatus?

    // ── Structured details ────────────────────────────────────────────
    //
    //  Type-specific payload. Each event type has its own struct so fields
    //  are typed, not a generic string bag. Gemini populates what it can;
    //  null fields mean "not mentioned in the transcript".

    var feedingDetails: FeedingDetails?
    var sleepDetails: SleepDetails?
    var diaperDetails: DiaperDetails?
    var healthDetails: HealthDetails?
    var milestoneDetails: MilestoneDetails?
    var moodDetails: MoodDetails?
    var activityDetails: ActivityDetails?
    var growthDetails: GrowthDetails?
    var accidentDetails: AccidentDetails?

    // ── Convenience ───────────────────────────────────────────────────

    /// True if this event has any "urgent" tag.
    var isUrgent: Bool { tags?.contains("urgent") == true }

    /// True if this is a first-time event (milestone, new food, etc.).
    var isFirstTime: Bool { tags?.contains("first_time") == true }

    /// True if this event has been edited by a caregiver after creation.
    var wasEdited: Bool { (editHistory?.isEmpty == false) }

    // ================================================================
    //  MARK: - EventStatus
    // ================================================================

    enum EventStatus: String, Codable {
        /// Event is actively happening (e.g. nap started, feeding in progress).
        case inProgress = "in_progress"
        /// Event has concluded (e.g. nap ended, feeding finished).
        case completed
        /// Gemini isn't sure this actually happened.
        case tentative
    }

    // ================================================================
    //  MARK: - TimestampConfidence
    // ================================================================

    enum TimestampConfidence: String, Codable {
        /// Parent said the exact time: "she ate at 3pm".
        case exact
        /// Gemini estimated from context: "just now", "a little while ago".
        case estimated
        /// No time reference in transcript — used the clip timestamp.
        case unknown
    }

    // ================================================================
    //  MARK: - EventType
    // ================================================================
    //
    //  Top-level categories. Each maps to an emoji and display name.
    //  Subtypes provide finer classification within the `subtype` field.
    //
    //  Category     Subtypes
    //  ─────────    ──────────────────────────────────────────────────
    //  feeding      breast, bottle, solids, pumping
    //  sleep        nap, night (with phase: start/end)
    //  diaper       wet, dirty, mixed
    //  health       fever, symptom, medication, vaccine, doctor_visit
    //  milestone    (domain in details: motor/language/cognitive/social/feeding)
    //  mood         (value in details: happy/fussy/crying/drowsy/etc.)
    //  activity     tummy_time, bath, outing, play, reading, music, class
    //  growth       (from well visits — weight, height, head circumference)
    //  accident     fall, bump, scratch, bite, burn, choking, other
    //  cry          crying episode (often triggered by cry detector)
    //  newFood      first time eating a specific food (also tagged first_time)
    //  emotionalSupport  caregiver stress detected — gentle check-in
    //  observation  anything that doesn't fit a structured type

    enum EventType: String, Codable, CaseIterable {
        case feeding
        case sleep
        case diaper
        case health = "health_note"
        case milestone
        case mood
        case activity
        case growth
        case accident
        case cry
        case newFood = "new_food"
        case emotionalSupport = "emotional_support"
        case observation

        var displayName: String {
            switch self {
            case .feeding:          return "Feeding"
            case .sleep:            return "Sleep"
            case .diaper:           return "Diaper"
            case .health:           return "Health"
            case .milestone:        return "Milestone"
            case .mood:             return "Mood"
            case .activity:         return "Activity"
            case .growth:           return "Growth"
            case .accident:         return "Accident"
            case .cry:              return "Crying"
            case .newFood:          return "New Food"
            case .emotionalSupport: return "Support"
            case .observation:      return "Note"
            }
        }

        var emoji: String {
            switch self {
            case .feeding:          return "🍼"
            case .sleep:            return "😴"
            case .diaper:           return "🚼"
            case .health:           return "🩺"
            case .milestone:        return "⭐"
            case .mood:             return "🫠"
            case .activity:         return "🎮"
            case .growth:           return "📏"
            case .accident:         return "🩹"
            case .cry:              return "😢"
            case .newFood:          return "🥕"
            case .emotionalSupport: return "💛"
            case .observation:      return "📝"
            }
        }
    }

    // ================================================================
    //  MARK: - Feeding details
    // ================================================================
    //
    //  Each feeding subtype has its own struct — breastfeeding tracks
    //  side/latch, bottle tracks amount/formula, solids tracks food/reaction.
    //  Only one of the four cases is populated per event.
    //
    //  WHY AN ENUM, NOT A FLAT STRUCT?
    //  --------------------------------
    //  A flat struct would have 20+ fields where most are nil. For example:
    //    - Breastfeeding doesn't have amountOz, formulaBrand, foodName
    //    - Bottle doesn't have side, leftMin, rightMin, latchQuality
    //    - Solids doesn't have side, contents, formulaBrand
    //  An enum with associated values makes it clear which fields belong
    //  to which subtype. The JSON encoder uses the subtype key to pick
    //  the right case.

    enum FeedingDetails: Codable, Equatable {
        /// Breastfeeding — tracks side, duration per side, latch quality.
        case breast(Breast)
        /// Bottle — tracks amount, contents (formula vs pumped milk), whether baby finished.
        case bottle(Bottle)
        /// Solids / baby-led weaning — tracks food name, preparation, reaction, allergen flag.
        case solids(Solids)
        /// Pumping — tracks output per side. Not a baby event per se, but parents track it.
        case pumping(Pumping)

        struct Breast: Codable, Equatable {
            var side: String?          // "left" | "right" | "both"
            var durationMin: Int?      // total nursing minutes
            var leftMin: Int?          // minutes on left side
            var rightMin: Int?         // minutes on right side
            var latchQuality: String?  // "good" | "poor" | "refused"
            var issues: String?        // "unlatching repeatedly"
        }

        struct Bottle: Codable, Equatable {
            var amountOz: Double?      // ounces consumed
            var amountMl: Double?      // millilitres consumed
            var contents: String?      // "formula" | "pumped_milk" | "donor_milk" | "water"
            var formulaBrand: String?  // "Enfamil", "Similac", etc.
            var finished: Bool?        // did baby finish the bottle?
            var issues: String?        // "gassy after", "refused halfway"
        }

        struct Solids: Codable, Equatable {
            var foodName: String?      // "sweet potato", "banana", "rice cereal"
            var preparation: String?   // "puree" | "mashed" | "finger_food" | "cereal"
            var amount: String?        // "a few spoonfuls", "half a jar"
            var firstTime: Bool?       // first time trying this food → tagged "first_time"
            var reaction: String?      // "loved it", "made a face", "refused"
            var allergenic: Bool?      // true for top-8 allergens (peanut, egg, dairy, etc.)
        }

        struct Pumping: Codable, Equatable {
            var leftOz: Double?        // output from left side
            var rightOz: Double?       // output from right side
            var totalOz: Double?       // combined output
            var durationMin: Int?      // session duration
        }
    }

    // ================================================================
    //  MARK: - Sleep details
    // ================================================================
    //
    //  Sleep is logged as two events: start and end.
    //  Start event: phase=.start, location, sleepAssociation populated.
    //  End event:   phase=.end, durationMin, quality populated.
    //  The backend matches start→end pairs to calculate total sleep.

    struct SleepDetails: Codable, Equatable {
        /// Whether this is the beginning or end of a sleep period.
        var phase: Phase?

        /// How long the sleep lasted (minutes). Only on .end events.
        var durationMin: Int?

        /// Where the baby slept.
        var location: String?          // "crib" | "bassinet" | "arms" | "stroller" | "car" | "contact"

        /// What got the baby to sleep — important for sleep training tracking.
        var sleepAssociation: String?  // "nursing" | "rocking" | "pacifier" | "independent"

        /// Overall sleep quality. Only on .end events.
        var quality: String?           // "great" | "normal" | "short" | "refused"

        /// True if this is a wake-up during the night period (not morning wake).
        var nightWake: Bool?

        /// Cumulative night wakes so far. Populated on the morning .end event.
        var wakeCountTonight: Int?

        enum Phase: String, Codable {
            case start                 // baby went down
            case end                   // baby woke up
        }
    }

    // ================================================================
    //  MARK: - Diaper details
    // ================================================================
    //
    //  Flag rules (applied by backend, surfaced in UI):
    //    white stool → tag "urgent" — possible biliary atresia, needs ER
    //    red stool   → tag "urgent" — possible blood
    //    green stool → tag "monitor" — often normal, but note in summary
    //    severe rash → tag "urgent"

    struct DiaperDetails: Codable, Equatable {
        var stoolColor: String?        // "yellow" | "green" | "brown" | "black" | "red" | "white"
        var stoolConsistency: String?  // "normal" | "loose" | "watery" | "hard" | "mucousy"
        var blowout: Bool?             // did it escape the diaper?
        var rashNoted: Bool?
        var rashSeverity: String?      // "mild" | "moderate" | "severe"
    }

    // ================================================================
    //  MARK: - Health details
    // ================================================================
    //
    //  Health is broad — uses subtype to differentiate:
    //    "fever"        → tempC, tempF, measurementMethod
    //    "symptom"      → symptom, severity, associatedSymptoms
    //    "medication"   → medicationName, doseMl, reason
    //    "vaccine"      → vaccines[], postVaccineFever
    //    "doctor_visit" → visitType, findings, measurements
    //
    //  Like feeding, this could be an enum. Kept as a struct because
    //  doctor visits often include fever readings + measurements +
    //  findings all at once, and an enum would force picking one.

    struct HealthDetails: Codable, Equatable {
        // ── Fever ──
        var tempC: Double?             // 38.1
        var tempF: Double?             // 100.6 (either or both may be present)
        var measurementMethod: String? // "rectal" | "forehead" | "ear" | "axillary"

        // ── Symptom ──
        var symptom: String?           // "congestion", "cough", "vomiting"
        var severity: String?          // "mild" | "moderate" | "severe"
        var associatedSymptoms: [String]? // ["runny nose", "sneezing"]

        // ── Medication ──
        var medicationName: String?    // "Tylenol", "Motrin"
        var doseMl: Double?            // 2.5
        var reason: String?            // "fever", "teething pain"

        // ── Vaccine ──
        var vaccines: [String]?        // ["DTaP", "Hib", "PCV15", "IPV", "RV"]
        var postVaccineFever: Bool?

        // ── Doctor visit ──
        var visitType: String?         // "well_visit" | "sick_visit" | "telehealth" | "specialist"
        var findings: String?          // "lungs clear, viral URI"
        var instructions: String?      // "rest, monitor fever, come back if worse"

        // ── Measurements (from well visits) ──
        var weightKg: Double?
        var heightCm: Double?
        var headCircumferenceCm: Double?
    }

    // ================================================================
    //  MARK: - Milestone details
    // ================================================================
    //
    //  Developmental firsts. Domain helps group milestones in the
    //  summary report (motor milestones vs language milestones).

    struct MilestoneDetails: Codable, Equatable {
        /// Which developmental area: motor (rolling, walking), language (first word),
        /// cognitive (object permanence), social (first smile), feeding (self-feeding).
        var domain: String?            // "motor" | "language" | "cognitive" | "social" | "feeding"
        var description: String?       // "rolled from back to front unassisted"
        var firstTime: Bool?           // true → add "first_time" tag
        var whoWitnessed: String?      // "Dad", "Mom"
    }

    // ================================================================
    //  MARK: - Mood details
    // ================================================================
    //
    //  Tracks emotional state over a period, not a point-in-time.
    //  Useful for detecting patterns (always fussy after daycare,
    //  happiest in the morning, etc.).

    struct MoodDetails: Codable, Equatable {
        var value: String?             // "happy" | "content" | "alert" | "fussy" | "crying" | "inconsolable" | "drowsy"
        var trigger: String?           // "overtired", "hungry", "teething", "stranger anxiety"
        var resolved: Bool?            // did the mood improve?
        var resolution: String?        // "calmed after nap", "distracted with toy"
        var durationDescription: String? // "all morning", "about 20 minutes"
    }

    // ================================================================
    //  MARK: - Activity details
    // ================================================================
    //
    //  Subtype (in parent BabyEvent) differentiates:
    //    tummy_time, bath, outing, play, reading, music, class, other

    struct ActivityDetails: Codable, Equatable {
        var durationMin: Int?          // how long the activity lasted
        var location: String?          // "play mat", "park", "bathtub"
        var description: String?       // "hates tummy time but we're getting there"
        var withCaregiver: String?     // "Mom", "Dad", "Nanny"
    }

    // ================================================================
    //  MARK: - Growth details
    // ================================================================
    //
    //  Usually from doctor well visits or home scale readings.
    //  Both metric and imperial stored — Gemini converts if only one
    //  unit system is mentioned.

    struct GrowthDetails: Codable, Equatable {
        var weightKg: Double?
        var weightLbs: Double?
        var heightCm: Double?
        var heightIn: Double?
        var headCircumferenceCm: Double?
        var source: String?            // "doctor_visit" | "home_scale" | "manual_entry"
    }

    // ================================================================
    //  MARK: - Accident details
    // ================================================================
    //
    //  For when the baby gets hurt — extremely common for 0–3 year olds
    //  learning to crawl, walk, and climb. Tracks what happened, where
    //  on the body, severity, and what was done about it.
    //
    //  Severity guide (for Gemini):
    //    minor    — crying but calmed quickly, no visible injury
    //    moderate — visible bump/bruise/bleeding, needed ice or bandaid
    //    severe   → tag "urgent" — hit head hard, won't stop crying,
    //               vomiting after head injury, needs ER

    struct AccidentDetails: Codable, Equatable {
        var injuryType: String?        // "fall" | "bump" | "scratch" | "bite" | "burn" | "choking" | "other"
        var bodyPart: String?          // "head" | "face" | "arm" | "leg" | "hand" | "mouth" | "other"
        var severity: String?          // "minor" | "moderate" | "severe"
        var context: String?           // "fell off couch", "bumped head on table corner"
        var treatment: String?         // "ice pack", "bandaid", "nothing needed", "ER visit"
        var symptoms: [String]?        // ["crying", "bump/swelling", "bleeding", "vomiting"]
    }
}

extension BabyEvent {
    struct EditEntry: Codable, Equatable {
        var editedAt: Date
        var previousDetail: String?
    }
}

// ============================================================
//  EventCorrection — Gemini says a previously logged event was wrong
// ============================================================
//  When a new transcript provides context that contradicts an earlier event,
//  Gemini returns corrections instead of (or alongside) new events.
//  Example: "actually she only ate for 5 minutes, not 15"
//           → correction with action=update, fields={"detail": "Breastfed 5 min."}

struct EventCorrection: Codable {
    /// The `id` of the BabyEvent to change or remove.
    var eventId: String

    /// What to do: update specific fields, or delete the event entirely.
    var action: CorrectionAction

    /// For `update` actions — a map of field names to new values.
    var fields: [String: String]?

    /// Why this correction was made (from Gemini).
    var reason: String?

    enum CorrectionAction: String, Codable {
        case update
        case delete
    }
}

// ============================================================
//  AnalyzeResponse — full payload from the backend /analyze endpoint
// ============================================================
struct AnalyzeResponse: Codable {
    /// New events extracted from this audio clip.
    var newEvents: [BabyEvent]

    /// Changes to previously logged events.
    var corrections: [EventCorrection]

    /// How many corrections were actually applied on the server side.
    var correctionsApplied: Int?

    /// One-sentence summary of this clip (used to build daily narrative).
    var summaryHint: String?

    /// Token counts for cost tracking.
    var usage: UsageInfo?
}

// ============================================================
//  UsageInfo — Gemini token counts for cost tracking
// ============================================================
struct UsageInfo: Codable {
    var inputTokens: Int?
    var outputTokens: Int?
}
