"""Gemini 2.5 Flash helpers for Babble (audio analysis + summary generation).

Each function returns a (result, usage) tuple.
usage = {"input_tokens": int, "output_tokens": int, "cost_usd": float}

Gemini 2.5 Flash pricing (≤200K context, as of March 2026):
  Input:  $0.075 / 1M tokens
  Output: $0.30  / 1M tokens
"""

import base64
import json
import os
import re
from typing import Optional

from google import genai
from google.genai import types

_client: Optional[genai.Client] = None
MODEL = "gemini-2.5-flash"

# Valid event types — must match the type list in ANALYZE_SYSTEM prompt
_VALID_EVENT_TYPES = frozenset({
    "feeding", "nap", "cry", "diaper", "outing",
    "health_note", "activity", "new_food", "milestone", "observation",
})

# Source field values used in Gemini output and backend filter
SOURCE_NEW_AUDIO = "new_audio"      # evidence heard in the current clip
SOURCE_PAST_CONTEXT = "past_context"  # inferred from reference audio or events_today

# Pricing per 1M tokens (Gemini 2.5 Flash, ≤200K context)
_INPUT_COST_PER_M  = 0.075
_OUTPUT_COST_PER_M = 0.30


def _extract_usage(response) -> dict:
    """Pull token counts from response.usage_metadata and compute cost."""
    meta = getattr(response, "usage_metadata", None)
    inp  = getattr(meta, "prompt_token_count", 0) or 0
    out  = getattr(meta, "candidates_token_count", 0) or 0
    cost = (inp * _INPUT_COST_PER_M + out * _OUTPUT_COST_PER_M) / 1_000_000
    return {"input_tokens": inp, "output_tokens": out, "cost_usd": round(cost, 6)}


def get_client() -> genai.Client:
    global _client
    if _client is None:
        api_key = os.environ.get("GOOGLE_API_KEY")
        if api_key:
            _client = genai.Client(api_key=api_key)
        else:
            _client = genai.Client()  # uses ADC / GOOGLE_CLOUD_PROJECT
    return _client


def _is_vague_babble(event: dict) -> bool:
    """Return True for activity events whose detail is a vague babble/coo/vocalization.

    These get a stricter confidence threshold (≥80) to reduce noise.
    """
    if event.get("event_type") != "activity":
        return False
    detail = (event.get("new_logging_detail") or "").lower()
    return any(t in detail for t in ("babbl", "coo", "vocaliz"))


def _confidence_threshold(event: dict, clip_duration_sec: float | None) -> int:
    """Return the minimum confidence required to keep this event."""
    if clip_duration_sec is not None and clip_duration_sec < 5.0:
        return 90  # short clips: raise bar across the board
    if event.get("evidence_source") == "baby_voice":
        return 85  # baby voice only — higher bar to avoid background noise false positives
    if _is_vague_babble(event):
        return 80  # vague babble activity: elevated threshold
    return 70      # caregiver_speech / both / standard


def _parse_json_response(text: str) -> any:
    """Extract JSON from Gemini response text (strips markdown code fences if present)."""
    text = text.strip()
    # Strip ```json ... ``` or ``` ... ```
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    return json.loads(text)


ANALYZE_SYSTEM = """You are a baby monitor for {baby_name}, age {baby_age_months} months.
Current clip timestamp: {clip_timestamp}
Today's events so far: {events_json}
Previous clip summary: "{last_clip_summary}"{reference_note}

══ STEP 1: IS THIS CLIP WORTH LOGGING? ═════════════════════════════

Log an event only if the clip contains one of:
  A. {baby_name}'s own sounds — crying, babbling, words, laughter
  B. Caregiver speech to or about {baby_name} — commands, reactions, corrections
  C. Caregiver performing care on {baby_name} — diaper, feeding, bathing, dressing
     Caregiver care speech is ALWAYS worth logging even without baby sounds.
     "let's change the diaper" · "let's change diaper" · "oh it's wet" → diaper event
     No baby name required — care actions are by definition about {baby_name}.

Always ignore: background TV · music · traffic · adult conversation with no baby involvement.
If normal-tone reference clips are provided, parentese (higher pitch, slower pace, sing-song)
means the caregiver is addressing {baby_name} even without saying the name.

Only skip:
  - Name called with nothing following ("Luca?" then silence)
  - Vague baby sound with no caregiver reaction
  - Single proto-words ("da", "ba") unless caregiver reacted as a milestone

══ STEP 2: WHICH EVENT TYPE? ═══════════════════════════════════════

feeding     — food/drink offered or consumed; quantity, reaction
nap         — fell asleep / woke / duration
cry         — audible crying or mention of it; reason if known
diaper      — any check or change; includes dry checks ("seems dry, let's keep it")
              infer entirely from caregiver speech — no baby sounds needed
outing      — location, who went, what happened
health_note — rash, fever, medicine, doctor
activity    — {baby_name} actively doing something: walking, laughing, biting, throwing, exploring
              (skip soft background babbling with no caregiver reaction)
new_food    — first time eating something new
milestone   — first word/step/skill; set notable:true if remarkable for {baby_age_months} months
observation — corrections, repeated behaviors, mood, personality

══ STEP 3: NEW EVENT OR ENRICHMENT? ════════════════════════════════

new_logging: TRUE  [CURRENT CLIP] — evidence is directly heard in THIS clip right now
  → Always TRUE for caregiver care actions (diaper/feeding/bathing) heard in this clip
  → TRUE for any baby sound heard in this clip
  → TRUE for any new information not yet in events_today

new_logging: FALSE [CONTEXT] — inferred from reference clips / events_today / last_clip_summary
  → Clip only continues an already-logged event with no new facts
  → Caregiver refers to something that happened earlier ("he bit earlier")
  → Inference from reference audio about something still ongoing

══ OUTPUT FORMAT ════════════════════════════════════════════════════

STYLE: Warm, vivid, present-tense. Use caregiver's role/name, never "Caregiver".
If you hear a role name ("daddy's here", "come to mommy") set caregiver_hint.{known_note}

Return JSON array ([] if nothing detected).

── PATH A: new_logging = true ───────────────────────────────────────
{{
  "new_logging": true,
  "event_type": "feeding|nap|cry|diaper|outing|health_note|activity|new_food|milestone|observation",
  "new_logging_timestamp": "<ISO 8601>",
  "new_logging_detail": "<warm vivid description>",
  "confidence": 0-100,
  "notable": false,
  "evidence_source": "baby_voice|caregiver_speech|both",
  "caregiver_hint": "<role/name from spoken words, or null>",
  "caregiver_voice_match": "<caregiver name matched by voice, or null>",
  "caregiver_voice_segment": {{"start_sec": 0.0, "end_sec": 0.0}},
  "past_content_id": null,
  "past_content_detail": null
}}

── PATH B: new_logging = false ──────────────────────────────────────
{{
  "new_logging": false,
  "event_type": "feeding|nap|cry|diaper|outing|health_note|activity|new_food|milestone|observation",
  "new_logging_timestamp": null,
  "new_logging_detail": null,
  "confidence": 0-100,
  "notable": false,
  "evidence_source": "baby_voice|caregiver_speech|both",
  "caregiver_hint": null,
  "caregiver_voice_match": null,
  "caregiver_voice_segment": null,
  "past_content_id": "<ID of event to update, or null — backend will find it>",
  "past_content_detail": "<detail to merge into existing event>"
}}

RULES:
- evidence_source: "baby_voice" = {baby_name}'s sounds only · "caregiver_speech" = caregiver words only · "both" = both
- PATH A requires: event_type + new_logging_timestamp + new_logging_detail
- PATH B requires: event_type + past_content_detail
- caregiver_voice_segment: {{start_sec, end_sec}} when caregiver_voice_match is non-null; else null
- Confidence minimums: caregiver_speech events ≥ 70 · baby_voice events ≥ 85 · baby_voice in clips < 5s ≥ 90"""

SUMMARY_PROMPT = """Baby: {baby_name}, age {baby_age_months} months.
Today's events (JSON): {events_json}

Generate a day summary. Return JSON with exactly these keys:

{{
  "structured": {{
    "glance": ["<emoji + 5-8 word phrase>", "<emoji + 5-8 word phrase>"],
    "monitored_hrs": <float: seconds from first to last event timestamp / 3600>,
    "recording_gap": "<e.g. 'around noon'>" or null,

    "eating": {{
      "bullets": ["<Water/Breakfast/Lunch/Dinner/Snack · brief log, note if self-fed>"],
      "milk": {{"type": "formula|breast_milk|whole_milk|unknown", "amount": "<or null>"}},
      "new_food": "<first-time food name, or null>",
      "tip": "<one sentence feeding insight for {baby_age_months} months>"
    }},

    "nap": {{
      "bullets": ["<start time · duration · fell asleep independently or assisted>"],
      "tip": "<one sentence sleep insight for {baby_age_months} months>"
    }},

    "diaper": {{
      "wet": <int or null>,
      "poop": <int or null>,
      "color": "<if mentioned, or null>",
      "consistency": "<if mentioned, or null>",
      "uncertain": <true if inferred from speech>,
      "tip": "<one sentence digestion tip for {baby_age_months} months>"
    }},

    "play_mood": {{
      "bullets": ["<log entry>"],
      "tip": "<one sentence development insight for {baby_age_months} months>"
    }},

    "milestone": {{
      "bullet": "<what happened · time>",
      "tip": "<one sentence on where this fits in typical {baby_age_months}-month development>"
    }},

    "outing": {{
      "bullets": ["<where · how reacted · new sensory experiences>"],
      "tip": "<one sentence insight on exploration at this age>"
    }},

    "health": {{
      "bullets": ["<symptom/fever temp · medication name+dose+time · vaccine/doctor visit>"],
      "tip": "<one sentence health insight relevant to what happened>"
    }}
  }},
  "narrative": "<2-3 warm sentences for family sharing>",
  "social_tweet": "<see rules below>"
}}

STRUCTURED rules:
- All sections are null if no events of that type occurred. Skip null sections entirely.
- glance: exactly 2 items. Milestone first if one occurred.
- eating bullets: max 5. Meal label inferred from time + food type. No duplicate labels.
- nap bullets: max 3. Track duration + independence — doctors ask about this at checkups.
- diaper: separate wet/poop counts; uncertain=true if guessing from audio.
  Pediatricians flag <4 wet/day; poop every 1–3 days is normal at this age.
- play_mood bullets: max 4. Combine play + fussiness. Capture motor skills (cruising,
  standing, steps), language (proto-words, directed babbling), social play (imitation,
  peek-a-boo), emotional triggers, boundary testing. These entries become developmental
  records when looked back on after a month or year.
- milestone bullet: exactly 1 with time. First words/steps/waves/claps are baby book entries.
- outing bullets: max 2. New environments, people, sensory firsts are worth capturing.
- health bullets: max 3. Fever temp, medication name+dose+time, vaccine date — these
  matter at the next doctor visit and for long-term health records.
- All tips: one sentence only. A calm, factual observation tied specifically to what happened — not a textbook developmental milestone everyone knows. No "try", "consider", "make sure", "you should". Avoid obvious statements like "babies respond to their name" or "toddlers explore boundaries". Pick something specific and less obvious about this age or this behavior.
- Bullet style: concise log. Use · between sub-info. Times only for milestones.

SOCIAL_TWEET rules — written as {baby_name}, first-person, max 240 chars, end #Babble:
  Step 1: choose the ONE best moment from the entire day. Pick exactly one:
    🏆 HERO — milestone, first word/step/skill
    😂 FUNNY — absurd, chaotic, unintentionally hilarious
    💛 MEMORABLE — tender, sweet, quietly beautiful
    💔 HEARTBREAK — hard day, teething, refused favourite food, separation anxiety
  Step 2: write 1-2 sentences about THAT ONE MOMENT ONLY. CAPS for the peak word.
  STRICT RULES:
    - Do NOT combine two events. No "also", "and also", "but also", "plus".
    - One moment. Full stop. Make it land.
  Reframe positively: biting → "teething research", hitting → "high-five practice".
  Examples:
    "Said DA today. Did not know I could do that. Spent the rest of the day thinking about it. 🗣️ #Babble"
    "Found out the keyboard makes a sound for EVERY. SINGLE. KEY. Had to verify each one. 🎹 #Babble"
    "Turns out the banana that was perfect yesterday is now completely unacceptable. Hard day. 🍌 #Babble"
"""


async def analyze_audio(
    audio_bytes: bytes,
    baby_name: str,
    baby_age_months: int,
    events_today: list[dict],
    last_clip_summary: str,
    clip_timestamp: str,
    reference_clips: list[dict] = [],  # [{bytes, type: 'voice_reference'|'recent'|'caregiver', label?}]
    known_caregivers: list[str] = [],  # confirmed caregiver names e.g. ["daddy", "mommy"]
    clip_duration_sec: float | None = None,
) -> tuple[list[dict], dict, list[dict]]:
    """
    Send an audio clip to Gemini 2.5 Flash for event extraction.
    Returns (events, usage, raw_events) where events is confidence-filtered, raw_events is not.
    """
    client = get_client()

    # Build reference note for the system prompt
    n_voice = sum(1 for r in reference_clips if r.get("type") == "voice_reference")
    n_recent = sum(1 for r in reference_clips if r.get("type") == "recent")
    n_caregiver = sum(1 for r in reference_clips if r.get("type") == "caregiver")
    n_normal = sum(1 for r in reference_clips if r.get("type") == "caregiver_normal")
    reference_note = ""
    ref_parts = []
    if n_voice:
        ref_parts.append(f"{n_voice} permanent voice reference clip(s) of {baby_name}")
    if n_recent:
        ref_parts.append(
            f"{n_recent} recent clip(s) already analyzed and logged "
            f"(use for voice comparison AND to refine past events via enriches_event_id if this clip adds context)"
        )
    if n_caregiver:
        caregiver_names = ", ".join(
            r.get("label", "?") for r in reference_clips if r.get("type") == "caregiver"
        )
        ref_parts.append(f"voice clips of known caregivers ({caregiver_names})")
    if n_normal:
        normal_names = ", ".join(
            r.get("label", "?") for r in reference_clips if r.get("type") == "caregiver_normal"
        )
        ref_parts.append(f"normal-tone (adult-to-adult) voice clips of {normal_names}")
    if ref_parts:
        reference_note = "\nReference audio provided before the current clip: " + "; ".join(ref_parts) + "."

    known_note = ""
    if known_caregivers:
        known_note = f"\nKnown caregivers for {baby_name}: {', '.join(known_caregivers)}."

    system_prompt = ANALYZE_SYSTEM.format(
        baby_name=baby_name,
        baby_age_months=baby_age_months,
        clip_timestamp=clip_timestamp,
        events_json=json.dumps(events_today, default=str),
        last_clip_summary=last_clip_summary or "none",
        reference_note=reference_note,
        known_note=known_note,
    )

    duration_note = f" Clip duration: {clip_duration_sec:.1f}s." if clip_duration_sec is not None else ""
    prompt = (
        f"Audio clip recorded at {clip_timestamp}.{duration_note} "
        "Analyze this audio and return the JSON event array as instructed."
    )

    # Build contents: voice reference → recent clips → caregiver voices → normal tones → clip to analyze
    contents = []
    voice_refs = [r for r in reference_clips if r.get("type") == "voice_reference"]
    recent_refs = [r for r in reference_clips if r.get("type") == "recent"]
    caregiver_refs = [r for r in reference_clips if r.get("type") == "caregiver"]
    normal_refs = [r for r in reference_clips if r.get("type") == "caregiver_normal"]

    for r in voice_refs:
        contents.append(types.Part.from_bytes(data=r["bytes"], mime_type=r.get("mime_type", "audio/webm")))
    if voice_refs:
        contents.append(types.Part.from_text(
            text=f"Above: {baby_name}'s permanent voice reference — their most characteristic sounds. "
                 f"Use it to recognize {baby_name}'s voice in the clip to analyze below."
        ))

    for r in recent_refs:
        contents.append(types.Part.from_bytes(data=r["bytes"], mime_type=r.get("mime_type", "audio/webm")))
    if recent_refs:
        contents.append(types.Part.from_text(
            text=(
                f"Above: {len(recent_refs)} recent audio clip(s) of {baby_name} that were already analyzed "
                f"and logged. Use them for two purposes: "
                f"(1) voice comparison — identify {baby_name}'s voice in the clip below; "
                f"(2) re-evaluation — if the current clip clarifies or updates what was detected in the recent clips, "
                f"use enriches_event_id to refine those events rather than creating duplicates."
            )
        ))

    for r in caregiver_refs:
        contents.append(types.Part.from_bytes(data=r["bytes"], mime_type=r.get("mime_type", "audio/webm")))
    if caregiver_refs:
        names = ", ".join(r.get("label", "?") for r in caregiver_refs)
        contents.append(types.Part.from_text(
            text=f"Above: voice clips of known caregivers ({names}). "
                 f"Match the speaker in the clip below to one of these names if possible "
                 f"and set caregiver_voice_match accordingly."
        ))

    for r in normal_refs:
        contents.append(types.Part.from_bytes(data=r["bytes"], mime_type=r.get("mime_type", "audio/webm")))
    if normal_refs:
        names = ", ".join(r.get("label", "?") for r in normal_refs)
        contents.append(types.Part.from_text(
            text=f"Above: normal adult-voice clips of {names} when NOT speaking to the baby. "
                 f"Notice the tone, pitch, and pace. If you hear a shift to higher pitch, "
                 f"slower pace, or exaggerated intonation in the clip below — that's infant-directed "
                 f"speech (parentese), meaning the caregiver is addressing {baby_name} "
                 f"even if the baby's name is never said."
        ))

    # The clip to analyze
    contents.append(types.Part.from_bytes(data=audio_bytes, mime_type="audio/webm"))
    contents.append(types.Part.from_text(text=prompt))

    response = await client.aio.models.generate_content(
        model=MODEL,
        contents=contents,
        config=types.GenerateContentConfig(
            system_instruction=system_prompt,
            response_mime_type="application/json",
            temperature=0.2,
        ),
    )

    usage = _extract_usage(response)

    raw = response.text or "[]"
    try:
        events = _parse_json_response(raw)
        if not isinstance(events, list):
            print(f"[gemini] WARNING: expected list, got {type(events).__name__}: {raw[:200]}")
            events = []
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"[gemini] WARNING: JSON parse failed ({exc}): {raw[:300]}")
        events = []

    # Drop events missing required fields — these would cause Firestore write errors
    events = [
        e for e in events
        if e.get("event_type") in _VALID_EVENT_TYPES
        and (
            # new_logging:true requires timestamp + detail
            (e.get("new_logging") and e.get("new_logging_timestamp") and e.get("new_logging_detail"))
            # new_logging:false requires past_content_detail (type already checked above)
            or (not e.get("new_logging") and e.get("past_content_detail"))
        )
    ]

    # Deep-copy dicts before filtering so that pop() on 'events' items in main.py
    # cannot mutate the raw_events dicts (shallow copy shares references).
    raw_events = [dict(e) for e in events]

    # Filter by confidence; short clips and vague babble get a stricter threshold
    events = [
        e for e in events
        if e.get("confidence", 0) >= _confidence_threshold(e, clip_duration_sec)
    ]
    return events, usage, raw_events


async def generate_summary(
    baby_name: str,
    baby_age_months: int,
    events: list[dict],
) -> tuple[dict, dict]:
    """
    Generate a structured/narrative/social_tweet summary from today's events.
    Returns (summary_dict, usage) where usage = {"input_tokens", "output_tokens", "cost_usd"}.
    """
    client = get_client()

    if not events:
        return {
            "structured": {},
            "narrative": f"It's a quiet day for {baby_name} so far — nothing logged yet.",
            "social_tweet": f"Today is a mystery 🤫 #Babble",
        }, {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0}

    prompt = SUMMARY_PROMPT.format(
        baby_name=baby_name,
        baby_age_months=baby_age_months,
        events_json=json.dumps(events, default=str),
    )

    response = await client.aio.models.generate_content(
        model=MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            temperature=0.7,
        ),
    )

    usage = _extract_usage(response)

    raw = response.text or "{}"
    try:
        summary = _parse_json_response(raw)
    except (json.JSONDecodeError, ValueError):
        summary = {}

    return {
        "structured": summary.get("structured", {}),
        "narrative": summary.get("narrative", ""),
        "social_tweet": summary.get("social_tweet", ""),
    }, usage
