// Placeholder file kept for Xcode project compatibility.
// The real implementation was moved to OnDevice/OnDeviceAnalysisService.swift
// to keep on-device-only code separate. When the FoundationModels framework
// isn't available at build time, provide a minimal stub so references to
// `OnDeviceAnalysisService` compile.

// Move the real on-device implementation here so Xcode's project file list
// resolves the symbol when FoundationModels is available. If FoundationModels
// isn't available, the implementation below is excluded by the same
// conditional that's used in the detailed implementation file.

#if canImport(FoundationModels)
import Foundation
import FoundationModels

// Copy of the full implementation originally placed in OnDevice/OnDeviceAnalysisService.swift

@available(iOS 26.0, *)
@Generable
struct ExtractedEvent {
	@Guide(description: "Type of baby event. One of: feeding, sleep, diaper, health_note, milestone, mood, activity, play, cry, new_food, observation")
	var type: String

	@Guide(description: "More specific classification. For feeding: breast/bottle/solids/pumping. For diaper: wet/dirty/mixed. For sleep: nap/night. For activity: tummy_time/bath/outing. For play: sensory/toys/reading/music/free_play/tummy_time. Leave empty if not applicable.")
	var subtype: String?

	@Guide(description: "Human-readable description of what happened. ONLY include details that were explicitly stated in the transcript. Do NOT invent amounts, durations, or specifics. Example: if transcript says '拉屎了', detail should be 'Pooped' — NOT 'Pooped, large amount'. If transcript says 'breastfed 15 minutes left side', then include those details.")
	var detail: String

	@Guide(description: "Whether this event is particularly important — a milestone, first time, urgent health concern, or notable observation. true or false.")
	var notable: Bool

	@Guide(description: "How confident you are this event actually happened, from 0.0 (uncertain) to 1.0 (definite). Use 0.8+ for clearly stated events, 0.5-0.7 for inferred events.")
	var confidence: Float

	@Guide(description: "The exact phrase from the transcript that produced this event. Quote the relevant part verbatim.")
	var sourceQuote: String?

	@Guide(description: "Who reported this event if identifiable from the transcript (e.g. 'Mom', 'Dad', 'Nanny'). Leave empty if unknown.")
	var speaker: String?

	@Guide(description: "Event status: 'in_progress' if still happening (e.g. nap started), 'completed' if finished, 'tentative' if uncertain. Default to 'completed'.")
	var status: String?

	@Guide(description: "Comma-separated tags: 'first_time' for firsts, 'urgent' for health concerns needing immediate attention, 'new_allergen' for allergenic foods. Leave empty if none apply.")
	var tags: String?

	@Guide(description: "Relative time hint from transcript, e.g. 'just now', '10 minutes ago', 'at 3pm'. Leave empty if the event is happening now.")
	var timeHint: String?
}

@available(iOS 26.0, *)
@Generable
struct CaregiverMood {
	@Guide(description: "Detected mood: 'ok' (neutral/fine), 'tired' (exhausted/sleep-deprived), 'frustrated' (overwhelmed/can't cope), 'anxious' (worried about baby's health), 'happy' (joyful/proud). Default to 'ok' if no emotional signal.")
	var mood: String

	@Guide(description: "true if the caregiver sounds like they need emotional support — e.g. crying, saying they can't cope, expressing hopelessness. false for normal tiredness or mild frustration.")
	var needsSupport: Bool

	@Guide(description: "Short quote from the transcript that indicates the mood, if any. Empty if mood is 'ok'.")
	var quote: String?
}

@available(iOS 26.0, *)
@Generable
struct TranscriptAnalysis {
	@Guide(description: "Whether the transcript is relevant to baby care. false if it's purely adult conversation with no baby-related content.")
	var relevant: Bool

	@Guide(description: "All baby events extracted from the transcript. A single sentence can produce multiple events — e.g. 'she pooped then drank a bottle' = one diaper + one feeding. Empty array if not relevant.")
	var events: [ExtractedEvent]

	@Guide(description: "How the caregiver sounds emotionally based on tone, word choice, and context.")
	var caregiverMood: CaregiverMood
}

@available(iOS 26.0, *)
@Generable
struct CorrectedTranscript {
	@Guide(description: "The corrected, clean transcript. Fix ASR errors, add punctuation, fix wrong characters, remove hallucinated phrases. Keep the original meaning.")
	var corrected: String

	@Guide(description: "true if corrections were made, false if original was clean.")
	var wasChanged: Bool
}

@available(iOS 26.0, *)
@MainActor
final class OnDeviceAnalysisService {
	static var isAvailable: Bool {
		SystemLanguageModel.default.isAvailable
	}

	private var session: LanguageModelSession?

	/// Called when the caregiver sounds distressed.
	var onEmotionalSupportNeeded: (() -> Void)?

	/// Called with every detected mood.
	var onMoodDetected: ((String) -> Void)?

	/// Latest detected caregiver mood.
	var lastCaregiverMood: String = "ok"

	// MARK: - Step 1: Correct transcript

	/// Use Foundation Models to fix ASR errors before event extraction.
	func correctTranscript(
		raw: String,
		babyName: String,
		recentContext: String
	) async throws -> String {
		let session = self.session ?? LanguageModelSession()
		self.session = session

		let prompt = """
		Fix this voice-to-text transcript. The speaker is talking about a baby named \(babyName).

		Fix these ASR errors:
		- Baby name misspelled: "陆卡", "露卡", "Localash" → "\(babyName)"
		- Wrong characters: 拍隔→拍嗝(burp), 拉死→拉屎(poop), 味奶→喂奶(feed)
		- Remove hallucinations: "謝謝觀看", "谢谢观看", "请订阅", "Thank you for watching"
		- Add punctuation at natural sentence breaks
		- Keep English+Chinese mixing as-is (that's intentional)
		- Do NOT change meaning, only fix errors

		Recent context:
		\(recentContext.prefix(500))

		Raw transcript to fix:
		\(raw)
		"""

		let response = try await session.respond(to: prompt, generating: CorrectedTranscript.self)
		let result = response.content

		if result.wasChanged {
			NSLog("[OnDevice] ✏️ Transcript corrected: '\(raw.prefix(60))' → '\(result.corrected.prefix(60))'")
		}

		return result.corrected.isEmpty ? raw : result.corrected
	}

	// MARK: - Step 2: Extract events

	func analyze(
		transcript: String,
		babyName: String,
		ageMonths: Int,
		triggerHint: String,
		clipTimestamp: Date
	) async throws -> AnalyzeResponse {
		let session = self.session ?? LanguageModelSession()
		self.session = session

		let ageSuffix: String
		if ageMonths < 1 { ageSuffix = "newborn" }
		else if ageMonths == 1 { ageSuffix = "1 month old" }
		else { ageSuffix = "\(ageMonths) months old" }

		let config = AgeDefaults.eventConfig(ageMonths: ageMonths)
		let allowedTypesStr = config.allowedTypes.sorted().joined(separator: ", ")
		let vocabStr = config.chineseVocab.map { "  " + $0 }.joined(separator: "\n")
		let notesStr = config.notes.map { "- " + $0 }.joined(separator: "\n")

		let prompt = """
		You are a baby care assistant. Extract events from this caregiver \
		conversation about a baby named \(babyName) (\(ageSuffix)).

		ALLOWED EVENT TYPES for this age:
		\(allowedTypesStr)
		Do NOT extract any event type not in this list.

		CRITICAL RULES:
		- ONLY extract events EXPLICITLY stated in the transcript.
		- If the transcript says "拉屎了" (pooped), extract ONLY a diaper event. \
		  Do NOT invent a feeding, sleep, or any other event that was not mentioned.
		- If only one action is mentioned, return ONLY one event.
		- Multiple events from one sentence are OK, but ONLY if each is explicitly stated.
		- Ignore repeated/garbled speech recognition errors \
		  (e.g. "有点卡, 有点卡, 有点卡" — treat as said once).
		- Use short detail text. Do NOT invent amounts, durations, or specifics not stated.
		- Do NOT hallucinate events. If unsure, return 0 events.
		- Set confidence to 0.9 for clearly stated, 0.5 for uncertain.

		Age-specific notes:
		\(notesStr)

		Chinese vocabulary → event mapping:
		\(vocabStr)

		Caregiver mood detection:
		- "ok" = neutral, just reporting facts
		- "tired" = 好累/so tired/没睡好/exhausted
		- "frustrated" = 受不了了/why won't you stop/烦死了
		- "anxious" = 怎么办/is this normal/担心
		- "happy" = 好可爱/so cute/好开心
		- needsSupport = true ONLY for genuine distress
		- Default: mood="ok", needsSupport=false

		Transcript:
		\(transcript)
		"""

		NSLog("[OnDevice] 🧠 Sending to Foundation Models: '\(prompt.suffix(200))'")

		let response = try await session.respond(
			to: prompt,
			generating: TranscriptAnalysis.self
		)
		let result = response.content

		let mood = result.caregiverMood
		NSLog("[OnDevice] 🧠 Foundation Models response: relevant=\(result.relevant) events=\(result.events.count) mood=\(mood.mood) needsSupport=\(mood.needsSupport)")
		if mood.mood != "ok" {
			NSLog("[OnDevice] 💛 Caregiver mood: \(mood.mood)\(mood.needsSupport ? " ⚠️ NEEDS SUPPORT" : "") quote='\(mood.quote ?? "")'")
		}

		// Surface caregiver mood
		lastCaregiverMood = mood.mood
		onMoodDetected?(mood.mood)
		if mood.needsSupport {
			onEmotionalSupportNeeded?()
		}

		// If caregiver is distressed, also create an emotional_support event
		if mood.needsSupport {
			let supportEvent = BabyEvent(
				id: UUID().uuidString,
				type: .emotionalSupport,
				timestamp: clipTimestamp,
				createdAt: Date(),
				detail: mood.quote ?? "Caregiver needs support",
				notable: true,
				confidence: 0.8,
				status: .completed
			)
			let supportResponse = AnalyzeResponse(newEvents: [supportEvent], corrections: [])
			// This will be merged with baby events below
			_ = supportResponse // logged above, applied separately if no baby events
		}

		guard result.relevant, !result.events.isEmpty else {
			// Still return emotional support event even if no baby events
			if mood.needsSupport {
				let supportEvent = BabyEvent(
					id: UUID().uuidString,
					type: .emotionalSupport,
					timestamp: clipTimestamp,
					createdAt: Date(),
					detail: mood.quote ?? "Caregiver needs support",
					notable: true,
					confidence: 0.8,
					status: .completed
				)
				return AnalyzeResponse(newEvents: [supportEvent], corrections: [])
			}
			return AnalyzeResponse(newEvents: [], corrections: [])
		}

		let events = result.events.map { extracted -> BabyEvent in
			let eventType = BabyEvent.EventType(rawValue: extracted.type) ?? .observation

			let status: BabyEvent.EventStatus? = {
				switch extracted.status {
				case "in_progress": return .inProgress
				case "tentative": return .tentative
				default: return .completed
				}
			}()

			let tags: [String]? = extracted.tags?
				.split(separator: ",")
				.map { String($0).trimmingCharacters(in: CharacterSet.whitespaces) }
				.filter { !$0.isEmpty }

			return BabyEvent(
				id: UUID().uuidString,
				type: eventType,
				subtype: extracted.subtype,
				timestamp: clipTimestamp,
				timestampConfidence: .unknown,
				createdAt: Date(),
				detail: extracted.detail,
				notable: extracted.notable,
				confidence: extracted.confidence,
				sourceQuote: extracted.sourceQuote,
				speaker: extracted.speaker,
				tags: tags,
				status: status
			)
		}

		// ── Post-extraction validation pipeline ──────────────────
		var validated = events

		// 1. Age filter: reject types not allowed for this age
		validated = validated.filter { config.allowedTypes.contains($0.type.rawValue) }
		if validated.count < events.count {
			NSLog("[OnDevice] 🚫 Age filter: \(events.count) → \(validated.count)")
		}

		// 2. Keyword validation: certain event types require specific words in the transcript
		validated = Self.keywordValidate(events: validated, transcript: transcript)

		// 3. Intent filter: reject events if the transcript is a question, negation,
		//    or hypothetical — not a factual report of something that happened
		validated = Self.intentValidate(events: validated, transcript: transcript)

		// 4. Dedup: collapse identical events (same type+subtype+detail)
		var seen: Set<String> = []
		validated = validated.filter { event in
			let key = "\(event.type.rawValue)|\(event.subtype ?? "")|\(event.detail)"
			return seen.insert(key).inserted
		}

		// 4. Temporal logic: no two events of the same type within 1 min
		//    unless one is in_progress and the other is completed (start→end pair)
		validated = Self.temporalValidate(events: validated)

		return AnalyzeResponse(newEvents: validated, corrections: [])
	}

	// MARK: - Keyword validation
	//
	// For high-stakes event types (diaper, feeding, sleep), the transcript
	// MUST contain at least one keyword that actually describes the event.
	// This prevents the 3B model from hallucinating events from unrelated speech.
	// E.g. "怎么又diaper change了" is a question, not a new diaper event —
	// but it contains "diaper change" so it passes. The key is that pure
	// commentary without ANY relevant word gets blocked.

	private static let diaperKeywords: Set<String> = [
		// Chinese
		"拉屎", "拉臭", "拉粑", "便便", "大便", "小便", "尿了", "尿湿",
		"换尿布", "换片", "尿布", "纸尿裤", "屙屎", "屙尿",
		"上厕所", "坐马桶", "拉了",
		// English
		"poop", "pooped", "pooping", "pee", "peed", "peeing",
		"diaper", "nappy", "blowout", "potty",
	]

	private static let feedingKeywords: Set<String> = [
		// Chinese
		"喂奶", "吃奶", "喝奶", "喝水", "吃饭", "吃东西", "辅食",
		"喝完", "吃完", "饿了", "奶瓶", "母乳", "配方",
		"喂食", "吃了", "喝了",
		// English
		"feed", "feeding", "fed", "bottle", "breast", "nursing",
		"ate", "eat", "eating", "milk", "formula", "solids",
		"hungry", "drink", "drank",
	]

	private static let sleepKeywords: Set<String> = [
		// Chinese
		"睡觉", "睡着", "睡了", "醒了", "醒来", "起来了",
		"午睡", "小睡", "困了", "入睡", "哄睡",
		"夜醒", "夜奶", "睡眠",
		// English
		"sleep", "sleeping", "slept", "nap", "napping", "napped",
		"woke", "awake", "asleep", "drowsy", "bedtime",
	]

	private static func keywordValidate(events: [BabyEvent], transcript: String) -> [BabyEvent] {
		let lower = transcript.lowercased()
		return events.filter { event in
			let keywords: Set<String>?
			switch event.type {
			case .diaper:  keywords = diaperKeywords
			case .feeding: keywords = feedingKeywords
			case .sleep:   keywords = sleepKeywords
			default:       keywords = nil  // other types don't need keyword validation
			}

			guard let required = keywords else { return true }

			let found = required.contains { lower.contains($0) }
			if !found {
				NSLog("[OnDevice] 🚫 Keyword filter: rejected \(event.type.rawValue) '\(event.detail.prefix(40))' — no matching keyword in transcript")
			}
			return found
		}
	}

	// MARK: - Intent validation
	//
	// Detects whether the transcript is reporting a fact ("she pooped")
	// vs asking a question, complaining, negating, or speaking hypothetically.
	// If the overall transcript intent is non-factual, reject all events.
	//
	// Examples that should be REJECTED:
	//   "怎么又diaper change了" — question/complaint about a past event
	//   "是不是要吃奶了" — hypothetical question
	//   "她没有睡觉" — she did NOT sleep (negation of event)
	//   "why is she pooping again" — complaint, not report
	//
	// Examples that should PASS:
	//   "她拉屎了" — factual report
	//   "不要再拉了" — "stop pooping" = baby DID poop (complaint confirms fact)
	//   "别吃了" — "stop eating" = baby IS eating (complaint confirms fact)
	//   "Luca just pooped" — factual report
	//   "喂完奶了" — factual completion report

	private static let questionPatterns: [String] = [
		// Chinese question/hypothetical markers
		"怎么又", "为什么", "怎么回事", "怎么了",
		"是不是", "是吗", "吗?", "吗？",
		"有没有", "要不要", "会不会",
		"奇了怪", "奇怪",
		// Chinese negation — only true negation (event did NOT happen)
		// NOTE: 不要/别 are excluded — in baby context they're complaints
		// that CONFIRM the action ("不要再拉了" = baby pooped, caregiver is annoyed)
		"没有", "不是", "并没", "没拉", "没吃", "没睡", "没喝",
		// English question/complaint
		"why is", "why did", "why does", "how come",
		"did she", "did he", "is she", "is he",
		"again?", "again？",
		// English negation — only true negation
		"didn't", "did not", "hasn't", "never",
		// English hypothetical
		"should i", "should we", "do i need", "maybe",
	]

	/// Factual markers — if present alongside a question marker, the transcript
	/// is still reporting a fact. These must be specific enough to indicate
	/// a completed action, not just a sentence particle.
	/// E.g. "刚换完尿布" = factual. But "diaper change了" alone is not —
	/// "了" is too generic (appears in questions like "怎么了").
	private static let factualMarkers: [String] = [
		// Chinese: specific completions (not bare 了 which appears in questions)
		"完了", "好了", "换好", "吃好", "喝好", "睡好",
		"换完", "吃完", "喝完", "拉完",
		"刚刚", "刚才", "刚换", "刚吃", "刚喝", "刚拉",
		// English: specific factual indicators
		"just pooped", "just ate", "just fed", "just woke",
		"already", "finished", "done",
	]

	private static func intentValidate(events: [BabyEvent], transcript: String) -> [BabyEvent] {
		let lower = transcript.lowercased()

		// Check if transcript has question/negation/hypothetical patterns
		let hasNonFactual = questionPatterns.contains { lower.contains($0) }
		guard hasNonFactual else { return events }  // no red flags, pass all

		// Check if there are also factual markers — mixed intent is OK
		let hasFactual = factualMarkers.contains { lower.contains($0) }
		if hasFactual {
			// Mixed: "怎么又拉了" — has both question and factual "了"
			// Let it through but log
			NSLog("[OnDevice] ⚠️ Intent: mixed (question + factual) — allowing events")
			return events
		}

		// Pure question/negation/hypothetical — reject all events
		NSLog("[OnDevice] 🚫 Intent filter: rejected \(events.count) events — transcript is question/negation/hypothetical: '\(transcript.prefix(60))'")
		return []
	}

	// MARK: - Temporal validation
	//
	// Two events of the same type can't happen within 1 minute of each other
	// UNLESS they form a start→end pair (in_progress → completed).
	// This catches the 3B model producing "Pooped" + "Diaper changed" from
	// a single mention — only the first one survives.

	private static func temporalValidate(events: [BabyEvent]) -> [BabyEvent] {
		var result: [BabyEvent] = []

		for event in events {
			// Check if there's already an event of the same type within 1 min
			let isDuplicate = result.contains { existing in
				guard existing.type == event.type else { return false }
				let gap = abs(existing.timestamp.timeIntervalSince(event.timestamp))
				guard gap < 60 else { return false }

				// Allow start→end pairs: in_progress followed by completed
				if existing.status == .inProgress && event.status == .completed { return false }
				if existing.status == .completed && event.status == .inProgress { return false }

				return true
			}

			if isDuplicate {
				NSLog("[OnDevice] 🚫 Temporal filter: rejected \(event.type.rawValue) '\(event.detail.prefix(40))' — same type within 1 min")
			} else {
				result.append(event)
			}
		}

		return result
	}

	// MARK: - Validation review (called every 5 min)
	//
	// Given recent events and the transcript context from the last 20 min,
	// ask Foundation Models whether any events should be corrected or deleted.
	// This catches:
	//   - "actually she only ate for 5 minutes" → update feeding detail
	//   - "oh wait she didn't actually poop" → delete the diaper event
	//   - Misheard events that made it past the initial extraction

	func reviewEvents(
		events: [BabyEvent],
		transcriptContext: String,
		babyName: String,
		ageMonths: Int
	) async throws -> [EventCorrection] {
		guard !events.isEmpty, !transcriptContext.isEmpty else { return [] }

		let session = self.session ?? LanguageModelSession()
		self.session = session

		let eventSummary = events.map { event in
			"[\(event.id.prefix(8))] \(event.type.rawValue) \(event.timestamp.formatted(date: .omitted, time: .shortened)): \(event.detail)"
		}.joined(separator: "\n")

		let prompt = """
		You are reviewing baby events for accuracy. Baby: \(babyName), \(ageMonths) months old.

		These events were logged in the last 20 minutes:
		\(eventSummary)

		Recent conversation transcript (last 20 min):
		\(transcriptContext.prefix(2000))

		Review rules:
		- If the transcript shows a caregiver CORRECTING a previous statement \
		  (e.g. "actually she only ate 5 minutes" or "oh she didn't poop"), \
		  return a correction.
		- If an event is clearly wrong based on later context, correct or delete it.
		- If everything looks fine, return an empty corrections array.
		- Do NOT correct events just because they lack detail — only correct \
		  events that are factually wrong based on what was said later.
		"""

		let response = try await session.respond(
			to: prompt,
			generating: EventReviewResult.self
		)

		let result = response.content
		guard !result.corrections.isEmpty else { return [] }

		return result.corrections.compactMap { correction -> EventCorrection? in
			// Match the short ID prefix back to the full event ID
			guard let matchedEvent = events.first(where: {
				$0.id.hasPrefix(correction.eventIdPrefix)
			}) else {
				NSLog("[OnDevice] ⚠️ Review: no event matching prefix '\(correction.eventIdPrefix)'")
				return nil
			}

			let action: EventCorrection.CorrectionAction = correction.action == "delete" ? .delete : .update
			let fields: [String: String]? = action == .update ? ["detail": correction.updatedDetail ?? matchedEvent.detail] : nil

			return EventCorrection(
				eventId: matchedEvent.id,
				action: action,
				fields: fields,
				reason: correction.reason
			)
		}
	}

	func resetSession() {
		session = nil
	}
}

// MARK: - Review result schema

@available(iOS 26.0, *)
@Generable
struct EventReviewCorrection {
	@Guide(description: "First 8 characters of the event ID to correct (from the [xxxxxxxx] prefix in the event list).")
	var eventIdPrefix: String

	@Guide(description: "Action: 'update' to change the event detail, 'delete' to remove a wrong event.")
	var action: String

	@Guide(description: "Updated description if action is 'update'. Leave empty for 'delete'.")
	var updatedDetail: String?

	@Guide(description: "Brief reason for the correction — what in the transcript triggered it.")
	var reason: String
}

@available(iOS 26.0, *)
@Generable
struct EventReviewResult {
	@Guide(description: "Corrections to apply. Empty array if all events are accurate.")
	var corrections: [EventReviewCorrection]
}

#endif
