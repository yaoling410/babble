// ============================================================
//  PhoneticMatcher.swift — consonant-skeleton phonetic matching
// ============================================================
//
//  PURPOSE
//  -------
//  SFSpeechRecognizer frequently mishears baby names by producing
//  a phonetically similar common English word:
//    "Luca" → "Look" / "Luke" / "Looka" / "Luka"
//    "Mia"  → "Me a" / "Mia" / "Maya"
//    "Eli"  → "Ellie" / "Ally" / "Ali"
//
//  Simple substring matching misses these. This module provides
//  consonant-skeleton matching: vowels are stripped and consonants
//  are normalised into broad acoustic classes. The resulting code
//  is compared for equality. Equal codes → same name.
//
//  ALGORITHM
//  ---------
//  1. Lowercase the word.
//  2. Walk character-by-character applying English phoneme rules:
//       • Vowels (a e i o u) → kept ONLY at word-start (as "A") to
//         distinguish "eli"("AL") from "lee"("L")
//       • Consonant clusters normalised to acoustic class symbols
//         (see table in `consonantCode(for:)` below)
//       • Silent letters dropped: h (between vowels), w/y (semivowels),
//         gh (in e.g. "right"), silent k in "knee"
//  3. Deduplicate consecutive identical codes (handles doubled letters).
//  4. Compare codes: equal → phonetic match.
//
//  WHY CONSONANT-SKELETON, NOT FULL PHONEME SEQUENCE
//  --------------------------------------------------
//  Vowel quality is the most variable part of speech recognition output —
//  it changes with accent, speaking rate, and stress. Consonant structure
//  is far more stable. The consonant-skeleton approach is:
//    • Safe (low false-positive rate at maxDistance=0)
//    • Accurate for the most common ASR mishearings of baby names
//    • Zero runtime cost (no model, no lookup table, pure character rules)
//
//  EXAMPLE: baby name "Luca"
//    "luca"  → code "LK"  ← exact
//    "luke"  → code "LK"  ← match ✓
//    "look"  → code "LK"  ← match ✓
//    "looka" → code "LK"  ← match ✓
//    "luka"  → code "LK"  ← match ✓
//    "love"  → code "LF"  ← no match (different consonant) ✓
//    "luck"  → code "LK"  ← match (acceptable; "luck" rarely triggers in context)
//    "lucas" → code "LKS" ← no exact match; add as explicit alias
//
//  USAGE
//  -----
//  Used in WakeWordService.bestNameConfidence() as an additional check
//  after exact name/alias substring matching. Phonetic matches are logged
//  so you can see when this path fires.

struct PhoneticMatcher {

    // ================================================================
    //  MARK: - Consonant code
    // ================================================================

    /// Maps an English word to its consonant skeleton code.
    ///
    /// The code preserves consonant structure while discarding vowel
    /// quality — the most variable part of speech recognition output.
    ///
    /// Acoustic class symbols used:
    ///   A  — initial vowel marker (e.g. "eli" → "AL", "ali" → "AL")
    ///   B  — bilabial stops/fricatives: b, p, m
    ///   T  — dental/alveolar stops: d, t
    ///   K  — velar stops: k, g (hard), c (hard), q
    ///   F  — labiodental fricatives: f, v, ph
    ///   S  — sibilants: s, z, c (soft), x(part)
    ///   X  — postalveolar: sh, ch
    ///   0  — dental fricative: th
    ///   J  — palatal affricate: j, g (soft)
    ///   L  — lateral liquid: l
    ///   R  — rhotic: r
    ///   N  — nasals: n, ng
    ///   M  — bilabial nasal: m (kept separate from N for accuracy)
    static func consonantCode(for word: String) -> String {
        let s = Array(word.lowercased())
        var code = ""
        var i = 0

        func peek(_ n: Int = 1) -> Character {
            let j = i + n
            return j < s.count ? s[j] : "\0"
        }

        while i < s.count {
            let c = s[i]
            var token: String? = nil

            switch c {
            // ── Vowels ─────────────────────────────────────────────────────
            case "a", "e", "i", "o", "u":
                // Mark initial vowel so "eli" ≠ "lee"
                if code.isEmpty { token = "A" }
                // Interior vowels → dropped (we only care about consonant skeleton)

            // ── Bilabial stops ──────────────────────────────────────────────
            case "b":
                token = "B"
            case "p":
                if peek() == "h" { token = "F"; i += 1 }   // ph → F
                else { token = "B" }                         // p ≈ b (unvoiced pair)

            // ── Dental/alveolar stops ───────────────────────────────────────
            case "d":
                token = "T"    // d ≈ t (voiced/unvoiced pair; often swapped in ASR)
            case "t":
                if peek() == "h" { token = "0"; i += 1 }   // th → 0
                else { token = "T" }

            // ── Velar stops ─────────────────────────────────────────────────
            case "c":
                let nx = peek()
                if nx == "h" { token = "X"; i += 1 }        // ch → X
                else if "eiy".contains(nx) { token = "S" }   // soft-c → S
                else { token = "K" }                          // hard-c → K
            case "g":
                let nx = peek()
                if nx == "h" { i += 1 }                      // gh silent (right, night)
                else if "eiy".contains(nx) { token = "J" }   // soft-g → J
                else { token = "K" }
            case "k":
                if peek() == "n" { token = nil }              // silent k in "knee"
                else { token = "K" }
            case "q":
                token = "K"

            // ── Labiodental fricatives ──────────────────────────────────────
            case "f":
                token = "F"
            case "v":
                token = "F"    // v ≈ f (voiced/unvoiced pair)

            // ── Sibilants ───────────────────────────────────────────────────
            case "s":
                if peek() == "h" { token = "X"; i += 1 }    // sh → X
                else { token = "S" }
            case "z":
                token = "S"    // z ≈ s
            case "x":
                // "x" = /ks/ — append K then S
                appendDedup("K", to: &code)
                token = "S"

            // ── Palatal affricate ───────────────────────────────────────────
            case "j":
                token = "J"

            // ── Liquids ─────────────────────────────────────────────────────
            case "l":
                token = "L"
            case "r":
                token = "R"

            // ── Nasals ──────────────────────────────────────────────────────
            case "m":
                token = "M"
            case "n":
                token = peek() == "g" ? "N" : "N"   // ng and n both → N

            // ── Silent / semivowels ─────────────────────────────────────────
            case "h":
                token = nil   // often silent (silent in "ah", aspirate elsewhere)
            case "w", "y":
                token = nil   // semivowels — stripped from consonant skeleton

            default:
                token = nil
            }

            if let t = token {
                appendDedup(t, to: &code)
            }
            i += 1
        }

        return code
    }

    // ================================================================
    //  MARK: - Public matching API
    // ================================================================

    /// Very common English words that happen to share a consonant skeleton
    /// with baby names. These should never trigger a phonetic match because
    /// they appear in almost every sentence.
    /// Example: "like" → LK == "luca" → LK. "like" appears ~50× per conversation.
    private static let commonWordBlocklist: Set<String> = [
        // LK matches: like, lick, lock, leak, lack, lake, leg, log, lag, lug
        "like", "lick", "lock", "leak", "lack", "lake", "leg", "log", "lag", "lug",
        // LK matches via look/luck already handled as aliases, but block the verb forms
        "liked", "likes", "liking", "locking", "leaking", "lacking",
        // Other extremely common short words that could collide
        "let", "lot", "lit", "late", "light", "right", "left", "last",
        "get", "got", "got", "bit", "but", "bat", "bet", "big", "bag", "bug",
        "make", "made", "may", "my", "me", "much", "milk",
        "no", "not", "now", "new", "name", "nice", "nine",
        "put", "pay", "play", "pick", "pack",
        "say", "see", "sit", "set", "so", "some",
        "take", "tell", "the", "that", "this", "think", "time", "too", "two",
        "want", "was", "what", "when", "will", "with", "would",
        "back", "book", "look",
    ]

    /// Returns true if `word` could be an ASR mishearing of `target`.
    ///
    /// Uses consonant-skeleton matching:
    ///   - `maxDistance = 0`: exact consonant match (safe, catches "luke"/"look" for "luca")
    ///   - `maxDistance = 1`: one consonant edit allowed (also catches "lucas")
    ///
    /// The first consonant (or vowel marker) must match in all cases —
    /// this prevents cross-initial false positives.
    ///
    /// Common English words are blocklisted to prevent false positives
    /// from words like "like" matching "luca" (both produce code "LK").
    static func isMatch(_ word: String, target: String, maxDistance: Int = 0) -> Bool {
        guard !word.isEmpty, !target.isEmpty else { return false }
        let lower = word.lowercased()
        // Block very common English words that collide with name codes
        guard !commonWordBlocklist.contains(lower) else { return false }
        let cw = consonantCode(for: lower)
        let ct = consonantCode(for: target)
        guard !cw.isEmpty, !ct.isEmpty else { return false }
        // First symbol must match — different initials are almost never mishearings
        guard cw.first == ct.first else { return false }
        if cw == ct { return true }
        guard maxDistance > 0 else { return false }
        return levenshtein(Array(cw), Array(ct)) <= maxDistance
    }

    /// Returns all words in `words` that are a phonetic match for `target`.
    static func matches(in words: [String], target: String, maxDistance: Int = 0) -> [String] {
        words.filter { isMatch($0, target: target, maxDistance: maxDistance) }
    }

    // ================================================================
    //  MARK: - Helpers
    // ================================================================

    /// Append `token` to `code`, skipping if identical to the last character
    /// (handles doubled letters like "ll", "ck", "ss").
    private static func appendDedup(_ token: String, to code: inout String) {
        for ch in token {
            let t = String(ch)
            if code.last.map(String.init) != t { code += t }
        }
    }

    /// Levenshtein edit distance on generic equatable sequences.
    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        let m = a.count, n = b.count
        guard m > 0 else { return n }
        guard n > 0 else { return m }
        var row = Array(0...n)
        for i in 1...m {
            var prev = row[0]
            row[0] = i
            for j in 1...n {
                let tmp = row[j]
                row[j] = a[i-1] == b[j-1] ? prev : 1 + min(prev, row[j], row[j-1])
                prev = tmp
            }
        }
        return row[n]
    }
}
