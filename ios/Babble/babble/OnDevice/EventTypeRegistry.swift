import Foundation

// ============================================================
//  EventTypeRegistry — Single source of truth for event types
// ============================================================
//
//  Centralizes all event type metadata that was previously scattered:
//    - BabyEvent.EventType (display names, emojis)
//    - AgeDefaults (allowed types, age vocab)
//    - OnDeviceAnalysisService (validation keywords)
//    - RelevanceGate (relevance keywords)
//
//  To add a new event type or tweak age rules, edit ONLY this file.
//  Everything else reads from the registry.

enum EventTypeRegistry {

    // MARK: - Event definition

    struct EventDef {
        let type: String                // raw value: "feeding", "diaper", etc.
        let displayName: String
        let emoji: String
        let subtypes: [String]          // valid subtypes
        let ageRange: ClosedRange<Int>  // months: 0...36 = all ages
        let validationKeywords: ValidationKeywords?  // nil = no keyword gate
        let promptHint: String          // short instruction for LLM
    }

    struct ValidationKeywords {
        let zh: Set<String>
        let en: Set<String>

        var all: Set<String> { zh.union(en) }
    }

    // MARK: - Registry

    static let all: [EventDef] = [
        EventDef(
            type: "feeding",
            displayName: "Feeding",
            emoji: "🍼",
            subtypes: ["breast", "bottle", "solids", "pumping"],
            ageRange: 0...36,
            validationKeywords: ValidationKeywords(
                zh: ["喂奶", "吃奶", "喝奶", "喝水", "吃饭", "吃东西", "辅食",
                     "喝完", "吃完", "饿了", "奶瓶", "母乳", "配方",
                     "喂食", "吃了", "喝了"],
                en: ["feed", "feeding", "fed", "bottle", "breast", "nursing",
                     "ate", "eat", "eating", "milk", "formula", "solids",
                     "hungry", "drink", "drank"]
            ),
            promptHint: "Only when food/milk is consumed or offered"
        ),
        EventDef(
            type: "sleep",
            displayName: "Sleep",
            emoji: "😴",
            subtypes: ["nap", "night"],
            ageRange: 0...36,
            validationKeywords: ValidationKeywords(
                zh: ["睡觉", "睡着", "睡了", "醒了", "醒来", "起来了",
                     "午睡", "小睡", "困了", "入睡", "哄睡",
                     "夜醒", "夜奶", "睡眠"],
                en: ["sleep", "sleeping", "slept", "nap", "napping", "napped",
                     "woke", "awake", "asleep", "drowsy", "bedtime"]
            ),
            promptHint: "Sleep started (in_progress) or woke up (completed)"
        ),
        EventDef(
            type: "diaper",
            displayName: "Diaper",
            emoji: "🚼",
            subtypes: ["wet", "dirty", "mixed", "potty"],
            ageRange: 0...36,
            validationKeywords: ValidationKeywords(
                zh: ["拉屎", "拉臭", "拉粑", "便便", "大便", "小便", "尿了", "尿湿",
                     "换尿布", "换片", "尿布", "纸尿裤", "屙屎", "屙尿",
                     "上厕所", "坐马桶", "拉了"],
                en: ["poop", "pooped", "pooping", "pee", "peed", "peeing",
                     "diaper", "nappy", "blowout", "potty"]
            ),
            promptHint: "Only when actual poop/pee/diaper change happened"
        ),
        EventDef(
            type: "health_note",
            displayName: "Health",
            emoji: "🩺",
            subtypes: ["fever", "symptom", "medication", "vaccine", "doctor_visit"],
            ageRange: 0...36,
            validationKeywords: nil,  // health events are too varied to keyword-gate
            promptHint: "Fever, illness, medication, doctor visits"
        ),
        EventDef(
            type: "milestone",
            displayName: "Milestone",
            emoji: "⭐",
            subtypes: [],
            ageRange: 0...36,
            validationKeywords: nil,
            promptHint: "ONLY when caregiver shows excitement about a FIRST TIME achievement"
        ),
        EventDef(
            type: "mood",
            displayName: "Mood",
            emoji: "🫠",
            subtypes: [],
            ageRange: 0...36,
            validationKeywords: nil,
            promptHint: "Baby's emotional state — fussy, happy, cranky"
        ),
        EventDef(
            type: "activity",
            displayName: "Activity",
            emoji: "🎮",
            subtypes: ["bath", "outing", "learning", "class"],
            ageRange: 0...36,
            validationKeywords: nil,
            promptHint: "Bath, outing, learning words. Teaching baby = activity (subtype: learning)"
        ),
        EventDef(
            type: "play",
            displayName: "Play",
            emoji: "🧸",
            subtypes: ["sensory", "toys", "reading", "music", "free_play", "tummy_time"],
            ageRange: 4...36,  // no "play" for 0-3mo
            validationKeywords: nil,
            promptHint: "Interactive play sessions"
        ),
        EventDef(
            type: "growth",
            displayName: "Growth",
            emoji: "📏",
            subtypes: [],
            ageRange: 0...36,
            validationKeywords: nil,
            promptHint: "Weight, height, head circumference measurements"
        ),
        EventDef(
            type: "accident",
            displayName: "Accident",
            emoji: "🩹",
            subtypes: ["fall", "bump", "scratch", "bite", "burn", "choking"],
            ageRange: 7...36,  // rare before crawling age
            validationKeywords: nil,
            promptHint: "Falls, bumps, minor injuries"
        ),
        EventDef(
            type: "cry",
            displayName: "Crying",
            emoji: "😢",
            subtypes: [],
            ageRange: 0...36,
            validationKeywords: nil,
            promptHint: "Crying episode — usually from CryDetector, not transcript"
        ),
        EventDef(
            type: "new_food",
            displayName: "New Food",
            emoji: "🥕",
            subtypes: [],
            ageRange: 4...36,  // solids start ~4-6mo
            validationKeywords: nil,
            promptHint: "First time eating a specific food"
        ),
        EventDef(
            type: "emotional_support",
            displayName: "Support",
            emoji: "💛",
            subtypes: [],
            ageRange: 0...36,
            validationKeywords: nil,
            promptHint: "Caregiver emotional distress — never shown on timeline"
        ),
        EventDef(
            type: "observation",
            displayName: "Note",
            emoji: "📝",
            subtypes: [],
            ageRange: 0...36,
            validationKeywords: nil,
            promptHint: "Anything that doesn't fit a structured type"
        ),
    ]

    // MARK: - Lookup

    private static let byType: [String: EventDef] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.type, $0) })
    }()

    static func definition(for type: String) -> EventDef? {
        byType[type]
    }

    static func displayName(for type: String) -> String {
        byType[type]?.displayName ?? type
    }

    static func emoji(for type: String) -> String {
        byType[type]?.emoji ?? "📝"
    }

    // MARK: - Age filtering

    /// Event types allowed for a given age in months.
    static func allowedTypes(ageMonths: Int) -> Set<String> {
        Set(all.filter { $0.ageRange.contains(ageMonths) }.map { $0.type })
    }

    /// Event definitions allowed for a given age.
    static func allowedDefinitions(ageMonths: Int) -> [EventDef] {
        all.filter { $0.ageRange.contains(ageMonths) }
    }

    // MARK: - Validation keywords

    /// Get validation keywords for a given event type.
    /// Returns nil if the type doesn't require keyword validation.
    static func validationKeywords(for type: String) -> Set<String>? {
        byType[type]?.validationKeywords?.all
    }

    // MARK: - Prompt generation

    /// Build a compact type list with hints for the LLM prompt.
    /// Only includes types valid for the given age.
    static func promptTypeList(ageMonths: Int) -> String {
        allowedDefinitions(ageMonths: ageMonths)
            .map { "\($0.type): \($0.promptHint)" }
            .joined(separator: "\n")
    }

    /// Build a compact allowed-types string for the LLM prompt.
    static func allowedTypesString(ageMonths: Int) -> String {
        allowedTypes(ageMonths: ageMonths).sorted().joined(separator: ", ")
    }

    // MARK: - Age-specific vocabulary for WhisperKit prompt

    struct WhisperVocab {
        let zh: String
        let en: String
    }

    /// Returns age-appropriate vocabulary for WhisperKit prompt biasing.
    /// Only includes words caregivers actually say at this age.
    static func whisperVocab(ageMonths: Int) -> WhisperVocab {
        switch ageMonths {
        case 0...3:
            return WhisperVocab(
                zh: "拉屎 喂奶 吐奶 打嗝 拍嗝 换尿布 睡觉 醒了 哭了 趴着 发烧",
                en: "bottle pooped diaper feeding burp spit nap crying tummy time"
            )
        case 4...6:
            return WhisperVocab(
                zh: "拉屎 喂奶 辅食 吐奶 打嗝 换尿布 睡觉 醒了 哭了 翻身 发烧",
                en: "bottle pooped diaper feeding solids burp nap crying rolled over"
            )
        case 7...12:
            return WhisperVocab(
                zh: "拉屎 吃饭 辅食 换尿布 睡觉 醒了 哭了 爬了 站起来 长牙 发烧",
                en: "pooped eating diaper solids nap crying crawling standing teething"
            )
        case 13...24:
            return WhisperVocab(
                zh: "拉屎 吃饭 换尿布 睡觉 醒了 哭了 走路 说话 发脾气 摔了 发烧",
                en: "pooped eating diaper nap crying walking talking tantrum fell"
            )
        default:
            return WhisperVocab(
                zh: "拉屎 吃饭 上厕所 坐马桶 睡觉 醒了 哭了 跑了 说话 发脾气 摔了",
                en: "pooped eating potty diaper nap crying running talking tantrum fell"
            )
        }
    }

    // MARK: - Age-specific Chinese vocab for LLM prompt

    /// Returns Chinese vocabulary mapped to event types for the LLM extraction prompt.
    static func chineseVocabForPrompt(ageMonths: Int) -> [String] {
        // Common across all ages
        var vocab = [
            "拉屎/拉臭臭/拉粑粑 = pooped (diaper, subtype: dirty)",
            "换尿布 = diaper changed (diaper, status: completed)",
            "尿了/尿湿了 = wet diaper (diaper, subtype: wet)",
            "喂奶/吃奶 = feeding (feeding)",
            "喝水 = drinking water (feeding)",
            "睡觉/睡着了 = fell asleep (sleep, status: in_progress)",
            "醒了/起来了 = woke up (sleep, status: completed)",
            "哭了/闹了 = crying (cry)",
            "洗澡 = bath (activity, subtype: bath)",
            "发烧/发热 = fever (health_note)",
            "咳嗽 = cough (health_note)",
            "出去/外出 = outing (activity, subtype: outing)",
            "玩/玩耍 = playing (play)",
        ]

        // Age-specific additions
        switch ageMonths {
        case 0...3:
            vocab.append(contentsOf: [
                "吐奶 = spit up (health_note)",
                "打嗝/拍嗝/拍隔 = burping (activity)",
                "趴着/趴趴 = tummy time (activity, subtype: tummy_time)",
            ])
        case 4...6:
            vocab.append(contentsOf: [
                "吐奶 = spit up (health_note)",
                "打嗝/拍嗝 = burping (activity)",
                "辅食 = solids (feeding, subtype: solids)",
                "翻身 = rolled over (milestone)",
            ])
        case 7...12:
            vocab.append(contentsOf: [
                "辅食/吃饭 = eating meal (feeding, subtype: solids)",
                "爬/爬了 = crawling (milestone)",
                "站/站起来 = standing (milestone)",
                "长牙 = teething (health_note)",
            ])
        case 13...24:
            vocab.append(contentsOf: [
                "吃饭/吃东西 = eating meal (feeding, subtype: solids)",
                "走路/走了 = walking (milestone)",
                "说话/叫妈妈/叫爸爸 = speaking (milestone)",
                "闹脾气/发脾气 = tantrum (mood)",
                "摔了/摔倒 = fell (accident)",
                "长牙 = teething (health_note)",
            ])
        default:
            vocab.append(contentsOf: [
                "上厕所/坐马桶 = potty (diaper, subtype: potty)",
                "吃饭 = eating meal (feeding, subtype: solids)",
                "闹脾气/发脾气 = tantrum (mood)",
                "摔了/摔倒 = fell (accident)",
                "跑/跑了 = running (milestone)",
            ])
        }

        return vocab
    }

    // MARK: - Age-specific notes for LLM prompt

    static func ageNotes(ageMonths: Int) -> [String] {
        switch ageMonths {
        case 0...3:
            return [
                "Burping after feeds is normal.",
                "Spit up is common.",
            ]
        case 4...6:
            return [
                "May be starting solids.",
                "Rolling is a key milestone.",
            ]
        case 7...12:
            return [
                "No burping or spit up at this age.",
                "Crawling, standing are key milestones.",
            ]
        case 13...24:
            return [
                "No burping, spit up, or tummy time.",
                "Walking, talking, tantrums are common.",
            ]
        default:
            return [
                "Potty training may be starting.",
                "No burping, spit up, or tummy time.",
            ]
        }
    }
}
