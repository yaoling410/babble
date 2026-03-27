import Foundation

// ============================================================
//  RelevanceGate.swift — On-device relevance classifier
// ============================================================
//
//  Decides if a transcription window is about baby care.
//  WhisperKit transcribes continuously — most household audio
//  is not about the baby. This gate filters before the expensive
//  Foundation Models 3B analysis.
//
//  TWO-TIER DESIGN
//  ----------------
//  Level 1 (strict): Baby name, keywords, phrases, Chinese terms.
//          Always active. A Level 1 match starts/extends a 2-minute
//          "active period".
//
//  Level 2 (loose):  Question patterns, pronouns, contextual phrases.
//          Only active during the active period (2 min after L1 match).
//          Catches follow-up conversation like "是生病了吗?" spoken
//          seconds after "Luca拉屎了".
//
//  IMPORTANT: Only Level 1 matches extend the active period. Level 2
//  matches consume it but do not renew — prevents infinite chains of
//  loose matches keeping the window alive.

enum RelevanceGate {

    // MARK: - Result type

    enum GateResult {
        case passed(Level)
        case blocked

        enum Level: String {
            case level1 = "L1"
            case level2 = "L2"
        }

        var isRelevant: Bool {
            if case .passed = self { return true }
            return false
        }
    }

    // MARK: - Active period state

    /// Timestamp of the last Level 1 match.
    private(set) static var lastPassedAt: Date?

    /// Duration of the active period after a Level 1 match.
    private static let activePeriodDuration: TimeInterval = 120 // 2 minutes

    /// Whether we're in the active period (a Level 1 window passed recently).
    static var isActivePeriod: Bool {
        guard let last = lastPassedAt else { return false }
        return Date().timeIntervalSince(last) < activePeriodDuration
    }

    /// Call this when a Level 1 match occurs to start/extend the active period.
    static func markPassed() {
        lastPassedAt = Date()
    }

    /// Reset state (e.g. when pipeline stops).
    static func reset() {
        lastPassedAt = nil
    }

    // MARK: - Public gate

    static func isRelevant(text: String, babyName: String) -> GateResult {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return .blocked }

        let words = lower.split(separator: " ").map(String.init)

        // Chinese text has no spaces — skip minimum word guard
        let hasChinese = lower.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        if words.count < 3 && !hasChinese { return .blocked }
        if isOnlyFiller(words) { return .blocked }

        let wordSet = Set(words)

        // Level 1: strict keyword/name matching
        if checkLevel1(lower: lower, words: words, wordSet: wordSet, babyName: babyName, hasChinese: hasChinese) {
            return .passed(.level1)
        }

        // Level 2: looser conditions, only during active period
        if isActivePeriod && checkLevel2(lower: lower, words: words, wordSet: wordSet, hasChinese: hasChinese) {
            return .passed(.level2)
        }

        return .blocked
    }

    // MARK: - Level 1 (strict)

    private static func checkLevel1(
        lower: String,
        words: [String],
        wordSet: Set<String>,
        babyName: String,
        hasChinese: Bool
    ) -> Bool {
        // Baby's name
        if !babyName.isEmpty && lower.contains(babyName.lowercased()) { return true }

        // Single-word keywords (O(1))
        if !wordSet.isDisjoint(with: singleWordKeywords) { return true }

        // Multi-word phrases
        if multiWordPhrases.contains(where: { lower.contains($0) }) { return true }

        // Baby nicknames
        if babyNicknames.contains(where: { lower.contains($0) }) { return true }

        // Chinese keywords
        if chineseSingleCharKeywords.contains(where: { lower.contains($0) }) { return true }
        if chineseKeywords.contains(where: { lower.contains($0) }) { return true }

        // Pronoun + baby keyword co-occurrence (strict: >= 5 words)
        if hasPronounWithBabyContext(words) { return true }

        return false
    }

    // MARK: - Level 2 (loose, active period only)

    private static func checkLevel2(
        lower: String,
        words: [String],
        wordSet: Set<String>,
        hasChinese: Bool
    ) -> Bool {
        // Chinese question / continuation patterns
        if chineseLevel2Patterns.contains(where: { lower.contains($0) }) { return true }

        // English follow-up patterns
        if englishLevel2Patterns.contains(where: { lower.contains($0) }) { return true }

        // Bare pronouns with low threshold (>= 3 words)
        // Parents say "she's sick", "he ate" — during active period this is enough
        if words.count >= 3 && !wordSet.isDisjoint(with: level2Pronouns) { return true }

        return false
    }

    // MARK: - Pronoun + context (Level 1 helper)

    private static func hasPronounWithBabyContext(_ words: [String]) -> Bool {
        let pronouns: Set<String> = ["she", "he", "her", "him"]
        let hasPronoun = !Set(words).isDisjoint(with: pronouns)
        guard hasPronoun, words.count >= 5 else { return false }
        return !Set(words).isDisjoint(with: contextKeywords)
    }

    private static let contextKeywords: Set<String> = [
        "feed", "feeding", "bottle", "nursing", "milk", "eat", "eating", "ate", "hungry",
        "sleep", "sleeping", "slept", "nap", "napping", "awake", "woke", "tired",
        "diaper", "poop", "pee", "rash",
        "crying", "cried", "fussy", "fussing", "upset", "calm", "calmed",
        "bath", "medicine", "fever", "doctor", "teething",
        "crawl", "walked", "rolled", "smiled", "laughed",
    ]

    // ════════════════════════════════════════════════════════════
    // MARK: - Level 1 keywords
    // ════════════════════════════════════════════════════════════

    private static let singleWordKeywords: Set<String> = [
        // Feeding
        "feed", "feeding", "bottle", "nursing", "nurse", "breastfeed", "breastfeeding",
        "formula", "milk", "eat", "eating", "ate", "hungry", "hunger",
        "latch", "latched", "solids", "puree", "cereal", "sippy",
        "burp", "burping", "reflux", "swallow",
        "pumping", "pumped", "pump", "letdown",
        "foremilk", "hindmilk", "oversupply", "mastitis", "weaning",
        // Sleep
        "sleep", "sleeping", "slept", "nap", "napping", "napped", "awake",
        "woke", "tired", "drowsy", "bed", "bedtime",
        "crib", "bassinet", "overnight", "nighttime",
        "overtired", "undertired", "catnap",
        "dreamfeed", "ferber", "stirred", "stirring", "settled", "settling",
        // Diaper
        "diaper", "nappy", "poop", "pooped", "pooping", "pee", "peed", "peeing",
        "rash", "wipe", "wiped", "blowout", "straining",
        // Hygiene
        "bath", "bathing", "bathed", "wash", "washing", "washed",
        // Skin
        "eczema", "hives", "itchy", "itching", "scratching", "swollen", "swelling", "jaundice",
        // Health
        "sick", "fever", "temperature", "medicine", "medication", "dose",
        "tylenol", "ibuprofen", "motrin", "advil",
        "doctor", "pediatrician", "appointment", "vaccine", "vaccination",
        "hospital", "congestion", "congested", "cough", "coughing",
        "teething", "tooth", "teeth", "allergic", "allergy",
        "vomit", "vomiting", "diarrhea", "constipated",
        "weight", "height", "checkup", "antibiotic", "inhaler",
        "gassy", "windy", "colic", "colicky", "wheezing", "wheeze",
        "thrush", "rsv", "croup", "stridor", "jaundice", "gerd", "regression",
        // Milestones
        "smile", "smiled", "smiling", "laugh", "laughed", "laughing",
        "giggle", "giggled", "giggling",
        "crawl", "crawled", "crawling", "stand", "stood", "standing",
        "walked", "walking", "roll", "rolled", "rolling",
        "sit", "sat", "sitting", "grab", "grabbed",
        "wave", "waved", "waving", "clap", "clapped", "clapping",
        "point", "pointed", "pointing", "milestone", "cruising",
        // Speech
        "babbling", "babble", "talking", "cooing", "words", "sentence", "communicate",
        // Emotion
        "crying", "cried", "fuss", "fussy", "fussing", "upset", "inconsolable",
        "calm", "calmed", "calming", "content", "irritable",
        "soothed", "soothing", "comfort", "comforting",
        "clingy", "startled", "overstimulated",
        // Soothing
        "pacifier", "paci", "dummy", "soother",
        "swaddle", "swaddled", "swaddling",
        "rocking", "rocked", "bouncing", "bounced", "shushing",
        // Activity
        "stroller", "carrier", "swing", "bouncer",
        "daycare", "nursery", "nanny", "babysitter", "playground", "park",
        // Growth
        "ounce", "ounces", "oz", "milliliter", "gained", "percentile", "weighed",
    ]

    private static let multiWordPhrases: [String] = [
        "spit up", "spitting up", "cluster feeding", "breast milk", "breast pump",
        "milk supply", "nursing strike", "bottle refusal",
        "tongue tie", "lip tie", "clogged duct",
        "baby-led weaning", "baby led weaning", "high chair",
        "sippy cup", "first foods", "skin to skin",
        "went down", "put down", "fell asleep", "went to sleep",
        "woke up", "wake up", "down for",
        "night feed", "night waking", "sleep training", "cry it out",
        "wake window", "drowsy but awake", "contact nap",
        "dream feed", "fighting sleep", "sleep regression", "night terror",
        "blow out", "blood in stool", "green poop", "white stool",
        "ear infection", "runny nose", "hand foot mouth",
        "breathing fast", "arching back", "gripe water", "gas drops",
        "urgent care", "growth spurt", "cradle cap", "baby acne",
        "first time", "for the first time",
        "pulled up", "first steps", "first words",
        "said mama", "said dada", "tummy time",
        "separation anxiety", "stranger anxiety",
        "won't settle", "won't sleep", "won't stop crying",
        "middle of the night", "through the night",
        "did she eat", "did he eat",
        "still sleeping", "still napping",
        "back to sleep", "one side", "both sides",
    ]

    private static let babyNicknames = [
        "little one", "the little one", "our little",
        "little guy", "little girl", "little man", "little miss",
        "munchkin", "bubba", "bubs", "bub",
        "peanut", "bean", "nugget", "jellybean",
        "bambino", "sweetpea", "sweet pea",
        "tiny", "tiny one", "the baby", "our baby",
    ]

    // MARK: - Level 1 Chinese keywords

    private static let chineseSingleCharKeywords: Set<String> = [
        "哭", "奶", "睡", "吃", "尿", "拉", "烧", "饿", "困",
    ]

    private static let chineseKeywords: [String] = [
        "喂奶", "喂食", "奶瓶", "母乳", "哺乳", "配方奶", "吃奶",
        "辅食", "打嗝", "吐奶", "溢奶", "饿了", "奶量", "奶水",
        "吸奶", "泵奶", "堵奶", "乳腺炎",
        "飲奶", "食嘢", "餓了", "餵奶",
        "睡觉", "睡着了", "午睡", "小睡", "醒了", "醒来", "困了",
        "婴儿床", "入睡", "哄睡", "睡整觉",
        "夜醒", "夜奶", "夜哭", "睡眠训练",
        "瞓覺", "瞓著", "唔瞓",
        "尿布", "纸尿裤", "便便", "大便", "小便", "拉了",
        "换尿布", "尿布疹",
        "屙屎", "屙尿", "濕了", "換片",
        "生病", "病了", "不舒服", "难受", "不对劲",
        "发烧", "体温", "儿科", "疫苗", "打针",
        "鼻塞", "咳嗽", "感冒", "长牙", "过敏",
        "腹泻", "便秘", "体检", "胀气", "黄疸", "湿疹",
        "發燒", "睇醫生", "唔舒服",
        "笑了", "翻身", "爬了", "站起来", "走路了",
        "坐起来", "第一次", "趴着练习",
        "識笑", "識爬", "識行",
        "说话了", "叫妈妈", "叫爸爸",
        "哭闹", "烦躁", "粘人", "闹觉",
        "喊", "扭计", "唔肯", "好乖",
        "安抚奶嘴", "奶嘴", "包巾", "背带",
        "奶咀", "揹帶",
        "洗澡", "沖涼",
    ]

    // ════════════════════════════════════════════════════════════
    // MARK: - Level 2 patterns (active period only)
    // ════════════════════════════════════════════════════════════

    /// Chinese question particles, hedging words, and continuation phrases.
    /// These are common in follow-up conversation but too generic for Level 1.
    private static let chineseLevel2Patterns: [String] = [
        // Question particles
        "吗", "了吗", "怎么", "什么", "是不是", "有没有", "好不好", "对不对",
        // Hedging / continuation — parents thinking aloud about the baby
        "好像", "感觉", "要不要", "还是", "应该", "可能", "需不需要",
        // Cantonese question particles
        "咩", "点解", "系咪", "使唔使",
    ]

    /// English follow-up phrases parents use without repeating the baby's name.
    private static let englishLevel2Patterns: [String] = [
        "is she", "is he", "did she", "did he", "was she", "was he",
        "has she", "has he", "can she", "can he",
        "does she", "does he",
        "how is", "what about", "should we", "do we need",
        "when did", "how long", "how much",
    ]

    /// Pronouns accepted with low word-count threshold (>= 3 words) during active period.
    private static let level2Pronouns: Set<String> = [
        "she", "he", "her", "him",
    ]

    // MARK: - Filler detection

    private static let fillerWords: Set<String> = [
        "um", "uh", "hmm", "hm", "okay", "ok", "yeah", "yes", "no",
        "hi", "hello", "bye", "goodbye", "oh", "ah", "er", "right", "like",
        "嗯", "啊", "哦", "呢", "吧", "喔", "唔", "哈",
    ]

    private static func isOnlyFiller(_ words: [String]) -> Bool {
        if words.allSatisfy({ fillerWords.contains($0) }) { return true }
        let joined = words.joined()
        let fillerChars: Set<Character> = ["嗯", "啊", "哦", "呢", "吧", "喔", "唔", "哈", " "]
        return joined.allSatisfy { fillerChars.contains($0) }
    }
}
