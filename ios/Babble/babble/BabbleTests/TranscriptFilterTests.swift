import XCTest
@testable import babble

/// Unit tests for TranscriptFilter — pure logic, no audio, runs in simulator.
final class TranscriptFilterTests: XCTestCase {

    let babyName = "Luca"

    // MARK: - Always pass

    func testCryTriggerAlwaysPasses() {
        XCTAssertTrue(shouldAnalyze("", triggerKind: "cry"))
        XCTAssertTrue(shouldAnalyze("um", triggerKind: "cry"))
        XCTAssertTrue(shouldAnalyze("random unrelated words about weather", triggerKind: "cry"))
    }

    // MARK: - Baby name

    func testBabyNamePasses() {
        XCTAssertTrue(shouldAnalyze("Luca just woke up"))
        XCTAssertTrue(shouldAnalyze("Is luca hungry?"))       // case-insensitive
        XCTAssertTrue(shouldAnalyze("LUCA smiled today"))
    }

    // MARK: - Feeding

    func testFeedingKeywords() {
        XCTAssertTrue(shouldAnalyze("time for a bottle"))
        XCTAssertTrue(shouldAnalyze("she's hungry again"))
        XCTAssertTrue(shouldAnalyze("nursing for fifteen minutes"))
        XCTAssertTrue(shouldAnalyze("he spit up after eating"))
        XCTAssertTrue(shouldAnalyze("tried some solids today"))
        XCTAssertTrue(shouldAnalyze("formula is ready"))
        XCTAssertTrue(shouldAnalyze("he burped after the feed"))
    }

    // MARK: - Sleep

    func testSleepKeywords() {
        XCTAssertTrue(shouldAnalyze("she finally fell asleep"))
        XCTAssertTrue(shouldAnalyze("just went down for a nap"))
        XCTAssertTrue(shouldAnalyze("woke up from his nap"))
        XCTAssertTrue(shouldAnalyze("put her in the crib"))
        XCTAssertTrue(shouldAnalyze("seems really tired and drowsy"))
        XCTAssertTrue(shouldAnalyze("slept through the night"))
        XCTAssertTrue(shouldAnalyze("bedtime routine done"))
    }

    // MARK: - Diaper

    func testDiaperKeywords() {
        XCTAssertTrue(shouldAnalyze("needs a diaper change"))
        XCTAssertTrue(shouldAnalyze("he pooped again"))
        XCTAssertTrue(shouldAnalyze("wet diaper"))
        XCTAssertTrue(shouldAnalyze("changing her right now"))
        XCTAssertTrue(shouldAnalyze("noticed a rash"))
    }

    // MARK: - Health

    func testHealthKeywords() {
        XCTAssertTrue(shouldAnalyze("she has a fever of 38 degrees"))
        XCTAssertTrue(shouldAnalyze("gave some tylenol"))
        XCTAssertTrue(shouldAnalyze("doctor appointment tomorrow"))
        XCTAssertTrue(shouldAnalyze("vaccine shot this morning"))
        XCTAssertTrue(shouldAnalyze("teething again won't stop crying"))
        XCTAssertTrue(shouldAnalyze("runny nose and congestion"))
        XCTAssertTrue(shouldAnalyze("threw up after feeding"))
    }

    // MARK: - Milestones

    func testMilestoneKeywords() {
        XCTAssertTrue(shouldAnalyze("she smiled at me today"))
        XCTAssertTrue(shouldAnalyze("he started crawling this morning"))
        XCTAssertTrue(shouldAnalyze("took her first steps"))
        XCTAssertTrue(shouldAnalyze("rolled over for the first time"))
        XCTAssertTrue(shouldAnalyze("sat up by himself"))
        XCTAssertTrue(shouldAnalyze("waved goodbye"))
        XCTAssertTrue(shouldAnalyze("what a milestone today"))
    }

    // MARK: - Speech

    func testSpeechKeywords() {
        XCTAssertTrue(shouldAnalyze("she said mama clearly"))
        XCTAssertTrue(shouldAnalyze("he's been babbling all day"))
        XCTAssertTrue(shouldAnalyze("said his first word"))
        XCTAssertTrue(shouldAnalyze("lots of cooing sounds"))
    }

    // MARK: - Third-person observation

    func testThirdPersonObservation() {
        XCTAssertTrue(shouldAnalyze("she seems really happy and content today playing"))
        XCTAssertTrue(shouldAnalyze("he was very fussy after the last feeding time"))
        XCTAssertTrue(shouldAnalyze("the baby was looking around and exploring"))
        XCTAssertTrue(shouldAnalyze("they were calm after the bath tonight"))
    }

    // MARK: - Should filter (drop)

    func testEmptyTranscriptFiltered() {
        XCTAssertFalse(shouldAnalyze(""))
        XCTAssertFalse(shouldAnalyze("   "))
    }

    func testFillerOnlyFiltered() {
        XCTAssertFalse(shouldAnalyze("um"))
        XCTAssertFalse(shouldAnalyze("uh okay yeah"))
        XCTAssertFalse(shouldAnalyze("hmm yes"))
        XCTAssertFalse(shouldAnalyze("hi hello bye"))
    }

    func testTooShortNoKeywordFiltered() {
        XCTAssertFalse(shouldAnalyze("what time is it"))
        XCTAssertFalse(shouldAnalyze("nice weather today"))
        XCTAssertFalse(shouldAnalyze("order pizza please"))
    }

    func testUnrelatedLongSentenceFiltered() {
        XCTAssertFalse(shouldAnalyze("the meeting is scheduled for three o'clock this afternoon"))
        XCTAssertFalse(shouldAnalyze("can you turn off the lights in the living room please"))
    }

    // MARK: - ASR phrase variants (common mishearings)

    func testASRVariantSpitUp() {
        // "spit up" → ASR may produce "spat up" (past tense) or "spit-up" (hyphenated)
        XCTAssertTrue(shouldAnalyze("she spat up after the bottle"))
        XCTAssertTrue(shouldAnalyze("there was some spit-up on her shirt"))
    }

    func testASRVariantDiaper() {
        // "diaper" → ASR may produce "day pair"
        XCTAssertTrue(shouldAnalyze("need to do a day pair change"))
        XCTAssertTrue(shouldAnalyze("the day pair was soaked"))
    }

    func testASRVariantSleepRegression() {
        // "sleep regression" → ASR may produce "sleek regression"
        XCTAssertTrue(shouldAnalyze("I think it's a sleek regression"))
        XCTAssertTrue(shouldAnalyze("dealing with sleek regression this week"))
    }

    // MARK: - containsSecondaryReference

    func testSecondaryRefPronouns() {
        // Pronouns with enough context should pass
        XCTAssertTrue(containsSecondaryReference("she's been fussy all morning"))
        XCTAssertTrue(containsSecondaryReference("he just woke up from his nap"))
        XCTAssertTrue(containsSecondaryReference("we put him down an hour ago"))
        XCTAssertTrue(containsSecondaryReference("did he eat anything today"))
        XCTAssertTrue(containsSecondaryReference("they were calm after the bath"))
    }

    func testSecondaryRefNicknames() {
        // Nicknames always pass regardless of word count
        XCTAssertTrue(containsSecondaryReference("little one won't settle"))
        XCTAssertTrue(containsSecondaryReference("the little one is sleeping"))
        XCTAssertTrue(containsSecondaryReference("our baby is crying"))
        XCTAssertTrue(containsSecondaryReference("munchkin finally ate"))
        XCTAssertTrue(containsSecondaryReference("our little peanut smiled"))
    }

    func testSecondaryRefFalsePositiveGuard() {
        // Sentences with no baby pronoun (she/he/we/they/her/him/you) should NOT fire.
        // "I'm so tired" was the key regression — it would incorrectly start a capture.
        XCTAssertFalse(containsSecondaryReference("I'm so tired"))
        XCTAssertFalse(containsSecondaryReference("I need coffee now"))
        XCTAssertFalse(containsSecondaryReference("going to the store today"))
        XCTAssertFalse(containsSecondaryReference("pizza for dinner tonight"))
    }

    func testSecondaryRefTooShort() {
        // Under 3 words — blocked by word count guard
        XCTAssertFalse(containsSecondaryReference("she"))
        XCTAssertFalse(containsSecondaryReference("he cried"))
    }

    // MARK: - Active period shouldAnalyze

    func testActivePeriodSecondaryRefPasses() {
        // During active period, secondary references should pass shouldAnalyze
        XCTAssertTrue(shouldAnalyze("she's been fussy", isActivePeriod: true))
        XCTAssertTrue(shouldAnalyze("he just woke up", isActivePeriod: true))
        XCTAssertTrue(shouldAnalyze("little one is crying", isActivePeriod: true))
    }

    func testActivePeriodIsolatedPronounBlocked() {
        // Short pronoun utterances under word count guard should not pass
        XCTAssertFalse(shouldAnalyze("she", isActivePeriod: true))
    }

    // MARK: - Helper

    private func shouldAnalyze(
        _ transcript: String,
        triggerKind: String = "name",
        isActivePeriod: Bool = false
    ) -> Bool {
        TranscriptFilter.shouldAnalyze(
            transcript: transcript,
            babyName: babyName,
            triggerKind: triggerKind,
            isActivePeriod: isActivePeriod
        )
    }

    private func containsSecondaryReference(_ transcript: String) -> Bool {
        TranscriptFilter.containsSecondaryReference(transcript)
    }
}
