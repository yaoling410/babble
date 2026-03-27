"""
Gemini API client.

# Why text-only input?
  Current approach: send only the speaker-annotated transcript (plain text) to Gemini.
  Alternative A: send raw audio bytes directly — Gemini 2.0+ supports native audio input.
    Rejected: ~10x more tokens (audio is expensive), adds latency, and the transcript from
    Apple SFSpeechRecognizer already captures ~95% of what matters. The marginal accuracy
    gain doesn't justify the cost for routine baby-care logging.
  Alternative B: send audio + transcript together for grounding.
    Could revisit if tone/emotion detection becomes a priority (e.g. detecting distress
    from vocal quality that isn't captured in words).

# Why Gemini and not OpenAI / Claude?
  Gemini 2.5 Flash is currently the most cost-effective model for structured JSON extraction
  at the required quality level. Its native JSON mode (response_mime_type) is reliable and
  cheap. OpenAI GPT-4o-mini is a comparable alternative; Claude Haiku is another.
  The architecture is model-agnostic — swap MODEL constant to switch.
"""
import base64
import json
import logging
from datetime import datetime, timezone

from google import genai
from google.genai import types

import config as cfg

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Cost tracking — in-memory daily accumulator
# ---------------------------------------------------------------------------
# Keyed by YYYY-MM-DD (UTC). Survives the process lifetime; resets on restart.
# Fine for a single-user baby monitor — cost data doesn't need to be durable.
#
# Structure per date:
#   {"calls": int, "input_tokens": int, "output_tokens": int, "cost_usd": float,
#    "by_type": {"analyze": {...}, "relevance": {...}, "voice_note": {...}, "summary": {...}}}

_daily: dict[str, dict] = {}


def _cost_for(model: str, input_tokens: int, output_tokens: int) -> float:
    if cfg.RELEVANCE_MODEL in model:
        return input_tokens * cfg.COST_INPUT_LITE + output_tokens * cfg.COST_OUTPUT_LITE
    return input_tokens * cfg.COST_INPUT_FLASH + output_tokens * cfg.COST_OUTPUT_FLASH


def _record_usage(call_type: str, model: str, input_tokens: int, output_tokens: int) -> float:
    """Accumulate tokens + cost for today; log a one-liner. Returns call cost in USD."""
    cost = _cost_for(model, input_tokens, output_tokens)
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    day = _daily.setdefault(date_str, {
        "calls": 0, "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "by_type": {}
    })
    day["calls"] += 1
    day["input_tokens"] += input_tokens
    day["output_tokens"] += output_tokens
    day["cost_usd"] += cost

    bucket = day["by_type"].setdefault(call_type, {
        "calls": 0, "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0
    })
    bucket["calls"] += 1
    bucket["input_tokens"] += input_tokens
    bucket["output_tokens"] += output_tokens
    bucket["cost_usd"] += cost

    logger.info(
        "[COST] %s in=%d out=%d call=$%.6f | day_total=$%.4f (%d calls)",
        call_type, input_tokens, output_tokens, cost, day["cost_usd"], day["calls"]
    )
    return cost


def get_daily_usage(date_str: str | None = None) -> dict:
    """Return accumulated usage for a given date (default: today UTC)."""
    key = date_str or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return {"date": key, **_daily.get(key, {
        "calls": 0, "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "by_type": {}
    })}

# ---------------------------------------------------------------------------
# Model selection
# ---------------------------------------------------------------------------
#
# Current: gemini-2.5-flash for all heavy calls (analyze, voice note, summary).
#          gemini-2.0-flash-lite for the cheap relevance gate.
#
# Why two models?
#   The relevance check is a simple yes/no classification. Using the full 2.5-flash
#   model here wastes money (~3x more expensive per token than flash-lite). Flash-lite
#   is sufficient for binary classification and completes faster (~200ms vs ~700ms).
#
# Alternatives:
#   - Single model for everything: simpler code, but relevance calls now cost more.
#   - On-device classifier (CoreML): zero cost, zero latency, but requires training data
#     and a model artifact to ship with the app. Worth exploring once we have enough data.
#   - Embedding-based similarity search: fast, cheap, but needs a labeled dataset.
#     The keyword approach + Gemini fallback gets ~95% accuracy at minimal complexity.
#
MODEL = cfg.ANALYSIS_MODEL
RELEVANCE_MODEL = cfg.RELEVANCE_MODEL

# ---------------------------------------------------------------------------
# Event type allowlist
# ---------------------------------------------------------------------------
#
# Current: explicit set of allowed types; anything unrecognised falls back to "observation".
#
# Why validate at all?
#   Gemini occasionally hallucinates type names (e.g. "nap" instead of "nap_start",
#   "health" instead of "health_note"). Mapping unknowns to "observation" is safe —
#   the event still gets logged, just with a generic type. The parent can correct it
#   via voice note.
#
# Alternative: reject unknown events entirely (drop them).
#   Rejected because losing data is worse than miscategorising it.
#
VALID_EVENT_TYPES = {
    "feeding", "nap_start", "nap_end", "cry", "diaper", "outing",
    "health_note", "activity", "new_food", "milestone", "observation",
    "emotional_support",
}

# ---------------------------------------------------------------------------
# Singleton Gemini client
# ---------------------------------------------------------------------------
#
# Current: one genai.Client instance shared across all requests (module-level singleton).
#
# Why singleton?
#   genai.Client() initialises auth, HTTP connection pools, and retry state.
#   Creating a new one per request wastes ~50-100ms per call and re-authenticates
#   unnecessarily.
#
# Alternative: dependency injection (pass client as a parameter).
#   Cleaner for testing but adds boilerplate to every call site. The module-level
#   singleton is fine here because this is a single-process server — no concurrency
#   issues from shared state.
#
_CLIENT: genai.Client | None = None


def _client() -> genai.Client:
    global _CLIENT
    if _CLIENT is None:
        _CLIENT = genai.Client()
    return _CLIENT


# ---------------------------------------------------------------------------
# Budget helpers
# ---------------------------------------------------------------------------
#
# _BABY_KEYWORDS is used in _keyword_relevance_check() as the first line of
# defence before spending tokens on Gemini. See that function for the full
# three-tier strategy.
#
_BABY_KEYWORDS = {
    "fed", "feed", "feeding", "bottle", "breast", "nurse", "nursing",
    "nap", "sleep", "sleeping", "slept", "woke", "awake",
    "cry", "crying", "cried", "fuss", "fussy",
    "diaper", "poop", "pee", "wet", "dirty",
    "milk", "solid", "food", "ate", "eat", "eating", "hungry",
    "bath", "sick", "fever", "medicine", "doctor",
    "crawl", "walk", "stand", "talk", "word", "smile", "laugh", "play",
    "roll", "rolled", "tummy",
}


def _keyword_relevance_check(transcript: str, baby_name: str) -> bool | None:
    """
    Fast local relevance check — no API call, no latency, zero cost.

    Three-tier strategy (cheapest → most expensive):
      Tier 1 (this function): keyword set + baby name substring match.
        - Catches ~80% of cases instantly.
        - Returns True if confident it's relevant, False if confident it's not.
        - Returns None if uncertain → caller falls through to Tier 2.
      Tier 2 (check_relevance caller): cheap Gemini flash-lite API call.
        - Handles ambiguous sentences that look baby-related but aren't
          (e.g. "we need more milk" could be grocery talk, not feeding).
        - Only reached for ~20% of transcripts.
      Tier 3 (iOS TranscriptFilter): runs on-device before any network call.
        - Mirrors this logic in Swift so most irrelevant audio never reaches
          the backend at all. This function is the server-side safety net.

    Why keyword matching and not a regex or NLP model?
      A keyword set covers the vocabulary reliably for infant care without any
      training data or model dependency. The false-negative rate (baby-related
      content missing all keywords) is very low in practice because caregivers
      use predictable, domain-specific language.

    Returns:
      True  — clearly baby-related, pass to Gemini
      False — clearly irrelevant, drop
      None  — uncertain, escalate to cheap Gemini call
    """
    lower = transcript.lower()
    if baby_name.lower() in lower:
        return True
    words = set(lower.split())
    if words & _BABY_KEYWORDS:
        return True
    if len(transcript.strip()) < 10:
        return False
    return None  # uncertain — let Gemini decide


def _compact_json(obj) -> str:
    """Serialize to compact JSON (no indent/spaces) to minimize tokens."""
    return json.dumps(obj, separators=(",", ":"), default=str)


def _compact_events(events: list[dict]) -> str:
    """
    Flatten events to one short line each to minimise token usage.

    Current format: "<id> <timestamp> <type> <detail>"
    Example:
      abc123 2025-03-19T14:32 feeding Breastfed 12 min left, 8 min right.
      def456 2025-03-19T15:10 nap_start Went down for afternoon nap.

    Why not send full JSON?
      Full JSON for 20 events is ~2000 tokens. This compact format is ~300 tokens.
      Gemini needs the event IDs (for corrections) and the details (for context);
      it doesn't need created_at, speaker, or notable flags for this task.

    Alternative: send only the last N events as full JSON for richer context.
      Worth considering if correction accuracy degrades — the compact format loses
      fields like `notable` and `speaker` that could help Gemini understand context.
    """
    if not events:
        return "[]"
    lines = []
    for ev in events:
        ts = ev.get("timestamp", "")[:16]  # trim to minute precision
        lines.append(f'{ev.get("id","?")} {ts} {ev.get("type","")} {ev.get("detail","")}')
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Analyze transcript
# ---------------------------------------------------------------------------
#
# Design: one Gemini call extracts new events AND corrections in a single round-trip.
#
# Why combine events + corrections in one call?
#   Earlier design used two separate calls: one to check relevance, one to analyse.
#   That doubled latency and cost. The analyse call already has all the context
#   needed to apply corrections (recent events list), so there's no reason to split.
#   Corrections are rare (~5% of clips) — the small extra JSON in the response
#   is negligible.
#
# Why include transcript_last_10min?
#   A single 30-second clip often lacks context. "She just went down" only makes
#   sense if you know what happened in the last few minutes. The rolling 10-min
#   buffer gives Gemini that context without sending the full day's history.
#   Capped at cfg.TRANSCRIPT_CONTEXT_MAX_CHARS to limit token spend on long sessions.
#
# Temperature = 0.1 (near-deterministic):
#   Event extraction is a classification + extraction task, not a creative one.
#   Higher temperature introduces hallucination (invented events). We want
#   conservative, literal extraction — if something wasn't said, don't log it.
#
_ANALYZE_SYSTEM = """You are Babble, a precise baby activity logger.
You receive a speaker-labeled transcript of a recording captured when a baby's name was mentioned or crying was detected.

Your job:
1. Decide if the clip is relevant to baby activity (care, feeding, sleep, health, milestones, mood).
2. If relevant: clean the raw ASR transcript and extract events.
3. If any past logged events were explicitly corrected or clarified: return them as past_events.

Rules:
- relevant = false if the clip is casual conversation, background noise, or has nothing baby-related.
- transcript and new_events are only required when relevant = true.
- new_events: only log activities that clearly involve the baby. Use speaker's words for description.
- past_events: only reference IDs from [Recent events] that were explicitly corrected in this clip.
- Do NOT invent or assume corrections.
- Timestamps: ISO 8601 UTC, using clip_timestamp as reference.
- notable = true only for first-time milestones or urgent health concerns.
- For transcript: fix ASR errors (e.g. "cyber" → "yeah"), collapse repeated filler words, keep speaker turns.
- speaker in transcript: use whatever labels the input already has (e.g. "Speaker 1", "Speaker 2"). If the input has no speaker labels, use "Speaker 1" for all lines — do NOT infer or invent multiple speakers.
- person: who the event is about or performed by — "baby", or the speaker label from the transcript (e.g. "Speaker 1"). Only use "Speaker 2" etc. if the input actually labels them.
- status on new_events: "confirmed" (clearly stated) or "tentative" (inferred/uncertain).
- status on past_events: "updated" or "deleted".

Event types: feeding | nap_start | nap_end | cry | diaper | outing | health_note | activity | new_food | milestone | emotional_support | observation

emotional_support: use when the caregiver expresses clear emotional distress — e.g. crying, saying they're overwhelmed, exhausted beyond normal tiredness, feeling hopeless, or asking for help. One sentence of warm acknowledgement in the description. notable = true always.

Return ONLY valid JSON:
{
  "relevant": <true|false>,
  "transcript": [
    {"ts": <seconds as int>, "speaker": "<Speaker 1|Speaker 2|Baby>", "text": "<cleaned text>"}
  ],
  "new_events": [
    {
      "ts": "<ISO 8601 UTC>",
      "type": "<event_type>",
      "description": "<what happened, in plain English>",
      "status": "confirmed" | "tentative",
      "person": "<baby|Speaker 1|Speaker 2>",
      "notable": <true|false>
    }
  ],
  "past_events": [
    {
      "id": "<id from Recent events>",
      "ts": "<original event timestamp>",
      "type": "<event_type>",
      "description": "<updated description, or null if deleted>",
      "status": "updated" | "deleted",
      "person": "<baby|Speaker 1|Speaker 2>"
    }
  ]
}
When relevant = false, return {"relevant": false} only — omit all other fields.
"""

_ANALYZE_USER = """Baby: {baby_name}, {baby_age_months}mo. Trigger: {trigger_hint}. Time: {clip_timestamp}.

[Context — last 10min]
{transcript_last_10min}

[Current clip]
{transcript}

[Recent events]
{events_last_10min_compact}

Extract baby activity events and corrections."""


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

    prompt = _ANALYZE_USER.format(
        baby_name=baby_name,
        baby_age_months=baby_age_months,
        trigger_hint=trigger_hint,
        clip_timestamp=clip_timestamp,
        # Cap 10-min context to limit token spend on long sessions.
        # Alternative: summarise older context rather than truncating — would preserve
        # information better but adds another Gemini call.
        transcript_last_10min=(transcript_last_10min or "(none)")[-cfg.TRANSCRIPT_CONTEXT_MAX_CHARS:],
        transcript=transcript or "(no transcript available)",
        events_last_10min_compact=_compact_events(events_last_10min),
    )

    response = client.models.generate_content(
        model=MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            system_instruction=_ANALYZE_SYSTEM,
            # Near-deterministic: extraction task, not creative writing.
            # Alternative: temperature=0 for fully deterministic output. Kept at 0.1
            # to allow minor phrasing variation in the detail field (less robotic).
            temperature=0.1,
            # Forced JSON mode: Gemini guarantees valid JSON output.
            # Alternative: ask for JSON in the prompt only (no mime type).
            #   Rejected: without forced mode, Gemini occasionally wraps JSON in
            #   markdown code fences (```json ... ```) which breaks parsing.
            response_mime_type="application/json",
        ),
    )

    # Log finish reason and raw text so empty/blocked responses are diagnosable.
    candidate = response.candidates[0] if response.candidates else None
    finish_reason = candidate.finish_reason.name if candidate else "NO_CANDIDATE"
    raw_text = response.text or ""
    if not raw_text:
        logger.warning(
            "[GEMINI] Empty response — finish_reason=%s. Safety block or quota issue. "
            "Transcript snippet: %s",
            finish_reason, transcript[:150],
        )
    elif finish_reason not in ("STOP", "MAX_TOKENS"):
        logger.warning("[GEMINI] Unexpected finish_reason=%s — response may be incomplete", finish_reason)
    else:
        logger.debug("[GEMINI] Raw response: %s", raw_text[:300])

    text = raw_text or "{}"
    usage = {
        "input_tokens": response.usage_metadata.prompt_token_count or 0,
        "output_tokens": response.usage_metadata.candidates_token_count or 0,
    }
    usage["cost_usd"] = _record_usage("analyze", MODEL, usage["input_tokens"], usage["output_tokens"])

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        logger.error(f"Gemini returned invalid JSON: {text[:300]}")
        parsed = {}

    relevant = parsed.get("relevant", True)  # default True if field missing (safe fallback)

    new_events = []
    for ev in parsed.get("new_events", []):
        if ev.get("type") not in VALID_EVENT_TYPES:
            ev["type"] = "observation"
        new_events.append(ev)

    past_events = []
    for ev in parsed.get("past_events", []):
        if ev.get("status") in ("updated", "deleted") and ev.get("id"):
            past_events.append(ev)

    clean_transcript = parsed.get("transcript", [])

    return {
        "relevant": relevant,
        "transcript": clean_transcript,
        "new_events": new_events,
        "past_events": past_events,
        "usage": usage,
    }


# ---------------------------------------------------------------------------
# Relevance check (cheap text call — used as server-side fallback only)
# ---------------------------------------------------------------------------
#
# The primary relevance gate now lives on-device (Swift TranscriptFilter).
# This function is the server-side safety net for the small fraction of
# transcripts that reach the backend but weren't filtered by the iOS client
# (e.g. future web clients, test scripts, or edge cases in TranscriptFilter).
#
# It is NOT called in the main audio pipeline (MonitorViewModel.handleClip
# uses TranscriptFilter directly and skips the network entirely for irrelevant
# clips). It remains available as a standalone endpoint (/check-relevance) for
# tooling and debugging.
#
# Why keep the on-device filter AND this server-side check?
#   Defence in depth. The iOS filter saves money and latency. This function
#   catches anything the iOS filter missed without requiring a full Gemini analysis.
#
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

    # Fast local keyword check — avoids API call for most transcripts
    local = _keyword_relevance_check(transcript, baby_name)
    if local is not None:
        return {"relevant": local, "reason": "keyword match" if local else "no keywords", "usage": {}}

    # Uncertain — fall through to cheap Gemini lite model
    client = _client()
    prompt = _RELEVANCE_USER.format(
        baby_name=baby_name,
        baby_age_months=baby_age_months,
        transcript=transcript[:500],  # shorter = cheaper
    )
    response = client.models.generate_content(
        model=RELEVANCE_MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            system_instruction=_RELEVANCE_SYSTEM,
            # temperature=0.0: fully deterministic for a binary yes/no task.
            # Any variation here risks flipping the answer on identical inputs.
            temperature=0.0,
            response_mime_type="application/json",
        ),
    )
    text = response.text or '{"relevant": false, "reason": "no response"}'
    usage = {
        "input_tokens": response.usage_metadata.prompt_token_count or 0,
        "output_tokens": response.usage_metadata.candidates_token_count or 0,
    }
    usage["cost_usd"] = _record_usage("relevance", RELEVANCE_MODEL, usage["input_tokens"], usage["output_tokens"])
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        # Parse failure → allow through (false negative is better than false positive here:
        # better to analyse something irrelevant than to silently drop a real event).
        parsed = {"relevant": True, "reason": "parse error, allowing through"}
    parsed["usage"] = usage
    return parsed


# ---------------------------------------------------------------------------
# Voice note processing (edit mode or support mode)
# ---------------------------------------------------------------------------
#
# Why one endpoint for two very different tasks?
#   "Edit" and "Support" share the same trigger (hold-to-record button) and
#   the same audio pipeline (record → transcribe → send). The difference is
#   only in what Gemini does with the transcript. One endpoint keeps the iOS
#   code simple: it sends mode="edit" or mode="support" and gets back a
#   unified response shape.
#
# "Edit" mode (mode="edit"):
#   The caregiver is correcting the log. Gemini acts as a structured editor:
#   extract new events and corrections from the voice note.
#   Context: last N events from today's log (so Gemini can match "the 3pm feed"
#   to the actual event ID). Capped at cfg.VOICE_NOTE_EVENT_CONTEXT_LIMIT to
#   avoid sending the entire day's log for a minor correction.
#
# "Support" mode (mode="support"):
#   The caregiver wants to talk — vent, ask a question, get reassurance.
#   Gemini responds as a warm parenting companion. No event extraction happens.
#   Keeping this in the same endpoint means the same audio path handles both
#   use cases without adding an extra API endpoint on the server.
#
# Alternative: separate endpoints (/voice-note/edit and /voice-note/support).
#   Cleaner REST design but adds boilerplate on both iOS and server sides for
#   what is functionally a single-switch difference in prompt selection.
#
# Temperature = 0.2 for edit, same for support:
#   Edit mode stays near-deterministic (extraction task). Support mode could
#   use higher temperature for more varied, natural-feeling responses, but 0.2
#   keeps it grounded enough to avoid hallucinating parenting advice.
#
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
        prompt = f"Baby: {baby_name}, {baby_age_months}mo.\nCaregiver says: \"{transcript}\""
    else:
        # Cap to last N events — older history isn't needed for corrections.
        # Alternative: send all events and let Gemini choose relevant context.
        #   Rejected: more tokens, higher cost, and Gemini performs equally well
        #   with a short recent window for the correction tasks we've observed.
        recent_events = (events_today or [])[-cfg.VOICE_NOTE_EVENT_CONTEXT_LIMIT:]
        system = _VOICE_NOTE_EDIT_SYSTEM
        prompt = (
            f"Baby: {baby_name}, {baby_age_months}mo.\n"
            f"Recent log:\n{_compact_events(recent_events)}\n\n"
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
    usage["cost_usd"] = _record_usage("voice_note", MODEL, usage["input_tokens"], usage["output_tokens"])
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = {"reply": "Got it!", "new_events": [], "corrections": []}
    parsed["usage"] = usage
    return parsed


# ---------------------------------------------------------------------------
# Audio vault analysis (1-hour batch — native audio input to Gemini)
# ---------------------------------------------------------------------------
#
# Why send audio directly instead of transcripts?
#   The real-time pipeline sends transcripts (text). Gemini hears what the ASR
#   captured but not tone, emotion, baby vocalizations, or quiet speech below
#   the VAD threshold. Sending actual audio to Gemini 2.0+ lets it:
#     1. Hear the emotional tone of the caregiver's voice
#     2. Catch events the ASR missed or mis-transcribed
#     3. Detect emotional distress from vocal quality alone
#   This is the "second opinion" pass — it logs what the fast pipeline missed.
#
# Cost:
#   Gemini charges ~$0.001/sec of audio for 2.0 Flash. 60 minutes = ~$3.60 worst-case,
#   but only clips that passed VAD + speech gate are included — typically 5–15 min/hour.
#   ~$0.30–0.90/hour at full sensitivity. This is configurable via max clips.

_VAULT_SYSTEM = """You are Babble, a baby activity monitor reviewing audio clips from the past hour.
You will receive multiple audio segments with timestamps. Listen carefully to each.

Your tasks:
1. Extract baby care events (feeding, sleep, diapers, milestones, etc.)
2. Detect emotional distress in the caregiver's voice or words — if a caregiver sounds overwhelmed, is crying, or expresses hopelessness, log an emotional_support event.
3. Note anything the text log might have missed — quiet whispers, crying, background context.

Rules:
- Only log events you are confident actually happened.
- emotional_support: caregiver is clearly distressed (crying, saying they can't cope, exhausted beyond tiredness). Mark notable=true.
- Do not duplicate events already in [Existing events today].
- Timestamps: ISO 8601 UTC. Use the provided clip timestamps as reference.
- status: "confirmed" for clear events, "tentative" for uncertain.

Event types: feeding | nap_start | nap_end | cry | diaper | outing | health_note | activity | new_food | milestone | emotional_support | observation

Return ONLY valid JSON:
{
  "new_events": [
    {
      "ts": "<ISO 8601 UTC>",
      "type": "<event_type>",
      "description": "<what happened>",
      "status": "confirmed" | "tentative",
      "person": "baby" | "caregiver",
      "notable": <true|false>
    }
  ],
  "summary": "<one warm sentence about the hour>",
  "emotional_support_needed": <true|false>
}
If nothing new was found, return {"new_events": [], "summary": "Quiet hour.", "emotional_support_needed": false}
"""


def analyze_audio_vault(
    clips: list[dict],
    baby_name: str,
    baby_age_months: int,
    existing_events: list[dict],
    date_str: str,
) -> dict:
    """
    Analyze a batch of audio clips (from the past hour) using Gemini's native audio input.

    clips: [{"audio_base64": str, "timestamp": str, "duration_seconds": float,
              "transcript": str, "trigger_kind": str}]
    Returns: {"new_events": [...], "summary": str, "emotional_support_needed": bool, "usage": {...}}
    """
    if not clips:
        return {"new_events": [], "summary": "No audio clips.", "emotional_support_needed": False, "usage": {}}

    client = _client()

    # Build the prompt content — interleave text labels with inline audio parts
    contents = []

    prompt_intro = (
        f"Baby: {baby_name}, {baby_age_months}mo. Date: {date_str}.\n\n"
        f"[Existing events today — do not duplicate these]\n"
        f"{_compact_events(existing_events) or '(none yet)'}\n\n"
        f"Now review {len(clips)} audio clip(s) from the past hour:"
    )
    contents.append(prompt_intro)

    for i, clip in enumerate(clips):
        ts = clip.get("timestamp", "")[:16]
        dur = clip.get("duration_seconds", 0)
        kind = clip.get("trigger_kind", "auto")
        transcript_hint = clip.get("transcript", "").strip()

        label = f"\n--- Clip {i+1}/{len(clips)} | {ts} UTC | {dur:.0f}s | trigger={kind}"
        if transcript_hint:
            label += f"\n(ASR hint: \"{transcript_hint[:120]}\")"
        contents.append(label)

        # Inline audio as base64
        audio_b64 = clip.get("audio_base64", "")
        if audio_b64:
            contents.append(
                types.Part.from_bytes(
                    # AudioVaultService always encodes with base64EncodedString() — always base64.
                    data=base64.b64decode(audio_b64),
                    mime_type=clip.get("mime_type", "audio/wav"),
                )
            )

    contents.append("\nExtract all baby care events and emotional support signals from these clips.")

    response = client.models.generate_content(
        model=MODEL,
        contents=contents,
        config=types.GenerateContentConfig(
            system_instruction=_VAULT_SYSTEM,
            temperature=0.15,
            response_mime_type="application/json",
        ),
    )

    text = response.text or "{}"
    usage = {
        "input_tokens": response.usage_metadata.prompt_token_count or 0,
        "output_tokens": response.usage_metadata.candidates_token_count or 0,
    }
    usage["cost_usd"] = _record_usage("vault", MODEL, usage["input_tokens"], usage["output_tokens"])

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        logger.error(f"Vault analysis: invalid JSON: {text[:300]}")
        parsed = {}

    new_events = []
    for ev in parsed.get("new_events", []):
        if ev.get("type") not in VALID_EVENT_TYPES:
            ev["type"] = "observation"
        new_events.append(ev)

    logger.info("[VAULT] clips=%d → events=%d emotional_support=%s cost=$%.4f",
                len(clips), len(new_events),
                parsed.get("emotional_support_needed", False),
                usage.get("cost_usd", 0))

    return {
        "new_events": new_events,
        "summary": parsed.get("summary", ""),
        "emotional_support_needed": bool(parsed.get("emotional_support_needed", False)),
        "usage": usage,
    }


# ---------------------------------------------------------------------------
# Daily summary
# ---------------------------------------------------------------------------
#
# Why generate the summary on-demand (not automatically at day end)?
#   Parents open the summary at unpredictable times — some at 9pm, some the
#   next morning. Running it at a fixed time (e.g. midnight cron) would mean
#   the summary is outdated by the time they read it. On-demand generation
#   always uses the latest events.
#
#   Downside: costs tokens on every tap. Mitigated by caching: the backend
#   caches the generated summary keyed by (date, event_count). If no new events
#   were logged since the last generation, the cached version is returned.
#   See /summary endpoint in main.py.
#
# Why a higher temperature (0.4) for summary vs analysis (0.1)?
#   The summary is a narrative text, not a structured extraction. Some variation
#   in phrasing makes it feel personal rather than formulaic. 0.4 still keeps
#   it factually grounded — we're not generating fiction, just warm prose.
#   Alternative: temperature=0 for fully reproducible summaries.
#   Tradeoff: deterministic summaries feel robotic after reading them a few days
#   in a row; 0.4 introduces enough variation to feel fresh.
#
# Why include event count in the prompt?
#   Gemini performs better when given an explicit count — it's less likely to
#   invent events or miss sections when it knows exactly how many events to
#   account for. Cheap signal, noticeable quality improvement in testing.
#
_SUMMARY_SYSTEM = """You are Babble, a warm baby activity summarizer.
Given today's logged events for a baby, produce a structured daily report.

Tone: warm and factual, like a thoughtful friend summarizing the day. Not clinical.
Good: "Rough start to the morning but she turned it around after the nap."
Bad: "Infant exhibited elevated fussiness in the 07:00–09:00 window."

Return ONLY valid JSON matching this exact schema (omit sections with no data):
{
  "one_liner": "<single warm sentence capturing the vibe of the day>",
  "stats_bar": {
    "feed_count": <int|null>,
    "sleep_hours_total": <float|null>,
    "wet_count": <int|null>,
    "dirty_count": <int|null>,
    "health_status": "normal" | "flagged"
  },
  "feeding": {
    "total_count": <int>,
    "total_volume": "<string like '~22 oz' or null>",
    "entries": [
      {"time": "7:10 am", "type": "Bottle", "detail": "4 oz"},
      {"time": "9:45 am", "type": "Breast L/R", "detail": "L 12 min · R 8 min"},
      {"time": "12:30 pm", "type": "Solids", "detail": "Sweet potato, first time"}
    ],
    "flags": ["<warning if any, e.g. fewer than expected feeds, new allergen>"]
  },
  "sleep": {
    "total_minutes": <int>,
    "day_minutes": <int>,
    "night_minutes": <int>,
    "entries": [
      {"label": "Nap 1", "start": "9:05 am", "end": "10:50 am", "duration_minutes": 105},
      {"label": "Night", "start": "7:30 pm", "end": "6:15 am", "duration_minutes": 645, "notes": "woke 2x: 12:40am, 3:55am"}
    ],
    "flags": ["<warning if any, e.g. total sleep below age range>"]
  },
  "diapers": {
    "wet_count": <int>,
    "dirty_count": <int>,
    "note": "<anomaly note if any, e.g. unusual color>"
  },
  "health": {
    "entries": [
      {"time": "11:30 am", "detail": "Temp 38.1°C — low-grade, monitored"},
      {"time": "2:00 pm", "detail": "Tylenol 2.5 mL given"}
    ],
    "summary": "<brief health note>"
  },
  "milestones": ["<milestone or notable moment, written warmly, one sentence each>"],
  "mood_arc": "<paragraph describing emotional tone across the day>",
  "pediatrician_summary": "<structured plain-text for doctor: sleep, feeding, diapers, milestones, concerns>",
  "social_tweet": "<tweet-length summary with emoji, under 280 chars>"
}
Omit "health" entirely if no health events were logged.
Omit "milestones" if no milestones were detected.
"""


def generate_summary(
    events: list[dict],
    baby_name: str,
    baby_age_months: int,
    date_str: str,
) -> dict:
    """Generate a rich structured daily summary from events."""
    if not events:
        return {
            "one_liner": f"Looks like a quiet day for {baby_name}!",
            "stats_bar": {"health_status": "normal"},
            "social_tweet": f"Quiet day with {baby_name} \U0001f495",
            "usage": {},
        }

    client = _client()
    prompt = (
        f"Baby: {baby_name}, {baby_age_months} months old. Date: {date_str}.\n\n"
        f"Today's logged events ({len(events)} total):\n{_compact_events(events)}"
    )

    response = client.models.generate_content(
        model=MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            system_instruction=_SUMMARY_SYSTEM,
            # 0.4: warmer, more varied prose. See module-level note on temperature choices.
            temperature=0.4,
            response_mime_type="application/json",
        ),
    )
    text = response.text or "{}"
    usage = {
        "input_tokens": response.usage_metadata.prompt_token_count or 0,
        "output_tokens": response.usage_metadata.candidates_token_count or 0,
    }
    usage["cost_usd"] = _record_usage("summary", MODEL, usage["input_tokens"], usage["output_tokens"])
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        logger.error(f"Summary: Gemini returned invalid JSON: {text[:300]}")
        parsed = {
            "one_liner": f"Today was a full day with {baby_name}.",
            "social_tweet": f"Another wonderful day with {baby_name} \U0001f37c",
        }
    parsed["usage"] = usage
    return parsed
