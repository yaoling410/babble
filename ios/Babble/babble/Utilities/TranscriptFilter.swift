import Foundation

// ============================================================
//  TranscriptFilter.swift — On-device relevance gate for Gemini
// ============================================================
//
//  PURPOSE
//  -------
//  Before sending an audio clip to the Gemini backend (which costs money
//  and takes time), we evaluate the transcript locally. If it's clearly
//  not about the baby, we skip the network call entirely.
//
//  Gemini is only called when this returns true.
//
//  DECISION LOGIC (in order)
//  --------------------------
//  1. Cry trigger → always send (the cry itself is the event).
//  2. Baby's primary name appears → send.
//  3. Active period + secondary reference (she/he/little one) → send.
//  4. Single-word keyword match (O(1) Set lookup) → send.
//     Categories: feeding, sleep, diaper, hygiene, skin, health,
//                 milestones, speech, emotion, soothing, activity, growth.
//  5. Multi-word phrase match (substring scan) → send.
//     Examples: "spit up", "sleep regression", "tummy time".
//  6. Nickname or pronoun pattern → send.
//  7. Chinese keyword match → send.
//  8. None of the above → skip.
//
//  PERFORMANCE
//  -----------
//  - Single-word keywords: Set<String> — O(1) per word, negligible cost.
//  - Multi-word phrases: [String] — linear scan kept to ~80 phrases.
//  - Chinese keywords: substring scan on character sequences.
//  Both run in microseconds on every partial transcript update.
//
//  CHINESE SUPPORT
//  ---------------
//  Mandarin (Simplified + Traditional) and Cantonese keywords are included.
//  Chinese text has no spaces — `lower.contains(keyword)` works naturally.
//  Single-character keywords (哭=cry, 奶=milk, 睡=sleep) are in a separate
//  set to signal their special status; matching logic is identical.
//
//  TUNING
//  ------
//  - Too many false positives → add words to the ignore list or increase
//    the pronoun word-count guard (currently 8 words minimum).
//  - Missing events → add keywords to the relevant category set, or
//    add a multi-word phrase to multiWordPhrases.

/// On-device rule engine that decides if a transcript is worth sending to Gemini.
/// Free, instant, no network. Gemini is only called when this returns true.
///
/// Performance: single-word keywords use a Set (O(1) per word).
/// Multi-word phrases fall back to substring scan — kept short to stay fast.
enum TranscriptFilter {

    // MARK: - Public

    /// Main gate — returns true if the transcript should be sent to Gemini.
    ///
    /// - `isActivePeriod`: true for 2 minutes after the baby's primary name was
    ///   heard. Enables weaker rules: secondary references (she/he/little one/cutie)
    ///   are treated the same as the baby's name, so any sentence mentioning them
    ///   passes. Outside the active period, keywords or observation patterns are
    ///   still required.
    static func shouldAnalyze(
        transcript: String,
        babyName: String,
        triggerKind: String,
        isActivePeriod: Bool = false
    ) -> Bool {
        // Rule 1: cry trigger always passes — the cry itself is the event
        if triggerKind == "cry" { return true }

        let lower = transcript.lowercased().trimmingCharacters(in: .whitespaces)

        guard !lower.isEmpty else { return false }
        let words = lower.split(separator: " ").map(String.init)

        // Chinese text has no spaces — the recognizer returns the entire phrase as one
        // token, so a word count check would drop all valid Chinese transcripts.
        // Skip the minimum-word guard when Chinese characters are present.
        let hasChinese = lower.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        if words.count < 2 && !hasChinese { return false }
        if isOnlyFiller(words) { return false }

        // Rule 2: baby's primary name mentioned → always passes
        if !babyName.isEmpty && lower.contains(babyName.lowercased()) { return true }

        // Rule 2b (active period only): secondary reference is enough.
        // Parents rarely say the baby's name to each other — they say "she",
        // "little one", "cutie". During the active period (2 min after the
        // primary name was last heard), these are treated as baby references.
        if isActivePeriod && containsSecondaryReference(lower, wordCount: words.count) { return true }

        // Rule 3: single-word keyword match (O(1) Set lookup per word)
        let wordSet = Set(words)
        if !wordSet.isDisjoint(with: singleWordKeywords) { return true }

        // Rule 4: multi-word phrase match (substring scan — list kept small)
        if multiWordPhrases.contains(where: { lower.contains($0) }) { return true }

        // Rule 5: nickname / indirect reference with enough context
        if containsNicknameOrPronounPattern(lower, wordCount: words.count) { return true }

        // Rule 6: Chinese keyword match — substring scan works naturally for
        // Chinese since characters are not separated by spaces.
        if chineseSingleCharKeywords.contains(where: { lower.contains($0) }) { return true }
        if chineseKeywords.contains(where: { lower.contains($0) }) { return true }

        return false
    }

    /// Returns true if the transcript contains a secondary reference to the baby —
    /// pronouns or pet names that parents commonly use instead of the baby's name.
    /// Requires at least 3 words so single-word utterances don't trigger.
    static func containsSecondaryReference(_ lower: String, wordCount: Int = 99) -> Bool {
        guard wordCount >= 3 || lower.split(separator: " ").count >= 3 else { return false }

        // Nicknames — very specific, safe even without word count guard
        if babyNicknames.contains(where: { lower.contains($0) }) { return true }

        // Pronouns — common in caregiver-to-caregiver shorthand:
        // "she's been fussy", "did he eat?", "we just put him down"
        let pronouns: Set<String> = ["she", "he", "we", "they", "her", "him", "you"]
        let words = Set(lower.split(separator: " ").map(String.init))
        return !words.isDisjoint(with: pronouns)
    }

    // MARK: - Single-word keywords (Set — fast lookup)

    private static let singleWordKeywords: Set<String> = {
        // Feeding
        let feeding: Set<String> = [
            "feed", "feeding", "bottle", "nursing", "nurse", "breastfeed", "breastfeeding",
            "formula", "milk", "eat", "eating", "ate", "hungry", "hunger",
            "latch", "latched", "solids", "puree", "cereal", "sippy",
            "burp", "burping", "reflux", "swallow",
            "pumping", "pumped", "pump", "letdown",  // pumping
            "foremilk", "hindmilk", "oversupply", "mastitis",
            "weaning",                                // self-feeding / BLW
        ]
        // Sleep
        let sleep: Set<String> = [
            "sleep", "sleeping", "slept", "nap", "napping", "napped", "awake",
            "woke", "tired", "drowsy", "bed", "bedtime",
            "crib", "bassinet", "overnight", "nighttime",
            "overtired", "undertired", "catnap",      // sleep quality
            "dreamfeed", "ferber",                    // sleep training
            "stirred", "stirring", "settled", "settling",
        ]
        // Diaper
        let diaper: Set<String> = [
            "diaper", "nappy", "poop", "pooped", "pooping", "pee", "peed", "peeing",
            "rash", "wipe", "wiped", "blowout", "straining",
        ]
        // Hygiene
        let hygiene: Set<String> = [
            "bath", "bathing", "bathed", "wash", "washing", "washed",
        ]
        // Skin
        let skin: Set<String> = [
            "eczema", "hives", "itchy", "itching", "scratching",
            "swollen", "swelling", "jaundice",
        ]
        // Health
        let health: Set<String> = [
            "sick", "fever", "temperature", "medicine", "medication", "dose",
            "tylenol", "ibuprofen", "motrin", "advil",
            "doctor", "pediatrician", "appointment", "vaccine", "vaccination",
            "hospital", "rash", "congestion", "congested", "cough", "coughing",
            "teething", "tooth", "teeth", "allergic", "allergy",
            "vomit", "vomiting", "diarrhea", "constipated",
            "weight", "height", "checkup", "antibiotic", "inhaler",
            "gassy", "windy", "colic", "colicky", "wheezing", "wheeze",
            "thrush", "mastitis", "rsv", "croup", "stridor",
            "jaundice", "reflux", "gerd",
            "regression",                            // sleep regression
        ]
        // Milestones
        let milestones: Set<String> = [
            "smile", "smiled", "smiling", "laugh", "laughed", "laughing",
            "giggle", "giggled", "giggling",
            "crawl", "crawled", "crawling",
            "stand", "stood", "standing",
            "walked", "walking",
            "roll", "rolled", "rolling",
            "sit", "sat", "sitting",
            "grab", "grabbed", "wave", "waved", "waving",
            "clap", "clapped", "clapping",
            "point", "pointed", "pointing",
            "milestone", "cruising",                  // pulling to stand, walking along furniture
        ]
        // Speech / communication
        let speech: Set<String> = [
            "babbling", "babble", "talking", "cooing",
            "words", "sentence", "communicate",
        ]
        // Emotion / behavior
        let emotion: Set<String> = [
            "crying", "cried", "fuss", "fussy", "fussing",
            "upset", "inconsolable",
            "calm", "calmed", "calming", "content", "irritable",
            "soothed", "soothing", "comfort", "comforting",
            "clingy", "startled", "overstimulated",
        ]
        // Soothing methods — parents talk about what's working/not working
        let soothing: Set<String> = [
            "pacifier", "paci", "dummy", "soother",
            "swaddle", "swaddled", "swaddling",
            "rocking", "rocked", "bouncing", "bounced",
            "shushing",
        ]
        // Activity / gear
        let activity: Set<String> = [
            "stroller", "carrier", "swing", "bouncer",
            "daycare", "nursery", "nanny", "babysitter",
            "playground", "park",
        ]
        // Growth / measurement
        let growth: Set<String> = [
            "ounce", "ounces", "oz", "milliliter",
            "gained", "percentile", "weighed",
        ]

        return feeding
            .union(sleep)
            .union(diaper)
            .union(hygiene)
            .union(skin)
            .union(health)
            .union(milestones)
            .union(speech)
            .union(emotion)
            .union(soothing)
            .union(activity)
            .union(growth)
    }()

    // MARK: - Multi-word phrases (substring scan — keep list short)

    private static let multiWordPhrases: [String] = [
        // Feeding
        "spit up", "spitting up", "cluster feeding", "cluster fed",
        "breast milk", "breast pump", "let down", "let-down",
        "low supply", "milk supply", "nursing strike", "bottle refusal",
        "tongue tie", "lip tie", "clogged duct", "blocked duct",
        "baby-led weaning", "baby led weaning", "high chair",
        "sippy cup", "straw cup", "first foods",
        "skin to skin", "skin-to-skin",

        // Sleep
        "went down", "put down", "fell asleep", "went to sleep",
        "woke up", "wake up", "up from", "down for",
        "night feed", "night feeding", "night waking",
        "sleep train", "sleep training", "cry it out",
        "wake window", "drowsy but awake",
        "contact nap", "contact sleep",
        "dream feed", "up at", "up every",
        "fight the nap", "fighting sleep", "fighting the nap",
        "sleep regression", "four month", "four-month",
        "night terror", "night terrors", "standing in crib",

        // Diaper
        "blow out", "blood in stool", "mucus in stool",
        "green poop", "black stool", "white stool",

        // ASR variant forms — common mishearings of baby-care phrases.
        // Single-word variants ("feet" for "feed") are ordinary English words and
        // would cause false positives, so only two-word patterns are added here.
        // The two-word co-occurrence is specific enough to baby context to be safe.
        "spat up",          // past tense of "spit up"
        "spit-up",          // hyphenated ASR output
        "day pair",         // "diaper" ASR mishearing
        "sleek regression", // "sleep regression" mishearing

        // Health
        "pulling at ear", "tugging at ear", "ear infection",
        "runny nose", "hand foot mouth", "hand-foot-mouth",
        "pinkeye", "eye discharge", "barking cough",
        "breathing fast", "breathing hard", "arching back",
        "gripe water", "gas drops", "white noise",
        "urgent care", "check-up", "growth spurt",

        // Skin
        "cradle cap", "baby acne", "drool rash", "heat rash",
        "dry skin", "dry patch",

        // Milestones / development
        "first time", "for the first time",
        "pulled up", "pulling up", "pull up",     // pulling to stand
        "first steps", "first words", "first word",
        "said mama", "said dada", "said no",
        "tummy time",
        "wonder weeks", "growth leap",
        "gross motor", "fine motor",
        "pincer grasp", "object permanence",
        "separation anxiety", "stranger anxiety",

        // Soothing / caregiving
        "won't settle", "won't sleep", "won't stop crying",
        "white noise machine",

        // Indirect time references that strongly imply baby context
        "in the night", "middle of the night", "through the night",
        "this morning", "last night", "earlier today", "a few minutes ago",
        "woke at", "woke up at",

        // Caregiver shorthand (very common in handoff conversations)
        "how'd she", "how'd he",
        "did she eat", "did he eat",
        "any poop", "did she poop", "did he poop",
        "still sleeping", "still napping",
        "went back down", "back to sleep",
        "nanny said", "daycare said", "daycare report",

        // Feeding measurement context
        "one side", "both sides",
    ]

    // MARK: - Nickname / pronoun pattern

    /// Parents almost never say the baby's name to each other — they use nicknames
    /// or gendered pronouns. This catches patterns like:
    ///   "the little one was so fussy"
    ///   "our munchkin finally slept"
    ///   "she's been clingy all day"  (8+ words with she/he + baby-like context)
    private static let babyNicknames = [
        "little one", "the little one", "our little",
        "little guy", "little girl", "little man", "little miss",
        "munchkin", "bubba", "bubs", "bub",
        "peanut", "bean", "nugget", "jellybean",
        "bambino", "sweetpea", "sweet pea",
        "tiny", "tiny one", "the baby", "our baby",
    ]

    private static func containsNicknameOrPronounPattern(_ lower: String, wordCount: Int) -> Bool {
        // Nickname match — parents use these constantly instead of the baby's name
        if babyNicknames.contains(where: { lower.contains($0) }) { return true }

        // Pronoun pattern: requires 8+ words to reduce false positives.
        // "she went to the store" is fine; "she was so fussy today I couldn't put her down" is baby talk.
        if wordCount >= 8 {
            let pronouns = ["she's", "he's", "she was", "he was", "she's been", "he's been",
                            "she had", "he had", "she did", "he did", "she won't", "he won't",
                            "her ", "him "]
            if pronouns.contains(where: { lower.contains($0) }) { return true }
        }

        return false
    }

    // MARK: - Chinese keywords (Mandarin + Cantonese)
    //
    // Chinese has no word boundaries — characters are not separated by spaces.
    // The existing `lower.contains($0)` substring check works naturally for Chinese;
    // no changes to matching logic are needed. Both Simplified (普通话) and
    // Traditional (粤语) variants are included where they differ.

    static let chineseSingleCharKeywords: Set<String> = [
        // Core baby signals — single chars worth matching even standalone
        "哭", "奶", "睡", "吃", "尿", "拉", "烧", "饿", "困",
    ]

    static let chineseKeywords: [String] = [
        // Feeding 喂食
        "喂奶", "喂食", "奶瓶", "母乳", "哺乳", "配方奶", "吃奶", "吃东西",
        "辅食", "米粉", "高椅", "离乳", "断奶", "打嗝", "吐奶", "溢奶",
        "反流", "吞咽", "饿了", "含乳", "上奶", "奶量", "奶水",
        "追奶", "背奶", "吸奶", "泵奶", "堵奶", "乳腺炎",
        // Cantonese variants
        "飲奶", "食嘢", "餓了", "餵奶",

        // Sleep 睡眠
        "睡觉", "睡着了", "午睡", "小睡", "醒了", "醒来", "困了",
        "睡前", "婴儿床", "摇篮", "入睡", "哄睡", "睡整觉",
        "夜醒", "夜奶", "夜哭", "放下", "翻醒", "睡眠训练",
        "哄睡", "接觉",
        // Cantonese variants
        "瞓覺", "瞓著", "唔瞓", "夜奶",

        // Diapers 尿布
        "尿布", "纸尿裤", "尿不湿", "便便", "大便", "小便", "拉了",
        "换尿布", "尿布疹", "血便", "绿色大便", "黑便", "白便",
        "漏尿", "爆漏",
        // Cantonese variants
        "屙屎", "屙尿", "濕了", "換片",

        // Health 健康
        "生病", "病了", "不舒服", "难受", "不对劲",
        "发烧", "体温", "药", "儿科", "疫苗", "打针", "出疹",
        "鼻塞", "咳嗽", "感冒", "流鼻涕", "耳朵疼", "长牙", "过敏",
        "吐了", "腹泻", "便秘", "体重", "身高", "体检",
        "肠绞痛", "胀气", "呼吸急促", "呼吸困难", "黄疸",
        "鹅口疮", "湿疹", "荨麻疹", "中耳炎", "手足口病",
        "奶水不足", "乳头混淆", "吸吮无力",
        // Cantonese variants
        "發燒", "藥水", "打針", "睇醫生", "黃疸", "唔舒服",

        // Milestones 发育里程碑
        "笑了", "翻身", "爬了", "爬行", "站起来", "走路了", "迈步",
        "抓东西", "坐起来", "第一次", "新技能", "抬头", "趴着练习",
        "手眼协调", "认人", "认生", "分离焦虑",
        // Cantonese variants
        "識笑", "識爬", "識行", "第一次",

        // Speech 语言发展
        "说话了", "咿呀学语", "叫妈妈", "叫爸爸", "说词了", "第一个词",
        "喃语", "牙牙学语", "学说话",
        // Cantonese variants
        "識叫", "叫媽媽", "叫爸爸",

        // Emotion / behavior 情绪行为
        "哭闹", "烦躁", "不安", "安静下来", "情绪", "粘人",
        "闹觉", "哄不住", "过度刺激",
        // Cantonese variants
        "喊", "扭计", "唔肯", "好乖",

        // Soothing 安抚
        "安抚奶嘴", "奶嘴", "包巾", "摇摇", "背带", "婴儿车",
        // Cantonese variants
        "奶咀", "揹帶",

        // Activity 活动
        "趴趴时间", "外出", "公园", "推车", "婴儿车", "托班",
        "早教", "绘本", "唱儿歌",

        // Growth 生长
        "克", "毫升", "生长曲线", "生长加速", "体重增长",
        // Cantonese variants
        "磅重", "量身高",

        // Skin 皮肤
        "湿疹", "黄疸", "胎脂", "奶癣", "痒", "尿布疹", "痱子",
        // Cantonese variants
        "濕疹", "黃疸",

        // Hygiene 卫生
        "洗澡", "洗屁屁",
        // Cantonese variants
        "沖涼",

        // Caregiver shorthand 照顾者用语
        "今天", "昨晚", "刚才", "一直", "又哭了", "好像",
        "感觉", "已经", "终于", "还是", "上午", "下午",
        "这次", "又一次",
        // Cantonese variants
        "琴晚", "啱啱", "而家", "係咁",
    ]

    // MARK: - Filler detection

    private static let fillerWords: Set<String> = [
        "um", "uh", "hmm", "hm", "okay", "ok", "yeah", "yes", "no",
        "hi", "hello", "bye", "goodbye", "oh", "ah", "er", "right", "like",
        // Chinese filler
        "嗯", "啊", "哦", "呢", "吧", "喔", "唔", "哈",
    ]

    private static func isOnlyFiller(_ words: [String]) -> Bool {
        // For English: check word-by-word
        if words.allSatisfy({ fillerWords.contains($0) }) { return true }
        // For Chinese: the whole transcript may be a single "word" token.
        // Check if the joined string is nothing but filler characters.
        let joined = words.joined()
        let fillerChars: Set<Character> = ["嗯", "啊", "哦", "呢", "吧", "喔", "唔", "哈", " "]
        return joined.allSatisfy { fillerChars.contains($0) }
    }
}
