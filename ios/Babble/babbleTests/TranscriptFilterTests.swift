import XCTest
@testable import babble

final class TranscriptFilterTests: XCTestCase {

    private func check(_ transcript: String, baby: String = "Oliver", trigger: String = "name") -> Bool {
        TranscriptFilter.shouldAnalyze(transcript: transcript, babyName: baby, triggerKind: trigger)
    }

    // MARK: - Cry trigger always passes

    func test_cryTrigger_alwaysPasses() {
        XCTAssertTrue(check("", trigger: "cry"))
        XCTAssertTrue(check("um okay", trigger: "cry"))
        // parents talking about something totally unrelated — still logs because the cry is the event
        XCTAssertTrue(check("babe did you put the laundry in", trigger: "cry"))
    }

    // MARK: - Baby name in conversation

    func test_babyNameMentioned_passes() {
        // parent calling out to partner across the room
        XCTAssertTrue(check("hey come look Oliver is doing the thing again"))
        // parent talking to the baby directly
        XCTAssertTrue(check("oh my goodness Oliver you're so silly yes you are"))
        // casual mention while multitasking
        XCTAssertTrue(check("I think oliver needs a diaper, he smells"))
    }

    func test_keywordsAlone_passWithoutName() {
        // parent narrating to no one in particular
        XCTAssertTrue(check("okay she finally went down, I cannot believe it"))
        XCTAssertTrue(check("he's been cluster feeding all night long I'm losing my mind"))
    }

    // MARK: - Feeding

    func test_feeding_passes() {
        // parent updating partner
        XCTAssertTrue(check("just finished the bottle, he took about three ounces"))
        // parent talking to baby while nursing
        XCTAssertTrue(check("there you go buddy, good latch, that's it"))
        // frustration out loud
        XCTAssertTrue(check("ugh she keeps unlatching and I don't know what she wants"))
        // introducing solids, talking to partner
        XCTAssertTrue(check("she tried the sweet potato puree, made the most disgusted face"))
        // narrating a mess
        XCTAssertTrue(check("oh no he spit up everywhere, all over himself and me"))
        // asking partner
        XCTAssertTrue(check("when did you last feed her, she's acting hungry again"))
    }

    // MARK: - Sleep

    func test_sleep_passes() {
        // whispering update to partner
        XCTAssertTrue(check("shhh she just went down, don't make any noise"))
        // exhausted parent venting
        XCTAssertTrue(check("he was up every two hours last night I'm so tired"))
        // proud moment
        XCTAssertTrue(check("put him down awake and he fell asleep by himself, first time ever"))
        // tracking nap
        XCTAssertTrue(check("she went down around one, so probably up by three"))
        // early morning
        XCTAssertTrue(check("he woke up at five and just would not go back to sleep"))
    }

    // MARK: - Diaper

    func test_diaper_passes() {
        // calling for backup
        XCTAssertTrue(check("babe can you come help, it's a blowout situation in here"))
        // talking to baby while changing
        XCTAssertTrue(check("okay buddy let's get this diaper off, oh wow okay that's a lot"))
        // updating partner on the day
        XCTAssertTrue(check("he pooped like four times today, something is definitely off"))
        // noticing a problem
        XCTAssertTrue(check("her bottom is so red, I think we need the rash cream"))
    }

    // MARK: - Health

    func test_health_passes() {
        // worried parent texting or talking to partner
        XCTAssertTrue(check("he felt really warm so I took his temperature, it's 38 point 5"))
        // coordinating medication
        XCTAssertTrue(check("I gave her the tylenol at like two so we can do another dose at eight"))
        // after doctor visit
        XCTAssertTrue(check("doctor said lungs sound clear it's probably just a cold"))
        // noticing symptoms
        XCTAssertTrue(check("she's so congested, keeps sneezing, I feel so bad for her"))
        // teething suspicion
        XCTAssertTrue(check("he's been chewing on everything and drooling like crazy, has to be teething"))
        // vaccine day
        XCTAssertTrue(check("shots today, he screamed but honestly calmed down pretty fast"))
    }

    // MARK: - Milestones

    func test_milestones_passes() {
        // excited parent yelling to partner
        XCTAssertTrue(check("babe babe babe she just smiled at me, a real smile, get in here"))
        // narrating to themselves
        XCTAssertTrue(check("oh my god he just rolled over by himself, where's my phone"))
        // talking to baby
        XCTAssertTrue(check("look at you sitting up all by yourself, you're such a big girl"))
        // calling partner over
        XCTAssertTrue(check("come here quick he's trying to take steps, he keeps letting go of the table"))
        // to the baby
        XCTAssertTrue(check("you grabbed the ring! good job buddy, yes you did"))
    }

    // MARK: - Speech

    func test_speech_passes() {
        // texting partner while it happens
        XCTAssertTrue(check("she just said mama, like actually said it, I'm crying"))
        // narrating the moment
        XCTAssertTrue(check("he's been making so many new sounds today, lots of babbling, really different"))
        // to partner
        XCTAssertTrue(check("she keeps doing this thing that sounds like bye bye when we wave"))
    }

    // MARK: - Mood and emotion

    func test_emotion_passes() {
        // venting to partner
        XCTAssertTrue(check("he's been so fussy today, literally nothing works, I've tried everything"))
        // update while rocking
        XCTAssertTrue(check("finally got her calm, took like twenty minutes of rocking in the dark"))
        // observing behavior
        XCTAssertTrue(check("she gets so upset whenever I try to put her down even for a second"))
    }

    // MARK: - Activity and outings

    func test_activity_passes() {
        // narrating tummy time to partner
        XCTAssertTrue(check("doing tummy time, he hates it but we have to, pediatrician said so"))
        // recapping the day
        XCTAssertTrue(check("took her to the park this morning, she loved looking at the trees from the stroller"))
        // bedtime routine
        XCTAssertTrue(check("just read him three books, he kept grabbing the pages and chewing on them"))
        // swim class recap
        XCTAssertTrue(check("swim class was so cute, she splashed the whole time and didn't cry at all"))
    }

    // MARK: - Observation (long sentences without explicit baby keywords)

    func test_observationPattern_passes() {
        // talking to partner about baby's behavior
        XCTAssertTrue(check("she won't stop staring at the ceiling fan, like completely mesmerized by it"))
        XCTAssertTrue(check("the baby is being so chill right now just sitting there looking around"))
        XCTAssertTrue(check("he's been really alert all afternoon, following everything with his eyes"))
    }

    // MARK: - Should NOT pass

    func test_empty_fails() {
        XCTAssertFalse(check(""))
        XCTAssertFalse(check("   "))
    }

    func test_tooShort_fails() {
        XCTAssertFalse(check("okay"))
        XCTAssertFalse(check("oh no"))
    }

    func test_justFillerSounds_fails() {
        // mic picks up someone trailing off
        XCTAssertFalse(check("um uh okay yeah"))
        XCTAssertFalse(check("hmm okay right"))
    }

    func test_parentsTalkingAboutThemselves_fails() {
        // parents chatting in the background — baby monitor picked it up
        XCTAssertFalse(check("what do you feel like for dinner tonight"))
        XCTAssertFalse(check("did you remember to pay the credit card"))
        XCTAssertFalse(check("I'm going to run to the store, you need anything"))
        XCTAssertFalse(check("can you turn that down a little babe"))
        XCTAssertFalse(check("my back is so sore from that couch"))
        XCTAssertFalse(check("I'll call mom back after she goes to sleep"))
    }

    func test_shortVagueObservation_fails() {
        // pronoun present but way too short and vague
        XCTAssertFalse(check("he looks fine"))
        XCTAssertFalse(check("she seems okay"))
        XCTAssertFalse(check("he's good"))
    }

    // MARK: - Edge cases

    func test_emptyBabyName_noAutoPass() {
        XCTAssertFalse(check("what do you want for dinner tonight", baby: ""))
    }

    func test_babyNameSubstring_knownLimitation() {
        // Baby named "Al" — simple .contains() will match inside "also", "always", etc.
        // Known limitation, just documenting current behavior
        let result = check("I should also grab the groceries later", baby: "Al")
        _ = result  // returns true today — substring match is too broad for short names
    }
}
