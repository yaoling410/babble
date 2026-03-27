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

import asyncio
import base64
import functools
import logging
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone, timedelta

from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI, HTTPException, Request
from google.genai.errors import ClientError as GeminiClientError
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

import db
import gemini_client
import diarization

# ---------------------------------------------------------------------------
# Logging setup — structured output to both console and a rolling log file.
# Log file: /tmp/babble_backend.log  (tail -f to monitor live)
# ---------------------------------------------------------------------------
_LOG_FILE = "/tmp/babble_backend.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(name)s | %(message)s",
    datefmt="%H:%M:%S",
)
_file_handler = logging.FileHandler(_LOG_FILE)
_file_handler.setFormatter(logging.Formatter(
    "%(asctime)s %(levelname)-8s %(name)s | %(message)s",
    datefmt="%H:%M:%S",
))
logging.getLogger().addHandler(_file_handler)

logger = logging.getLogger(__name__)

# In-memory speaker cache — avoids a DB query on every diarize request
_speaker_cache: list[dict] | None = None


def _invalidate_speaker_cache():
    global _speaker_cache
    _speaker_cache = None


async def _get_speakers_cached() -> list[dict]:
    global _speaker_cache
    if _speaker_cache is None:
        _speaker_cache = await db.get_speaker_embeddings()
    return _speaker_cache


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.init_db()
    logger.info("Database initialized")
    diarization._load_pipeline()   # pre-warm heavy model at startup, not on first request
    yield


app = FastAPI(title="Babble", version="2.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def _log_requests(request: Request, call_next):
    """Log every request with method, path, status code, and wall-clock duration."""
    t0 = time.monotonic()
    logger.info("→ %s %s", request.method, request.url.path)
    response = await call_next(request)
    ms = (time.monotonic() - t0) * 1000
    logger.info("← %s %s %d  %.0fms", request.method, request.url.path, response.status_code, ms)
    return response


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "ok", "version": "2.0.0"}


# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------

@app.get("/cost")
async def get_cost(date: str = ""):
    """Return accumulated Gemini token usage and cost for a date (default: today UTC)."""
    return gemini_client.get_daily_usage(date or None)


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
    known_speakers = await _get_speakers_cached()
    logger.info("[DIARIZE] audio=%.1fKB transcript=%dw speakers_known=%d",
                len(audio_bytes) / 1024, len(req.raw_transcript.split()), len(known_speakers))
    # pyannote is CPU-intensive and synchronous — run in a thread pool so
    # FastAPI's event loop stays free to handle other requests while it runs.
    loop = asyncio.get_event_loop()
    result = await loop.run_in_executor(
        None,
        functools.partial(
            diarization.diarize,
            audio_bytes=audio_bytes,
            raw_transcript=req.raw_transcript,
            known_speakers=known_speakers,
            word_timestamps=req.word_timestamps,
        ),
    )
    logger.info("[DIARIZE] done segments=%d", len(result.get("segments", [])))
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

    logger.info("[ANALYZE] trigger=%s transcript=%dw context=%dw baby=%s/%dmo",
                req.trigger_hint, len(req.transcript.split()),
                len(req.transcript_last_10min.split()), req.baby_name, req.baby_age_months)

    # Events from the last 10 minutes for correction context
    ten_min_ago = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
    events_last_10min = await db.get_events_since(date_str, ten_min_ago)

    try:
        result = gemini_client.analyze_from_transcript(
            transcript=req.transcript,
            transcript_last_10min=req.transcript_last_10min,
            baby_name=req.baby_name,
            baby_age_months=req.baby_age_months,
            clip_timestamp=clip_ts,
            trigger_hint=req.trigger_hint,
            events_last_10min=events_last_10min,
        )
    except GeminiClientError as e:
        status = e.status_code if hasattr(e, "status_code") else 500
        logger.warning("[ANALYZE] Gemini error %d: %s", status, str(e)[:200])
        raise HTTPException(status_code=status, detail=str(e))

    usage = result["usage"]
    logger.info("[ANALYZE] relevant=%s events=%d past_events=%d tokens in=%d out=%d",
                result["relevant"], len(result["new_events"]), len(result["past_events"]),
                usage.get("input_tokens", 0), usage.get("output_tokens", 0))
    for line in result.get("transcript", []):
        logger.info("[TRANSCRIPT] %ss %s: %s",
                    line.get("ts", "?"), line.get("speaker", "?"), line.get("text", ""))
    for ev in result["new_events"]:
        logger.info("[ANALYZE]   + [%s] %s — %s (%s)",
                    ev.get("status", "?"), ev.get("type"), ev.get("description", "")[:80], ev.get("person", "?"))
    for ev in result["past_events"]:
        logger.info("[ANALYZE]   ~ [%s] %s %s", ev.get("status"), ev.get("id"), ev.get("description", "")[:60])

    # Persist new events
    inserted_ids = await db.add_events(result["new_events"], date_str)
    for i, ev in enumerate(result["new_events"]):
        if i < len(inserted_ids):
            ev["id"] = inserted_ids[i]

    # Apply past_event corrections
    corrections_applied = await db.apply_corrections(result["past_events"])

    # Remap Gemini's field names to match the iOS AnalyzeResponse model:
    #   Gemini "ts"          → iOS "timestamp"
    #   Gemini "description" → iOS "detail"
    #   Gemini "past_events" → iOS "corrections" (with action/fields format)
    ios_events = []
    for ev in result["new_events"]:
        ios_events.append({
            "id": ev.get("id", ""),
            "timestamp": ev.get("ts", clip_ts),
            "type": ev.get("type", "observation"),
            "detail": ev.get("description", ""),
            "notable": ev.get("notable", False),
            "speaker": ev.get("person"),
        })

    ios_corrections = []
    for ev in result["past_events"]:
        action = "delete" if ev.get("status") == "deleted" else "update"
        corr = {
            "event_id": ev.get("id", ""),
            "action": action,
        }
        if action == "update" and ev.get("description"):
            corr["fields"] = {"detail": ev["description"]}
        ios_corrections.append(corr)

    return {
        "new_events": ios_events,
        "corrections": ios_corrections,
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

    # Transcribe via diarization (get clean annotated transcript).
    # Run in executor — pyannote is CPU-intensive and synchronous; calling it
    # directly would block the FastAPI event loop for 5–30 seconds.
    known_speakers = await _get_speakers_cached()
    loop = asyncio.get_event_loop()
    diar_result = await loop.run_in_executor(
        None,
        functools.partial(
            diarization.diarize,
            audio_bytes=audio_bytes,
            raw_transcript="",
            known_speakers=known_speakers,
        ),
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
# Audio vault (1-hour batch analysis with native Gemini audio input)
# ---------------------------------------------------------------------------

class VaultClip(BaseModel):
    audio_base64: str
    mime_type: str = "audio/wav"
    timestamp: str          # ISO 8601 UTC when the clip was captured
    duration_seconds: float
    trigger_kind: str = "auto"
    transcript: str = ""    # ASR hint (may be empty)


class VaultRequest(BaseModel):
    clips: list[VaultClip]
    baby_name: str
    baby_age_months: int
    date_str: str = ""


@app.post("/analyze-audio-vault")
async def analyze_audio_vault(req: VaultRequest):
    """
    Receive a batch of audio clips from the past hour and analyze them with
    Gemini's native audio understanding. Returns new events that the real-time
    pipeline may have missed, plus an emotional-support flag.
    """
    date_str = req.date_str or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    existing_events = await db.get_events(date_str)

    logger.info("[VAULT] clips=%d baby=%s/%dmo date=%s",
                len(req.clips), req.baby_name, req.baby_age_months, date_str)

    clips_dicts = [c.model_dump() for c in req.clips]

    # Gemini audio analysis is CPU-bound (network + model) — run in executor
    # so we don't block the FastAPI event loop.
    loop = asyncio.get_event_loop()
    result = await loop.run_in_executor(
        None,
        functools.partial(
            gemini_client.analyze_audio_vault,
            clips=clips_dicts,
            baby_name=req.baby_name,
            baby_age_months=req.baby_age_months,
            existing_events=existing_events,
            date_str=date_str,
        ),
    )

    inserted_ids = await db.add_events(result["new_events"], date_str)
    for i, ev in enumerate(result["new_events"]):
        if i < len(inserted_ids):
            ev["id"] = inserted_ids[i]

    logger.info("[VAULT] inserted=%d emotional_support=%s",
                len(inserted_ids), result.get("emotional_support_needed"))
    return result


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

    # Skip regeneration if cached summary is newer than the latest event
    cached = await db.get_summary(date_str)
    if cached and events:
        latest_event_ts = max((e.get("created_at", "") for e in events), default="")
        cached_at = cached.get("generated_at", "")
        if cached_at and latest_event_ts and cached_at >= latest_event_ts:
            return {"summary": cached, "date": date_str, "cached": True}

    summary = gemini_client.generate_summary(
        events=events,
        baby_name=req.baby_name,
        baby_age_months=req.baby_age_months,
        date_str=date_str,
    )
    await db.set_summary(summary, date_str)
    return {"summary": summary, "date": date_str, "cached": False}


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
    name_variants: list[str] = []    # ASR transcriptions of speaker saying the baby's name


@app.post("/speakers/enroll")
async def enroll_speaker(req: EnrollRequest):
    audio_bytes = base64.b64decode(req.audio_base64)
    loop = asyncio.get_event_loop()
    embedding_bytes = await loop.run_in_executor(
        None, functools.partial(diarization.extract_embedding, audio_bytes)
    )
    if embedding_bytes is None:
        logger.warning("[ENROLL] pyannote unavailable — storing '%s' without voice embedding", req.label)
        embedding_bytes = b""
    # The enrollment audio embedding doubles as the name embedding — it captures
    # how this speaker's voice sounds when saying the baby's name. Stored separately
    # so diarize() can do a fast cosine similarity check (no extra pyannote needed).
    name_embedding = embedding_bytes if embedding_bytes else None
    variants = list(dict.fromkeys(v.lower().strip() for v in req.name_variants if v.strip()))
    if variants:
        logger.info("[ENROLL] '%s' name_variants=%s", req.label, variants)
    result = await db.upsert_speaker(
        label=req.label,
        embedding=embedding_bytes,
        speaker_id=req.speaker_id,
        name_variants=variants,
        name_embedding=name_embedding,
    )
    _invalidate_speaker_cache()
    return result


@app.get("/speakers")
async def list_speakers():
    speakers = await db.get_speakers()
    return {"speakers": speakers}


@app.get("/speakers/{speaker_id}/embedding")
async def get_speaker_embedding(speaker_id: str):
    """Return the raw float32 embedding for a speaker as base64."""
    embedding_bytes = await db.get_speaker_embedding(speaker_id)
    if not embedding_bytes:
        # None = speaker not in DB; b"" = label-only enrollment with no voice data
        raise HTTPException(status_code=404, detail="Speaker not found or has no voice embedding")
    return {"speaker_id": speaker_id, "embedding_base64": base64.b64encode(embedding_bytes).decode()}


@app.post("/speakers/compare")
async def compare_speaker(body: dict):
    """
    Debug endpoint: take an audio clip and compare it against all enrolled speakers
    using the same embedding path as the diarize loop.

    Body: { "audio_base64": "<base64 WAV>" }
    Returns similarity scores for every known speaker, sorted best-first.

    Use this to verify enrollment quality — if your own voice scores < 0.75
    against your own enrollment, re-enroll with a cleaner clip.
    """
    audio_bytes = base64.b64decode(body.get("audio_base64", ""))
    if not audio_bytes:
        raise HTTPException(status_code=422, detail="audio_base64 is required")
    known_speakers = await _get_speakers_cached()
    results = diarization.compare_embeddings(audio_bytes, known_speakers)
    return {"threshold": diarization.SIMILARITY_THRESHOLD, "results": results}


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
    _invalidate_speaker_cache()
    return {"status": "deleted", "id": speaker_id}
