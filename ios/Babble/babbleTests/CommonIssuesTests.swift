import XCTest
@testable import babble

/// Tests that the transcript filter captures the language parents actually use
/// when describing common baby issues: sleep problems, skin conditions, feeding
/// difficulties, digestive issues, and illnesses.
///
/// Each section is organized as:
///   - What the issue is (comment)
///   - Real parent phrases that should be captured
///
final class CommonIssuesTests: XCTestCase {

    private func check(_ transcript: String, baby: String = "Oliver", trigger: String = "name") -> Bool {
        TranscriptFilter.shouldAnalyze(transcript: transcript, babyName: baby, triggerKind: trigger)
    }

    // MARK: ─── SLEEP PROBLEMS ────────────────────────────────────────────

    // Sleep regression: baby who slept well suddenly wakes constantly.
    // Most common at 4, 8–10, and 12 months. Parents rarely use the
    // clinical term — they describe the symptom.
    func test_sleepRegression_passes() {
        XCTAssertTrue(check("she was sleeping through the night and now she's up every two hours"))
        XCTAssertTrue(check("I think we're in a sleep regression, it's like we went backwards"))
        XCTAssertTrue(check("four month sleep regression is hitting us hard right now"))
        XCTAssertTrue(check("he was doing so well and now he won't sleep for more than an hour"))
        XCTAssertTrue(check("up six times last night, something changed this week"))
    }

    // Overtiredness: missed nap window, too much wake time.
    // One of the most common causes of hard nights and short naps.
    func test_overtiredness_passes() {
        XCTAssertTrue(check("she's so overtired, been fighting sleep for like an hour"))
        XCTAssertTrue(check("he missed his nap window and now he's a wreck"))
        XCTAssertTrue(check("we were out too long and she's overtired, tonight is going to be rough"))
        XCTAssertTrue(check("he's exhausted but keeps waking up after 20 minutes"))
        XCTAssertTrue(check("fighting sleep again, I can see the tired cues but she won't go down"))
    }

    // Night waking and sleep associations: baby only falls back asleep
    // when nursed, rocked, or held. Common after 4-month regression.
    func test_nightWaking_passes() {
        XCTAssertTrue(check("he's up every 45 minutes and only settles when I nurse him back"))
        XCTAssertTrue(check("she wakes up screaming and won't go back down without being rocked"))
        XCTAssertTrue(check("up all night, I don't think either of us slept more than an hour"))
        XCTAssertTrue(check("wakes every two hours like clockwork, has been for two weeks"))
        XCTAssertTrue(check("he associates nursing with sleep so whenever he comes up between cycles he needs me"))
    }

    // Motor milestone disrupting sleep: baby practices new skill at night.
    // Very common when learning to roll, crawl, or pull to stand.
    func test_milestoneDisruptingSleep_passes() {
        XCTAssertTrue(check("he learned to pull up and now stands in the crib and screams, can't get back down"))
        XCTAssertTrue(check("she keeps rolling onto her tummy at night and then cries because she's stuck"))
        XCTAssertTrue(check("ever since he started crawling the naps have been terrible"))
        XCTAssertTrue(check("she practices standing in the crib at like 2am, just stands there and yells"))
    }

    // Separation anxiety: peaks 7–10 months. Makes bedtime and nap
    // drop-offs suddenly very difficult.
    func test_separationAnxiety_passes() {
        XCTAssertTrue(check("separation anxiety is so real right now, screams the second I leave the room"))
        XCTAssertTrue(check("she's so clingy at bedtime, won't let me put her down at all"))
        XCTAssertTrue(check("he cries every time I leave even just to go to the bathroom"))
        XCTAssertTrue(check("she used to go down easy and now bedtime takes an hour because of separation anxiety"))
    }

    // Nap transition trouble: dropping from 3 to 2 naps (~6 months)
    // or 2 to 1 nap (~12–18 months). Causes schedule chaos.
    func test_napTransition_passes() {
        XCTAssertTrue(check("I think she's ready to drop the third nap but then she can't make it to bedtime"))
        XCTAssertTrue(check("transitioning to one nap has been brutal, he's a mess by 4pm"))
        XCTAssertTrue(check("she's fighting the morning nap now but the afternoon nap alone isn't enough"))
        XCTAssertTrue(check("catnapping again, 25 minutes every nap no matter what I do"))
    }

    // Night terrors: distinct from nightmares. Baby screams, appears awake
    // but is not, doesn't respond, no memory of it.
    func test_nightTerrors_passes() {
        XCTAssertTrue(check("she had what I think was a night terror, screamed but her eyes were open and she didn't recognize me"))
        XCTAssertTrue(check("night terrors started this week, super scary to witness"))
        XCTAssertTrue(check("he was screaming but completely inconsolable, like he wasn't really awake"))
    }

    // MARK: ─── SKIN CONDITIONS ───────────────────────────────────────────

    // Diaper rash: most common skin issue. Can be irritant-based or yeast.
    // Yeast rash doesn't respond to normal cream — needs antifungal.
    func test_diaperRash_passes() {
        XCTAssertTrue(check("her bottom is so red, the diaper rash is getting worse not better"))
        XCTAssertTrue(check("tried zinc oxide for two days and the rash isn't clearing up, might be yeast"))
        XCTAssertTrue(check("he has a yeast diaper rash, the cream isn't working, need to call the doctor"))
        XCTAssertTrue(check("really bad rash, there are little satellite spots around it which I think means yeast infection"))
        XCTAssertTrue(check("she screams every time I wipe her, the rash is so raw"))
    }

    // Eczema: chronic dry itchy patches. Triggered by heat, sweat,
    // certain fabrics, food allergens, low humidity.
    func test_eczema_passes() {
        XCTAssertTrue(check("he has eczema flaring up on his cheeks and the backs of his knees"))
        XCTAssertTrue(check("eczema is so bad this week, she won't stop scratching her arms"))
        XCTAssertTrue(check("dry patches everywhere, I think it's eczema, need to get a referral to a dermatologist"))
        XCTAssertTrue(check("the eczema cream helped but it keeps coming back behind her ears"))
        XCTAssertTrue(check("itchy dry skin all over his torso, scratching in his sleep"))
    }

    // Cradle cap: yellowish flaky crust on scalp. Looks alarming,
    // usually harmless. Parents often describe it without knowing the name.
    func test_cradleCap_passes() {
        XCTAssertTrue(check("she has cradle cap really bad, thick yellow crusty patches all over her head"))
        XCTAssertTrue(check("cradle cap is spreading to his eyebrows and behind his ears now"))
        XCTAssertTrue(check("flaky stuff all over the scalp, been brushing it but it keeps coming back"))
        XCTAssertTrue(check("thick scaly patches on her head, is that cradle cap or something else"))
    }

    // Heat rash / miliaria: tiny red bumps from blocked sweat glands.
    // Common in hot weather or when overdressed.
    func test_heatRash_passes() {
        XCTAssertTrue(check("heat rash all over his chest and neck from being in the carrier too long"))
        XCTAssertTrue(check("tiny red bumps everywhere, I think it's a heat rash from the warm day"))
        XCTAssertTrue(check("she has a rash on her back where the carrier sits, probably heat rash"))
    }

    // Baby acne / milia: tiny whiteheads common in newborns.
    // Hormonal, resolves on its own.
    func test_babyAcne_passes() {
        XCTAssertTrue(check("baby acne is flaring up on his cheeks and forehead"))
        XCTAssertTrue(check("she has little white bumps all over her nose, doctor said it's milia"))
        XCTAssertTrue(check("his face looks like a teenager's right now, baby acne everywhere"))
    }

    // Drool rash: red irritated skin around mouth and chin from
    // constant drool. Very common during teething.
    func test_droolRash_passes() {
        XCTAssertTrue(check("drool rash around her mouth is really red and raw, she's teething so much"))
        XCTAssertTrue(check("chin is so chapped from all the drool, red and irritated"))
        XCTAssertTrue(check("rash around his lips from the constant drooling, need to keep it dry"))
    }

    // Hives / allergic reaction: raised welts, can spread quickly.
    // Urgent if accompanied by swelling or breathing changes.
    func test_hivesAllergicReaction_passes() {
        XCTAssertTrue(check("she broke out in hives after trying egg for the first time, calling the doctor"))
        XCTAssertTrue(check("hives all over his body, appeared within 20 minutes of eating"))
        XCTAssertTrue(check("allergic reaction to the peanut butter, face is swelling a little, going to the ER"))
        XCTAssertTrue(check("swollen lip after the new food, worried it might be an allergy"))
    }

    // Roseola: fever for 3–5 days, then rash appears as fever breaks.
    // Very common in babies 6–24 months.
    func test_roseola_passes() {
        XCTAssertTrue(check("had a high fever for four days and now there's a rash all over his trunk, pediatrician thinks it's roseola"))
        XCTAssertTrue(check("fever broke this morning and now she has a rash, doctor said roseola"))
        XCTAssertTrue(check("roseola confirmed, rash is already fading and she's acting normal again"))
    }

    // Hand-foot-mouth: blisters on hands, feet, and mouth. Viral,
    // very contagious. Common in daycare settings.
    func test_handFootMouth_passes() {
        XCTAssertTrue(check("hand foot mouth is going around daycare and now she has blisters in her mouth"))
        XCTAssertTrue(check("he has hand-foot-mouth, sores on his hands and feet and won't eat because his mouth hurts"))
        XCTAssertTrue(check("blisters on his feet and palms, pretty sure it's hand foot mouth"))
        XCTAssertTrue(check("the spots look like hand foot mouth, going to the pediatrician today"))
    }

    // MARK: ─── FEEDING PROBLEMS ──────────────────────────────────────────

    // Nursing strike: baby suddenly refuses the breast, not weaning.
    // Often caused by illness, ear infection, teething, or a fright
    // during nursing.
    func test_nursingStrike_passes() {
        XCTAssertTrue(check("she's refusing the breast all of a sudden, nursing strike out of nowhere"))
        XCTAssertTrue(check("he was nursing fine and now he won't latch at all, keeps pulling off and crying"))
        XCTAssertTrue(check("nursing strike started three days ago, she screams when I try to latch her"))
        XCTAssertTrue(check("breast refusal has been going on since yesterday, don't know what triggered it"))
    }

    // Bottle refusal: breastfed baby won't take a bottle.
    // Very common when returning to work. Stressful for caregivers.
    func test_bottleRefusal_passes() {
        XCTAssertTrue(check("bottle refusal is so stressful, she won't take it from anyone"))
        XCTAssertTrue(check("he refuses every bottle we've tried, going through like six different nipples"))
        XCTAssertTrue(check("she'll only nurse, went back to work yesterday and she just screamed and refused the bottle all day"))
        XCTAssertTrue(check("tried every bottle on the market, still refusing, daycare is panicking"))
    }

    // Tongue tie / lip tie: restricts latch, causes nipple pain and poor
    // milk transfer. Often missed at birth.
    func test_tongueLipTie_passes() {
        XCTAssertTrue(check("lactation consultant thinks he has a tongue tie, explaining the latch issues"))
        XCTAssertTrue(check("she has a lip tie and a posterior tongue tie, going to see a specialist about revision"))
        XCTAssertTrue(check("tongue tie is making nursing so painful, she can't transfer milk efficiently"))
        XCTAssertTrue(check("the dentist confirmed a tongue tie, booked the frenotomy for next week"))
    }

    // Low milk supply: real or perceived. Major source of anxiety.
    // Often leads to supplementing with formula.
    func test_lowSupply_passes() {
        XCTAssertTrue(check("worried about low supply, she's not gaining weight well"))
        XCTAssertTrue(check("milk supply dropped this week, barely pumping two ounces a session"))
        XCTAssertTrue(check("think I have low supply, she's always hungry and fussy after nursing"))
        XCTAssertTrue(check("supply has been tanking since I went back to work, supplementing with formula now"))
    }

    // Mastitis / blocked duct: painful breast infection or blockage.
    // Needs treatment or can worsen quickly.
    func test_mastitisCloggedDuct_passes() {
        XCTAssertTrue(check("I have mastitis, breast is red and hot and I have a fever"))
        XCTAssertTrue(check("clogged duct for three days, really painful, trying to massage it out"))
        XCTAssertTrue(check("blocked duct isn't clearing, might be turning into mastitis, calling the doctor"))
        XCTAssertTrue(check("woke up with a hard painful lump in my breast, think it's a clogged duct"))
    }

    // Cluster feeding: very frequent feeds in a short period.
    // Normal and expected during growth spurts but exhausting.
    func test_clusterFeeding_passes() {
        XCTAssertTrue(check("she's cluster feeding tonight, been on the breast for like three hours solid"))
        XCTAssertTrue(check("cluster feeding every evening this week, I'm basically a human pacifier from 5 to 9"))
        XCTAssertTrue(check("growth spurt cluster feeding is back, he wants to eat every 45 minutes"))
        XCTAssertTrue(check("is this normal, she's been cluster feeding for four days straight"))
    }

    // Nipple confusion / pain: baby switches between breast and bottle
    // and has trouble with latch after.
    func test_nippleIssues_passes() {
        XCTAssertTrue(check("she's having nipple confusion after we introduced the bottle, latch is all wrong now"))
        XCTAssertTrue(check("my nipples are so cracked and painful, nursing is brutal right now"))
        XCTAssertTrue(check("nipple pain is making me want to quit breastfeeding, it shouldn't hurt this much"))
    }

    // MARK: ─── DIGESTIVE ISSUES ──────────────────────────────────────────

    // Gas / wind: very common in newborns. Immature digestive system.
    // Causes crying, leg pulling, arching.
    func test_gas_passes() {
        XCTAssertTrue(check("he's so gassy today, been farting and crying all morning"))
        XCTAssertTrue(check("she has terrible gas, pulling her legs up to her chest and screaming"))
        XCTAssertTrue(check("gas drops seem to help a little but he's still really windy"))
        XCTAssertTrue(check("gassy baby, trying bicycle legs and tummy massage"))
        XCTAssertTrue(check("she seems to have a lot of gas after the formula, switching brands"))
    }

    // Colic: crying >3 hours/day, >3 days/week, >3 weeks. Unknown cause.
    // One of the most stressful early baby experiences.
    func test_colic_passes() {
        XCTAssertTrue(check("I think she has colic, screams from 6 to 10 every single night, nothing helps"))
        XCTAssertTrue(check("colicky baby is destroying us, been six weeks of evening screaming"))
        XCTAssertTrue(check("pediatrician says it's colic and to just wait it out, easier said than done"))
        XCTAssertTrue(check("the colic seems to be easing up, screaming sessions are getting shorter"))
    }

    // Reflux / GERD: acid comes back up, causing pain. Different from
    // normal spitting up. Baby arches back, refuses feeds, cries during.
    func test_reflux_passes() {
        XCTAssertTrue(check("he arches his back during feeds, pediatrician thinks it's reflux"))
        XCTAssertTrue(check("arches back and screams after every feed, definitely reflux"))
        XCTAssertTrue(check("GERD is making feeding miserable, she cries through every bottle"))
        XCTAssertTrue(check("silent reflux, she doesn't spit up much but clearly in pain, arching and screaming"))
        XCTAssertTrue(check("started Zantac for reflux yesterday, hoping it helps"))
        XCTAssertTrue(check("spitting up constantly, like projectile, worried it might be more than normal reflux"))
    }

    // Constipation: common when introducing solids. Straining, hard
    // pellet-like stools, infrequent bowel movements.
    func test_constipation_passes() {
        XCTAssertTrue(check("she's been constipated since we started rice cereal, three days no poop"))
        XCTAssertTrue(check("straining so hard to poop, face turns red, clearly in pain"))
        XCTAssertTrue(check("hard little pellet poops, that's constipation right, what do I do"))
        XCTAssertTrue(check("constipated since starting solids, trying prune puree"))
        XCTAssertTrue(check("no poop in four days and he's straining every hour, calling the doctor"))
    }

    // Diarrhea: watery frequent stools. Can cause dehydration quickly.
    // Common with illness or new foods.
    func test_diarrhea_passes() {
        XCTAssertTrue(check("explosive watery diarrhea four times today, worried about dehydration"))
        XCTAssertTrue(check("she's had diarrhea since yesterday, watching wet diapers closely"))
        XCTAssertTrue(check("diarrhea and a low fever, probably a stomach bug"))
        XCTAssertTrue(check("mucus in the stool along with diarrhea, calling the pediatrician"))
    }

    // Blood in stool: always requires evaluation. Can be food allergy
    // (FPIES/MSPI), anal fissure, or more serious.
    func test_bloodInStool_passes() {
        XCTAssertTrue(check("there's blood in his stool, bright red streaks, calling the doctor now"))
        XCTAssertTrue(check("blood in stool since we introduced cow's milk protein, possible MSPI"))
        XCTAssertTrue(check("little blood in the diaper, pediatrician thinks it's a small anal fissure"))
    }

    // MARK: ─── ILLNESSES ─────────────────────────────────────────────────

    // RSV: respiratory syncytial virus. Very common and can be serious
    // in infants under 6 months. Wheezing, fast breathing, retractions.
    func test_rsv_passes() {
        XCTAssertTrue(check("she's wheezing and breathing really fast, going to the ER, worried about RSV"))
        XCTAssertTrue(check("RSV confirmed at the doctor, they said to monitor her breathing closely"))
        XCTAssertTrue(check("he has RSV, breathing is labored and he won't eat, they admitted him to the hospital"))
        XCTAssertTrue(check("chest is retracting when she breathes and she's wheezing, that's not normal"))
        XCTAssertTrue(check("breathing so fast, counting like 60 breaths a minute, calling the pediatrician"))
    }

    // Ear infection: common after a cold. Pulling at ear, inconsolable
    // crying, fever, waking at night, refusing to lie flat.
    func test_earInfection_passes() {
        XCTAssertTrue(check("she keeps pulling at her ear and has had a fever for two days, ear infection?"))
        XCTAssertTrue(check("tugging at his ear all day, super cranky, probably an ear infection"))
        XCTAssertTrue(check("ear infection confirmed, starting amoxicillin today"))
        XCTAssertTrue(check("third ear infection in two months, ENT is talking about tubes"))
        XCTAssertTrue(check("he won't lie flat without screaming, and keeps touching his ear"))
    }

    // Thrush: oral candida. White patches in mouth that don't wipe off.
    // Can transfer to mother's nipples.
    func test_thrush_passes() {
        XCTAssertTrue(check("white patches inside her cheeks and on her tongue, pretty sure it's thrush"))
        XCTAssertTrue(check("thrush confirmed, nystatin drops started today"))
        XCTAssertTrue(check("she has thrush and now my nipples are burning so I probably have it too"))
        XCTAssertTrue(check("yeast infection in his mouth, white coating won't wipe off"))
        XCTAssertTrue(check("oral thrush keeps coming back, we keep passing it back and forth"))
    }

    // Croup: barking cough, stridor. Often worse at night.
    // Caused by viral inflammation of the larynx.
    func test_croup_passes() {
        XCTAssertTrue(check("he woke up at midnight with this horrible barking cough, sounds like croup"))
        XCTAssertTrue(check("croup diagnosed, they gave a steroid dose at the ER"))
        XCTAssertTrue(check("that barking seal cough is back, second bout of croup this winter"))
        XCTAssertTrue(check("making a weird high pitched sound when she breathes in, the stridor sound"))
    }

    // Pinkeye / conjunctivitis: red goopy eyes. Can be viral, bacterial,
    // or from a blocked tear duct in newborns.
    func test_pinkeye_passes() {
        XCTAssertTrue(check("woke up with his eye completely crusted shut, think it's pinkeye"))
        XCTAssertTrue(check("conjunctivitis, antibiotic drops started, keeping her home from daycare"))
        XCTAssertTrue(check("yellow discharge coming out of both eyes, pediatrician said bacterial conjunctivitis"))
        XCTAssertTrue(check("her tear duct is blocked again, eye keeps getting goopy"))
    }

    // MARK: ─── DEVELOPMENTAL CONCERNS ────────────────────────────────────

    // Skill regression: losing a previously acquired skill.
    // Always warrants pediatrician attention.
    func test_skillRegression_passes() {
        XCTAssertTrue(check("she used to say mama and now she's stopped completely, that's a regression isn't it"))
        XCTAssertTrue(check("he was rolling both ways and hasn't done it in two weeks, regression?"))
        XCTAssertTrue(check("speech regression after the new baby arrived, saying fewer words than before"))
    }

    // MARK: ─── SHOULD STILL NOT PASS ─────────────────────────────────────

    // These are clearly non-baby conversations that should stay filtered out
    // even after the keyword expansion.
    func test_adultConversation_stillFails() {
        XCTAssertFalse(check("what do you want for dinner tonight"))
        XCTAssertFalse(check("did you pay the electricity bill this month"))
        XCTAssertFalse(check("I'm going to pop to the grocery store"))
        XCTAssertFalse(check("can you turn the TV down a bit"))
        XCTAssertFalse(check("my back is so sore from that chair"))
    }
}
