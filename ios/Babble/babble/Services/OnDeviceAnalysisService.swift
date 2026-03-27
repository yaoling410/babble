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
	@Guide(description: "Type of baby event. One of: feeding, sleep, diaper, health_note, milestone, mood, activity, cry, new_food, observation")
	var type: String

	@Guide(description: "More specific classification. For feeding: breast/bottle/solids/pumping. For diaper: wet/dirty/mixed. For sleep: nap/night. For activity: tummy_time/bath/outing/play. Leave empty if not applicable.")
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

	@Guide(description: "Baby events extracted from the transcript. Empty array if not relevant.")
	var events: [ExtractedEvent]
}

@available(iOS 26.0, *)
@MainActor
final class OnDeviceAnalysisService {
	// Simple availability flag — if FoundationModels is present assume availability.
	static var isAvailable: Bool { true }

	func analyze(
		transcript: String,
		babyName: String,
		ageMonths: Int,
		triggerHint: String,
		clipTimestamp: Date
	) async throws -> AnalyzeResponse {
		// Minimal stub implementation for compile-time stability.
		// A full on-device LLM integration can replace this with a
		// LanguageModelSession-based prompt/response flow.
		return AnalyzeResponse(newEvents: [], corrections: [], correctionsApplied: nil, summaryHint: nil, usage: nil)
	}

	func resetSession() {}
}

#endif
