# Babble Daily Report — Design Doc

## North star

A daily report a parent actually wants to read at 8pm when they're exhausted.
Not a data dump — a warm, concise brief that tells the story of the baby's day,
answers the questions that cause the most anxiety, and makes the pediatrician
visit effortless.

**The one question every parent is really asking:** *Is my baby okay today?*
The report should answer that in the first 3 seconds.

---

## What we learned from research

### From app reviews (Huckleberry, Glow Baby, Sprout, Baby Connect)

- **Dark mode is non-negotiable.** Glow Baby is widely criticized for being
  blinding during 2am feeds. This is our most-used surface at 2am — it must
  be dark by default.
- **One-handed logging is table stakes.** Sprout won a WWDC feature for Apple
  Watch Double Tap support. Any interaction requiring two hands gets abandoned.
- **Prediction beats logging.** Huckleberry's SweetSpot ("put baby down between
  10:00–10:20am") is the feature parents love most. Answering "when should I?"
  is more valuable than recording "what happened."
- **Multi-caregiver sync is a first-class need,** not a premium add-on. The
  nanny handoff is a high-stakes moment. Partner sync matters from day one.
- **Anxiety risk is real.** Apps that surface norms and comparisons without
  context increase anxiety instead of reducing it. Flags should answer
  "is this okay?" not just "this is different."

### From parenting philosophies

| Philosophy | What they want | What to avoid |
|---|---|---|
| Babywise / schedule-based | Wake windows, eat-wake-sleep pattern, schedule readiness | Nothing — they love data |
| Responsive / demand feeding | Quick memory aid (when did she last eat?), wet diaper count | Showing feeds as "too close" or "too short" |
| Attachment parenting | Milestones, memories, narrative notes | Prescriptive schedule framing |
| Montessori / RIE | What the baby initiated and explored | Over-monitoring, constant alerts |

**Design implication:** The report should default to descriptive, not prescriptive.
Recommendations and norms are opt-in.

### From the best health summary products (Oura, WHOOP, Apple Health)

- **Oura's model wins:** single score → sub-scores → contributing factors →
  narrative insight. Progressive disclosure. Users get the answer in 1 second
  or 60 seconds depending on how much they want.
- **Apple Health is the counter-example:** raw data, no summary, user has to
  construct meaning. Collecting data ≠ delivering insight.
- **WHOOP's verdict framing:** "Today is a green day." Parents want this
  equivalent: "Good day. Nothing to worry about."

### What caregivers most want to know (in priority order)

1. Is the baby getting enough to eat? (wet diapers + feed count + weight trend)
2. How much did they sleep? (total hours, night stretches)
3. Anything wrong health-wise? (fever, unusual symptoms)
4. What milestones or new things happened?
5. How was their mood overall?
6. What do I need to know for tonight/tomorrow?

---

## Three distinct report surfaces

### 1. Daily brief (primary — parents at 8pm)

Full day story. One screen summary, drill-down available.

### 2. Nanny handoff card (caregiver transition)

Shareable snapshot: last feed, nap times, last diaper, mood notes.
One tap to share as a message.

### 3. Pediatrician export (2-week trend PDF)

Structured clinical summary: feed totals, sleep totals, wet diaper count,
milestones, symptoms. Date-ranged. Shareable link or PDF.

---

## Daily brief design

### Header

```
Tuesday, March 19  ·  Oliver  ·  6 months 12 days
```

Age shown in months + days — development windows are tight.

---

### Verdict line (AI-generated, 1 sentence)

The first thing parents see. Written like a thoughtful friend, not a robot.

> "Good day overall — two solid naps, ate well, and rolled back to front for
> the very first time."

> "Rough night carried into a fussy morning, but things turned around after
> the afternoon nap and she finished a full bottle."

> "Pretty uneventful, which is a good thing. Normal feeds, two decent naps,
> no concerns."

**Tone:** Warm, factual, slightly personal. Nanny logbook, not clinical chart.

---

### Stats row

Quick scan for the numbers. Flags shown inline.

```
🍼 7 feeds   😴 13.5h sleep   💧 8 wet   💩 3 dirty   🌡️ Normal
```

With a concern:
```
🍼 4 feeds ⚠️   😴 15h sleep   💧 5 wet ⚠️   💩 0 (day 2)
```

Tap any stat to jump to that section. Flags are contextual to baby's age —
a 6-week-old with 4 feeds reads very differently than a 6-month-old with 4 feeds.

---

### Feeding

**Summary line first:**
> "7 feeds today, about 22 oz total. Good day."

**Timeline (expandable):**

```
7:10 am    Bottle           4 oz  (formula)
9:45 am    Breast           L 12 min · R 8 min
12:30 pm   Solids           Sweet potato — first time ✨
1:15 pm    Breast           L 10 min
4:00 pm    Bottle           5 oz
6:30 pm    Breast           R 15 min · L 10 min
8:45 pm    Breast           R 8 min  (bedtime)
```

**Flags (shown in summary, not just buried in timeline):**
- Fewer feeds than expected for age
- Refused 2+ consecutive feeds
- Spit up / vomiting mentioned
- New top-8 allergen introduced (watch for reaction in next 2 hours)
- Cluster feeding period noted

---

### Sleep

**Summary line:**
> "13.5h total — 3.5h in two naps, 10h overnight with 2 wake-ups."

**Visual timeline (horizontal bars like a sleep consultant's chart):**

```
12am ─────────────────────────────────────── 11pm
     ████████████████             ████   ████
     Night (10h)          Nap1   Nap2
     Wake-ups: 12:40am, 3:55am
```

**Expandable detail:**
```
9:05 – 10:50 am     Nap 1       1h 45m
2:15 – 3:40 pm      Nap 2       1h 25m
7:30 pm – 6:15 am   Night       10h 45m
                    Woke: 12:40am (20 min), 3:55am (10 min)
```

**Flags:**
- Total sleep below age range
- Both naps under 30 min (overtiredness signal)
- More night wakes than recent baseline

---

### Diapers

Simpler — count and any anomalies.

```
8 wet · 3 dirty
```

**Only surfaced if notable:**
> "Stool was green — common with teething or foremilk imbalance, nothing urgent
> unless it continues."

> "No dirty diaper today (day 2). For a baby this age, 3+ days is worth a call
> to the pediatrician."

**Flags:**
- Under 6 wet diapers after day 4 (dehydration risk)
- White, red, or black stool (after meconium phase)
- Diaper rash mentioned

---

### Health

Hidden on healthy days. Shown if any health event was logged.

```
⚠️ Health

11:30 am   Temp 38.1°C (100.6°F)   low-grade, monitored
 2:00 pm   Tylenol 2.5mL given
 5:00 pm   Temp 37.4°C (99.3°F)    back to normal

Resolved same day with Tylenol. No other symptoms.
```

**Always urgent (push notification, not just in-report):**
- Fever ≥38°C / 100.4°F in any infant under 3 months
- Seizure-like activity described
- Blue/gray coloring mentioned
- Baby described as unable to wake

---

### Milestones & moments

The section parents screenshot and send to grandparents.

```
✨  Oliver rolled from back to front for the first time — play mat, around 10am.
    Dad was there and caught it.

    He spent about 5 minutes staring at the ceiling fan completely mesmerized.

    Said something that sounded like "ma" twice. Probably coincidence,
    but worth watching.
```

Sourced from anything Gemini classified as: milestone, first-time event,
or notable observation. Written narratively, not as bullet data.

---

### Mood & behavior arc

One paragraph. Useful for spotting leap patterns and overtiredness cycles.

> "Started the morning unsettled — fussy through the first feed and hard to put
> down. Mood lifted a lot after the first nap. Afternoon was calm and curious.
> Went down for bed without much fuss."

---

### What to watch tonight / tomorrow (optional, AI-generated)

Only shown when there's something actionable.

> "He skipped his usual afternoon nap — might be overtired at bedtime.
> Try moving it 30 minutes earlier."

> "Introduced peanut butter today. Watch for any reaction (hives, vomiting,
> swelling) for the next few hours."

> "Fever resolved but keep an eye on temperature tonight. If it comes back
> above 38.5°C, call the pediatrician."

---

### Pediatrician-ready summary (collapsible)

Auto-generated rolling 2-week summary formatted for handoff.

```
For your next visit  ·  9-month checkup on April 4

Sleep      Avg 13.2h/day (past 7 days). Night waking 1–2x.
Feeding    Breast + bottle, ~24 oz/day. Purees since 6 months.
           New this week: sweet potato (✓), peas (✓).
Diapers    6–8 wet/day. 2–3 dirty, normal.
Milestones Rolling both ways. Sitting with support. Babbling (ba, da).
           Reaching and grasping. No first words yet.
Symptoms   Low-grade fever March 19, resolved same day with Tylenol.
Weight     7.2 kg on March 10 (last recorded).
```

---

## Nanny handoff card

One-tap, shareable as a message or in-app notification.

```
Oliver — as of 3:45 pm

Last fed:    1:15 pm  (breast, 10 min each side)
Total today: 4 feeds, ~14 oz
Naps:        9:05–10:50 am  (1h 45m)
Last diaper: 2:30 pm  (wet)
Mood:        Calm after nap, starting to get a bit fussy
Next feed:   Around 4:00–4:30 pm
```

---

## What the report should NOT include

- Raw transcripts
- Every individual event logged internally — curate, don't dump
- Clinical language in the main summary view
- Alarmist framing for things that are normal
- Comparisons to "what other babies are doing" by default

---

## Science-backed facts to track (and why they matter)

This section captures research findings that should inform what the app surfaces, flags, and explains. The goal: surface the right insight at the right developmental moment — not just log data.

---

### Sleep

**Wake windows are the most actionable per-age metric.**
The maximum comfortable awake time between sleeps shifts dramatically in the first two years. Overtiredness and undertiredness both cause harder days. The app should track and flag drift from age-appropriate wake windows.

| Age | Wake window | Total daily sleep |
|---|---|---|
| 0–2 months | 30 min – 1.75 hrs | 16–17 hrs |
| 3–5 months | 1 – 2.5 hrs | 14.5–15 hrs |
| 6–8 months | 2 – 3.5 hrs | 14+ hrs |
| 9–12 months | 2.5 – 4 hrs | 13–14 hrs |
| 12–18 months | 3.5 – 5 hrs | 12–14 hrs |
| 18–24 months | 4.5 – 6 hrs | 11–14 hrs |

**The "4-month regression" is a permanent upgrade, not a setback.**
Around 3–4 months, sleep architecture permanently transitions from 2-state (active/quiet) to 4-stage adult-like cycles. The baby won't revert. The app should reframe this for parents and recalibrate expectations at this age.

**Circadian rhythm doesn't exist at birth.** Cortisol rhythm forms at ~8 weeks, melatonin at ~9 weeks, body temperature at ~11 weeks. A stable circadian rhythm isn't established until ~12 months. Consistent bedtime is the strongest predictor of sleep quality during this formation window — more important to track than total sleep duration alone.

**Sleep regressions cluster around developmental leaps** — commonly at 4, 8–10, 12, 18, and 24 months — coinciding with major neurological changes (object permanence at ~8–10m, language explosion at ~18m, autonomy awareness at 24m). The app can proactively warn parents when their baby's age approaches these windows and sleep patterns are shifting.

**REM sleep dominates infant sleep at 50% (vs. 20% in adults).** This is when synaptic pruning and learning consolidation happen. Infants have ~1,000 trillion synapses at 6 months — more than adults — and sleep is when the brain selects which to keep. "Sleep is when they grow" is literally true.

**Breast milk is circadian.** Melatonin peaks in nighttime milk; daytime milk has different hormone compositions. Mixing pumped milk randomly disrupts this entrainment signal — worth surfacing once in the app.

---

### Feeding

**Hunger cues have a defined hierarchy — and late cues are the least useful.**

- Early (easy to miss): stirring, lip-smacking, sucking hands, head-turning
- Active: rooting, fussing, increased movement
- Late (hardest state to feed from): crying — a baby in distress cries has more difficulty latching

The app should note when a feed starts after prolonged crying — a proxy for missed early cues, and a pattern worth surfacing.

**Feeding frequency drops significantly with age:**

| Age | Frequency | Volume (formula) |
|---|---|---|
| 0–1 month | 8–12x/day | 1–2 oz per feed |
| 2–3 months | 7–9x/day | 4–5 oz |
| 4–5 months | 6–7x/day | 4–6 oz |
| 6 months | ~6x/day + solids intro | 6–8 oz |
| 9–12 months | 3–4 milk feeds + 3 meals | Transitioning to table food |

**Babies can taste in the womb.** Flavor compounds from the maternal diet pass into amniotic fluid. Prenatal exposure to varied flavors predicts postnatal food acceptance — there's a genuine food diversity story that starts before birth.

**Taste buds are 3× denser in newborns** (~10,000 vs. ~3,000–5,000 in adults). Bitter sensitivity doesn't register until ~2–3 months; salt not until ~3–4 months. There's a window around 5–7 months where bitter vegetables may be accepted before full sensitivity activates. The app can flag this window.

**The satiation cue problem.** Research shows mothers find hunger cues far more salient than fullness cues. Babies show clear hunger behaviors by 4–6 months but distinct satiation behaviors (turning away, pushing food) not until ~6–8 months. This asymmetry may contribute to overfeeding and is worth contextualizing in the report.

---

### Language and babbling

This is the highest-value audio tracking opportunity. Language development is deeply sequential with well-defined clinical checkpoints.

| Age | Stage |
|---|---|
| 0–2 months | Crying differentiation; startles to sound |
| 2–4 months | Cooing — soft vowel-dominant sounds ("oooh", "aaah") |
| 4–6 months | Marginal babbling — first consonant-vowel combos |
| 6–10 months | **Canonical babbling** — "ba-ba-ba", "ma-ma-ma" ← critical window |
| 10–15 months | Jargon — adult-length "sentences" with real prosody but no words |
| 12 months | First words (1–3 consistent, meaningful) |
| 18 months | 50-word vocabulary threshold |
| 24 months | ~300-word vocabulary; two-word phrases ("more milk", "daddy go") |

**The canonical babbling ratio (CBR) is a validated clinical metric.**
CBR = canonical syllables / total syllables. It should be rising through 6–10 months. A CBR below threshold past 10 months is a validated early predictor of smaller vocabulary at 18, 24, and 30 months. This is detectable from audio using MFCC analysis — a core feature the app can build toward.

**The 50-word threshold at 18 months is not arbitrary.** It marks the inflection point before the vocabulary explosion (10+ new words/day). Fewer than 50 words at 18 months = "late talker" classification with elevated risk of persistent delay. The app should let parents log new words and surface this milestone proactively.

**Language learning starts before birth.** The auditory system is functional at 26–28 weeks gestation. By birth, newborns already discriminate their mother's voice and their native language from foreign ones. Bilingual prenatal exposure widens phonetic sensitivity.

**A baby's cry accent reflects the mother's language.** French newborns cry with a rising melody contour; German newborns with a falling one — matching the prosody of the languages heard in utero. Even cry patterns are linguistically shaped from birth. Fun fact worth sharing in the app around the first week.

---

### Cry analysis

**Humans unaided classify cry type correctly only ~33% of the time.**
ML systems using MFCCs + deep learning achieve **94–97% accuracy** on labeled cry datasets. The features: zero-crossing rate, RMS energy, spectral centroid, bandwidth, Mel-spectrogram. Real-time cry classification is technically achievable on-device.

**Distinguishable cry types and their acoustic signatures:**

| Cry type | Acoustic signature |
|---|---|
| Pain/discomfort | Higher pitch, abrupt onset, short inter-cry pauses, high energy in upper bands |
| Hunger | Rhythmic, lower-pitched, melodic pattern, gradual escalation |
| Fatigue | Lower energy, nasal/whining quality, longer intervals between cries |
| Gas/discomfort | Short bursts, often accompanied by body stiffening |

**Pre-cry sounds may carry more signal than the cry itself.** The Dunstan Baby Language hypothesis — that reflexive pre-cry vocalizations ("Neh", "Owh", "Eh") contain cause-specific information — has a biologically plausible mechanism even if cross-cultural validation is incomplete. Pre-cry audio is an underexplored high-value detection window.

**Pathological cry detection has clinical significance.** Abnormal cry acoustics are established early indicators of neurological conditions (HIE, Down syndrome). Cry analysis has been researched as a newborn screening tool. This is a long-term research direction worth noting.

---

### Surprising facts worth surfacing in context

These are counterintuitive enough that the app should proactively explain them when they're relevant — not just log the data.

- **Newborns breathe and swallow simultaneously.** The larynx sits higher at birth, enabling parallel airways. This disappears by 3–4 months as the larynx descends — the same change that enables complex speech sounds.
- **Babies under 6 months have an aquatic diving reflex.** They automatically hold their breath when submerged. It fades by 6 months.
- **Plain water is dangerous before 6 months.** Even a few ounces can dilute blood sodium and cause hyponatremic seizures. Worth an in-app note when parents start asking about water.
- **Skull plates remain unfused for 18–24 months** to allow the brain to triple in weight during the first 3 years. Fontanelles are a feature, not a fragility.
- **Deferred imitation appears at 18–24 months** — the baby can watch an action, wait hours or days, and reproduce it. This is a direct observable sign of long-term memory consolidation. Worth logging when parents notice it.

---

### Trackable metrics the app should capture

| Metric | Signal source | Why it matters |
|---|---|---|
| Wake window duration | Auto-calculated from feed/sleep timestamps | Flag overtiredness; age-adjusted norms |
| Bedtime consistency | Sleep onset time each night | Strongest predictor of sleep quality; circadian entrainment |
| Feed-to-sleep association | Tag if baby asleep at end of feed | Risk factor for night waking; worth surfacing gently |
| Canonical babbling detection | MFCC audio analysis (ambient) | CBR is a validated early language delay predictor |
| New word log | Parent-reported entries | 50-word threshold at 18m is a clinical benchmark |
| Cry type classification | Real-time audio + ML | Pain vs. hunger vs. tired; 94–97% accuracy achievable |
| Jargon/babble onset | Audio detection + log | Absence at 12m is a clinical red flag |
| New food introductions | Manual log | Track diversity; flag high-allergen firsts |
| Night waking frequency trend | Sleep log over 7+ days | Regression detection; compare to age baseline |
| Vocabulary milestone | Running count from logs | Surfaces 18m threshold proactively |

---

## Open questions

- **Sharing format.** PDF for pediatrician. Image card for grandparents
  (like a Polaroid of the day's highlights). Text message for nanny.
- **Push vs. in-report alerts.** Fever in a newborn = push immediately.
  Low wet count = in-report flag only. Where is the line?
- **Schedule recommendations (SweetSpot equivalent).** Opt-in only.
  Don't impose schedule philosophy on demand-feeding families.
- **Growth data entry.** Weight and height need manual entry or a connected
  scale. Where does the parent input this? Should it prompt after well visits?
- **Leap tracking.** Wonder Weeks integration — show fussy phase context
  ("may be in leap 5 — extra clingy and unsettled is normal right now").
- **Multi-language.** Many caregivers (nannies, grandparents) aren't
  English-first. How does Gemini handle mixed-language transcripts?
