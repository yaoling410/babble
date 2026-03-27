import AVFoundation
import os
import Speech

// ============================================================
//  WakeWordService.swift — Continuous baby-name detection
// ============================================================
//
//  PURPOSE
//  -------
//  Listens to the live audio stream via SFSpeechRecognizer and fires
//  a callback whenever the baby's name appears in the transcript.
//  This is the primary trigger for starting a recording clip.
//
//  MULTILINGUAL SUPPORT
//  --------------------
//  Many households speak more than one language to their baby.
//  Rather than one recognizer for all languages, this service creates
//  one independent SFSpeechRecognizer session PER locale.
//
//  Example: English + Mandarin → "en-US" and "zh-CN" sessions run in
//  parallel. The same audio buffer is fed to both. Whichever recognizer
//  hears the baby's name first fires `onWakeWordDetected`.
//
//  Combined partial transcripts (from all active locales) are joined
//  with a space and passed to `onPartialTranscript`. This gives
//  TranscriptFilter a bilingual view for the early-abort check.
//
//  SFSpeechRecognizer LIMITATIONS
//  --------------------------------
//  - Apple's speech recognition tasks expire after ~60 seconds and
//    stop returning results. We preemptively restart every 55 seconds
//    (AppConfig.speechTaskRestartSeconds) to avoid a gap in detection.
//  - When a task is restarted, its cumulative partial transcript resets
//    to "". AudioCaptureService detects this (shorter incoming transcript)
//    and saves the old content to `captureTranscriptBase` so nothing is lost.
//
//  VAD GATE + SILENCE PAUSE
//  -------------------------
//  This service does NOT run the recognizer when no audio arrives.
//  After `silencePauseSeconds` (default 10 s) of no buffers,
//  all recognition tasks are cancelled. They restart the moment
//  a new buffer arrives. This saves significant CPU when the room is quiet.
//
//  The upstream VAD gate (AudioCaptureService) already filters out
//  buffers below the silence threshold, so silence pause is a second
//  layer of defense for extended quiet periods.

final class WakeWordService {

    /// The baby's name in lowercase. Set in `start()`, used in `checkForWakeWord()`.
    var babyName: String = ""

    /// Lowercase aliases — words the ASR commonly outputs instead of the baby's name.
    /// e.g. ["look", "luke", "looka"] for "Luca". Treated as exact matches.
    var nameAliases: [String] = []

    /// Called on the main thread when the baby's name is detected.
    /// Receives the combined partial transcript from all active locales.
    var onWakeWordDetected: ((String) -> Void)?

    /// The best available partial transcript right now — from whichever session
    /// has produced the longest non-empty result. Used by cry/manual triggers
    /// to seed the initial transcript even when the wake word was never detected.
    var currentBestTranscript: String {
        sessions.map { $0.lastPartial }.max(by: { $0.count < $1.count }) ?? ""
    }

    /// Called on the main thread with every partial recognition result.
    /// AudioCaptureService uses this for real-time transcript accumulation
    /// and early-abort evaluation during an active capture.
    var onPartialTranscript: ((String) -> Void)?

    // ================================================================
    //  MARK: - Per-locale recognition session
    // ================================================================

    /// Holds everything needed for one language's recognition session.
    private struct Session {
        let locale: String                               // e.g. "en-US" or "zh-CN"
        let recognizer: SFSpeechRecognizer              // one recognizer per locale
        var request: SFSpeechAudioBufferRecognitionRequest?  // active streaming request
        var task: SFSpeechRecognitionTask?               // active recognition task
        var lastPartial: String = ""                    // most recent partial from this locale
        /// Incremented each time a new task is started. Callbacks from old tasks
        /// check this and bail out instead of spawning yet another task (prevents
        /// the exponential restart storm seen in production).
        var generation: Int = 0
        /// Starts true if the device supports on-device recognition.
        /// Set to false after repeated ENOMEM failures so subsequent tasks
        /// use server-based recognition instead of retrying the failing model.
        var useOnDeviceRecognition: Bool = false
    }

    /// All active recognition sessions (one per locale passed to `start()`).
    private var sessions: [Session] = []

    /// Fires every `speechTaskRestartSeconds` to preemptively restart all tasks
    /// before Apple's 60-second expiry limit.
    private var restartTimer: Timer?

    /// After this fires, all tasks are paused to save CPU during silence.
    /// Restarted immediately when a new audio buffer arrives.
    private var silenceTimer: Timer?

    /// True after `start()`, false after `stop()`. Guards against timer callbacks
    /// that fire after the service has been stopped.
    private var isRunning = false

    /// True when all tasks have been intentionally paused due to silence.
    /// Set false and tasks restarted the moment `appendBuffer()` is called.
    private var isPaused = false

    /// When the last wake word was reported. Guards against duplicate triggers
    /// from the same utterance (cool down = `triggerCooldownSeconds`).
    private var lastTriggerTime: Date = .distantPast

    /// Rate-limits the cooldown log to one entry per 30 s — avoids flooding
    /// when the recognizer produces 10+ partials/sec during the 60s cooldown.
    private var lastCooldownLogTime: Date = .distantPast

    /// Rate-limits the "what did I hear" transcript log to 1 per second per session.
    /// Keeps info-level logs readable without drowning in 10 Hz partials.
    private var lastTranscriptLogTime: [Int: Date] = [:]

    /// Last transcript we ran bestNameConfidence on, per session index.
    /// Skips the scan when the transcript hasn't changed since the last partial.
    private var lastCheckedTranscript: [Int: String] = [:]

    /// Time of the last bestNameConfidence scan (across all sessions).
    /// Limits scan rate to once per `wakeWordScanIntervalSeconds` — callers
    /// accept up to that much detection latency in exchange for far fewer scans.
    private var lastScanTime: Date = .distantPast

    /// Tracks consecutive failures per session for exponential backoff.
    /// Reset to 0 on any successful partial result.
    private var consecutiveFailures: [Int] = []

    /// How long to wait after the last audio buffer before pausing recognition.
    /// Forwarded from AppConfig for easy tuning.
    private static var silencePauseSeconds: TimeInterval { AppConfig.recognizerPauseAfterSilenceSeconds }

    // ================================================================
    //  MARK: - Public API
    // ================================================================

    /// Start recognition for one or more locales simultaneously.
    ///
    /// - Parameters:
    ///   - babyName: The baby's name as the user typed it. Stored lowercase
    ///               for case-insensitive matching in the transcript.
    ///   - locales:  BCP-47 locale identifiers. Pass multiple for bilingual households.
    ///               Example: `["en-US", "zh-CN"]` for English + Mandarin.
    ///               Locales that don't have an available recognizer are silently skipped.
    ///
    /// - Throws: `WakeWordError.notAuthorized` if speech recognition permission
    ///           has not been granted.
    func start(babyName: String, locales: [String] = ["en-US"], aliases: [String] = []) throws {
        self.babyName    = babyName.lowercased()
        self.nameAliases = aliases.map { $0.lowercased() }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw WakeWordError.notAuthorized
        }

        // Create one Session per locale. `compactMap` drops any locale whose
        // SFSpeechRecognizer is nil (e.g. unsupported language on this device).
        sessions = locales.compactMap { locale in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
                BabbleLog.active.error("\(BabbleLog.ts) ❌ No SFSpeechRecognizer for locale \(locale, privacy: .public)")
                return nil
            }
            var session = Session(locale: locale, recognizer: recognizer)
            session.useOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            BabbleLog.active.info("\(BabbleLog.ts) 🗣 Recognizer ready: \(locale, privacy: .public) onDevice=\(recognizer.supportsOnDeviceRecognition, privacy: .public) available=\(recognizer.isAvailable, privacy: .public)")
            return session
        }
        consecutiveFailures = Array(repeating: 0, count: sessions.count)
        BabbleLog.active.info("\(BabbleLog.ts) 🚀 WakeWordService started — name='\(babyName, privacy: .public)' aliases=[\(self.nameAliases.joined(separator: ","), privacy: .public)] sessions=\(self.sessions.count, privacy: .public)")

        isRunning = true
        startAllTasks()     // begin recognition immediately
        scheduleRestart()   // preemptive 55-second restart timer
    }

    /// Stop all recognition sessions and release resources.
    func stop() {
        isRunning = false
        restartTimer?.invalidate()
        restartTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        cancelAllTasks()
        sessions = []
    }

    /// Feed one audio buffer to all active recognition sessions.
    ///
    /// Only called when speech-band RMS is above the silence threshold
    /// (gated upstream in AudioCaptureService.handleBuffer). So this
    /// function only runs when there is actual sound in the room.
    ///
    /// Also manages the silence pause/resume cycle:
    /// - If paused, restart all tasks before processing the buffer.
    /// - Reset the silence timer so tasks aren't paused mid-speech.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        // If we were paused due to silence, resume recognition now
        if isPaused {
            isPaused = false
            BabbleLog.active.info("\(BabbleLog.ts) ▶️ Resuming from silence pause — restarting recognition tasks")
            startAllTasks()
        }

        // Broadcast the same buffer to every locale's recognition request
        for session in sessions {
            session.request?.append(buffer)
        }

        // Reset the silence countdown — if no buffer arrives for `silencePauseSeconds`,
        // this timer fires and pauses all tasks to save CPU.
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: WakeWordService.silencePauseSeconds,
            repeats: false
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            BabbleLog.active.info("\(BabbleLog.ts) ⏸ Recognizer pausing after \(Int(WakeWordService.silencePauseSeconds), privacy: .public)s silence — will resume on next speech buffer")
            self.isPaused = true
            self.cancelAllTasks()
        }
    }

    // ================================================================
    //  MARK: - On-device recognition check
    // ================================================================

    /// Returns true if ALL requested locales support on-device speech recognition.
    ///
    /// On-device recognition (iOS 16+, requires the language model to be downloaded)
    /// works without internet and has no privacy exposure. The app requests it when
    /// available (`requiresOnDeviceRecognition = true` in startTask).
    ///
    /// If this returns false, recognition falls back to Apple's servers —
    /// audio is sent to Apple, not Gemini.
    static func isOnDeviceRecognitionAvailable(for locales: [String] = ["en-US"]) -> Bool {
        locales.allSatisfy { locale in
            SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition ?? false
        }
    }

    // ================================================================
    //  MARK: - Task lifecycle (private)
    // ================================================================

    /// Cancel existing tasks and start fresh ones for all sessions.
    /// Called on initial start, preemptive restart (55 s timer), and silence resume.
    private func startAllTasks() {
        cancelAllTasks()
        guard isRunning else { return }
        // Reset failure counters on intentional restarts (55s timer, silence resume).
        // These are clean restarts, not error retries — backoff should reset.
        consecutiveFailures = Array(repeating: 0, count: sessions.count)
        for i in sessions.indices {
            startTask(at: i)
        }
    }

    /// Start (or restart) the recognition task for session at `index`.
    ///
    /// Each task:
    /// 1. Creates a new SFSpeechAudioBufferRecognitionRequest with partial results.
    /// 2. Uses on-device recognition if supported (privacy + works offline).
    /// 3. On each partial result, checks for the baby's name and fires onPartialTranscript.
    /// 4. On error or final result, restarts itself after a 100ms delay.
    private func startTask(at index: Int) {
        guard isRunning, index < sessions.count else { return }
        let recognizer = sessions[index].recognizer
        guard recognizer.isAvailable else {
            BabbleLog.active.warning("\(BabbleLog.ts) ⚠️ Recognizer unavailable for locale \(self.sessions[index].locale, privacy: .public) — skipping (no internet? restricted?)")
            return
        }

        // Cancel any existing task for this session BEFORE creating a new one.
        // Without this, the old task's callback can still fire and spawn another
        // startTask call, creating an exponential restart storm.
        sessions[index].task?.cancel()
        sessions[index].task = nil
        sessions[index].request?.endAudio()
        sessions[index].request = nil

        // Bump generation so stale callbacks from the old task are ignored.
        sessions[index].generation += 1
        let taskGeneration = sessions[index].generation

        BabbleLog.active.info("\(BabbleLog.ts) ▶️ Starting recognition task [\(self.sessions[index].locale, privacy: .public)] onDevice=\(self.sessions[index].useOnDeviceRecognition, privacy: .public)")

        // A new request must be created for each task — requests can't be reused.
        let request = SFSpeechAudioBufferRecognitionRequest()
        // partial results = true: we get transcripts while the user is still speaking,
        // not just after a pause. Essential for real-time wake word detection.
        request.shouldReportPartialResults = true
        // On-device recognition: no audio sent to Apple's servers.
        // Falls back to server-based if the language model isn't downloaded.
        request.requiresOnDeviceRecognition = sessions[index].useOnDeviceRecognition
        // Hint the recognizer toward the baby's name so it isn't mistaken for
        // a common word (e.g. "Luca" → "Look", "Mia" → "me a").
        // Also add common mishearings as hints so the acoustic model is biased
        // toward the correct word even when the pronunciation is ambiguous.
        if !babyName.isEmpty {
            let name = babyName.capitalized
            var hints: [String] = [babyName, name, "\(name).", "Hey \(name)", "Hey \(babyName)"]
            // Add user-defined aliases so the LM is also biased toward the correct word
            // when the recognizer would otherwise pick a common English substitute.
            hints += nameAliases + nameAliases.map { $0.capitalized }
            request.contextualStrings = hints
        }

        sessions[index].request = request

        sessions[index].task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Dispatch the entire handler body to main — this serialises all reads/writes
            // of `sessions`, `consecutiveFailures`, and related state with every other
            // caller (startAllTasks, stop, currentBestTranscript). Partials arrive ~10 Hz
            // so one main-queue hop per partial is negligible.
            DispatchQueue.main.async { [weak self] in
                guard let self, index < self.sessions.count else { return }

                // Stale callback from an old task — ignore it to prevent restart storms.
                guard self.sessions[index].generation == taskGeneration else { return }

                if let result {
                    self.consecutiveFailures[index] = 0
                    let transcript = result.bestTranscription.formattedString
                    self.sessions[index].lastPartial = transcript

                    let kind = result.isFinal ? "FINAL" : "partial"
                    if result.isFinal {
                        let segDebug = result.bestTranscription.segments
                            .map { seg -> String in
                                let c = seg.confidence > 0 ? "\(Int(seg.confidence * 100))%" : "?"
                                return "\(seg.substring)(\(c))"
                            }
                            .joined(separator: " ")
                        BabbleLog.active.info("\(BabbleLog.ts) 📝 [\(self.sessions[index].locale, privacy: .public)] \(kind, privacy: .public): \(segDebug.prefix(120), privacy: .public)")
                    } else {
                        // Throttled info log: show transcript at most once per second per session.
                        // Lets you see what's being heard in real time without flooding at 10 Hz.
                        let now = Date()
                        let last = self.lastTranscriptLogTime[index] ?? .distantPast
                        if now.timeIntervalSince(last) >= 1.0 {
                            self.lastTranscriptLogTime[index] = now
                            BabbleLog.active.info("\(BabbleLog.ts) 👂 [\(self.sessions[index].locale, privacy: .public)] heard: '\(transcript.prefix(120), privacy: .public)'")
                        }
                    }

                    self.checkForWakeWord(in: result, sessionIndex: index)

                    if !result.isFinal {
                        // Combine all locales' partials so TranscriptFilter gets bilingual input.
                        let combined = self.sessions.map { $0.lastPartial }.filter { !$0.isEmpty }.joined(separator: " ")
                        self.onPartialTranscript?(combined)
                    }
                }

                // SFSpeechRecognitionTask calls this with isFinal=true after ~60 s,
                // or with an error if something went wrong. In both cases, restart
                // to maintain continuous recognition — UNLESS the task was intentionally
                // cancelled (e.g. by cancelAllTasks). Cancellation fires this callback
                // with error != nil, but startAllTasks() is already creating a fresh
                // task, so restarting here would create a second concurrent task.
                let nsErr = error as NSError?
                let wasCancelled = nsErr?.code == NSUserCancelledError
                    || (nsErr?.domain == "kAFAssistantErrorDomain" && nsErr?.code == 203)
                    || (nsErr?.localizedDescription.lowercased().contains("cancel") == true)
                // "No speech detected" (kAFAssistantErrorDomain 1110): Apple's internal timeout.
                let isNoSpeech = nsErr?.domain == "kAFAssistantErrorDomain" && nsErr?.code == 1110

                if !wasCancelled && (error != nil || result?.isFinal == true) {
                    if self.isRunning {
                        if isNoSpeech {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                                guard let self, self.isRunning, !self.isPaused else { return }
                                self.startTask(at: index)
                            }
                        } else {
                            let failures = index < self.consecutiveFailures.count
                                ? self.consecutiveFailures[index] : 0
                            let delay = min(0.1 * pow(5.0, Double(failures)), 30.0)
                            if index < self.consecutiveFailures.count {
                                self.consecutiveFailures[index] += 1
                            }
                            if let err = error {
                                BabbleLog.active.warning("\(BabbleLog.ts) ⚠️ Task error (attempt \(failures + 1, privacy: .public), retry in \(String(format: "%.1f", delay), privacy: .public)s): \(err.localizedDescription, privacy: .public)")
                            }
                            if failures >= 2 && self.sessions[index].useOnDeviceRecognition {
                                BabbleLog.active.warning("\(BabbleLog.ts) ⚠️ On-device recognition failing — switching to server-based for \(self.sessions[index].locale, privacy: .public)")
                                self.sessions[index].useOnDeviceRecognition = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                guard let self, self.isRunning, !self.isPaused else { return }
                                self.startTask(at: index)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Cancel all active recognition tasks and clear their requests.
    /// Clears `lastPartial` so stale transcripts don't appear after resume.
    private func cancelAllTasks() {
        for i in sessions.indices {
            sessions[i].task?.cancel()
            sessions[i].task = nil
            sessions[i].request?.endAudio()   // signal end-of-stream before releasing
            sessions[i].request = nil
            sessions[i].lastPartial = ""
        }
        // New tasks start with a fresh cumulative transcript — reset caches so
        // the first partial from the new task is scanned immediately.
        lastCheckedTranscript.removeAll()
        lastScanTime = .distantPast
    }

    /// Schedule the preemptive task restart timer.
    /// Apple's tasks expire after ~60 s — we restart at 55 s to avoid a gap.
    private func scheduleRestart() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.speechTaskRestartSeconds,
            repeats: true
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            BabbleLog.active.info("\(BabbleLog.ts) 🔄 \(Int(Constants.speechTaskRestartSeconds), privacy: .public)s preemptive restart — cycling all recognition tasks (brief detection gap possible)")
            self.startAllTasks()
        }
    }

    // ================================================================
    //  MARK: - Wake word check
    // ================================================================

    /// Called on every partial transcript from every locale.
    /// Fires `onWakeWordDetected` when the baby's name appears and
    /// the cooldown has expired.
    /// Scans all segments (including alternative hypotheses) for the baby's name.
    /// Returns the highest confidence found, or nil if the name wasn't present.
    private func bestNameConfidence(in result: SFSpeechRecognitionResult) -> Float? {
        var best: Float? = nil
        var foundInBestHypothesis = false

        // Check ALL transcription hypotheses, not just bestTranscription.
        // Apple ranks them by confidence — bestTranscription = transcriptions[0].
        // The baby's name may appear in a lower-ranked hypothesis (e.g. "Luca"
        // as hypothesis #2 when "Look" wins as #1). We accept any hypothesis
        // that contains the name, using its rank as a confidence proxy.
        let hypothesisCount = result.transcriptions.count
        for (rank, transcription) in result.transcriptions.enumerated() {
            // Proxy confidence: hypothesis rank 0 = 0.9, rank 1 = 0.6, rank 2+ = 0.4
            let rankConf: Float = rank == 0 ? 0.9 : (rank == 1 ? 0.6 : 0.4)

            var loggedThisHypothesis = false
            for segment in transcription.segments {
                let candidates = [segment.substring] + segment.alternativeSubstrings

                // Log misses on the best hypothesis so we can diagnose mishearings.
                if rank == 0 && !segment.substring.lowercased().contains(babyName) && !segment.alternativeSubstrings.isEmpty {
                    let alts = segment.alternativeSubstrings.prefix(4).joined(separator: "|")
                    BabbleLog.active.debug("\(BabbleLog.ts) 🔤 '\(segment.substring, privacy: .public)' alts: [\(alts, privacy: .public)]")
                }

                for candidate in candidates {
                    let c = candidate.lowercased()
                    let matchesName  = c.contains(babyName)
                    let matchesAlias = !nameAliases.isEmpty && nameAliases.contains(where: { c.contains($0) })

                    // Phonetic fallback: check each word's consonant skeleton.
                    // Catches mishearings like "Look"/"Luke" for "Luca" that don't
                    // appear in the alias list. Confidence is discounted (×0.8) since
                    // phonetic matches are less certain than exact/alias matches.
                    let phoneticWord: String?
                    if !matchesName && !matchesAlias && !babyName.isEmpty {
                        let words = c.split(separator: " ").map(String.init)
                        phoneticWord = words.first(where: { PhoneticMatcher.isMatch($0, target: babyName) })
                    } else {
                        phoneticWord = nil
                    }

                    let didMatch = matchesName || matchesAlias || (phoneticWord != nil)
                    if didMatch {
                        let baseConf: Float = segment.confidence > 0 ? segment.confidence : rankConf
                        let conf: Float = phoneticWord != nil && !matchesName && !matchesAlias
                            ? baseConf * 0.8   // slight discount for phonetic-only match
                            : baseConf
                        if best == nil || conf > best! { best = conf }

                        if rank == 0 { foundInBestHypothesis = true }

                        if let pw = phoneticWord {
                            BabbleLog.active.info("\(BabbleLog.ts) 🎵 Phonetic match: '\(pw, privacy: .public)' ≈ '\(self.babyName, privacy: .public)' (code '\(PhoneticMatcher.consonantCode(for: pw), privacy: .public)' == '\(PhoneticMatcher.consonantCode(for: self.babyName), privacy: .public)')")
                        }
                        // Only log lower hypotheses when name was NOT in the best one —
                        // that's the interesting case (name hidden in a lower-ranked guess).
                        if rank > 0 && !foundInBestHypothesis && !loggedThisHypothesis {
                            BabbleLog.active.info("\(BabbleLog.ts) 💡 '\(self.babyName, privacy: .public)' found in hypothesis #\(rank, privacy: .public)/\(hypothesisCount, privacy: .public) — best was '\(result.bestTranscription.formattedString.prefix(40), privacy: .public)'")
                            loggedThisHypothesis = true
                        }
                    }
                }
            }
        }
        return best
    }

    private func checkForWakeWord(in result: SFSpeechRecognitionResult, sessionIndex: Int) {
        // ── Fast-path guards (before the expensive multi-hypothesis scan) ──────
        // 1. Skip entirely during cooldown — no need to scan.
        let cooldownRemaining = Constants.triggerCooldownSeconds - Date().timeIntervalSince(lastTriggerTime)
        guard cooldownRemaining <= 0 else {
            // Rate-limited to once per 30 s so this doesn't flood during the 60s cooldown.
            if Date().timeIntervalSince(lastCooldownLogTime) >= 30 {
                lastCooldownLogTime = Date()
                BabbleLog.active.info("\(BabbleLog.ts) ⏳ Cooldown — \(Int(cooldownRemaining), privacy: .public)s remaining, wake word check skipped")
            }
            return
        }

        // 2. Throttle the scan rate. Partials arrive every ~100 ms; scanning all
        //    hypotheses on every partial is wasteful.
        //    • First detection (never triggered): 1 s interval — low latency matters.
        //    • Re-detection (after a prior trigger + cooldown): 10 s interval — a
        //      second utterance is less time-critical.
        let everTriggered = lastTriggerTime != .distantPast
        let scanInterval = everTriggered
            ? AppConfig.wakeWordRescanIntervalSeconds
            : AppConfig.wakeWordInitialScanIntervalSeconds
        let timeSinceScan = Date().timeIntervalSince(lastScanTime)
        guard timeSinceScan >= scanInterval else { return }

        // 3. Skip if the transcript hasn't changed (identical consecutive partials).
        let transcript = result.bestTranscription.formattedString
        if lastCheckedTranscript[sessionIndex] == transcript {
            BabbleLog.active.debug("\(BabbleLog.ts) ⏭ Same transcript — skipping scan: '\(transcript.prefix(60), privacy: .public)'")
            return
        }
        lastCheckedTranscript[sessionIndex] = transcript
        lastScanTime = Date()
        BabbleLog.active.info("\(BabbleLog.ts) 🔎 Scanning for '\(self.babyName, privacy: .public)' in: '\(transcript.prefix(80), privacy: .public)'")
        // ──────────────────────────────────────────────────────────────────────

        guard let confidence = bestNameConfidence(in: result) else {
            BabbleLog.active.info("\(BabbleLog.ts) 🔍 No match — '\(self.babyName, privacy: .public)' not in '\(transcript.prefix(80), privacy: .public)'")
            return
        }

        let pct = Int(confidence * 100)

        BabbleLog.active.info("\(BabbleLog.ts) 🔔 Wake word '\(self.babyName, privacy: .public)' detected conf=\(pct, privacy: .public)% — transcript='\(transcript.prefix(80), privacy: .public)'")
        lastTriggerTime = Date()
        // Use `transcript` — the text that actually contained the wake word.
        // The old approach (sessions.map { $0.lastPartial }.joined()) was unreliable:
        // other sessions may have just restarted and have empty lastPartial, producing
        // an empty string that starts accumulatedTranscript at "" even when speech was heard.
        DispatchQueue.main.async { [weak self] in
            self?.onWakeWordDetected?(transcript)
        }
    }

    // ================================================================
    //  MARK: - Permission helper
    // ================================================================

    /// Request speech recognition authorization. Returns the resulting status.
    /// Call this once before `start()`. Wraps the callback-based API in async/await.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

// ============================================================
//  WakeWordError — why start() can fail
// ============================================================
enum WakeWordError: Error {
    /// The user denied speech recognition permission in Settings.
    /// Show an alert asking them to enable it under Settings → Privacy → Speech Recognition.
    case notAuthorized
}
