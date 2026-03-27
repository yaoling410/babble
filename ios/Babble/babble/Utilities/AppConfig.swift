import Foundation

// ============================================================
//  AppConfig — all tunable parameters in one place
// ============================================================
//
//  HOW TO USE
//  ----------
//  Every value here has a plain-English explanation and a
//  "If you increase / decrease" note so you can tune without
//  guessing. Change the value, rebuild, and test — no other
//  files need touching.
//
//  SECTIONS
//  --------
//  1. Active Period          — how long the app stays alert after hearing the baby's name
//  2. Capture Window         — when to stop recording and send to Gemini
//  3. Silence Gate (VAD)     — how to detect silence and skip ML when quiet
//  4. Cry Detection          — sensitivity of the crying detector
//  5. Wake Word              — speech recognizer lifecycle
//  6. Relevance Filter       — how aggressively to filter out non-baby conversations
//  7. Gemini / Backend       — AI model and cost controls

enum AppConfig {

    // ================================================================
    //  1. ACTIVE PERIOD
    // ================================================================
    //  After the baby's PRIMARY NAME is heard, the app enters a
    //  heightened-sensitivity "active period". During this window,
    //  secondary references — "she", "he", "little one", "cutie" —
    //  are treated as baby references and trigger analysis even
    //  without a keyword match.
    //
    //  Only hearing the primary name again extends the timer.
    //  Secondary references, keywords, or crying do NOT extend it.

    /// Duration of the active period in seconds.
    ///
    /// - Increase → longer window of sensitivity after the baby's name.
    ///   Good for long bedtime routines or feeding sessions where the
    ///   name may only be said once.
    /// - Decrease → tighter window, fewer false positives from adult
    ///   conversation happening to mention "she" or "we".
    /// - Typical range: 60–300s. Default: 120s (2 minutes).
    static let activePeriodSeconds: Double = 120

    // ================================================================
    //  2. PRE-CAPTURE RING BUFFER
    // ================================================================
    //  A circular ring buffer runs continuously so that audio captured
    //  BEFORE a trigger fires can be prepended to the clip. Without it,
    //  a clip would start with "…Emma" — the tail of the name already
    //  spoken. With it, we capture the full name and several seconds
    //  of context before the trigger.

    /// Total seconds of audio the ring buffer holds.
    ///
    /// Must be ≥ preCaptureSeconds. At 48 kHz Int16 mono:
    ///   12 s ≈ 1.1 MB — negligible.
    ///
    /// - Default: 12s.
    static let ringBufferSeconds: Double = 12

    /// Seconds of pre-trigger audio to prepend to each clip.
    ///
    /// Snapshotted from the ring buffer the moment a trigger fires.
    /// Capped by ringBufferSeconds.
    ///
    /// - Increase → more context before the trigger; larger clip.
    /// - Decrease → leaner clip, less pre-roll context.
    /// - Default: 10s.
    static let preCaptureSeconds: Double = 10

    // ================================================================
    //  3. CAPTURE WINDOW
    // ================================================================
    //  Once a trigger fires (name, cry, or secondary ref), the app
    //  records audio. Recording continues until EITHER the silence
    //  timer fires OR the hard cap is hit.

    /// Seconds of real silence before the clip is sent to Gemini.
    ///
    /// Every new word from SFSpeechRecognizer resets this timer,
    /// so a continuous conversation is captured as ONE clip no matter
    /// how long it runs (up to maxCaptureSeconds).
    ///
    /// - Increase → more silence tolerance, good for speakers who
    ///   pause between sentences or think aloud.
    /// - Decrease → faster clip dispatch, lower latency to the log,
    ///   but might cut off mid-sentence if parent pauses.
    /// - Typical range: 5–20s. Default: 10s.
    static let silenceFlushSeconds: Double = 4

    /// Hard cap on clip length in seconds, regardless of speech activity.
    ///
    /// Prevents unbounded audio accumulation during very long
    /// conversations. At 48 kHz Int16 mono:
    ///   60s  ≈  5.8 MB
    ///   90s  ≈  8.6 MB  ← default
    ///   120s ≈ 11.5 MB
    ///
    /// - Increase → one Gemini call covers more of a long conversation.
    /// - Decrease → smaller audio files, lower memory and upload cost,
    ///   but long conversations get split into multiple clips.
    /// - Typical range: 60–180s. Default: 90s.
    static let maxCaptureSeconds: Double = 90

    /// Cooldown after a clip is sent before a new trigger is accepted.
    ///
    /// Prevents the same event from being logged twice. The recognizer
    /// may produce a "final" result that re-fires the wake word check
    /// immediately after a clip is flushed — this cooldown blocks that.
    ///
    /// - Increase → fewer duplicate triggers; might miss rapid events.
    /// - Decrease → more responsive but risks duplicate logging.
    /// - Default: 5s (just long enough to let the recognizer's final result
    ///   settle after a flush — the old 60s value silently dropped back-to-back events).
    static let triggerCooldownSeconds: Double = 5

    /// How often WakeWordService scans for the baby's name BEFORE the first
    /// detection. 1 s gives ≤1 s detection latency while scanning ~10× less
    /// than checking every 100 ms partial.
    static let wakeWordInitialScanIntervalSeconds: Double = 1

    /// How often WakeWordService scans for the baby's name AFTER a trigger has
    /// already fired (i.e. after the cooldown expires). A second utterance of
    /// the name is less time-critical, so 10 s latency is acceptable.
    static let wakeWordRescanIntervalSeconds: Double = 2

    // ================================================================
    //  3. SILENCE GATE (Voice Activity Detection)
    // ================================================================
    //  A hardware-accelerated speech-band filter (300 Hz high-pass)
    //  runs on every audio buffer. When the energy is below the
    //  threshold, BOTH the cry detector and speech recognizer are
    //  skipped entirely — the biggest source of background heat/CPU.

    /// Minimum RMS energy in the 300 Hz+ speech band to forward audio
    /// to the ML pipelines (SFSpeechRecognizer + SNAudioStreamAnalyzer).
    ///
    /// Scale: 0.0 (complete silence) → 1.0 (full scale).
    ///   ~0.001–0.003 = quiet room at night
    ///   ~0.005       = room with light HVAC / very quiet speech  ← default
    ///   ~0.010–0.020 = audible ambient noise (fan, white noise machine)
    ///   ~0.030+      = active speech
    ///
    /// - Increase → more aggressive gating; saves more CPU/battery but
    ///   risks missing quiet speech or soft cries in a noisy room.
    /// - Decrease → more sensitive; catches quieter sounds but ML runs
    ///   more often in noisy environments (more heat).
    /// - If your nursery has a white noise machine, try 0.010–0.015.
    /// VAD threshold when NOT in the active period (no recent baby name heard).
    /// Higher = more aggressive gating → cooler phone, saves battery.
    /// Default: 0.010 (blocks fan / white noise machine energy).
    static let silenceThreshold: Float = 0.003

    /// VAD threshold DURING the active period (baby's name was just heard).
    /// Lower = more sensitive → catches quieter follow-up speech and soft voices.
    /// Default: 0.002 (near-silent room sensitivity, active for only 2 min at a time).
    static let silenceThresholdActive: Float = 0.002

    /// Number of buffers to hold the gate OPEN after speech energy drops.
    ///
    /// Each buffer ≈ 85ms at 48 kHz / 4096 frames.
    /// 5 buffers ≈ 425ms of "tail" after energy drops.
    ///
    /// Without hysteresis, a brief pause mid-sentence would gate out
    /// the recognizer and cause it to declare a final result, resetting
    /// the cumulative transcript.
    ///
    /// - Increase → smoother handling of pauses, at the cost of slightly
    ///   longer ML activity after speech ends.
    /// - Decrease → more aggressive power saving; risk of choppy ASR.
    /// - Typical range: 3–40. Default: 35 (~3 s).
    /// At 85 ms/buffer, 35 buffers ≈ 3 s — bridges normal inter-word and
    /// inter-phrase pauses so SFSpeechRecognizer gets a continuous stream.
    /// (Was 5 / ~425 ms — too short; gate flickered mid-sentence.)
    static let silenceHoldBuffers: Int = 35

    // ================================================================
    //  4. CRY DETECTION
    // ================================================================
    //  Apple's SNAudioStreamAnalyzer (SoundAnalysis framework) runs a
    //  full neural network to classify sound. It's accurate but
    //  expensive — we throttle it to ~2 Hz to reduce CPU/heat.

    /// Confidence level (0–1) required to trigger a cry event.
    ///
    /// SNClassifySoundRequest returns a confidence for "infant_cry".
    ///
    /// - Increase → fewer false positives (e.g., a cough won't trigger),
    ///   but might miss quieter or muffled cries.
    /// - Decrease → more sensitive; higher chance of false triggers from
    ///   other sustained sounds (dog whine, TV, some music).
    /// - Typical range: 0.70–0.95. Default: 0.85.
    static let cryConfidenceThreshold: Double = 0.85

    /// Run SNAudioStreamAnalyzer every N audio buffers.
    ///
    /// At ~10 buffers/sec (4096 frames @ 48 kHz), N=5 → ~2 Hz analysis.
    /// Baby crying lasts seconds — 2 Hz is more than sufficient to detect it.
    ///
    /// - Increase → less CPU; slower detection latency (N=10 → ~1 Hz).
    /// - Decrease → faster detection; more CPU and heat (N=1 = full rate).
    /// - Typical range: 3–10. Default: 5.
    static let cryAnalysisInterval: Int = 5

    /// Minimum confidence (0–1) from SoundAnalysis "speech" identifier to open
    /// the gate for SFSpeechRecognizer. Below this, the recognizer is not fed audio.
    /// This is a cheap ML gate — the same SNAudioStreamAnalyzer that runs for cry
    /// detection also emits a "speech" confidence at zero additional model cost.
    ///
    /// - Increase → stricter gate; might miss whispered speech or distant voices.
    /// - Decrease → more permissive; non-speech sounds (TV, music) may pass through.
    /// - Typical range: 0.20–0.50. Default: 0.30.
    static let speechGateConfidenceThreshold: Double = 0.30

    /// Seconds to keep the speech gate open after the last confident speech detection.
    /// Prevents choppy recognizer input during brief pauses between words.
    /// Default: 2 s.
    static let speechGateHoldSeconds: Double = 2.0

    // ================================================================
    //  5. WAKE WORD (SFSpeechRecognizer lifecycle)
    // ================================================================

    /// How often to restart the SFSpeechRecognizer task in seconds.
    ///
    /// Apple's SFSpeechRecognitionTask expires after ~60 seconds and
    /// stops producing results. We preemptively restart slightly before
    /// that to avoid a gap in detection.
    ///
    /// - Should always be < 60s.
    /// - Decrease → more restarts, slightly more overhead, but safer
    ///   margin if Apple tightens the 60s limit.
    /// - Default: 55s.
    static let speechTaskRestartSeconds: Double = 55

    /// Seconds of silence after which the recognizer task is PAUSED.
    ///
    /// When no audio arrives (VAD gate is blocking), the WakeWordService
    /// pauses the SFSpeechRecognitionTask entirely after this many seconds,
    /// eliminating its idle CPU cost. It resumes the moment speech energy
    /// is detected again.
    ///
    /// - Increase → recognizer stays alive longer during silence; helpful
    ///   if you have intermittent low-energy speech.
    /// - Decrease → more aggressive pausing; maximum battery savings.
    /// - Default: 10s (matches silenceFlushSeconds).
    static let recognizerPauseAfterSilenceSeconds: Double = 10

    // ================================================================
    //  6. RELEVANCE FILTER
    // ================================================================
    //  TranscriptFilter runs entirely on-device with no API cost.
    //  It gates whether a transcript is sent to Gemini at all.

    /// Minimum seconds of captured speech before the early-abort
    /// relevance check runs.
    ///
    /// When a trigger fires, we wait this long before checking whether
    /// the conversation is baby-related. Too short → might abort a clip
    /// before the parent gets to the baby-related part. Too long → wastes
    /// audio capture time on clearly irrelevant conversations.
    ///
    /// - Increase → more patience before aborting; catches baby topics
    ///   that come up later in a conversation.
    /// - Decrease → faster abort for irrelevant content; saves battery
    ///   and avoids recording private adult conversations.
    /// - Default: 10s.
    static let earlyAbortCheckSeconds: TimeInterval = 5

    /// Minimum number of post-trigger words required before early-abort
    /// can fire. Guards against aborting on the very first partial result
    /// which may be incomplete.
    ///
    /// - Increase → wait for more words before deciding.
    /// - Decrease → abort faster on short non-baby phrases.
    /// - Default: 6 words.
    static let earlyAbortMinWordCount: Int = 6

    // ================================================================
    //  7. GEMINI / BACKEND
    // ================================================================

    /// Maximum characters of the 10-minute rolling transcript context
    /// sent to Gemini with each analysis request.
    ///
    /// Older transcripts are trimmed from the front. Shorter = cheaper.
    ///
    /// - Increase → Gemini has more conversational history for corrections.
    /// - Decrease → lower token cost per request.
    /// - Default: 800 chars (~130–160 words).
    static let transcriptContextMaxChars: Int = 800

    /// Maximum number of today's events sent to Gemini in voice-note
    /// edit mode for correction context. Older events are dropped.
    ///
    /// - Increase → Gemini can correct events from earlier in the day.
    /// - Decrease → lower token cost per voice-note call.
    /// - Default: 20 events.
    static let voiceNoteEventContextLimit: Int = 20
}
