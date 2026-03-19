# Babble iOS App

Native iOS app for the Babble baby activity monitor.

## Architecture

```
iOS App (SwiftUI + AVFoundation + Speech + SoundAnalysis)
  ├── Passive listening: AVAudioEngine → 12s ring buffer
  ├── Wake word: SFSpeechRecognizer (baby's name)
  ├── Cry detection: Apple SoundAnalysis (infant_cry)
  ├── Noise reduction: High-pass EQ (in-graph) + RNNoise (post-capture)
  └── POST /diarize → POST /check-relevance → POST /analyze → display events

FastAPI Backend
  ├── Speaker diarization (pyannote.audio, optional)
  ├── Gemini 2.5 Flash — text-only analysis from transcript
  └── SQLite (babble.db) — replaces Firestore
```

## Xcode Setup

1. Open Xcode → **File → New → Project** → iOS App
   - Product Name: `Babble`
   - Interface: SwiftUI
   - Language: Swift
   - Bundle ID: `com.yourname.babble`

2. Add all Swift files from this folder to the Xcode target.

3. In **Info.plist**, ensure these keys are present (already in `Info.plist`):
   - `NSMicrophoneUsageDescription`
   - `NSSpeechRecognitionUsageDescription`
   - `UIBackgroundModes → [audio]`

4. In **Signing & Capabilities**, add the **Background Modes** capability and check **Audio, AirPlay, and Picture in Picture**.

## Optional: RNNoise

For full noise suppression:

```bash
git clone https://github.com/xiph/rnnoise
cd rnnoise
autoreconf -fi
./configure
make
```

1. Add `librnnoise.a` to the Xcode target (Build Phases → Link Binary)
2. Add `rnnoise.h` to the project
3. Create `Babble-Bridging-Header.h`:
   ```c
   #include "rnnoise.h"
   ```
4. Set `Objective-C Bridging Header` in Build Settings

## Optional: pyannote.audio (Speaker Diarization)

```bash
pip install pyannote.audio torch
```

Set `HUGGINGFACE_TOKEN` in `.env` (requires accepting pyannote usage terms at huggingface.co/pyannote).

Without pyannote, diarization returns unannotated transcripts — the app still works fully.

## Backend

```bash
cd ../backend
pip install -r requirements.txt
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

Set `GOOGLE_API_KEY` in `.env`.

For on-device testing, use ngrok to expose localhost:
```bash
ngrok http 8000
```
Enter the ngrok URL in the app's Settings → Backend URL.
