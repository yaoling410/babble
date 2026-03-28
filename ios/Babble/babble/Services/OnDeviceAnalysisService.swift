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
	@Guide(description: "Type of baby event. One of: feeding, sleep, diaper, health_note, milestone, mood, activity, play, cry, new_food, observation. IMPORTANT: only use 'milestone' when the speaker sounds excited or surprised about a FIRST TIME achievement (e.g. 'Oh my god he just walked!' or '他会叫妈妈了！太棒了!'). Normal activities like saying a word or playing are NOT milestones — use 'observation' instead.")
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

	@Guide(description: "Who reported this event if identifiable from context (e.g. 'Mom', 'Dad'). Leave empty if unknown.")
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
	@Guide(description: "The corrected, clean transcript. Fix ASR errors, add punctuation, fix wrong characters, remove hallucinated phrases. If the text is pure nonsense/noise, return empty string.")
	var corrected: String

	@Guide(description: "true if the transcript contains meaningful speech in any language. false if it is random noise, gibberish, or nonsensical fragments that don't form any real words or sentences in any language.")
	var isMeaningful: Bool
}

@available(iOS 26.0, *)
final class OnDeviceAnalysisService: @unchecked Sendable {
	static var isAvailable: Bool {
		SystemLanguageModel.default.isAvailable
	}

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
		// Use a fresh session each time to avoid exceeding the 4096-token context limit.
		let session = LanguageModelSession()

		// Build list of words that sound like the baby's name so the LLM
		// knows to fix them. Uses PhoneticMatcher's consonant-skeleton: any
		// word with the same code as the baby name is a likely mishearing.
		// This generalizes across all names and accents — no hardcoding.
		let nameHint: String
		if !babyName.isEmpty {
			// Use enrollment-discovered name variants + phonetic aliases
			let aliases = BabyProfile.defaultAliases(for: babyName.lowercased())
			if aliases.isEmpty {
				nameHint = "ASR often mishears the baby's name — fix words that sound like \"\(babyName)\"."
			} else {
				let examples = aliases.prefix(5).joined(separator: ", ")
				nameHint = "ASR often mishears \"\(babyName)\" as: \(examples). Fix these to \"\(babyName)\" when about the baby."
			}
		} else {
			nameHint = ""
		}

		let prompt = """
		Fix this voice transcript for baby \(babyName). English+Chinese mix is normal. \
		Set isMeaningful=false if noise/gibberish. Only fix errors, keep meaning. \
		\(nameHint)

		Context: \(recentContext.prefix(200))

		Fix: \(raw.prefix(500))
		"""

		let response = try await session.respond(to: prompt, generating: CorrectedTranscript.self)
		let result = response.content

		// If the LLM says the text is meaningless noise, return empty
		if !result.isMeaningful {
			NSLog("[OnDevice] 🚫 Transcript is noise/gibberish — discarding: '\(raw.prefix(60))'")
			return ""
		}

		let corrected = result.corrected
		if !corrected.isEmpty && corrected != raw {
			NSLog("[OnDevice] ✏️ Transcript corrected: '\(raw.prefix(60))' → '\(corrected.prefix(60))'")
			return corrected
		}

		return raw
	}

	// MARK: - Step 2: Extract events

	func analyze(
		transcript: String,
		babyName: String,
		ageMonths: Int,
		triggerHint: String,
		clipTimestamp: Date
	) async throws -> AnalyzeResponse {
		let session = LanguageModelSession()

		let ageSuffix: String
		if ageMonths < 1 { ageSuffix = "newborn" }
		else if ageMonths == 1 { ageSuffix = "1 month old" }
		else { ageSuffix = "\(ageMonths) months old" }

		let allowedTypesStr = EventTypeRegistry.allowedTypesString(ageMonths: ageMonths)
		let vocabStr = EventTypeRegistry.chineseVocabForPrompt(ageMonths: ageMonths).prefix(8).joined(separator: "; ")

		let prompt = """
		Extract baby events from transcript. Baby: \(babyName), \(ageSuffix). \
		Allowed types: \(allowedTypesStr). \
		Set relevant=false if not about baby. Only extract explicitly stated events. \
		Do NOT extract "cry" — use mood instead. Default mood="ok", needsSupport=false.

		Learning rules: teaching words = activity (subtype: learning). \
		Baby saying a word = observation. First time + excitement = milestone.

		Vocab: \(vocabStr)

		Transcript: \(transcript.prefix(500))
		"""

		NSLog("[OnDevice] 🧠 Sending to Foundation Models: prompt ~\(prompt.count) chars, transcript ~\(transcript.count) chars")

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

		// 1. Confidence gate: single event needs >= 0.7, multiple events need >= 0.85 each.
		//    This prevents the 3B model from sneaking in low-confidence hallucinations
		//    alongside a real event.
		let confidenceThreshold: Float = events.count == 1 ? 0.7 : 0.85
		validated = validated.filter { event in
			let conf = event.confidence ?? 0
			if conf < confidenceThreshold {
				NSLog("[OnDevice] 🚫 Confidence filter: rejected \(event.type.rawValue) '\(event.detail.prefix(40))' — \(String(format: "%.2f", conf)) < \(String(format: "%.2f", confidenceThreshold)) (threshold for \(events.count) events)")
				return false
			}
			return true
		}

		// 2. Age filter: if the model returns a type not in the allowed list,
		//    convert it to a notable milestone (could be a developmental surprise)
		let allowedTypes = EventTypeRegistry.allowedTypes(ageMonths: ageMonths)
		validated = validated.map { event in
			if allowedTypes.contains(event.type.rawValue) {
				return event
			}
			NSLog("[OnDevice] ⭐ Age reclassify: \(event.type.rawValue) → milestone (unexpected for \(ageMonths)mo, confidence=\(String(format: "%.2f", event.confidence ?? 0)))")
			var milestone = event
			milestone.type = .milestone
			milestone.notable = true
			milestone.detail = "\(event.type.displayName): \(event.detail)"
			return milestone
		}

		// 3. Milestone gate: demote milestones to observations unless the transcript
		//    shows genuine excitement (exclamation marks, celebratory words).
		//    Normal activities like saying a word are observations, not milestones.
		validated = Self.milestoneGate(events: validated, transcript: transcript)

		// 4. Keyword validation: certain event types require specific words in the transcript
		validated = Self.keywordValidate(events: validated, transcript: transcript)

		// 5. Intent filter: reject events if the transcript is a question, negation,
		//    or hypothetical — not a factual report of something that happened
		validated = Self.intentValidate(events: validated, transcript: transcript)

		// 6. Dedup: collapse identical events (same type+subtype+detail)
		var seen: Set<String> = []
		validated = validated.filter { event in
			let key = "\(event.type.rawValue)|\(event.subtype ?? "")|\(event.detail)"
			return seen.insert(key).inserted
		}

		// 7. Temporal logic: no two events of the same type within 1 min
		//    unless one is in_progress and the other is completed (start→end pair)
		validated = Self.temporalValidate(events: validated)

		return AnalyzeResponse(newEvents: validated, corrections: [])
	}

	// MARK: - Milestone gate
	//
	// Milestones should only be created when the caregiver sounds genuinely
	// excited or surprised — indicating a first-time achievement. Normal
	// activities (baby says a word, plays with a toy) are observations.
	// Without excitement markers, demote milestone → observation.

	private static let excitementMarkers: [String] = [
		// Chinese
		"太棒了", "太厉害了", "好棒", "厉害", "第一次", "终于",
		"天哪", "我的天", "不敢相信", "哇", "耶",
		// English
		"first time", "for the first time", "finally",
		"oh my god", "omg", "amazing", "wow", "yay",
		"can you believe", "i can't believe",
		// Punctuation — exclamation marks signal excitement
		"！", "!",
	]

	private static func milestoneGate(events: [BabyEvent], transcript: String) -> [BabyEvent] {
		let lower = transcript.lowercased()
		let hasExcitement = excitementMarkers.contains { lower.contains($0) }

		if hasExcitement { return events } // excitement detected, allow milestones

		return events.map { event in
			guard event.type == .milestone else { return event }
			NSLog("[OnDevice] 🚫 Milestone demoted → observation (no excitement in transcript): '\(event.detail.prefix(40))'")
			var demoted = event
			demoted.type = .observation
			demoted.notable = false
			return demoted
		}
	}

	// MARK: - Keyword validation
	//
	// Uses EventTypeRegistry.validationKeywords() as single source of truth.
	// Types without validation keywords pass freely.

	private static func keywordValidate(events: [BabyEvent], transcript: String) -> [BabyEvent] {
		let lower = transcript.lowercased()
		return events.filter { event in
			guard let keywords = EventTypeRegistry.validationKeywords(for: event.type.rawValue) else {
				return true
			}
			let found = keywords.contains { lower.contains($0) }
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

	// MARK: - Merge duplicate events (deterministic, no LLM)
	//
	// Groups events by type+subtype within a time window. If the same event
	// type appears multiple times, merge them into one:
	//   - Keep the earliest timestamp as start time
	//   - Keep the latest timestamp as end time (stored in detail)
	//   - Keep the highest confidence
	//   - Combine details
	//   - Delete the duplicates
	//
	// Returns: (survivorUpdates, idsToDelete)
	//   survivorUpdates: events to update (merged detail + timestamps)
	//   idsToDelete: event IDs to remove

	struct MergeResult {
		var updates: [(id: String, detail: String, confidence: Float, sourceQuote: String?)]
		var idsToDelete: [String]
	}

	func mergeEvents(
		events: [BabyEvent],
		windowMinutes: Double = 20
	) -> MergeResult {
		var updates: [(id: String, detail: String, confidence: Float, sourceQuote: String?)] = []
		var idsToDelete: [String] = []

		// Group by type + subtype
		var groups: [String: [BabyEvent]] = [:]
		for event in events {
			let key = "\(event.type.rawValue)|\(event.subtype ?? "")"
			groups[key, default: []].append(event)
		}

		for (key, group) in groups {
			guard group.count >= 2 else { continue }
			let sorted = group.sorted { $0.timestamp < $1.timestamp }

			// Find clusters: events within 5 min of each other
			var clusters: [[BabyEvent]] = []
			var currentCluster: [BabyEvent] = [sorted[0]]

			for i in 1..<sorted.count {
				let gap = sorted[i].timestamp.timeIntervalSince(sorted[i-1].timestamp)
				if gap < 5 * 60 {
					currentCluster.append(sorted[i])
				} else {
					clusters.append(currentCluster)
					currentCluster = [sorted[i]]
				}
			}
			clusters.append(currentCluster)

			// Merge each cluster with 2+ events
			for cluster in clusters where cluster.count >= 2 {
				let survivor = cluster[0]
				let duplicates = Array(cluster.dropFirst())

				let startTime = survivor.timestamp
				let endTime = cluster.last!.timestamp
				let duration = endTime.timeIntervalSince(startTime)

				let durationStr: String
				if duration < 60 {
					durationStr = "\(Int(duration))s"
				} else {
					durationStr = "\(Int(duration / 60))m"
				}

				// Merge details — collect unique details from all events in cluster
				let allDetails = cluster.map { $0.detail }
				let uniqueDetails = allDetails.reduce(into: [String]()) { result, detail in
					if !result.contains(where: { $0.lowercased() == detail.lowercased() }) {
						result.append(detail)
					}
				}
				let combinedDetail: String
				if uniqueDetails.count == 1 {
					// All same detail — add duration if meaningful
					combinedDetail = duration > 30
						? "\(uniqueDetails[0]) (\(durationStr))"
						: uniqueDetails[0]
				} else {
					// Different details — join them
					combinedDetail = uniqueDetails.joined(separator: "; ")
						+ (duration > 30 ? " (\(durationStr))" : "")
				}

				// Merge source quotes — combine all transcripts
				let allQuotes = cluster.compactMap { $0.sourceQuote }.filter { !$0.isEmpty }
				let uniqueQuotes = allQuotes.reduce(into: [String]()) { result, quote in
					if !result.contains(quote) { result.append(quote) }
				}
				let mergedQuote: String? = uniqueQuotes.isEmpty ? nil : uniqueQuotes.joined(separator: " | ")

				let maxConfidence = cluster.map { $0.confidence ?? 0 }.max() ?? 0

				updates.append((id: survivor.id, detail: combinedDetail, confidence: maxConfidence, sourceQuote: mergedQuote))
				idsToDelete.append(contentsOf: duplicates.map { $0.id })

				NSLog("[OnDevice] 🔀 Merge: \(key) — \(cluster.count) events → 1 (span \(durationStr), details: \(uniqueDetails.count) unique)")
			}
		}

		return MergeResult(updates: updates, idsToDelete: idsToDelete)
	}

	// MARK: - LLM review (corrections/deletions based on transcript context)

	func reviewEvents(
		events: [BabyEvent],
		transcriptContext: String,
		babyName: String,
		ageMonths: Int
	) async throws -> [EventCorrection] {
		guard !events.isEmpty, !transcriptContext.isEmpty else { return [] }

		let session = LanguageModelSession()

		// Keep only the most recent 5 events to stay within the 4096-token context limit.
		let recentEvents = events.suffix(5)
		let eventSummary = recentEvents.map { event in
			"[\(event.id.prefix(8))] \(event.type.rawValue) \(event.timestamp.formatted(date: .omitted, time: .shortened)): \(event.detail.prefix(60))"
		}.joined(separator: "\n")

		let prompt = """
		Review these baby events for \(babyName). Correct or delete only if \
		the transcript shows a factual correction. Return empty corrections if OK.

		Events: \(eventSummary)

		Transcript: \(transcriptContext.prefix(800))
		"""

		let response = try await session.respond(
			to: prompt,
			generating: EventReviewResult.self
		)

		let result = response.content
		guard !result.corrections.isEmpty else { return [] }

		return result.corrections.compactMap { correction -> EventCorrection? in
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
