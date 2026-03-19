"""
Gemini API client.

All analysis uses text-only input (speaker-annotated transcript).
Audio-to-Gemini is intentionally omitted for now — transcript captures
sufficient information at much lower cost.
"""
import json
import logging

from google import genai
from google.genai import types

logger = logging.getLogger(__name__)

MODEL = "gemini-2.5-flash"

# Event types the model is allowed to return
VALID_EVENT_TYPES = {
    "feeding", "nap_start", "nap_end", "cry", "diaper", "outing",
    "health_note", "activity", "new_food", "milestone", "observation",
}


def _client() -> genai.Client:
    return genai.Client()


# ---------------------------------------------------------------------------
# Analyze transcript
# ---------------------------------------------------------------------------

_ANALYZE_SYSTEM = """You are Babble, a precise baby activity logger.
You receive a speaker-labeled transcript of a recording captured when a baby's name was mentioned or crying was detected.
Your job is to extract baby activity events from the transcript and optionally correct recent logged events.

Rules:
- Only log events that clearly involve the baby.
- Return multiple new_events if multiple activities happened.
- corrections must only reference event IDs from events_last_10min that were explicitly clarified or corrected in the current clip.
- Do NOT correct older events; do NOT invent corrections.
- Use the speaker's exact words when possible for the detail field.
- Timestamps should be ISO 8601 UTC; use the provided clip_timestamp as reference.
- notable = true only for first-time milestones or urgent health concerns.

Event types: feeding | nap_start | nap_end | cry | diaper | outing | health_note | activity | new_food | milestone | observation

Return ONLY valid JSON in this exact schema:
{
  "new_events": [
    {
      "type": "<event_type>",
      "detail": "<description>",
      "timestamp": "<ISO 8601 UTC>",
      "notable": <true|false>,
      "speaker": "<who reported this, or null>"
    }
  ],
  "corrections": [
    {
      "event_id": "<id from events_last_10min>",
      "action": "update" | "delete",
      "fields": { "detail": "...", ... }
    }
  ]
}
If nothing baby-related happened, return {"new_events": [], "corrections": []}.
"""

_ANALYZE_USER = """Baby: {baby_name}, {baby_age_months} months old.
Trigger: {trigger_hint}.
Current time: {clip_timestamp}.

--- Transcript of last 10 minutes (background context) ---
{transcript_last_10min}

--- Current clip transcript ---
{transcript}

--- Events logged in the last 10 minutes ---
{events_last_10min_json}

What happened? Extract all baby activity events and any corrections to recent events."""


def analyze_from_transcript(
    transcript: str,
    transcript_last_10min: str,
    baby_name: str,
    baby_age_months: int,
    clip_timestamp: str,
    trigger_hint: str,
    events_last_10min: list[dict],
) -> dict:
    """
    Send speaker-annotated transcript to Gemini and return structured events.

    Returns:
        {
            "new_events": [...],
            "corrections": [...],
            "usage": {"input_tokens": int, "output_tokens": int}
        }
    """
    client = _client()

    events_json = json.dumps(events_last_10min, indent=2, default=str) if events_last_10min else "[]"

    prompt = _ANALYZE_USER.format(
        baby_name=baby_name,
        baby_age_months=baby_age_months,
        trigger_hint=trigger_hint,
        clip_timestamp=clip_timestamp,
        transcript_last_10min=transcript_last_10min or "(none)",
        transcript=transcript or "(no transcript available)",
        events_last_10min_json=events_json,
    )

    response = client.models.generate_content(
        model=MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            system_instruction=_ANALYZE_SYSTEM,
            temperature=0.1,
            response_mime_type="application/json",
        ),
    )

    text = response.text or "{}"
    usage = {
        "input_tokens": response.usage_metadata.prompt_token_count or 0,
        "output_tokens": response.usage_metadata.candidates_token_count or 0,
    }

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        logger.error(f"Gemini returned invalid JSON: {text[:300]}")
        parsed = {}

    # Validate and sanitise
    new_events = []
    for ev in parsed.get("new_events", []):
        if ev.get("type") not in VALID_EVENT_TYPES:
            ev["type"] = "observation"
        new_events.append(ev)

    corrections = []
    for corr in parsed.get("corrections", []):
        if corr.get("action") in ("update", "delete") and corr.get("event_id"):
            corrections.append(corr)

    return {
        "new_events": new_events,
        "corrections": corrections,
        "usage": usage,
    }


# ---------------------------------------------------------------------------
# Relevance check (cheap text call before full analysis)
# ---------------------------------------------------------------------------

_RELEVANCE_SYSTEM = """You determine if a brief transcript is relevant to baby activity monitoring.
Reply with JSON only: {"relevant": true/false, "reason": "<one short sentence>"}"""

_RELEVANCE_USER = """Baby name: {baby_name}, age {baby_age_months} months.
Transcript: "{transcript}"
Is this audio relevant to baby activity (care, feeding, nap, milestones, mood, health)?"""


def check_relevance(
    transcript: str,
    baby_name: str,
    baby_age_months: int,
) -> dict:
    """
    Cheap text-only relevance gate.
    Returns {"relevant": bool, "reason": str, "usage": {...}}
    """
    if not transcript or len(transcript.strip()) < 3:
        return {"relevant": False, "reason": "empty transcript", "usage": {}}

    client = _client()
    prompt = _RELEVANCE_USER.format(
        baby_name=baby_name,
        baby_age_months=baby_age_months,
        transcript=transcript[:1000],
    )
    response = client.models.generate_content(
        model=MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            system_instruction=_RELEVANCE_SYSTEM,
            temperature=0.0,
            response_mime_type="application/json",
        ),
    )
    text = response.text or '{"relevant": false, "reason": "no response"}'
    usage = {
        "input_tokens": response.usage_metadata.prompt_token_count or 0,
        "output_tokens": response.usage_metadata.candidates_token_count or 0,
    }
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = {"relevant": True, "reason": "parse error, allowing through"}
    parsed["usage"] = usage
    return parsed


# ---------------------------------------------------------------------------
# Voice note processing (edit mode or support mode)
# ---------------------------------------------------------------------------

_VOICE_NOTE_EDIT_SYSTEM = """You are a baby activity log editor.
The caregiver has recorded a voice note to correct or add to today's baby log.
Extract corrections and new events from the transcript.

Return JSON:
{
  "new_events": [...],
  "corrections": [{"event_id": "...", "action": "update"|"delete", "fields": {...}}],
  "reply": "<brief friendly acknowledgement>"
}"""

_VOICE_NOTE_SUPPORT_SYSTEM = """You are a warm, empathetic parenting companion named Babble.
The caregiver has shared a voice note. Respond with genuine warmth and practical support.
Do NOT extract events or log anything.

Return JSON: {"reply": "<warm supportive response, 2-4 sentences>"}"""


def process_voice_note(
    transcript: str,
    mode: str,
    baby_name: str,
    baby_age_months: int,
    events_today: list[dict] | None = None,
) -> dict:
    """
    Process a manual voice note.
    mode: "edit" | "support"
    Returns {"new_events": [...], "corrections": [...], "reply": str, "usage": {...}}
    """
    client = _client()

    if mode == "support":
        system = _VOICE_NOTE_SUPPORT_SYSTEM
        prompt = f"Baby: {baby_name}, {baby_age_months} months.\nCaregiver says: \"{transcript}\""
    else:
        events_json = json.dumps(events_today or [], indent=2, default=str)
        system = _VOICE_NOTE_EDIT_SYSTEM
        prompt = (
            f"Baby: {baby_name}, {baby_age_months} months.\n"
            f"Today's log so far:\n{events_json}\n\n"
            f"Caregiver says: \"{transcript}\""
        )

    response = client.models.generate_content(
        model=MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            system_instruction=system,
            temperature=0.2,
            response_mime_type="application/json",
        ),
    )
    text = response.text or "{}"
    usage = {
        "input_tokens": response.usage_metadata.prompt_token_count or 0,
        "output_tokens": response.usage_metadata.candidates_token_count or 0,
    }
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = {"reply": "Got it!", "new_events": [], "corrections": []}
    parsed["usage"] = usage
    return parsed


# ---------------------------------------------------------------------------
# Daily summary
# ---------------------------------------------------------------------------

_SUMMARY_SYSTEM = """You are a warm baby activity summarizer.
Given a list of today's events for a baby, produce a structured daily summary.

Return JSON:
{
  "structured": {
    "glance": ["<2-3 bullet highlights>"],
    "eating": {"summary": "...", "count": N},
    "nap": {"summary": "...", "total_minutes": N},
    "diaper": {"summary": "...", "count": N},
    "play_mood": {"summary": "..."},
    "milestone": {"summary": "...", "items": ["..."]}
  },
  "narrative": "<2-3 paragraph warm narrative of the day>",
  "social_tweet": "<tweet-length summary with emoji, under 280 chars>"
}"""


def generate_summary(
    events: list[dict],
    baby_name: str,
    baby_age_months: int,
    date_str: str,
) -> dict:
    """Generate a structured + narrative daily summary from events."""
    if not events:
        return {
            "structured": {"glance": ["No events recorded today."]},
            "narrative": f"Looks like a quiet day for {baby_name}!",
            "social_tweet": f"Quiet day with {baby_name} \U0001f495",
            "usage": {},
        }

    client = _client()
    events_text = json.dumps(events, indent=2, default=str)
    prompt = (
        f"Baby: {baby_name}, {baby_age_months} months old. Date: {date_str}.\n\n"
        f"Today's events:\n{events_text}"
    )

    response = client.models.generate_content(
        model=MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            system_instruction=_SUMMARY_SYSTEM,
            temperature=0.4,
            response_mime_type="application/json",
        ),
    )
    text = response.text or "{}"
    usage = {
        "input_tokens": response.usage_metadata.prompt_token_count or 0,
        "output_tokens": response.usage_metadata.candidates_token_count or 0,
    }
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = {
            "structured": {"glance": ["Summary unavailable."]},
            "narrative": f"Today was a full day with {baby_name}.",
            "social_tweet": f"Another wonderful day with {baby_name} \U0001f37c",
        }
    parsed["usage"] = usage
    return parsed
