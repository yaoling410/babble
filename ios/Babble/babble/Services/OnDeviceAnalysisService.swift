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

	@Guide(description: "Human-readable description of what happened. Be specific: include amounts, durations, sides, foods, etc. Example: 'Breastfed 15 min left side, good latch'")
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
struct TranscriptAnalysis {
	@Guide(description: "Whether the transcript is relevant to baby care. false if it's purely adult conversation with no baby-related content.")
	var relevant: Bool

	@Guide(description: "All baby events extracted from the transcript. A single sentence can produce multiple events — e.g. 'she pooped then drank a bottle' = one diaper + one feeding. Empty array if not relevant.")
	var events: [ExtractedEvent]
}

@available(iOS 26.0, *)
@MainActor
final class OnDeviceAnalysisService {
	static var isAvailable: Bool {
		SystemLanguageModel.default.isAvailable
	}

	private var session: LanguageModelSession?

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

		let prompt = """
		You are a baby care assistant. Extract ALL events from this caregiver \
		conversation about a baby named \(babyName) (\(ageSuffix)).

		Rules:
		- A single sentence can contain MULTIPLE events. Extract every one. \
		  Example: "她拉完屎然后喝了奶" → 1 diaper event + 1 feeding event. \
		  Example: "he woke up, had a bottle, then played on the mat" → 1 sleep + 1 feeding + 1 play.
		- Use short, clear detail text (e.g. "Pooped", "Diaper changed", "Drank 4oz bottle").
		- Chinese baby-care terms:
		  拉屎/拉臭臭/拉粑粑 = pooped (diaper, subtype: dirty)
		  换尿布/尿布换了 = diaper changed (diaper, subtype: dirty, status: completed)
		  喂奶/吃奶 = feeding started (feeding, status: in_progress)
		  喝完了/吃完了 = feeding done (feeding, status: completed)
		  睡觉/睡着了 = fell asleep (sleep, status: in_progress)
		  醒了 = woke up (sleep, status: completed)
		  哭了 = crying (cry, status: completed)
		  吐奶 = spit up (health_note, status: completed)
		  打嗝 = burped (activity, status: completed)
		  洗澡 = bath (activity, status: completed)
		  玩/玩耍 = playing (play, status: completed)
		  趴着/趴趴 = tummy time (play, subtype: tummy_time)
		  发烧 = fever (health_note, status: in_progress)
		- Set confidence to 0.9 for clearly stated events
		- Do NOT merge multiple actions into one event — split them

		Transcript:
		\(transcript)
		"""

		NSLog("[OnDevice] 🧠 Sending to Foundation Models: '\(prompt.suffix(200))'")

		let response = try await session.respond(
			to: prompt,
			generating: TranscriptAnalysis.self
		)
		let result = response.content

		NSLog("[OnDevice] 🧠 Foundation Models response: relevant=\(result.relevant) events=\(result.events.count)")

		guard result.relevant, !result.events.isEmpty else {
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

		return AnalyzeResponse(newEvents: events, corrections: [])
	}

	func resetSession() {
		session = nil
	}
}

#endif
