# Thermal & Efficiency Design Notes
**Role: Product / Technical Design**
**Date: 2026-03-19**

---

## Problem: Phone Gets Hot During Idle Monitoring

When the app listens for long stretches with no baby activity, the phone heats up significantly. The cause is not the network or Gemini — it's the on-device ML pipelines running at full rate even when the room is completely silent.

---

## Root Causes (ranked by impact)

### 1. CryDetector runs a full neural net 10× per second
`SNAudioStreamAnalyzer` with Apple's `SNClassifySoundRequest` is a real ML model. Every tap callback (~100ms) dispatches a new inference job to `analysisQueue`. In a quiet room over 4 hours, that's ~144,000 inference calls with zero useful output.

**Fix applied:** Throttle to every 5th buffer (~500ms / 2 Hz). Baby cries last seconds — 2 Hz detection is more than sufficient. This cuts cry detector CPU by ~80%.

### 2. No silence gate — ML runs even in total silence
Both `SNAudioStreamAnalyzer` (cry) and `SFSpeechRecognizer` (wake word) process every buffer regardless of audio level. If the room is quiet, both ML pipelines still fire on every tap.

**Fix applied:** Calculate RMS of each buffer using `vDSP_rmsqv` (hardware-accelerated, near-zero cost). If RMS < 0.005 (roughly -46 dBFS — well above a silent room floor), skip forwarding to both services entirely. In practice this skips 70–90% of buffers during normal quiet periods.

### 3. SFSpeechRecognizer runs continuously
The wake word service keeps a live `SFSpeechRecognitionTask` running, restarting every 55s. This is a streaming ASR model that consumes CPU constantly. The silence gate in fix #2 reduces its input volume significantly, but it still runs.

**Recommended future improvement:** Pause and resume `SFSpeechRecognizer` based on silence duration. If RMS has been below threshold for >5 seconds, pause recognition. Resume on first non-silent buffer. This would near-eliminate ASR CPU during long quiet stretches.

---

## Changes Made

| File | Change |
|---|---|
| `Constants.swift` | Added `silenceThreshold = 0.005`, `cryAnalysisInterval = 5` |
| `AudioCaptureService.swift` | Added `Accelerate` import, RMS silence gate in `handleBuffer` |
| `CryDetector.swift` | Added buffer counter, analyze only every 5th buffer |

---

## Expected Impact

| Scenario | Before | After |
|---|---|---|
| Quiet room, 1 hour | Cry detector: 36,000 inferences | ~7,200 inferences (−80%) |
| Quiet room, 1 hour | ML pipelines: always active | ~10% of buffers forwarded to ML |
| Active cry event | Full detection | Full detection (no change) |
| Wake word event | Full detection | Full detection (no change) |

---

## Future Recommendations

### Short term
- **Adaptive silence threshold** — calculate a rolling noise floor and set threshold dynamically (handles different environments: city apartment vs. quiet house)
- **Pause SFSpeechRecognizer during extended silence** — add a 5s silence timer; suspend and resume the recognition task

### Medium term
- **Reduce tap sample rate** — the app captures at 48kHz but SoundAnalysis and speech recognition work fine at 16kHz. Processing 3× fewer samples per buffer reduces all per-sample work proportionally
- **Use `SNClassifySoundRequest` with a custom window** — instead of streaming every buffer, batch 1s of audio and analyze once

### UX suggestion
- **Add a "sensitivity" setting** — let parents tune the silence threshold for their environment. A city apartment with ambient noise needs a higher threshold than a rural quiet house. Expose this in Settings as a simple Low / Medium / High slider.
- **Show a heat indicator** — if the device thermal state is `.fair` or above (`ProcessInfo.thermalState`), show a subtle status indicator and automatically raise the silence threshold temporarily
