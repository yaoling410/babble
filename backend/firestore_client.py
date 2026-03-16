"""Firestore read/write helpers for Babble."""

import os
from datetime import datetime, timezone
from typing import Optional
from google.cloud import firestore

_db: Optional[firestore.AsyncClient] = None


def get_db() -> firestore.AsyncClient:
    global _db
    if _db is None:
        project = os.environ.get("FIRESTORE_PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT")
        _db = firestore.AsyncClient(project=project)
    return _db


def today_str() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def day_ref(date_str: Optional[str] = None) -> firestore.AsyncDocumentReference:
    date_str = date_str or today_str()
    return get_db().collection("days").document(date_str)


def events_ref(date_str: Optional[str] = None) -> firestore.AsyncCollectionReference:
    return day_ref(date_str).collection("events")


async def get_events(date_str: Optional[str] = None) -> list[dict]:
    """Return today's events sorted by timestamp."""
    docs = events_ref(date_str).order_by("timestamp").stream()
    result = []
    async for doc in docs:
        data = doc.to_dict()
        data["id"] = doc.id
        result.append(data)
    return result


async def add_event(event: dict, date_str: Optional[str] = None) -> str:
    """Add a new event; return the new document ID."""
    ref = events_ref(date_str).document()
    await ref.set(event)
    return ref.id


async def update_event(event_id: str, fields: dict, date_str: Optional[str] = None):
    """Merge-update an existing event."""
    ref = events_ref(date_str).document(event_id)
    await ref.update(fields)


async def delete_event(event_id: str, date_str: Optional[str] = None):
    """Delete an event."""
    ref = events_ref(date_str).document(event_id)
    await ref.delete()


async def get_summary(date_str: Optional[str] = None) -> Optional[dict]:
    """Return the cached summary for a given day, or None."""
    doc = await day_ref(date_str).get()
    if doc.exists:
        data = doc.to_dict()
        return data.get("summary")
    return None


async def set_summary(summary: dict, date_str: Optional[str] = None):
    """Write/overwrite the summary for a given day."""
    await day_ref(date_str).set({"summary": summary}, merge=True)


async def get_profile(baby_name: str) -> Optional[dict]:
    """Return profile metadata for a baby (excludes voice blobs), or None."""
    doc = await get_db().collection("profiles").document(baby_name.lower()).get()
    if doc.exists:
        data = doc.to_dict()
        data.pop("voice_reference_b64", None)
        return data
    return None


async def set_profile(baby_name: str, data: dict):
    """Create or update profile doc (safe to call with partial data)."""
    await get_db().collection("profiles").document(baby_name.lower()).set(data, merge=True)


async def get_caregivers(baby_name: str) -> dict:
    """Return {caregiverName: {voice_b64, normal_tone_b64, clip_count}} for all confirmed caregivers."""
    result = {}
    docs = get_db().collection("profiles").document(baby_name.lower()).collection("caregivers").stream()
    async for doc in docs:
        result[doc.id] = doc.to_dict()
    return result


async def set_caregiver(baby_name: str, caregiver_name: str, data: dict):
    """Upsert caregiver record under profiles/{baby}/caregivers/{name}."""
    ref = (
        get_db()
        .collection("profiles")
        .document(baby_name.lower())
        .collection("caregivers")
        .document(caregiver_name.lower())
    )
    await ref.set(data, merge=True)


async def get_voice_reference(baby_name: str) -> Optional[str]:
    """Return base64-encoded voice reference audio for this baby, or None."""
    doc = await get_db().collection("profiles").document(baby_name.lower()).get()
    if doc.exists:
        return doc.to_dict().get("voice_reference_b64")
    return None


async def set_voice_reference(baby_name: str, audio_b64: str):
    """Save base64-encoded voice reference audio for this baby."""
    await get_db().collection("profiles").document(baby_name.lower()).set(
        {"voice_reference_b64": audio_b64}, merge=True
    )


# ---------------------------------------------------------------------------
# Session stats (persistent across restarts)
# ---------------------------------------------------------------------------

_STATS_DOC = ("meta", "session_stats")


async def increment_stats(input_tokens: int, output_tokens: int, cost_usd: float):
    """Atomically increment all-time token/cost counters in Firestore."""
    ref = get_db().collection(_STATS_DOC[0]).document(_STATS_DOC[1])
    await ref.set(
        {
            "input_tokens": firestore.Increment(input_tokens),
            "output_tokens": firestore.Increment(output_tokens),
            "cost_usd": firestore.Increment(cost_usd),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        },
        merge=True,
    )


async def get_stats() -> dict:
    """Return all-time stats from Firestore, or zeroes if not yet written."""
    doc = await get_db().collection(_STATS_DOC[0]).document(_STATS_DOC[1]).get()
    if doc.exists:
        data = doc.to_dict()
        return {
            "input_tokens": data.get("input_tokens", 0),
            "output_tokens": data.get("output_tokens", 0),
            "cost_usd": data.get("cost_usd", 0.0),
            "updated_at": data.get("updated_at"),
        }
    return {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "updated_at": None}


# ---------------------------------------------------------------------------
# Application logs (persist across restarts)
# ---------------------------------------------------------------------------

async def write_log(level: str, message: str, context: Optional[dict] = None):
    """Append a structured log entry to the logs collection. Fire-and-forget safe."""
    entry = {
        "level": level,
        "message": message,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    if context:
        entry["context"] = context
    await get_db().collection("logs").add(entry)
