# Audio Pipeline — How Babble Listens, Detects, and Decides

A beginner-friendly walkthrough of everything that happens from "microphone on"
to "Gemini receives a clip". No prior audio or ML knowledge assumed.

---

## The big picture

Babble's microphone is always on while monitoring. But it doesn't record
everything and send it to the cloud — that would be expensive, slow, and a
privacy nightmare. Instead it runs a series of cheap local checks, and only
sends audio to the backend when it's confident something worth logging just
happened.

Think of it as a set of gates, each one cheaper than the next:

```
Microphone
    │
    ▼
[Gate 1] Speech-band energy check  ← almost free, runs on every buffer
    │ passes
    ▼
[Gate 2] Wake word OR cry detected ← cheap, on-device ML / string match
    │ triggers
    ▼
[Gate 3] TranscriptFilter          ← free, pure string matching
    │ passes
    ▼
[Gate 4] Early-abort check (10s)   ← free, same string matching mid-capture
    │ passes
    ▼
[Gate 5] Final TranscriptFilter    ← free, on the completed clip
    │ passes
    ▼
Backend → Diarize → Gemini         ← costs money, only reached when worthwhile
```

Each gate tries to kill irrelevant audio before it reaches the expensive next
step.

---

## Step 1 — The audio engine

**File:** [AudioCaptureService.swift](../ios/Babble/babble/Services/AudioCaptureService.swift)

When monitoring starts, `AVAudioEngine` opens a tap on the microphone input.
Every ~85 milliseconds it delivers a chunk of audio called a **buffer**
(4096 audio samples at 48,000 samples/second ≈ 85ms of sound).

Every single buffer goes through `handleBuffer()`:

```
microphone → handleBuffer() called ~12 times per second
```

Inside `handleBuffer`, three things always happen unconditionally:

1. **Ring buffer write** — the buffer is always saved into a 12-second rolling
   window. This is so that when a trigger fires, we can reach back in time and
   include audio from *before* the trigger. Think of it like a dashcam that
   is always overwriting the last 12 seconds.

2. **Post-capture write** — if a recording is currently active, the raw audio
   samples are also written into the clip being built.

3. **VAD gate check** — described next.

---

## Step 2 — The VAD gate (Voice Activity Detection)

**File:** [AudioCaptureService.swift](../ios/Babble/babble/Services/AudioCaptureService.swift) — `speechBandRMS()`, `handleBuffer()`

Before forwarding audio to any ML pipeline, we ask: *is anyone actually
talking right now?*

### Why this matters

A nursery is never truly silent. White noise machines, fans, and AC units
produce constant broadband noise. Without this gate, `SFSpeechRecognizer` and
`SNAudioStreamAnalyzer` (both heavy ML models) would run 24/7. That drains
the battery, heats the phone, and gets the app killed by iOS for excessive
CPU use.

### How it works — two parts

**Part A: Speech-band filter**

A plain loudness check (broadband RMS) would be fooled by a white noise
machine — it's loud but has no speech in it. So instead we first run the audio
through a **high-pass filter** set at 300 Hz.

A high-pass filter is exactly what it sounds like: it lets high frequencies
pass through and blocks low ones. Human speech lives between roughly 300 Hz
and 3400 Hz. White noise machines, fans, and AC hum are concentrated below
300 Hz. After filtering, we measure loudness (RMS = root mean square, a
standard way to measure average signal level).

```
Raw buffer
    │
    ▼
[300 Hz high-pass biquad filter] — strip low-frequency noise
    │
    ▼
Measure RMS loudness of what's left
    │
    ├── above threshold (0.005 ≈ -46 dBFS) → someone is probably talking
    └── below threshold → silent or only background noise
```

The filtered signal is used *only* for this gate decision. The original
unmodified audio is what gets sent to the speech recognizer — we don't want
to feed filtered audio to a model that expects natural sound.

The filter itself uses coefficients calculated from the
[Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) formula for a
2nd-order Butterworth high-pass filter. The math produces five numbers
`[b0, b1, b2, a1, a2]` that `vDSP_biquad` (Apple's hardware-accelerated DSP
library) applies to every sample in the buffer.

**Part B: Hysteresis (hold-open)**

If we closed the gate the instant loudness dropped, brief natural pauses
between words would chop the audio stream. The recognizer would see:
`"Oli...ver"` instead of `"Oliver"`.

So instead, once speech energy is detected, we hold the gate open for
5 more buffers (~425ms) after energy drops. `silenceHoldCount` counts down:

```
Energy detected  → silenceHoldCount = 5  → gate open
Next buffer quiet → silenceHoldCount = 4  → still open
Next buffer quiet → silenceHoldCount = 3  → still open
...
silenceHoldCount = 0 → gate closes
```

**Part C: Silence pause in WakeWordService**

There's a complementary mechanism in `WakeWordService`. If the VAD gate
blocks audio for 10 full seconds (a sustained quiet period — baby is sleeping,
nobody is talking), the `SFSpeechRecognizer` task is cancelled entirely.
When audio resumes, a fresh task starts. This saves even more CPU during
genuinely quiet periods.

---

## Step 3 — Two trigger paths

Once audio passes the VAD gate it goes to two detectors running in parallel.
Either one can trigger a recording.

```
Buffer passes VAD gate
        │
        ├──→ WakeWordService   (baby's name spoken)
        │
        └──→ CryDetector       (baby is crying)
```

### Trigger path A — Wake word (baby's name)

**File:** [WakeWordService.swift](../ios/Babble/babble/Services/WakeWordService.swift)

**What it does:** Listens continuously for the baby's name (e.g. "Oliver")
to be spoken anywhere in the room.

**How it works:**

Apple's `SFSpeechRecognizer` converts live audio into text in real time. It's
the same engine that powers Siri dictation. With `requiresOnDeviceRecognition`
set, the entire speech model runs locally on the iPhone's Neural Engine — no
audio is sent to Apple's servers.

`shouldReportPartialResults = true` means the recognizer fires its callback
on every word as it's recognized, not just at sentence end. This gives
near-real-time detection.

Every time a partial transcript arrives, `checkForWakeWord()` runs:

```swift
lower.contains(babyName)
```

That's the whole detection — a simple string contains check. If the baby's
name appears anywhere in the running transcript, it's a hit.

Two guards prevent false triggers:

- **Cooldown:** once triggered, won't fire again for 60 seconds. Prevents the
  same utterance from triggering multiple recordings.
- **Case-insensitive:** "Oliver", "oliver", and "OLIVER" all match.

**The 55-second restart problem:**

Apple hard-expires `SFSpeechRecognitionTask` at ~60 seconds — the task simply
stops working. To prevent a gap in detection, a repeating timer fires every
55 seconds and starts a fresh task, 5 seconds before Apple would kill the
old one. If a task ends for any other reason (error, device interrupt), the
completion handler starts a new one automatically with a 0.1s delay.

**Partial transcript feed:**

While a recording is active, every interim result also fires `onPartialTranscript`.
This streams the live speech text back to `AudioCaptureService` so it can
accumulate a richer transcript to include with the clip — and to power the
early-abort check described below.

**Timeline of a WakeWordService session:**

```
start() called
  ├─ startTask()       ← recognition task begins
  └─ scheduleRestart() ← 55s timer ticking

every ~85ms buffer via appendBuffer():
  ├─ reset 10s silence timer
  └─ append to recognitionRequest
       └─ recognizer fires callback
            ├─ checkForWakeWord() → name found + cooldown ok? → TRIGGER
            └─ onPartialTranscript() → live text to AudioCaptureService

at 10s of no audio:
  └─ cancelTask()  ← recognizer sleeps

next buffer arrives:
  └─ isPaused = true → startTask()  ← recognizer wakes

every 55s:
  └─ startTask()  ← task recycled
```

---

### Trigger path B — Cry detection

**File:** [CryDetector.swift](../ios/Babble/babble/Services/CryDetector.swift)

**What it does:** Detects infant crying using Apple's `SoundAnalysis`
framework (`SNAudioStreamAnalyzer`). This runs a trained neural network
that classifies ambient sound into categories — one of which is infant crying.

**How it works:**

`SNClassifySoundRequest` with `.version1` loads Apple's on-device sound
classifier. Every time it processes audio it produces confidence scores for
hundreds of sound categories. We watch for three identifiers:
`"infant_cry"`, `"baby_cry"`, and `"crying"`.

If any of those scores exceeds **0.85 confidence** (85%), `onCryDetected`
fires.

**Throttling:**

`SNAudioStreamAnalyzer` runs a full neural network — it's the most expensive
thing in the whole pipeline. But crying lasts seconds, not milliseconds.
There's no need to run it on every buffer. So it only processes every 5th
buffer (`cryAnalysisInterval = 5`), giving ~2 analyses per second. This cuts
CPU cost by ~80% with no meaningful impact on detection accuracy.

```
Buffer 1 → skip
Buffer 2 → skip
Buffer 3 → skip
Buffer 4 → skip
Buffer 5 → analyze (neural net runs)
Buffer 6 → skip
...
```

The same 60-second cooldown applies to cry triggers to prevent one crying
episode from generating multiple clips.

---

## Step 4 — The capture window opens

**File:** [AudioCaptureService.swift](../ios/Babble/babble/Services/AudioCaptureService.swift) — `triggerCapture()`

When either detector fires, `AudioCaptureService.triggerCapture()` is called.
This starts building the audio clip that will eventually be sent to the backend.

**Pre-capture (the ring buffer):**
The ring buffer has been silently recording the last 12 seconds the whole
time. When triggered, we immediately snapshot the last **10 seconds** from
it. This means the clip starts *before* the trigger — capturing whatever was
said just before the baby's name was mentioned or the cry started.

**Post-capture:**
After the trigger, the service continues recording for up to **30 seconds**
of new audio. A timer counts down from 30s. If the baby's name is spoken
again before the timer expires, the timer resets — the window extends to
capture the full conversation. The absolute maximum is 90 seconds.

```
                    TRIGGER FIRES HERE
                           │
──────────────────────────[│]────────────────────────────────────
        ←── 10s pre ──────[│]──────── up to 30s post ──────────→
                           │
                     clip starts here
```

The clip = pre-capture audio + post-capture audio, encoded as a WAV file.

---

## Step 5 — Early-abort check (mid-capture)

**File:** [AudioCaptureService.swift](../ios/Babble/babble/Services/AudioCaptureService.swift) — `wirePartialTranscript()`

The wake word might have been a false positive. Someone said a name that
sounds like the baby's name, or the speech recognizer misheard something.
We don't want to wait the full 30 seconds to find out.

After **10 seconds** of capture, the live partial transcript accumulated from
`onPartialTranscript` is checked against `TranscriptFilter.shouldAnalyze()`.

If the check returns `false` — meaning the conversation contains no
baby-related words and doesn't look like a caregiver talking about the baby —
`abortCapture()` is called immediately:

- The timer is cancelled
- The audio buffer is discarded
- No clip is sent anywhere
- Crucially: **no cooldown is applied.** It was a false positive, so the
  detector stays ready to fire immediately again.

```
Trigger fires → capture starts
    │
    │ 10 seconds pass
    │
    ▼
Is the live transcript baby-related?
    │
    ├── yes → keep recording, wait for 30s window
    │
    └── no  → abort now, discard audio, stay ready
```

---

## Step 6 — TranscriptFilter (local relevance gate)

**File:** [TranscriptFilter.swift](../ios/Babble/babble/Utilities/TranscriptFilter.swift)

`TranscriptFilter.shouldAnalyze()` is a pure on-device rule engine. No
network, no ML, no cost. It runs instantly. It is called in two places:
- **During capture** (the early-abort check at 10s)
- **After capture** (final check on the completed clip before calling the backend)

The rules run in order and return `true` (send to backend) or `false` (drop):

| Rule | Condition | Result |
|---|---|---|
| 1 | Trigger was a cry | Always pass — the cry is the event |
| 2 | Transcript is empty | Drop |
| 3 | Fewer than 2 words | Drop |
| 4 | Only filler words ("um", "uh", "okay", "yeah") | Drop |
| 5 | Baby's name appears in transcript | Pass |
| 6 | Any keyword from 12 categories matches | Pass |
| 7 | 8+ words AND contains "he/she/they/the baby" | Pass |
| — | Nothing matched | Drop |

The 12 keyword categories cover:

- **Feeding** — bottle, nursing, formula, latch, burp, spit up, solids, reflux…
- **Sleep** — nap, bedtime, crib, overtired, regression, woke up, went down…
- **Diapers** — poop, wet, change, blowout, rash, green poop, blood in stool…
- **Health** — fever, medicine, doctor, vaccine, rash, cough, teething, RSV…
- **Skin** — eczema, hives, jaundice, cradle cap, drool rash, swelling…
- **Milestones** — smiled, crawled, first time, new skill, trying to…
- **Speech** — babbling, said mama, first word, cooing…
- **Emotion** — fussy, inconsolable, calm, clingy, overstimulated…
- **Activity** — tummy time, stroller, daycare, swing, reading…
- **Growth** — ounces, percentile, growth spurt, weighed…
- **Hygiene** — bath, washing…
- **Caregiver phrases** — "this morning", "last night", "won't stop", "seemed"…

---

## Step 7 — Clip sent to the backend

**File:** [MonitorViewModel.swift](../ios/Babble/babble/ViewModels/MonitorViewModel.swift) — `handleClip()`

If both filter checks pass, the WAV clip is sent to the backend in two steps:

### Step 7a — Diarize

The audio is sent to `/diarize`. This step:
- Transcribes the full clip accurately
- Identifies who is speaking at each moment (speaker diarization)
- Returns an **annotated transcript** like:
  ```
  [Speaker A 0.0–4.2s] She had a really long nap today
  [Speaker B 4.5–7.1s] Yeah she went down at two and slept until four
  ```

The raw interim transcript from `WakeWordService` is included as context to
help the transcription — but the diarized version is what goes forward.

### Step 7b — Analyze (Gemini)

The annotated transcript is sent to `/analyze` along with:
- **10-minute context** — a rolling buffer of the last 10 minutes of
  annotated transcripts from previous clips. This lets Gemini understand
  conversation continuity ("she" in the current clip refers to the baby
  mentioned by name 3 minutes ago).
- **Trigger hint** — `"name"`, `"cry"`, or `"manual"` — tells Gemini what
  caused this clip to be captured.
- **Baby profile** — name and age in months, so Gemini can evaluate
  observations in the correct developmental context.
- **Date string** — for attaching events to the correct day.

Gemini returns structured events (feed logged, nap logged, milestone noted,
etc.) and corrections to existing events. These are applied to the local
event store.

---

## Step 8 — State machine

**File:** [MonitorViewModel.swift](../ios/Babble/babble/ViewModels/MonitorViewModel.swift)

`MonitorViewModel` orchestrates everything and owns a simple state machine
that drives the UI:

| State | Meaning |
|---|---|
| `idle` | Monitoring is off |
| `listening` | Mic is on, detectors are running, nothing triggered yet |
| `wakeDetected` | Trigger just fired — brief visual flash (~0.3s) |
| `capturing` | Recording the clip window |
| `analyzing` | Clip sent, waiting for backend response |
| `recording` | Parent is holding the manual record button |
| `error(String)` | Something failed (mic permission, etc.) |

Normal happy path:

```
idle → listening → wakeDetected → capturing → analyzing → listening
```

False positive path (early abort or filter drop):

```
listening → wakeDetected → capturing → [abort or filter drop] → listening
```

Manual recording path:

```
listening → recording → analyzing → listening
```

---

## Manual recording

Parents can press and hold a button to record a voice note at any time,
bypassing the wake word and cry detection entirely. This goes through the
same TranscriptFilter → diarize → Gemini pipeline, but with a `"manual"`
trigger hint. Two modes exist: `"edit"` (correct a logged event) and
`"support"` (ask a question, get a reply).

---

## All the tuning knobs

All timing and threshold constants live in
[Constants.swift](../ios/Babble/babble/Utilities/Constants.swift):

| Constant | Value | What it controls |
|---|---|---|
| `silenceThreshold` | 0.005 (-46 dBFS) | Minimum speech-band energy to pass the VAD gate |
| `silenceHoldBuffers` | 5 (~425ms) | How long the gate stays open after energy drops |
| `cryConfidenceThreshold` | 0.85 (85%) | Minimum cry confidence score to trigger |
| `cryAnalysisInterval` | 5 buffers | How often the cry neural net runs (~2 Hz) |
| `triggerCooldownSeconds` | 60s | Minimum gap between triggers (both name and cry) |
| `speechTaskRestartSeconds` | 55s | How often SFSpeechRecognizer task is recycled |
| `ringBufferSeconds` | 12s | How much audio the ring buffer holds |
| `preCaptureSeconds` | 10s | How much pre-trigger audio is included in the clip |
| `postCaptureSeconds` | 30s | How long post-trigger recording continues |
| `maxCaptureSeconds` | 90s | Hard cap on clip length |
| `earlyAbortCheckSeconds` | 10s | When to run the mid-capture relevance check |

---

## Full flow in one diagram

```
App opens → startMonitoring()
    ├─ request mic permission
    ├─ request speech recognition permission
    ├─ start WakeWordService (SFSpeechRecognizer, 55s restart loop)
    └─ start AudioCaptureService (AVAudioEngine tap, ring buffer, VAD)

Every ~85ms buffer:
    │
    ├─ [always] write to 12s ring buffer
    ├─ [if capturing] write to clip buffer
    │
    ├─ run 300 Hz high-pass filter → measure speech-band RMS
    │       │
    │       ├─ below threshold AND holdCount=0 → STOP HERE (silent)
    │       └─ above threshold OR holdCount>0  → continue
    │
    ├─→ WakeWordService
    │       └─ SFSpeechRecognizer (on-device, partial results)
    │               └─ every word: checkForWakeWord()
    │                       └─ name found + cooldown ok?
    │                               └─ TRIGGER → triggerCapture()
    │
    └─→ CryDetector (every 5th buffer only)
            └─ SNAudioStreamAnalyzer neural net
                    └─ confidence ≥ 85%?
                            └─ TRIGGER → triggerCapture()

triggerCapture() fires:
    ├─ snapshot 10s from ring buffer (pre-capture)
    ├─ start 30s post-capture window
    └─ start streaming onPartialTranscript callbacks

At 10s into capture:
    └─ TranscriptFilter.shouldAnalyze(partial transcript)?
            ├─ no  → abortCapture() — discard, no cooldown, stay ready
            └─ yes → keep recording

At 30s (or max 90s):
    └─ flushClip() → WAV file ready
            └─ TranscriptFilter.shouldAnalyze(full transcript)?
                    ├─ no  → drop clip, back to listening
                    └─ yes → send to backend
                                ├─ POST /diarize → annotated transcript
                                └─ POST /analyze → Gemini
                                        └─ events logged to event store
                                                └─ back to listening
```
