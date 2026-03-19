"""Babble — FastAPI backend (iOS redesign).

Endpoints:
  POST /diarize                  — audio + raw transcript → speaker-annotated transcript
  POST /check-relevance          — transcript text → is it baby-relevant?
  POST /analyze                  — annotated transcript → Gemini events + corrections
  POST /voice-note               — manual recording → edit or emotional support
  GET  /events                   — events for a date
  PATCH /events/{id}             — update an event
  DELETE /events/{id}            — delete an event
  POST /summary/generate         — generate daily summary
  GET  /summary                  — get cached summary
  POST /speakers/enroll          — audio segment + label → store voice embedding
  GET  /speakers                 — list all speaker profiles
  PATCH /speakers/{id}           — rename a speaker
  DELETE /speakers/{id}          — remove a speaker
  GET  /health                   — health check
"""

import base64
import logging
import os
from datetime import datetime, timezone, timedelta

from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

import db
import gemini_client
import diarization

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Babble", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def startup():
    await db.init_db()
    logger.info("Database initialized")


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "ok", "version": "2.0.0"}


# ---------------------------------------------------------------------------
# Diarize
# ---------------------------------------------------------------------------

class DiarizeRequest(BaseModel):
    audio_base64: str
    audio_mime_type: str = "audio/wav"
    raw_transcript: str
    word_timestamps: list[dict] | None = None


@app.post("/diarize")
async def diarize_audio(req: DiarizeRequest):
    audio_bytes = base64.b64decode(req.audio_base64)
    known_speakers = await db.get_speaker_embeddings()
    result = diarization.diarize(
        audio_bytes=audio_bytes,
        raw_transcript=req.raw_transcript,
        known_speakers=known_speakers,
        word_timestamps=req.word_timestamps,
    )
    return result


# ---------------------------------------------------------------------------
# Relevance check
# ---------------------------------------------------------------------------

class RelevanceRequest(BaseModel):
    transcript: str
    baby_name: str
    baby_age_months: int


@app.post("/check-relevance")
async def check_relevance(req: RelevanceRequest):
    result = gemini_client.check_relevance(
        transcript=req.transcript,
        baby_name=req.baby_name,
        baby_age_months=req.baby_age_months,
    )
    return result


# ---------------------------------------------------------------------------
# Analyze
# ---------------------------------------------------------------------------

class AnalyzeRequest(BaseModel):
    transcript: str
    transcript_last_10min: str = ""
    trigger_hint: str = "name"       # "name" | "cry" | "manual"
    baby_name: str
    baby_age_months: int
    clip_timestamp: str = ""         # ISO 8601 — when trigger fired
    date_str: str = ""               # YYYY-MM-DD; defaults to today


@app.post("/analyze")
async def analyze(req: AnalyzeRequest):
    date_str = req.date_str or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    clip_ts = req.clip_timestamp or datetime.now(timezone.utc).isoformat()

    # Events from the last 10 minutes for correction context
    ten_min_ago = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
    events_last_10min = await db.get_events_since(date_str, ten_min_ago)

    result = gemini_client.analyze_from_transcript(
        transcript=req.transcript,
        transcript_last_10min=req.transcript_last_10min,
        baby_name=req.baby_name,
        baby_age_months=req.baby_age_months,
        clip_timestamp=clip_ts,
        trigger_hint=req.trigger_hint,
        events_last_10min=events_last_10min,
    )

    # Persist new events
    inserted_ids = await db.add_events(result["new_events"], date_str)
    for i, ev in enumerate(result["new_events"]):
        if i < len(inserted_ids):
            ev["id"] = inserted_ids[i]

    # Apply corrections
    corrections_applied = await db.apply_corrections(result["corrections"])

    return {
        "new_events": result["new_events"],
        "corrections": result["corrections"],
        "corrections_applied": corrections_applied,
        "usage": result["usage"],
    }


# ---------------------------------------------------------------------------
# Voice note
# ---------------------------------------------------------------------------

class VoiceNoteRequest(BaseModel):
    audio_base64: str
    audio_mime_type: str = "audio/wav"
    mode: str = "edit"               # "edit" | "support"
    baby_name: str
    baby_age_months: int
    date_str: str = ""


@app.post("/voice-note")
async def voice_note(req: VoiceNoteRequest):
    date_str = req.date_str or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    audio_bytes = base64.b64decode(req.audio_base64)

    # Transcribe via diarization (get clean annotated transcript)
    known_speakers = await db.get_speaker_embeddings()
    # For voice notes, use basic diarization (no word timestamps from iOS here)
    diar_result = diarization.diarize(
        audio_bytes=audio_bytes,
        raw_transcript="",
        known_speakers=known_speakers,
    )
    transcript = diar_result.get("annotated_transcript", "")

    events_today = await db.get_events(date_str) if req.mode == "edit" else None

    result = gemini_client.process_voice_note(
        transcript=transcript,
        mode=req.mode,
        baby_name=req.baby_name,
        baby_age_months=req.baby_age_months,
        events_today=events_today,
    )

    if req.mode == "edit" and result.get("new_events"):
        inserted_ids = await db.add_events(result["new_events"], date_str)
        for i, ev in enumerate(result["new_events"]):
            if i < len(inserted_ids):
                ev["id"] = inserted_ids[i]
    if req.mode == "edit" and result.get("corrections"):
        await db.apply_corrections(result["corrections"])

    return result


# ---------------------------------------------------------------------------
# Events CRUD
# ---------------------------------------------------------------------------

@app.get("/events")
async def get_events(date: str = ""):
    date_str = date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    events = await db.get_events(date_str)
    return {"events": events, "date": date_str}


@app.patch("/events/{event_id}")
async def update_event(event_id: str, body: dict):
    fields = body.get("fields", body)
    await db.update_event(event_id, fields)
    return {"status": "updated", "id": event_id}


@app.delete("/events/{event_id}")
async def delete_event(event_id: str):
    await db.delete_event(event_id)
    return {"status": "deleted", "id": event_id}


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

class SummaryRequest(BaseModel):
    baby_name: str
    baby_age_months: int
    date_str: str = ""


@app.post("/summary/generate")
async def generate_summary(req: SummaryRequest):
    date_str = req.date_str or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    events = await db.get_events(date_str)
    summary = gemini_client.generate_summary(
        events=events,
        baby_name=req.baby_name,
        baby_age_months=req.baby_age_months,
        date_str=date_str,
    )
    await db.set_summary(summary, date_str)
    return {"summary": summary, "date": date_str}


@app.get("/summary")
async def get_summary(date: str = ""):
    date_str = date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    summary = await db.get_summary(date_str)
    return {"summary": summary, "date": date_str}


# ---------------------------------------------------------------------------
# Speaker profiles
# ---------------------------------------------------------------------------

class EnrollRequest(BaseModel):
    audio_base64: str
    label: str
    speaker_id: str | None = None    # if updating an existing profile


@app.post("/speakers/enroll")
async def enroll_speaker(req: EnrollRequest):
    audio_bytes = base64.b64decode(req.audio_base64)
    embedding_bytes = diarization.extract_embedding(audio_bytes)
    if embedding_bytes is None:
        raise HTTPException(status_code=422, detail="Could not extract voice embedding (pyannote unavailable)")
    result = await db.upsert_speaker(
        label=req.label,
        embedding=embedding_bytes,
        speaker_id=req.speaker_id,
    )
    return result


@app.get("/speakers")
async def list_speakers():
    speakers = await db.get_speakers()
    return {"speakers": speakers}


@app.patch("/speakers/{speaker_id}")
async def rename_speaker(speaker_id: str, body: dict):
    label = body.get("label")
    if not label:
        raise HTTPException(status_code=422, detail="label is required")
    await db.rename_speaker(speaker_id, label)
    return {"status": "updated", "id": speaker_id}


@app.delete("/speakers/{speaker_id}")
async def delete_speaker(speaker_id: str):
    await db.delete_speaker(speaker_id)
    return {"status": "deleted", "id": speaker_id}
