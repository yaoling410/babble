import Foundation
import Combine

@MainActor
final class SummaryViewModel: ObservableObject {
    @Published var summary: DaySummary? = nil
    @Published var isGenerating: Bool = false
    @Published var error: String? = nil

    private let profile: BabyProfile
    private let analysisService: AnalysisService

    init(profile: BabyProfile, analysisService: AnalysisService) {
        self.profile = profile
        self.analysisService = analysisService
    }

    func generateSummary(dateStr: String) async {
        isGenerating = true
        error = nil
        do {
            summary = try await analysisService.generateSummary(
                babyName: profile.babyName,
                ageMonths: profile.babyAgeMonths,
                dateStr: dateStr
            )
        } catch {
            self.error = error.localizedDescription
        }
        isGenerating = false
    }

    func fetchCachedSummary(dateStr: String) async {
        do {
            summary = try await analysisService.fetchSummary(dateStr: dateStr)
        } catch {
            print("[SummaryVM] fetch failed: \(error)")
        }
    }
}
