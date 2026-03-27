import Foundation
import Combine

// ============================================================
//  SummaryViewModel.swift — Daily report generation
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  Drives the SummaryView screen. When the user taps "Generate",
//  this ViewModel calls POST /summary/generate on the backend.
//  Gemini reads all of today's events from the backend DB and
//  returns a DaySummary (feeding totals, sleep timeline, milestones,
//  mood arc, pediatrician summary, shareable tweet).
//
//  CACHING
//  -------
//  fetchCachedSummary() loads a previously generated summary from
//  GET /summary?date=YYYY-MM-DD so the user sees content immediately
//  on screen open. generateSummary() overwrites the cache.
//
//  The summary is stored on the backend (babble.db), not locally.

@MainActor
final class SummaryViewModel: ObservableObject {
    @Published var summary: DaySummary? = nil
    @Published var isGenerating: Bool = false
    @Published var error: String? = nil

    let analysisService: AnalysisService

    init(analysisService: AnalysisService) {
        self.analysisService = analysisService
    }

    func generateSummary(babyName: String, ageMonths: Int, dateStr: String) async {
        isGenerating = true
        error = nil
        do {
            summary = try await analysisService.generateSummary(
                babyName: babyName,
                ageMonths: ageMonths,
                dateStr: dateStr
            )
        } catch {
            self.error = error.localizedDescription
            NSLog("[SummaryVM] generate failed: \(error)")
        }
        isGenerating = false
    }

    func fetchCachedSummary(dateStr: String) async {
        do {
            summary = try await analysisService.fetchSummary(dateStr: dateStr)
        } catch {
            NSLog("[SummaryVM] fetch failed: \(error)")
        }
    }
}
