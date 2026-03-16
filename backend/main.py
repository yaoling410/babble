"""Babble — FastAPI backend.

Endpoints:
  POST /analyze              — audio clip → events → Firestore + auto-summarize
  GET  /events               — today's events
  PATCH /events/{id}         — update an event
  DELETE /events/{id}        — delete an event
  POST /summary/generate     — on-demand summary generation
  GET  /summary              — latest cached summary
  WS   /ws/voice/edit-log    — Gemini Live: log editor
  WS   /ws/voice/companion   — Gemini Live: warm companion
"""

import asyncio
import base64
import json
import os
from datetime import datetime, timezone
from typing import Optional

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import firestore_client as db
import gemini_client as gemini
from gemini_client import SOURCE_NEW_AUDIO
import gemini_live as live

app = FastAPI(title="Babble")


async def _accumulate(usage: dict):
    """Persist Gemini usage to Firestore (atomic increment, survives restarts)."""
    asyncio.create_task(db.increment_stats(
        input_tokens=usage.get("input_tokens", 0),
        output_tokens=usage.get("output_tokens", 0),
        cost_usd=usage.get("cost_usd", 0.0),
    ))

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# No-cache middleware for HTML responses — ensures browser always fetches fresh index.html
from fastapi import Request as _Request

@app.middleware("http")
async def no_cache_html(request: _Request, call_next):
    response = await call_next(request)
    if request.url.path.endswith(".html") or request.url.path in ("/", "/static/"):
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
    return response

# Serve frontend from /static (for Cloud Run single-container deploy)
frontend_path = os.path.join(os.path.dirname(__file__), "..", "frontend")
if os.path.isdir(frontend_path):
    app.mount("/static", StaticFiles(directory=frontend_path, html=True), name="static")


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------

class AnalyzeRequest(BaseModel):
    audio_base64: str
    baby_name: str
    baby_age_months: int
    timestamp: str  # ISO 8601
    clip_duration_sec: Optional[float] = None
    context: Optional[dict] = None  # {events_today: [...], last_clip_summary: str}
    reference_audio: Optional[list[dict]] = None  # [{audio_base64: str, type: 'voice_reference'|'recent'}]


class UpdateEventRequest(BaseModel):
    fields: dict


class SummaryGenerateRequest(BaseModel):
    baby_name: str
    baby_age_months: int
    date: Optional[str] = None  # YYYY-MM-DD, defaults to today


class VoiceRefPayload(BaseModel):
    baby_name: str
    audio_b64: str


class CaregiverPayload(BaseModel):
    baby_name: str
    voice_b64: Optional[str] = None
    normal_tone_b64: Optional[str] = None
    clip_count: int = 1


def _find_similar_event(event: dict, recent_events: list) -> Optional[str]:
    """Return ID of a recent same-type event with ≥35% word overlap within 15 min, or None."""
    etype = event.get("type")
    edetail = (event.get("detail") or "").lower()
    try:
        etime = datetime.fromisoformat(event.get("timestamp", "").replace("Z", "+00:00"))
    except Exception:
        return None
    for ex in recent_events:
        if ex.get("type") != etype:
            continue
        try:
            ex_time = datetime.fromisoformat(ex.get("timestamp", "").replace("Z", "+00:00"))
            if abs((etime - ex_time).total_seconds()) > 900:  # 15 minutes, matches prompt dedup window
                continue
        except Exception:
            continue
        new_words = set(edetail.split())
        overlap = len(new_words & set((ex.get("detail") or "").lower().split())) / max(len(new_words), 1)
        if overlap > 0.35:
            return ex.get("id")
    return None


def _find_recent_same_type(event: dict, recent_events: list, max_gap_min: int = 30) -> Optional[str]:
    """Return ID of the most recent same-type event within max_gap_min, or None.
    Used to route past_context events to the right existing event for enrichment."""
    etype = event.get("type")
    try:
        etime = datetime.fromisoformat(event.get("timestamp", "").replace("Z", "+00:00"))
    except Exception:
        return None
    best_id = None
    best_gap = None
    for ex in recent_events:
        if ex.get("type") != etype:
            continue
        try:
            ex_time = datetime.fromisoformat(ex.get("timestamp", "").replace("Z", "+00:00"))
            gap = abs((etime - ex_time).total_seconds())
            if gap > max_gap_min * 60:
                continue
        except Exception:
            continue
        if best_gap is None or gap < best_gap:
            best_gap = gap
            best_id = ex.get("id")
    return best_id


# Redirect root to frontend
@app.get("/")
async def root():
    return RedirectResponse(url="/static/")


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# GET /stats
# ---------------------------------------------------------------------------

@app.get("/stats")
async def get_stats():
    return {"stats": await db.get_stats()}


# ---------------------------------------------------------------------------
# POST /analyze
# ---------------------------------------------------------------------------

@app.post("/analyze")
async def analyze(req: AnalyzeRequest):
    try:
        audio_bytes = base64.b64decode(req.audio_base64)
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid base64 audio")

    context = req.context or {}
    events_today = context.get("events_today", [])
    last_clip_summary = context.get("last_clip_summary", "")

    # Decode reference audio clips (voice reference + recent confirmed clips + caregiver voices)
    reference_clips = []
    for ref in (req.reference_audio or []):
        try:
            reference_clips.append({
                "bytes": base64.b64decode(ref["audio_base64"]),
                "type": ref.get("type", "recent"),
                "label": ref.get("label", ""),
                "mime_type": ref.get("mime_type", "audio/webm"),
            })
        except Exception:
            continue  # skip malformed entries

    known_caregivers = context.get("known_caregivers", [])

    if req.clip_duration_sec is not None:
        print(f"[analyze] clip_duration_sec={req.clip_duration_sec:.1f}s baby={req.baby_name}")

    # Call Gemini 2.5 Flash — returns (events, usage, raw_events)
    try:
        detected, usage, raw_events = await gemini.analyze_audio(
            audio_bytes=audio_bytes,
            baby_name=req.baby_name,
            baby_age_months=req.baby_age_months,
            events_today=events_today,
            last_clip_summary=last_clip_summary,
            clip_timestamp=req.timestamp,
            reference_clips=reference_clips,
            known_caregivers=known_caregivers,
            clip_duration_sec=req.clip_duration_sec,
        )
    except Exception as e:
        asyncio.create_task(db.write_log("ERROR", f"Gemini analyze_audio failed: {e}", {"baby_name": req.baby_name}))
        raise HTTPException(status_code=502, detail="Audio analysis failed. Please try again.")
    await _accumulate(usage)

    if not detected:
        return {"events_added": 0, "events": [], "raw_events": raw_events, "usage": usage}

    # Write events to Firestore
    date_str = req.timestamp[:10]  # YYYY-MM-DD
    new_event_ids = []

    # Fetch recent events once for dedup / past-context enrichment
    recent_events = await db.get_events(date_str)

    for raw in detected:
        new_logging = raw.get("new_logging", True)
        event_type = raw.get("event_type")
        caregiver_hint = raw.get("caregiver_hint")
        caregiver_voice_match = raw.get("caregiver_voice_match")

        if new_logging:
            # Build the Firestore event document from new_logging_* fields
            event = {
                "type": event_type,
                "timestamp": raw.get("new_logging_timestamp"),
                "detail": raw.get("new_logging_detail"),
                "notable": raw.get("notable", False),
                "caregiver_hint": caregiver_hint or caregiver_voice_match,
            }
            voice_seg = raw.get("caregiver_voice_segment")
            if voice_seg and isinstance(voice_seg, dict):
                event["caregiver_voice_segment"] = voice_seg
            # Safety-net dedup: if a very similar event already exists, enrich instead
            dup_id = _find_similar_event(event, recent_events)
            if dup_id:
                await db.update_event(dup_id, {"detail": event["detail"]}, date_str)
            else:
                event_id = await db.add_event(event, date_str)
                event["id"] = event_id
                new_event_ids.append(event_id)

        else:
            # Enrich an existing event with past_content_detail
            detail = raw.get("past_content_detail", "")
            target_id = raw.get("past_content_id")
            if not target_id:
                # Gemini couldn't identify which event — find most recent of same type
                probe = {"type": event_type, "timestamp": raw.get("new_logging_timestamp", req.timestamp)}
                target_id = _find_recent_same_type(probe, recent_events, max_gap_min=30)
            if target_id and detail:
                await db.update_event(target_id, {"detail": detail}, date_str)

    # Auto-summarize in background (non-blocking)
    if new_event_ids:
        asyncio.create_task(
            _auto_summarize(req.baby_name, req.baby_age_months, date_str)
        )

    return {
        "events_added": len(new_event_ids),
        "events": detected,
        "raw_events": raw_events,   # all events before confidence filter (for debug panel)
        "usage": usage,             # token counts + cost for this clip
    }


async def _auto_summarize(baby_name: str, baby_age_months: int, date_str: str):
    """Regenerate and cache the summary after new events are added."""
    try:
        events = await db.get_events(date_str)
        summary, usage = await gemini.generate_summary(baby_name, baby_age_months, events)
        await _accumulate(usage)
        summary["generated_at"] = datetime.now(timezone.utc).isoformat()
        await db.set_summary(summary, date_str)
    except Exception as e:
        await db.write_log("ERROR", f"Auto-summarize error: {e}", {"baby_name": baby_name, "date": date_str})


# ---------------------------------------------------------------------------
# GET /events
# ---------------------------------------------------------------------------

@app.get("/events")
async def get_events(date: Optional[str] = None):
    events = await db.get_events(date)
    return {"events": events}


# ---------------------------------------------------------------------------
# PATCH /events/{event_id}
# ---------------------------------------------------------------------------

@app.patch("/events/{event_id}")
async def update_event(event_id: str, req: UpdateEventRequest, date: Optional[str] = None):
    await db.update_event(event_id, req.fields, date)
    return {"status": "updated"}


# ---------------------------------------------------------------------------
# DELETE /events/{event_id}
# ---------------------------------------------------------------------------

@app.delete("/events/{event_id}")
async def delete_event(event_id: str, date: Optional[str] = None):
    await db.delete_event(event_id, date)
    return {"status": "deleted"}


# ---------------------------------------------------------------------------
# POST /summary/generate
# ---------------------------------------------------------------------------

@app.post("/summary/generate")
async def generate_summary(req: SummaryGenerateRequest):
    date_str = req.date or db.today_str()
    events = await db.get_events(date_str)
    summary, usage = await gemini.generate_summary(req.baby_name, req.baby_age_months, events)
    await _accumulate(usage)
    summary["generated_at"] = datetime.now(timezone.utc).isoformat()
    await db.set_summary(summary, date_str)
    return {"summary": summary, "usage": usage}


# ---------------------------------------------------------------------------
# GET /summary
# ---------------------------------------------------------------------------

@app.get("/summary")
async def get_summary(date: Optional[str] = None):
    summary = await db.get_summary(date)
    if not summary:
        return {"summary": None}
    return {"summary": summary}


@app.get("/voice-reference")
async def get_voice_ref(baby: str):
    b64 = await db.get_voice_reference(baby)
    if not b64:
        raise HTTPException(status_code=404, detail="No voice reference saved")
    return {"audio_b64": b64}


@app.put("/voice-reference")
async def put_voice_ref(payload: VoiceRefPayload):
    await db.set_voice_reference(payload.baby_name, payload.audio_b64)
    return {"ok": True}


@app.get("/caregivers")
async def get_caregivers(baby: str):
    caregivers = await db.get_caregivers(baby)
    return {"caregivers": caregivers}


@app.put("/caregivers/{name}")
async def put_caregiver(name: str, payload: CaregiverPayload):
    await db.set_caregiver(payload.baby_name, name, {
        "voice_b64": payload.voice_b64,
        "normal_tone_b64": payload.normal_tone_b64,
        "clip_count": payload.clip_count,
        "confirmed_at": datetime.now(timezone.utc).isoformat(),
    })
    return {"ok": True}


# ---------------------------------------------------------------------------
# WS /ws/voice/edit-log
# ---------------------------------------------------------------------------

@app.websocket("/ws/voice/edit-log")
async def ws_edit_log(websocket: WebSocket):
    await websocket.accept()

    # Expect first message to be JSON config: {baby_name, baby_age_months, date?, local_now?, tz_offset_minutes?}
    try:
        config_raw = await asyncio.wait_for(websocket.receive_text(), timeout=10.0)
        config = json.loads(config_raw)
        baby_name = config["baby_name"]
        baby_age_months = int(config["baby_age_months"])
        date_str = config.get("date")
        local_now = config.get("local_now")
        tz_offset_minutes = config.get("tz_offset_minutes", 0)
    except Exception as e:
        await websocket.send_json({"type": "error", "message": str(e)})
        await websocket.close()
        return

    events = await db.get_events(date_str)
    asyncio.create_task(db.write_log("INFO", "Voice edit-log session started", {"baby_name": baby_name, "date": date_str}))

    # Queue for incoming audio from browser
    audio_queue: asyncio.Queue[bytes] = asyncio.Queue()

    async def audio_in():
        while True:
            chunk = await audio_queue.get()
            if chunk is None:
                return
            yield chunk

    async def audio_out(pcm_bytes: bytes):
        await websocket.send_bytes(pcm_bytes)

    async def text_out(text: str):
        await websocket.send_json({"type": "transcript", "role": "gemini", "text": text})

    async def input_transcript(text: str):
        await websocket.send_json({"type": "transcript", "role": "user", "text": text})

    async def edit_cmd(cmd: dict):
        from google.api_core.exceptions import NotFound
        action = cmd.get("action")
        event_id = cmd.get("event_id")
        fields = cmd.get("fields", {})

        try:
            if action == "update" and event_id:
                await db.update_event(event_id, fields, date_str)
            elif action == "delete" and event_id:
                await db.delete_event(event_id, date_str)
            elif action == "add" and fields:
                await db.add_event(fields, date_str)
        except NotFound:
            # Event was deleted between session start and now — treat as add if updating
            if action == "update" and fields:
                await db.add_event(fields, date_str)
        except Exception as e:
            asyncio.create_task(db.write_log("ERROR", f"edit_cmd failed: {e}", {"cmd": cmd}))

        asyncio.create_task(db.write_log("INFO", f"Voice edit command: {action}", {"event_id": event_id, "date": date_str}))
        await websocket.send_json({"type": "edit_applied", "cmd": cmd})

    async def receive_from_browser():
        try:
            while True:
                msg = await websocket.receive()
                if "bytes" in msg:
                    await audio_queue.put(msg["bytes"])
                elif "text" in msg:
                    data = json.loads(msg["text"])
                    if data.get("type") == "done":
                        await audio_queue.put(None)
                        break
                    elif data.get("type") == "activity_start":
                        await audio_queue.put("ACTIVITY_START")
                    elif data.get("type") == "activity_end":
                        await audio_queue.put("ACTIVITY_END")
        except WebSocketDisconnect:
            await audio_queue.put(None)

    try:
        await asyncio.gather(
            receive_from_browser(),
            live.run_edit_log_session(
                baby_name=baby_name,
                events=events,
                local_now=local_now,
                tz_offset_minutes=tz_offset_minutes,
                audio_in=audio_in(),
                audio_out_callback=audio_out,
                text_out_callback=text_out,
                edit_cmd_callback=edit_cmd,
                input_transcript_callback=input_transcript,
            ),
        )
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await db.write_log("ERROR", f"Edit-log session error: {e}", {"baby_name": baby_name})
        try:
            await websocket.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        updated_events = await db.get_events(date_str)
        try:
            await websocket.send_json({"type": "session_end", "events": updated_events})
        except Exception:
            pass


# ---------------------------------------------------------------------------
# WS /ws/voice/companion
# ---------------------------------------------------------------------------

@app.websocket("/ws/voice/companion")
async def ws_companion(websocket: WebSocket):
    print("[ws_companion] connection received")
    await websocket.accept()
    print("[ws_companion] accepted")

    try:
        config_raw = await asyncio.wait_for(websocket.receive_text(), timeout=10.0)
        config = json.loads(config_raw)
        baby_name = config["baby_name"]
        baby_age_months = int(config["baby_age_months"])
        date_str = config.get("date")
    except Exception as e:
        await websocket.send_json({"type": "error", "message": str(e)})
        await websocket.close()
        return

    summary = await db.get_summary(date_str) or {}
    summary_structured = summary.get("structured", "No summary yet for today.")

    audio_queue: asyncio.Queue[bytes] = asyncio.Queue()

    async def audio_in():
        while True:
            chunk = await audio_queue.get()
            if chunk is None:
                return
            yield chunk

    async def audio_out(pcm_bytes: bytes):
        await websocket.send_bytes(pcm_bytes)

    async def text_out(text: str):
        await websocket.send_json({"type": "transcript", "role": "gemini", "text": text})

    async def input_transcript(text: str):
        await websocket.send_json({"type": "transcript", "role": "user", "text": text})

    summary_was_updated = False

    async def summary_update(conversation_text: str):
        nonlocal summary_was_updated
        # Re-generate summary with updated info after session ends
        try:
            events = await db.get_events(date_str)
            new_summary, usage = await gemini.generate_summary(baby_name, baby_age_months, events)
            await _accumulate(usage)
            new_summary["generated_at"] = datetime.now(timezone.utc).isoformat()
            await db.set_summary(new_summary, date_str)
            summary_was_updated = True
        except Exception as e:
            await db.write_log("ERROR", f"Companion summary update error: {e}", {"baby_name": baby_name, "date": date_str})

    async def receive_from_browser():
        try:
            while True:
                msg = await websocket.receive()
                if "bytes" in msg:
                    await audio_queue.put(msg["bytes"])
                elif "text" in msg:
                    data = json.loads(msg["text"])
                    if data.get("type") == "done":
                        await audio_queue.put(None)
                        break
                    elif data.get("type") == "activity_start":
                        await audio_queue.put("ACTIVITY_START")
                    elif data.get("type") == "activity_end":
                        await audio_queue.put("ACTIVITY_END")
        except WebSocketDisconnect:
            await audio_queue.put(None)

    try:
        await asyncio.gather(
            receive_from_browser(),
            live.run_companion_session(
                baby_name=baby_name,
                summary_structured=summary_structured,
                audio_in=audio_in(),
                audio_out_callback=audio_out,
                text_out_callback=text_out,
                input_transcript_callback=input_transcript,
                summary_update_callback=summary_update,
            ),
        )
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await db.write_log("ERROR", f"Companion session error: {e}", {"baby_name": baby_name})
        try:
            await websocket.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        # Only re-fetch summary if it was actually updated during the session
        final_summary = await db.get_summary(date_str) if summary_was_updated else summary
        try:
            await websocket.send_json({"type": "session_end", "summary": final_summary})
        except Exception:
            pass
