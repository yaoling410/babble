import Foundation
import Combine
import AVFoundation
import UserNotifications

// ============================================================
//  OnDevicePipeline.swift — Central coordinator for on-device build
// ============================================================

#if BABBLE_ON_DEVICE
@available(iOS 26.0, *)
@MainActor
final class OnDevicePipeline: ObservableObject {

    enum State: Equatable {
        case idle
        case listening
        case processing
        case error(String)
    }

    @Published var state: State = .idle
    @Published var lastTranscription: String = ""
    @Published var emotionalSupportDetected: Bool = false

    // ── Dependencies (injected by MonitorViewModel) ──────────────

    var profile: BabyProfile?
    var eventStore: EventStore?
    var speakerStore: SpeakerStore?
    var audioCapture: AudioCaptureService?
    var cryDetector: CryDetector?

    // ── On-device services ──────────────────────────────────────

    private let whisper = WhisperKitService()
    private lazy var analysisService = OnDeviceAnalysisService()
    private var validationTimer: Timer?      // 5-min (dedup + auto-complete)
    private var sixHourTimer: Timer?         // 6-hour pattern check
    private var dailyTimer: Timer?           // 24-hour daily review

    /// Prevents concurrent Foundation Models calls (correction + analysis vs review).
    private var isLLMBusy = false

    /// Counter for audio buffers received — logged periodically to confirm audio is flowing.
    private var bufferCount: Int = 0

    /// When monitoring started — used to avoid flagging patterns when
    /// monitoring has only been active for a short time.
    private var monitoringStartTime: Date?

    // ── Event burst detection ───────────────────────────────────
    // When many events arrive in a short window, trigger an early
    // validation pass (dedup + pattern check) without waiting for
    // the next 5-min timer. This catches rapid-fire scenarios like
    // "she pooped, then cried, then spit up, then cried again".

    /// Timestamps of recently created events (last 10 min).
    private var recentEventTimestamps: [Date] = []

    /// How many events in 10 minutes triggers an early validation.
    private let burstThreshold = 5

    /// Cooldown to avoid running burst validation back-to-back.
    private var lastBurstValidation: Date = .distantPast

    // ── Rolling transcript buffer (last 20 min) ──────────────────
    // Used by the 5-min validation pass to give Foundation Models
    // context for correcting recent events.

    private var recentTranscripts: [(timestamp: Date, text: String)] = []

    private func appendTranscript(_ text: String) {
        let now = Date()
        recentTranscripts.append((timestamp: now, text: text))
        let cutoff = now.addingTimeInterval(-20 * 60)
        recentTranscripts.removeAll { $0.timestamp < cutoff }
    }

    private func last20MinTranscript() -> String {
        recentTranscripts.map { $0.text }.joined(separator: "\n")
    }

    // ── Caregiver mood tracking ─────────────────────────────────
    // Don't send support notifications too quickly. Requirements:
    //   1. At least 6 hours of monitoring active
    //   2. At least 20 mood readings total
    //   3. 90%+ of those are negative (tired/frustrated/anxious)
    // This avoids false alarms from a rough 30-minute patch.

    /// All mood readings today: (timestamp, mood string).
    private var moodReadings: [(timestamp: Date, mood: String)] = []

    /// Only send one notification per day.
    private var didSendMoodNotificationToday: Bool = false

    init() {
        NSLog("[OnDevice] 🏗️ Pipeline created")
        whisper.onTranscription = { [weak self] window in
            Task { @MainActor in
                await self?.handleWindow(window)
            }
        }
    }

    // MARK: - Start

    func start() async {
        NSLog("[OnDevice] ▶️ start() called — state=\(String(describing: state))")

        guard state == .idle || {
            if case .error = state { return true }
            return false
        }() else {
            NSLog("[OnDevice] ⚠️ start() skipped — already in state \(String(describing: state))")
            return
        }

        // Step 1: Permissions
        NSLog("[OnDevice] 📋 Step 1/4: Requesting microphone permission...")
        let micGranted = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        guard micGranted else {
            NSLog("[OnDevice] ❌ Microphone permission DENIED")
            state = .error("Microphone permission denied")
            return
        }
        NSLog("[OnDevice] ✅ Microphone permission granted")

        // Request notification permission (for caregiver support notifications)
        let notifCenter = UNUserNotificationCenter.current()
        let notifGranted = try? await notifCenter.requestAuthorization(options: [.alert, .sound])
        NSLog("[OnDevice] 🔔 Notification permission: \(notifGranted == true ? "granted" : "denied/skipped")")

        // Step 2: Load WhisperKit model
        NSLog("[OnDevice] 📋 Step 2/4: Loading WhisperKit model (first launch downloads ~75 MB)...")
        do {
            try await whisper.loadModel()
            NSLog("[OnDevice] ✅ WhisperKit model loaded — isModelReady=\(whisper.isModelReady)")
        } catch {
            NSLog("[OnDevice] ❌ WhisperKit model FAILED: \(error.localizedDescription)")
            state = .error("WhisperKit model not ready: \(error.localizedDescription)")
            return
        }

        // Step 3: Validate dependencies
        NSLog("[OnDevice] 📋 Step 3/4: Checking dependencies...")
        guard let audioCapture else {
            NSLog("[OnDevice] ❌ AudioCaptureService is nil — not injected")
            state = .error("AudioCaptureService not configured")
            return
        }
        guard let profile else {
            NSLog("[OnDevice] ❌ BabyProfile is nil — not injected")
            state = .error("BabyProfile not configured")
            return
        }
        // Pass language + baby name + enrollment variants to WhisperKit
        whisper.language = profile.whisperLanguage
        whisper.babyName = profile.babyName
        whisper.ageMonths = profile.babyAgeMonths
        whisper.nameVariants = profile.nameVariants
        NSLog("[OnDevice] ✅ Dependencies OK — baby='\(profile.babyName)' age=\(profile.babyAgeMonths)mo speakers=\(speakerStore?.speakers.count ?? 0) language=\(profile.whisperLanguage) variants=\(profile.nameVariants.count)")

        // Wire audio buffer → WhisperKit
        bufferCount = 0
        audioCapture.onRawBuffer = { [weak self] samples, timestamp in
            guard let self else { return }
            self.bufferCount += 1
            // Log every 100th buffer (~8.5s at 85ms/buffer) to confirm audio is flowing
            if self.bufferCount % 100 == 1 {
                NSLog("[OnDevice] 🎤 Audio buffer #\(self.bufferCount) — \(samples.count) samples")
            }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { return }
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
            if let floatData = pcmBuffer.floatChannelData?[0] {
                for i in 0 ..< samples.count {
                    floatData[i] = Float(samples[i]) / 32767.0
                }
            }
            self.whisper.feedAudio(pcmBuffer)
        }

        // CryDetector fires independently
        cryDetector?.onCryDetected = { [weak self] in
            guard let self else { return }
            NSLog("[OnDevice] 😢 Cry detected — creating event")
            let event = BabyEvent(
                id: UUID().uuidString,
                type: .cry,
                timestamp: Date(),
                timestampConfidence: .exact,
                createdAt: Date(),
                detail: "Crying detected",
                notable: false,
                confidence: 0.85,
                status: .completed
            )
            let response = AnalyzeResponse(newEvents: [event], corrections: [])
            self.eventStore?.apply(response: response, dateStr: Self.todayStr())
        }

        // Step 4: Start audio engine
        NSLog("[OnDevice] 📋 Step 4/4: Starting audio engine...")
        do {
            try audioCapture.startListening()
            state = .listening
            monitoringStartTime = Date()
            startValidationTimers()
            NSLog("[OnDevice] ✅ Pipeline started — listening for speech")
            NSLog("[OnDevice] 📊 Config: VAD threshold=\(whisper.speechThresholdForLogging) silenceFlush=4s maxWindow=90s minWindow=0.5s")
        } catch {
            NSLog("[OnDevice] ❌ Audio engine FAILED: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Stop

    func stop() {
        NSLog("[OnDevice] ⏹️ stop() called — buffers processed: \(bufferCount)")
        audioCapture?.stopListening()
        validationTimer?.invalidate(); validationTimer = nil
        sixHourTimer?.invalidate(); sixHourTimer = nil
        dailyTimer?.invalidate(); dailyTimer = nil
        whisper.reset()
        state = .idle
    }

    // MARK: - Name enrollment

    /// Enroll the baby's name from a recorded audio clip.
    /// Runs WhisperKit once per configured language to discover all text variants.
    func enrollName(audioData: Data) async {
        #if canImport(WhisperKit)
        guard let kit = whisper.whisperKitInstance, let profile else { return }

        // Save audio for later re-decoding on language change
        if let url = NameEnrollmentService.saveEnrollmentAudio(audioData) {
            profile.nameEnrollmentAudioPath = url.path
        }

        let samples = AudioResampler.resample48to16(wavData: audioData)
        guard !samples.isEmpty else { return }

        let languages = NameEnrollmentService.languageCodes(from: profile.whisperLanguage)
        let variants = await NameEnrollmentService.discoverVariants(
            audioSamples: samples,
            whisperKit: kit,
            languages: languages,
            typedName: profile.babyName
        )
        profile.nameVariants = variants
        whisper.nameVariants = variants
        NSLog("[OnDevice] 🎤 Name enrolled — \(variants.count) variants: \(variants)")
        #endif
    }

    /// Re-decode saved enrollment audio with current language settings.
    /// Called when the user changes whisperLanguage in Settings.
    func regenerateNameVariants() async {
        #if canImport(WhisperKit)
        guard let kit = whisper.whisperKitInstance, let profile else { return }
        guard let audioPath = profile.nameEnrollmentAudioPath else {
            NSLog("[OnDevice] ⚠️ No enrollment audio saved — skipping regeneration")
            return
        }

        let url = URL(fileURLWithPath: audioPath)
        let languages = NameEnrollmentService.languageCodes(from: profile.whisperLanguage)
        let variants = await NameEnrollmentService.regenerateVariants(
            audioPath: url,
            whisperKit: kit,
            languages: languages,
            typedName: profile.babyName
        )
        profile.nameVariants = variants
        whisper.nameVariants = variants
        NSLog("[OnDevice] 🔄 Name variants regenerated — \(variants.count) variants: \(variants)")
        #endif
    }

    // MARK: - Window handling

    private func handleWindow(_ window: WhisperKitService.TranscriptionWindow) async {
        let duration = window.endTime.timeIntervalSince(window.startTime)
        NSLog("[OnDevice] 📝 Window received — \(String(format: "%.1f", duration))s, \(window.audioSamples.count) samples, text='\(window.text.prefix(100))'")

        guard state == .listening else {
            NSLog("[OnDevice] ⚠️ Window dropped — state=\(String(describing: state)) (expected .listening)")
            return
        }
        guard let profile, let eventStore else {
            NSLog("[OnDevice] ⚠️ Window dropped — profile or eventStore is nil")
            return
        }

        lastTranscription = window.text
        // Don't append raw transcript here — wait for corrected version below

        // Gate 1: Is the text empty?
        guard !window.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSLog("[OnDevice] 🚫 Gate 1 BLOCKED — empty transcription (noise/music)")
            return
        }

        // Gate 2: Relevance — merge manual aliases + enrollment variants
        let allAliases = Array(Set(profile.nameAliases + profile.nameVariants))
        let relevant = RelevanceGate.isRelevant(
            text: window.text,
            babyName: profile.babyName,
            nameAliases: allAliases,
            isOnlyBaby: profile.isOnlyBaby
        )
        guard relevant else {
            NSLog("[OnDevice] 🚫 Gate 2 BLOCKED — not baby-related: '\(window.text.prefix(80))'")
            // Still store raw transcript as context — helps the LLM corrector
            // understand conversation flow even for non-baby windows
            appendTranscript(window.text)
            return
        }
        NSLog("[OnDevice] ✅ Gate 2 PASSED — baby-related, proceeding to diarize+analyze")

        state = .processing

        // Step 3: Diarize (off main thread — segmentation is CPU-heavy)
        // SpeakerKit's embedding API is internal, so we can't match against
        // enrolled profiles yet. Labels are anonymous (SPEAKER_0, SPEAKER_1)
        // but still useful for separating who said what.
        let annotatedTranscript: String
        if speakerStore != nil {
            NSLog("[OnDevice] 🎙️ Step 3: Diarizing speakers...")
            do {
                let result = try await Task.detached {
                    try await OnDeviceDiarizationService.diarize(window: window)
                }.value
                annotatedTranscript = result.annotatedTranscript
                NSLog("[OnDevice] ✅ Diarized — \(result.segments.count) segments, \(result.unknownSpeakers.count) unknown")
                for seg in result.segments {
                    NSLog("[OnDevice]   [\(seg.speaker)] \(String(format: "%.1f", seg.start))–\(String(format: "%.1f", seg.end))s: \(seg.text.prefix(50))")
                }
            } catch {
                NSLog("[OnDevice] ⚠️ Diarization failed: \(error) — using cleaned transcript")
                annotatedTranscript = window.text
            }
        } else {
            NSLog("[OnDevice] ⚡ Step 3: No speakers enrolled — skipping diarization")
            annotatedTranscript = window.text
        }

        // Step 4a: Correct transcript with Foundation Models
        guard !isLLMBusy else {
            NSLog("[OnDevice] ⏳ LLM busy — skipping this window")
            state = .listening
            return
        }
        isLLMBusy = true
        defer { isLLMBusy = false }

        let dateStr = Self.todayStr()
        let service = analysisService

        let recentContext = last20MinTranscript()
        let babyName = profile.babyName
        let ageMonths = profile.babyAgeMonths

        // Run LLM correction off the main thread to keep UI responsive.
        let correctedTranscript: String = await Task.detached {
            do {
                return try await service.correctTranscript(
                    raw: annotatedTranscript,
                    babyName: babyName,
                    recentContext: recentContext
                )
            } catch {
                NSLog("[OnDevice] ⚠️ Transcript correction failed: \(error) — using original")
                return annotatedTranscript
            }
        }.value

        // Empty = LLM determined the transcript is noise/gibberish
        guard !correctedTranscript.isEmpty else {
            NSLog("[OnDevice] 🚫 Transcript discarded as noise — skipping analysis")
            state = .listening
            return
        }

        // Store corrected transcript as context for future corrections.
        appendTranscript(correctedTranscript)
        lastTranscription = correctedTranscript

        // Step 4b: Extract events from corrected transcript
        NSLog("[OnDevice] 🧠 Step 4b: Foundation Models event extraction — '\(correctedTranscript.prefix(80))'")

        do {
            service.onEmotionalSupportNeeded = { [weak self] in
                NSLog("[OnDevice] 💛 Emotional support needed — surfacing to UI")
                self?.emotionalSupportDetected = true
            }
            service.onMoodDetected = { [weak self] mood in
                self?.recordMood(mood)
            }
            let clipTimestamp = window.startTime
            // Run LLM extraction off the main thread
            let response = try await Task.detached {
                try await service.analyze(
                    transcript: correctedTranscript,
                    babyName: babyName,
                    ageMonths: ageMonths,
                    triggerHint: "continuous",
                    clipTimestamp: clipTimestamp
                )
            }.value

            if response.newEvents.isEmpty {
                NSLog("[OnDevice] ℹ️ Analysis returned 0 events (relevant but no extractable activity)")
            } else {
                NSLog("[OnDevice] ✅ Extracted \(response.newEvents.count) events:")
                for ev in response.newEvents {
                    NSLog("[OnDevice]   + \(ev.type.emoji) \(ev.type.rawValue)\(ev.subtype.map { "/\($0)" } ?? ""): \(ev.detail.prefix(60)) [confidence=\(String(format: "%.2f", ev.confidence ?? 0)) status=\(ev.status?.rawValue ?? "nil")]")
                }
                eventStore.apply(response: response, dateStr: dateStr)
                NSLog("[OnDevice] 💾 Events saved to EventStore")

                checkForEventBurst(newEventCount: response.newEvents.count)
            }
        } catch {
            NSLog("[OnDevice] ❌ Foundation Models analysis FAILED: \(error)")
            NSLog("[OnDevice]    Error type: \(type(of: error))")
            NSLog("[OnDevice]    Description: \(error.localizedDescription)")
        }

        state = .listening
        NSLog("[OnDevice] 🔄 Back to listening")
    }

    // MARK: - Multi-tier validation
    //
    // Three tiers of periodic checks, each at a different time scale:
    //
    //   5 min  — housekeeping: auto-complete stale events, dedup duplicates
    //   6 hour — pattern check: feeding frequency, sleep gaps, unusual activity
    //   24 hour — daily review: overall day assessment, missed patterns
    //
    // All checks consider monitoringActiveHours() to avoid false alerts
    // when monitoring just started or was interrupted.

    /// How many hours monitoring has been active today.
    private func monitoringActiveHours() -> Double {
        guard let start = monitoringStartTime else { return 0 }
        return Date().timeIntervalSince(start) / 3600
    }

    private func startValidationTimers() {
        // 5-min: housekeeping
        validationTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.run5MinValidation() }
        }
        // 6-hour: pattern detection
        sixHourTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.run6HourValidation() }
        }
        // Daily: schedule once for 8 PM (not polling every 5 min)
        scheduleDailyReview()
        NSLog("[OnDevice] ⏰ Validation timers started — 5min (housekeeping) + 6hr (patterns) + daily (8 PM)")
    }

    // ── Tier 1: Every 5 minutes ─────────────────────────────────

    private func run5MinValidation() {
        autoCompleteStaleEvents()
        deduplicateRecentEvents()

        // Only invoke Foundation Models review when >1 event was created
        // in the last 5 min — avoids unnecessary model calls on quiet periods.
        if let eventStore {
            let fiveMinAgo = Date().addingTimeInterval(-5 * 60)
            let recentCount = eventStore.events.filter {
                ($0.createdAt ?? $0.timestamp) >= fiveMinAgo
            }.count
            if recentCount > 1 {
                Task { await reviewRecentEvents() }
            }
        }
    }

    // ── Event burst detection ─────────────────────────────────

    private func checkForEventBurst(newEventCount: Int) {
        let now = Date()

        // Add timestamps for each new event
        for _ in 0..<newEventCount {
            recentEventTimestamps.append(now)
        }

        // Trim to last 10 minutes
        let cutoff = now.addingTimeInterval(-10 * 60)
        recentEventTimestamps.removeAll { $0 < cutoff }

        // Check burst threshold with cooldown (don't re-trigger within 5 min)
        guard recentEventTimestamps.count >= burstThreshold,
              now.timeIntervalSince(lastBurstValidation) >= 5 * 60 else { return }

        lastBurstValidation = now
        NSLog("[OnDevice] ⚡ Event burst detected — \(recentEventTimestamps.count) events in 10 min (threshold: \(burstThreshold)). Running early validation.")

        // Run all three tiers immediately
        run5MinValidation()
        run6HourValidation()
    }

    // ── Tier 1 implementation ─────────────────────────────────

    private func autoCompleteStaleEvents() {
        guard let eventStore else { return }
        let now = Date()
        let inProgressEvents = eventStore.events.filter { $0.status == .inProgress }
        guard !inProgressEvents.isEmpty else { return }
        NSLog("[OnDevice] ⏰ Auto-complete scan — \(inProgressEvents.count) in_progress events")

        for event in inProgressEvents {
            let timeoutMin = AgeDefaults.autoCompleteTimeoutMinutes(
                eventType: event.type.rawValue,
                subtype: event.subtype
            )
            let elapsed = now.timeIntervalSince(event.timestamp) / 60
            if elapsed > Double(timeoutMin) {
                let durationDesc = elapsed < 60
                    ? "\(Int(elapsed))m"
                    : "\(Int(elapsed / 60))h \(Int(elapsed.truncatingRemainder(dividingBy: 60)))m"
                let completionEvent = BabyEvent(
                    id: UUID().uuidString,
                    type: event.type,
                    subtype: event.subtype,
                    timestamp: now,
                    timestampConfidence: .estimated,
                    createdAt: now,
                    detail: "\(event.type.displayName) ended (auto-completed after \(durationDesc))",
                    notable: false,
                    confidence: 0.5,
                    status: .completed
                )
                let response = AnalyzeResponse(newEvents: [completionEvent], corrections: [])
                eventStore.apply(response: response, dateStr: Self.todayStr())
                NSLog("[OnDevice] ⏰ Auto-completed \(event.type.rawValue) after \(durationDesc)")
            }
        }
    }

    /// Deduplicate events from the last 20 minutes.
    /// Groups by type+subtype, then within each group merges events
    /// that are less than 5 min apart — keeps the higher-confidence one.
    private func deduplicateRecentEvents() {
        guard let eventStore else { return }
        let now = Date()
        let windowStart = now.addingTimeInterval(-20 * 60)

        let recent = eventStore.events.filter {
            ($0.createdAt ?? $0.timestamp) >= windowStart
        }
        guard recent.count >= 2 else { return }

        var groups: [String: [BabyEvent]] = [:]
        for event in recent {
            let key = "\(event.type.rawValue)|\(event.subtype ?? "")"
            groups[key, default: []].append(event)
        }

        var idsToDelete: Set<String> = []

        for (_, events) in groups {
            guard events.count >= 2 else { continue }
            let sorted = events.sorted { $0.timestamp < $1.timestamp }

            for i in 0..<(sorted.count - 1) {
                let a = sorted[i]
                let b = sorted[i + 1]
                guard !idsToDelete.contains(a.id), !idsToDelete.contains(b.id) else { continue }

                let gap = abs(b.timestamp.timeIntervalSince(a.timestamp))
                guard gap < 5 * 60 else { continue }

                let confA = a.confidence ?? 0
                let confB = b.confidence ?? 0
                if confA >= confB {
                    idsToDelete.insert(b.id)
                    NSLog("[OnDevice] 🔀 Dedup: dropping \(b.type.rawValue) '\(b.detail.prefix(40))' (dup of '\(a.detail.prefix(40))' \(Int(gap))s apart)")
                } else {
                    idsToDelete.insert(a.id)
                    NSLog("[OnDevice] 🔀 Dedup: dropping \(a.type.rawValue) '\(a.detail.prefix(40))' (dup of '\(b.detail.prefix(40))' \(Int(gap))s apart)")
                }
            }
        }

        if !idsToDelete.isEmpty {
            NSLog("[OnDevice] 🔀 Dedup: removed \(idsToDelete.count) duplicates from last 20 min")
            let dateStr = Self.todayStr()
            for id in idsToDelete {
                eventStore.delete(id: id, dateStr: dateStr)
            }
        }
    }

    // MARK: Review recent events with Foundation Models
    //
    // Sends the last 20 min of events + transcripts to Foundation Models
    // and asks: "did the caregiver correct or contradict any of these?"
    // Only runs if there are both events AND transcripts to compare.

    private func reviewRecentEvents() async {
        guard !isLLMBusy else {
            NSLog("[OnDevice] 🔍 Review skipped — LLM busy with window analysis")
            return
        }
        guard let eventStore, let profile else { return }
        isLLMBusy = true
        defer { isLLMBusy = false }
        let now = Date()
        let windowStart = now.addingTimeInterval(-20 * 60)
        let dateStr = Self.todayStr()

        let recentEvents = eventStore.events.filter {
            ($0.createdAt ?? $0.timestamp) >= windowStart
        }
        guard !recentEvents.isEmpty else { return }

        // Step 1: Deterministic merge — combine duplicate events of same type
        // logged multiple times. Merges details, source quotes, and timestamps.
        let mergeResult = analysisService.mergeEvents(events: recentEvents)
        if !mergeResult.idsToDelete.isEmpty {
            NSLog("[OnDevice] 🔀 Merge: combining \(mergeResult.idsToDelete.count) duplicate events")
            for id in mergeResult.idsToDelete {
                eventStore.delete(id: id, dateStr: dateStr)
            }
            for update in mergeResult.updates {
                if var event = eventStore.events.first(where: { $0.id == update.id }) {
                    event.detail = update.detail
                    event.confidence = update.confidence
                    event.sourceQuote = update.sourceQuote
                    eventStore.update(event, dateStr: dateStr)
                }
            }
        }

        // Step 2: LLM review — only if we have transcript context
        let context = last20MinTranscript()
        guard !context.isEmpty else { return }

        // Derive post-merge list by removing deleted IDs — avoids re-filtering eventStore
        let deletedIds = Set(mergeResult.idsToDelete)
        let postMergeEvents = recentEvents.filter { !deletedIds.contains($0.id) }
        guard !postMergeEvents.isEmpty else { return }

        NSLog("[OnDevice] 🔍 Review: checking \(postMergeEvents.count) events against \(recentTranscripts.count) transcripts")

        let service = analysisService
        let babyName = profile.babyName
        let ageMonths = profile.babyAgeMonths

        do {
            // Run LLM review off the main thread
            let corrections = try await Task.detached {
                try await service.reviewEvents(
                    events: postMergeEvents,
                    transcriptContext: context,
                    babyName: babyName,
                    ageMonths: ageMonths
                )
            }.value

            guard !corrections.isEmpty else {
                NSLog("[OnDevice] 🔍 Review: all events look correct")
                return
            }

            NSLog("[OnDevice] 🔍 Review: \(corrections.count) corrections:")
            for corr in corrections {
                NSLog("[OnDevice]   ✏️ \(corr.eventId.prefix(8)) → \(corr.action.rawValue): \(corr.reason ?? "")")
            }

            let response = AnalyzeResponse(newEvents: [], corrections: corrections)
            eventStore.apply(response: response, dateStr: dateStr)
        } catch {
            NSLog("[OnDevice] ⚠️ Review failed: \(error.localizedDescription)")
        }
    }

    // ── Tier 2: Every 6 hours ───────────────────────────────────
    //
    // Pattern detection across the last 6 hours.
    // Only runs if monitoring has been active for at least 3 hours.

    private func run6HourValidation() {
        guard let eventStore, let profile else { return }
        let activeHours = monitoringActiveHours()
        guard activeHours >= 3 else {
            NSLog("[OnDevice] ⏰ 6hr check skipped — only \(String(format: "%.1f", activeHours))h active (need 3h+)")
            return
        }

        NSLog("[OnDevice] ⏰ Running 6-hour pattern check (active \(String(format: "%.1f", activeHours))h)")
        let now = Date()
        let sixHoursAgo = now.addingTimeInterval(-6 * 3600)
        let recentEvents = eventStore.events.filter { $0.timestamp >= sixHoursAgo }
        let ageMonths = profile.babyAgeMonths
        var alerts: [String] = []

        // 1. Feeding frequency
        let feedingEvents = recentEvents.filter { $0.type == .feeding }
        let expectedFeeds6h = max(1, AgeDefaults.feedsPerDay(ageMonths: ageMonths) / 4)
        if feedingEvents.isEmpty && activeHours >= 4 {
            alerts.append("No feeding recorded in the last \(Int(activeHours)) hours")
        } else if feedingEvents.count > expectedFeeds6h * 2 {
            alerts.append("Unusually frequent feeding: \(feedingEvents.count) feeds in 6h (expected ~\(expectedFeeds6h))")
        }

        // 2. No sleep for too long
        let sleepEvents = recentEvents.filter { $0.type == .sleep }
        if sleepEvents.isEmpty && activeHours >= 4 {
            let maxAwakeHours = ageMonths < 3 ? 2.0 : (ageMonths < 6 ? 2.5 : 3.5)
            if activeHours > maxAwakeHours * 2 {
                alerts.append("No sleep recorded in \(Int(activeHours))h — baby may be overtired")
            }
        }

        // 3. Late-night activity (22:00–05:00)
        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 22 || hour < 5 {
            let latePlay = recentEvents.filter {
                ($0.type == .activity || $0.type.rawValue == "play") &&
                    (Calendar.current.component(.hour, from: $0.timestamp) >= 22 ||
                     Calendar.current.component(.hour, from: $0.timestamp) < 5)
            }
            if !latePlay.isEmpty {
                alerts.append("Late-night activity: \(latePlay.count) play events after 10 PM")
            }
            let lateFeedings = recentEvents.filter {
                $0.type == .feeding &&
                    (Calendar.current.component(.hour, from: $0.timestamp) >= 22 ||
                     Calendar.current.component(.hour, from: $0.timestamp) < 5)
            }
            if lateFeedings.count >= 3 {
                alerts.append("Frequent late-night feeding: \(lateFeedings.count) feeds since 10 PM")
            }
        }

        // 4. Excessive crying
        let cryEvents = recentEvents.filter { $0.type == .cry }
        if cryEvents.count >= 4 {
            alerts.append("Frequent crying: \(cryEvents.count) episodes in 6 hours")
        }

        if alerts.isEmpty {
            NSLog("[OnDevice] ⏰ 6hr check — all patterns normal (\(recentEvents.count) events)")
        } else {
            for alert in alerts {
                NSLog("[OnDevice] ⚠️ 6hr alert: \(alert)")
                let event = BabyEvent(
                    id: UUID().uuidString,
                    type: .observation,
                    timestamp: now,
                    createdAt: now,
                    detail: alert,
                    notable: true,
                    confidence: 0.7,
                    tags: ["pattern_alert"],
                    status: .completed
                )
                eventStore.apply(
                    response: AnalyzeResponse(newEvents: [event], corrections: []),
                    dateStr: Self.todayStr()
                )
            }
        }
    }

    // ── Tier 3: Daily review (once after 8 PM) ──────────────────
    //
    // Full-day pattern assessment. Compares totals against age norms.

    /// Schedule a one-shot timer for 8 PM today (or tomorrow if past 8 PM).
    /// Avoids polling every 5 minutes just to check the clock.
    private func scheduleDailyReview() {
        let cal = Calendar.current
        let now = Date()
        var target = cal.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
        if target <= now {
            // Already past 8 PM today — schedule for tomorrow
            target = cal.date(byAdding: .day, value: 1, to: target) ?? now
        }
        let delay = target.timeIntervalSince(now)
        NSLog("[OnDevice] 📋 Daily review scheduled in \(String(format: "%.0f", delay / 3600))h \(String(format: "%.0f", (delay.truncatingRemainder(dividingBy: 3600)) / 60))m")

        dailyTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.monitoringActiveHours() >= 6 {
                    self.runDailyReview()
                } else {
                    NSLog("[OnDevice] 📋 Daily review skipped — only \(String(format: "%.1f", self.monitoringActiveHours()))h active (need 6h+)")
                }
                // Schedule next day
                self.scheduleDailyReview()
            }
        }
    }

    private func runDailyReview() {
        guard let eventStore, let profile else { return }
        let activeHours = monitoringActiveHours()
        NSLog("[OnDevice] 📋 Running daily review (active \(String(format: "%.1f", activeHours))h)")

        let allEvents = eventStore.events
        let ageMonths = profile.babyAgeMonths
        var insights: [String] = []

        let feedCount = allEvents.filter { $0.type == .feeding }.count
        let sleepCount = allEvents.filter { $0.type == .sleep }.count
        let diaperCount = allEvents.filter { $0.type == .diaper }.count
        let cryCount = allEvents.filter { $0.type == .cry }.count

        let expectedFeeds = AgeDefaults.feedsPerDay(ageMonths: ageMonths)
        let expectedNaps = AgeDefaults.napsPerDay(ageMonths: ageMonths)

        // Scale expectations by how long monitoring was active
        let coverageRatio = min(1.0, activeHours / 14.0)  // assume 14h awake day

        NSLog("[OnDevice] 📊 Daily totals — feeds:\(feedCount) sleep:\(sleepCount) diapers:\(diaperCount) cries:\(cryCount) | coverage:\(Int(coverageRatio * 100))%")

        // Feeding
        let expectedFeedsScaled = Int(Double(expectedFeeds) * coverageRatio)
        if feedCount < expectedFeedsScaled / 2 && expectedFeedsScaled >= 2 {
            insights.append("Low feeding: \(feedCount) feeds today (expected ~\(expectedFeeds) for \(ageMonths)mo). Some may have been missed.")
        } else if feedCount > expectedFeeds * 2 {
            insights.append("High feeding: \(feedCount) feeds (expected ~\(expectedFeeds)). Could be a growth spurt or cluster feeding.")
        }

        // Sleep
        let expectedNapsScaled = Int(Double(expectedNaps) * coverageRatio)
        if sleepCount == 0 && activeHours >= 8 {
            insights.append("No sleep events recorded today. Baby may need more rest.")
        } else if sleepCount > expectedNaps * 3 {
            insights.append("Many sleep events: \(sleepCount) today. Baby may be fighting illness or overtired.")
        }

        // Diapers
        if diaperCount == 0 && activeHours >= 8 {
            insights.append("No diaper events today. Make sure baby is staying hydrated.")
        }

        // Crying
        if cryCount >= 6 {
            insights.append("High crying: \(cryCount) episodes today. Baby may be uncomfortable or going through a phase.")
        }

        // Night owl
        let nightEvents = allEvents.filter {
            let h = Calendar.current.component(.hour, from: $0.timestamp)
            return h >= 23 || h < 4
        }
        if nightEvents.count >= 5 {
            insights.append("Busy night: \(nightEvents.count) events between 11 PM–4 AM.")
        }

        if insights.isEmpty {
            NSLog("[OnDevice] 📋 Daily review — patterns look normal")
        } else {
            for insight in insights {
                NSLog("[OnDevice] 📋 Daily insight: \(insight)")
                let event = BabyEvent(
                    id: UUID().uuidString,
                    type: .observation,
                    timestamp: Date(),
                    createdAt: Date(),
                    detail: insight,
                    notable: true,
                    confidence: 0.7,
                    tags: ["daily_review"],
                    status: .completed
                )
                eventStore.apply(
                    response: AnalyzeResponse(newEvents: [event], corrections: []),
                    dateStr: Self.todayStr()
                )
            }
            // Notification
            let content = UNMutableNotificationContent()
            content.title = "Daily Summary 📋"
            content.body = insights.first ?? "Check today's activity patterns."
            if insights.count > 1 { content.body += " (+\(insights.count - 1) more)" }
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "daily-review-\(Self.todayStr())",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Caregiver mood tracking & notifications

    /// Record a negative mood detection. When the count exceeds the daily
    /// Record every mood reading. Checks if support notification should fire.
    /// Criteria: 6h+ active, 20+ readings, 90%+ negative.
    private func recordMood(_ mood: String) {
        let now = Date()

        // Reset if new day
        if let first = moodReadings.first,
           !Calendar.current.isDate(first.timestamp, inSameDayAs: now) {
            moodReadings.removeAll()
            didSendMoodNotificationToday = false
        }

        moodReadings.append((timestamp: now, mood: mood))

        let total = moodReadings.count
        let negative = moodReadings.filter { $0.mood != "ok" && $0.mood != "happy" }.count
        let ratio = total > 0 ? Double(negative) / Double(total) : 0

        NSLog("[OnDevice] 💛 Mood: \(mood) | today: \(negative)/\(total) negative (\(Int(ratio * 100))%)")

        // All 3 conditions must be met:
        guard !didSendMoodNotificationToday,
              monitoringActiveHours() >= 6,  // 1. at least 6 hours active
              total >= 20,                    // 2. at least 20 readings
              ratio >= 0.9                    // 3. 90%+ are negative
        else { return }

        didSendMoodNotificationToday = true
        NSLog("[OnDevice] 💛 Support notification triggered — \(negative)/\(total) negative over \(String(format: "%.1f", monitoringActiveHours()))h")
        sendSupportNotification()
    }

    /// Send a heartwarming local notification to the caregiver.
    private func sendSupportNotification() {
        let messages = [
            "You're doing an amazing job. It's okay to take a moment for yourself. 💛",
            "Parenting is hard — you're stronger than you think. Take a deep breath. 🌸",
            "Remember: you don't have to be perfect. You just have to be there. 💛",
            "It's been a tough day. You deserve a break — even 5 minutes helps. ☕",
            "Your baby is lucky to have you. Don't forget to take care of yourself too. 🤗",
        ]
        let message = messages.randomElement() ?? messages[0]

        let content = UNMutableNotificationContent()
        content.title = "Hey, you okay? 💛"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = "CAREGIVER_SUPPORT"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(
            identifier: "caregiver-support-\(Self.todayStr())",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[OnDevice] ⚠️ Failed to schedule support notification: \(error)")
            } else {
                NSLog("[OnDevice] 💛 Support notification scheduled")
            }
        }
    }

    // MARK: - Transcript cleanup

    /// Clean up WhisperKit output before feeding to Foundation Models.
    /// Fixes common ASR issues to improve event extraction accuracy.
    // MARK: - Helpers

    private static let _dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func todayStr() -> String { _dateFmt.string(from: Date()) }
}
#endif
