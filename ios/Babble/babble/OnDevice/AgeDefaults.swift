import Foundation

enum AgeDefaults {
    static func bottleOz(ageMonths: Int) -> Double {
        switch ageMonths {
        case 0...1: return 2.5
        case 2...3: return 4
        case 4...6: return 5
        case 7...9: return 6
        case 10...12: return 6
        case 13...18: return 5
        default: return 5
        }
    }

    static func breastMinutes(ageMonths: Int) -> Int {
        switch ageMonths {
        case 0...1: return 25
        case 2...3: return 20
        case 4...6: return 17
        case 7...9: return 15
        case 10...12: return 14
        case 13...18: return 12
        default: return 12
        }
    }

    static func napMinutes(ageMonths: Int) -> Int {
        switch ageMonths {
        case 0...1: return 45
        case 2...3: return 60
        case 4...6: return 75
        case 7...9: return 90
        case 10...12: return 90
        case 13...18: return 105
        default: return 120
        }
    }

    static func solidsOz(ageMonths: Int) -> Double? {
        switch ageMonths {
        case 6...8: return 1
        case 9...11: return 2
        case 12...17: return 3
        case 18...24: return 4
        default: return nil
        }
    }


    static func feedsPerDay(ageMonths: Int) -> Int {
        switch ageMonths {
        case 0...1: return 10
        case 2...3: return 8
        case 4...6: return 7
        case 7...9: return 6
        case 10...12: return 5
        case 13...18: return 4
        default: return 3
        }
    }

    static func napsPerDay(ageMonths: Int) -> Int {
        switch ageMonths {
        case 0...1: return 5
        case 2...3: return 4
        case 4...6: return 3
        case 7...9: return 3
        case 10...12: return 2
        case 13...18: return 2
        default: return 1
        }
    }

    // MARK: - Age-appropriate events & activities
    //
    // Each age group has a predefined set of event types, activities,
    // and Chinese vocabulary that the LLM is allowed to extract.
    // Events outside this list are rejected post-extraction.
    //
    // Age groups:
    //   Newborn  (0–3 mo)  — feeding-heavy, burping, spit up, tummy time
    //   Infant   (4–6 mo)  — introducing solids, still burping, rolling
    //   Crawler  (7–12 mo) — crawling, pulling up, finger foods, no burping
    //   Toddler  (13–24 mo) — walking, tantrums, meals, self-feeding
    //   Toddler+ (25–36 mo) — talking, potty training, running

    struct AgeEventConfig {
        /// Event types the LLM is allowed to extract for this age group.
        var allowedTypes: Set<String>

        /// Activities that are typical for this age group.
        var typicalActivities: [String]

        /// Chinese vocabulary mapped to event types — used in the LLM prompt.
        var chineseVocab: [String]

        /// Age-specific notes for the LLM prompt.
        var notes: [String]
    }

    // ── Common events for all ages (0–36 months) ─────────────
    // These are merged into every age group's config.

    private static let commonAllowedTypes: Set<String> = [
        "feeding", "sleep", "diaper", "cry", "health_note",
        "milestone", "mood", "activity", "observation",
    ]

    private static let commonChineseVocab: [String] = [
        "拉屎/拉臭臭/拉粑粑 = pooped (diaper, subtype: dirty)",
        "换尿布 = diaper changed (diaper, status: completed)",
        "尿了/尿湿了 = wet diaper (diaper, subtype: wet)",
        "喂奶/吃奶 = feeding (feeding)",
        "喝水 = drinking water (feeding)",
        "睡觉/睡着了 = fell asleep (sleep, status: in_progress)",
        "醒了/起来了 = woke up (sleep, status: completed)",
        "哭了/闹了 = crying (cry)",
        "洗澡/冲凉 = bath (activity, subtype: bath)",
        "发烧/发热 = fever (health_note)",
        "咳嗽 = cough (health_note)",
        "流鼻涕 = runny nose (health_note)",
        "出去/外出/出门 = outing (activity, subtype: outing)",
        "玩/玩耍 = playing (play)",
    ]

    private static let commonNotes: [String] = [
        "Common across all ages: feeding, sleep, diaper, crying, bath, outings.",
        "Health notes: fever, cough, runny nose, rash — always track these.",
    ]

    /// Merge common config with age-specific config.
    private static func mergedConfig(
        extraTypes: Set<String> = [],
        activities: [String],
        extraVocab: [String],
        extraNotes: [String]
    ) -> AgeEventConfig {
        AgeEventConfig(
            allowedTypes: commonAllowedTypes.union(extraTypes),
            typicalActivities: activities,
            chineseVocab: commonChineseVocab + extraVocab,
            notes: commonNotes + extraNotes
        )
    }

    static func eventConfig(ageMonths: Int) -> AgeEventConfig {
        switch ageMonths {
        case 0...3:
            return mergedConfig(
                activities: ["tummy_time", "bath", "skin_to_skin"],
                extraVocab: [
                    "吐奶 = spit up (health_note)",
                    "打嗝/拍嗝/拍隔 = burping (activity)",
                    "趴着/趴趴 = tummy time (activity, subtype: tummy_time)",
                    "喝完了/吃完了 = feeding done (feeding, status: completed)",
                ],
                extraNotes: [
                    "Burping after every feed is normal at this age.",
                    "Spit up is common and usually not a concern.",
                    "Tummy time is an important activity.",
                ]
            )

        case 4...6:
            return mergedConfig(
                extraTypes: ["play", "new_food"],
                activities: ["tummy_time", "bath", "sensory_play"],
                extraVocab: [
                    "吐奶 = spit up (health_note)",
                    "打嗝/拍嗝 = burping (activity)",
                    "辅食 = solids/baby food (feeding, subtype: solids)",
                    "趴着 = tummy time (play, subtype: tummy_time)",
                    "翻身 = rolled over (milestone)",
                ],
                extraNotes: [
                    "Baby may be starting solids — first foods tracked as new_food.",
                    "Rolling over is a common milestone.",
                    "Burping still relevant but less frequent.",
                ]
            )

        case 7...12:
            return mergedConfig(
                extraTypes: ["play", "new_food"],
                activities: ["bath", "crawling", "play", "reading", "music"],
                extraVocab: [
                    "辅食/吃饭 = eating meal (feeding, subtype: solids)",
                    "爬/爬了 = crawling (milestone)",
                    "站/站起来 = standing (milestone)",
                    "长牙 = teething (health_note)",
                ],
                extraNotes: [
                    "No burping — do NOT extract burping events.",
                    "No spit up — baby has outgrown this.",
                    "Crawling, pulling up, standing are key milestones.",
                ]
            )

        case 13...24:
            return mergedConfig(
                extraTypes: ["play", "new_food", "accident"],
                activities: ["bath", "walking", "play", "reading", "music", "outing", "playground"],
                extraVocab: [
                    "吃饭/吃东西 = eating meal (feeding, subtype: solids)",
                    "走路/走了 = walking (milestone)",
                    "说话/叫妈妈/叫爸爸 = speaking (milestone)",
                    "闹脾气/发脾气 = tantrum (mood)",
                    "摔了/摔倒 = fell (accident)",
                    "长牙 = teething (health_note)",
                ],
                extraNotes: [
                    "No burping, no spit up, no tummy time at this age.",
                    "Walking, talking, and tantrums are common.",
                    "Falls and accidents are frequent — track with accident type.",
                ]
            )

        default: // 25+ months
            return mergedConfig(
                extraTypes: ["play", "accident"],
                activities: ["bath", "playground", "play", "reading", "outing", "potty"],
                extraVocab: [
                    "上厕所/坐马桶 = potty (diaper, subtype: potty)",
                    "吃饭 = eating meal (feeding, subtype: solids)",
                    "闹脾气/发脾气 = tantrum (mood)",
                    "摔了/摔倒 = fell (accident)",
                    "说话/说了 = speaking (milestone)",
                    "跑/跑了 = running (milestone)",
                ],
                extraNotes: [
                    "Potty training may be starting — track toilet attempts.",
                    "No burping, no spit up, no tummy time.",
                    "Running, jumping, and sentences are milestones.",
                ]
            )
        }
    }

    // MARK: - Auto-completion timeouts (used by OnDevicePipeline)

    static func autoCompleteTimeoutMinutes(eventType: String, subtype: String?) -> Int {
        switch eventType {
        case "sleep":    return 180  // 3 hours
        case "feeding":
            switch subtype {
            case "breast":  return 45
            case "bottle":  return 30
            case "solids":  return 30
            case "pumping": return 30
            default:        return 45
            }
        case "activity": return 60
        default:         return 120  // 2 hours
        }
    }

    // MARK: - Amount adjustment

    static func adjusted(_ value: Double, descriptor: AmountDescriptor) -> Double {
        let factor: Double
        switch descriptor {
        case .concrete:  return value
        case .vague:     return value
        case .small:     factor = 0.7
        case .large:     factor = 1.3
        }
        return (factor * value).rounded(.up)
    }

    enum AmountDescriptor: String, Codable {
        case concrete   // "4 oz" — caregiver gave a number
        case vague      // "had a bottle" — no amount
        case small      // "a little", "small feed"
        case large      // "a lot", "big feed"
    }
}
