# Babble 🍼

Passive baby activity monitor with AI. Built for the Gemini Live Agent Challenge.

Passively listens to a baby's environment via phone mic → detects feeding, naps, crying,
milestones, observations → generates a daily summary → voice-edit with Gemini Live.

## Architecture

```
Phone PWA (HTML/JS — no framework)
├── VAD + MediaRecorder → webm/opus clips → POST /analyze (FIFO queue, sequential)
├── Poll GET /events every 3s → live event list with green flash on new items
├── [Edit Log] → WS /ws/voice/edit-log → Gemini Live (log editor)
├── [Summary] → GET /summary → Summary screen
│   └── [Talk to Gemini] → WS /ws/voice/companion → Gemini Live (warm companion)
└── [Share] → Social card → twitter.com/intent/tweet

Backend (FastAPI / Cloud Run)
├── POST /analyze → Gemini 2.5 Flash (audio) → Firestore → auto-summarize
├── GET  /events, PATCH /events/:id, DELETE /events/:id
├── POST /summary/generate, GET /summary
├── WS   /ws/voice/edit-log   — Gemini Live: log editor
└── WS   /ws/voice/companion  — Gemini Live: warm parenting companion

Firestore
└── days/{YYYY-MM-DD}/
    ├── events/{event_id}: {type, timestamp, detail, confidence, notable}
    └── summary: {structured, narrative, social_tweet, generated_at}
```

## Local Development

### Prerequisites
- Python 3.12+
- Google Cloud project with Firestore enabled
- Gemini API key (from Google AI Studio or GCP)

### Setup

```bash
cd babble/backend
pip install -r requirements.txt

# Create .env from example
cp ../.env.example ../.env
# Edit .env: add your GOOGLE_API_KEY and GOOGLE_CLOUD_PROJECT

# Authenticate with GCP (if using ADC instead of API key)
gcloud auth application-default login

# Run locally
uvicorn main:app --reload --port 8080
```

Open `http://localhost:8080/static/index.html` in your browser (or just `http://localhost:8080/static/`).

For the PWA mic to work on iPhone/Android, you need HTTPS. Use Cloud Run or ngrok for phone testing:
```bash
ngrok http 8080
# Use the ngrok HTTPS URL on your phone
```

## Google Cloud Setup

```bash
# 1. Create project
gcloud projects create babble-demo --name="Babble"
gcloud config set project babble-demo

# 2. Enable billing (required for Cloud Run + Firestore)
# Do this in the GCP Console: https://console.cloud.google.com/billing

# 3. Enable APIs
gcloud services enable \
  run.googleapis.com \
  firestore.googleapis.com \
  aiplatform.googleapis.com

# 4. Create Firestore database (Native mode)
gcloud firestore databases create --location=us-central1

# 5. Build and deploy to Cloud Run
gcloud builds submit --tag gcr.io/babble-demo/babble .
gcloud run deploy babble \
  --image gcr.io/babble-demo/babble \
  --platform managed \
  --region us-central1 \
  --allow-unauthenticated \
  --set-env-vars GOOGLE_CLOUD_PROJECT=babble-demo,FIRESTORE_PROJECT_ID=babble-demo,GOOGLE_API_KEY=your-key-here
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `GOOGLE_API_KEY` | Yes | Gemini API key from AI Studio |
| `GOOGLE_CLOUD_PROJECT` | Yes | GCP project ID |
| `FIRESTORE_PROJECT_ID` | Yes | Same as GOOGLE_CLOUD_PROJECT |

## Demo Script

1. Open PWA on phone, enter baby name "Luca", age 10 months
2. Say near phone: "Luca just had his lunch — he loved the broccoli"
3. Mic icon pulses → event appears in log within ~5s
4. Say: "Luca said mama for the first time!" → milestone event with ✨
5. Tap "Summary →" → full day narrative auto-generated
6. Tap "Talk to Gemini" → voice companion celebrates the milestone
7. Tap "Share" → social card with baby-voice tweet → "Share to Twitter/X"

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | Plain HTML/CSS/JS PWA (no framework) |
| Backend | Python (FastAPI) |
| AI (passive) | Gemini 2.5 Flash (audio input) |
| AI (voice) | Gemini Live API |
| Storage | Firestore (Google Cloud) |
| Hosting | Google Cloud Run |
