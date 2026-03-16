"""
Backend integration tests for audio analysis.

## Setup
1. Run the Babble app for 10–15 minutes while Luca is active.
2. Click "📥 Export Test Clips" in the debug panel — browser downloads .webm files.
3. Move downloaded files into this directory: backend/tests/fixtures/
   - Files named luca_conf*.webm  → clips where Luca sounds were detected (confidence > 60)
   - Files named no_luca_*.webm  → clips with no confirmed Luca sounds

## Running
    cd babble
    pip install pytest pytest-asyncio
    pytest backend/tests/ -v

## Notes
- Tests make real Gemini API calls — requires GOOGLE_API_KEY in environment
- Test results may vary slightly between runs (LLM non-determinism)
- luca_* tests assert at least one raw event is detected (lenient)
- no_luca_* tests assert no high-confidence (>= 75) events are returned (strict)
"""

import os
import sys
import types as builtin_types
import pytest
from pathlib import Path

# Add backend directory to import path
sys.path.insert(0, str(Path(__file__).parent.parent))

import gemini_client as gemini

FIXTURES = Path(__file__).parent / "fixtures"
BABY_NAME = "Luca"
BABY_AGE_MONTHS = 12
TEST_TIMESTAMP = "2026-03-15T00:00:00Z"

VALID_EVENT_TYPES = gemini._VALID_EVENT_TYPES


def _has_fixtures(pattern: str) -> bool:
    return bool(list(FIXTURES.glob(pattern)))


def _fixture_ids(pattern: str):
    """Return (path, id) pairs for parametrize — id is just the filename."""
    return [(p, p.name) for p in sorted(FIXTURES.glob(pattern))]


@pytest.mark.asyncio
@pytest.mark.skipif(not _has_fixtures("luca_*.webm"), reason="No luca_*.webm fixtures — export from the app first")
async def test_luca_clips_detect_events():
    """Clips exported with hasLucaSound=true should return at least one raw event."""
    clips = list(FIXTURES.glob("luca_*.webm"))
    for clip_path in clips:
        _, _, raw = await gemini.analyze_audio(
            audio_bytes=clip_path.read_bytes(),
            baby_name=BABY_NAME,
            baby_age_months=BABY_AGE_MONTHS,
            events_today=[],
            last_clip_summary="",
            clip_timestamp=TEST_TIMESTAMP,
        )
        assert len(raw) > 0, (
            f"Expected at least one detected event from {clip_path.name}, got none. "
            f"This clip was tagged as containing Luca sounds — Gemini should detect something."
        )


@pytest.mark.asyncio
@pytest.mark.skipif(not _has_fixtures("no_luca_*.webm"), reason="No no_luca_*.webm fixtures — export from the app first")
async def test_no_luca_clips_are_quiet():
    """Clips exported with no confirmed Luca sounds should have no high-confidence events."""
    for clip_path in FIXTURES.glob("no_luca_*.webm"):
        _, _, raw = await gemini.analyze_audio(
            audio_bytes=clip_path.read_bytes(),
            baby_name=BABY_NAME,
            baby_age_months=BABY_AGE_MONTHS,
            events_today=[],
            last_clip_summary="",
            clip_timestamp=TEST_TIMESTAMP,
        )
        high_conf = [e for e in raw if e.get("confidence", 0) >= 75]
        assert not high_conf, (
            f"Unexpected high-confidence events in {clip_path.name}: "
            f"{[e.get('detail') for e in high_conf]}"
        )


@pytest.mark.asyncio
async def test_analyze_returns_correct_structure():
    """analyze_audio() must always return (list, dict, list) with required usage keys."""
    # Use a minimal 1-second silent webm — won't detect anything, just checks return shape
    # Real fixture clips preferred, but this validates the function contract even without fixtures
    silent_clips = list(FIXTURES.glob("no_luca_*.webm")) or list(FIXTURES.glob("*.webm"))
    if not silent_clips:
        pytest.skip("No fixture clips available — export from the app first")

    events, usage, raw = await gemini.analyze_audio(
        audio_bytes=silent_clips[0].read_bytes(),
        baby_name=BABY_NAME,
        baby_age_months=BABY_AGE_MONTHS,
        events_today=[],
        last_clip_summary="",
        clip_timestamp=TEST_TIMESTAMP,
    )
    assert isinstance(events, list)
    assert isinstance(raw, list)
    assert isinstance(usage, dict)
    assert "input_tokens" in usage
    assert "output_tokens" in usage
    assert "cost_usd" in usage
    # raw_events must preserve confidence (not mutated by main.py's pop)
    for e in raw:
        assert "confidence" in e, f"confidence missing from raw_event: {e}"


# ---------------------------------------------------------------------------
# Integration tests — per-clip parametrized
# ---------------------------------------------------------------------------

_LUCA_CONF100 = _fixture_ids("luca_conf100_*.webm")
_LUCA_ALL     = _fixture_ids("luca_*.webm")
_NO_LUCA      = _fixture_ids("no_luca_*.webm")


@pytest.mark.asyncio
@pytest.mark.skipif(not _has_fixtures("luca_conf100_*.webm"), reason="No luca_conf100_*.webm fixtures")
@pytest.mark.parametrize("clip_path,clip_id", _LUCA_CONF100, ids=[x[1] for x in _LUCA_CONF100])
async def test_luca_conf100_produces_filtered_events(clip_path, clip_id):
    """100%-confidence clips must yield ≥1 event after confidence filtering (≥70)."""
    events, _, _ = await gemini.analyze_audio(
        audio_bytes=clip_path.read_bytes(),
        baby_name=BABY_NAME,
        baby_age_months=BABY_AGE_MONTHS,
        events_today=[],
        last_clip_summary="",
        clip_timestamp=TEST_TIMESTAMP,
    )
    assert len(events) > 0, (
        f"{clip_id}: expected ≥1 filtered event (conf≥70) from a conf100 clip, got none."
    )


@pytest.mark.asyncio
@pytest.mark.skipif(not _has_fixtures("luca_*.webm"), reason="No luca_*.webm fixtures")
@pytest.mark.parametrize("clip_path,clip_id", _LUCA_ALL, ids=[x[1] for x in _LUCA_ALL])
async def test_all_raw_events_have_required_fields(clip_path, clip_id):
    """Every raw event must contain all 7 required schema keys."""
    required = {"type", "timestamp", "detail", "confidence", "notable", "enriches_event_id", "caregiver_hint"}
    _, _, raw = await gemini.analyze_audio(
        audio_bytes=clip_path.read_bytes(),
        baby_name=BABY_NAME,
        baby_age_months=BABY_AGE_MONTHS,
        events_today=[],
        last_clip_summary="",
        clip_timestamp=TEST_TIMESTAMP,
    )
    for event in raw:
        missing = required - event.keys()
        assert not missing, f"{clip_id}: event missing keys {missing}: {event}"


@pytest.mark.asyncio
@pytest.mark.skipif(not _has_fixtures("luca_*.webm"), reason="No luca_*.webm fixtures")
@pytest.mark.parametrize("clip_path,clip_id", _LUCA_ALL, ids=[x[1] for x in _LUCA_ALL])
async def test_all_events_use_valid_types(clip_path, clip_id):
    """Every event type must be from the documented allowed set."""
    _, _, raw = await gemini.analyze_audio(
        audio_bytes=clip_path.read_bytes(),
        baby_name=BABY_NAME,
        baby_age_months=BABY_AGE_MONTHS,
        events_today=[],
        last_clip_summary="",
        clip_timestamp=TEST_TIMESTAMP,
    )
    for event in raw:
        assert event.get("type") in VALID_EVENT_TYPES, (
            f"{clip_id}: invalid event type '{event.get('type')}' in {event}"
        )


@pytest.mark.asyncio
@pytest.mark.skipif(not _has_fixtures("luca_*.webm"), reason="No luca_*.webm fixtures")
@pytest.mark.parametrize("clip_path,clip_id", _LUCA_ALL, ids=[x[1] for x in _LUCA_ALL])
async def test_confidence_filtering_enforced(clip_path, clip_id):
    """Filtered events must all have confidence≥70; vague babble/coo/vocaliz activity needs ≥80."""
    events, _, _ = await gemini.analyze_audio(
        audio_bytes=clip_path.read_bytes(),
        baby_name=BABY_NAME,
        baby_age_months=BABY_AGE_MONTHS,
        events_today=[],
        last_clip_summary="",
        clip_timestamp=TEST_TIMESTAMP,
    )
    for event in events:
        conf = event.get("confidence", 0)
        assert conf >= 70, f"{clip_id}: filtered event has conf={conf} (expected ≥70): {event}"
        if event.get("type") == "activity":
            detail = (event.get("detail") or "").lower()
            if any(t in detail for t in ("babbl", "coo", "vocaliz")):
                assert conf >= 80, (
                    f"{clip_id}: vague babble activity passed filter with conf={conf} (expected ≥80): {event}"
                )


@pytest.mark.asyncio
@pytest.mark.skipif(not _has_fixtures("no_luca_*.webm"), reason="No no_luca_*.webm fixtures")
@pytest.mark.parametrize("clip_path,clip_id", _NO_LUCA, ids=[x[1] for x in _NO_LUCA])
async def test_no_luca_clips_return_empty_filtered_events(clip_path, clip_id):
    """Clips with no Luca sounds should produce an empty filtered events list."""
    events, _, _ = await gemini.analyze_audio(
        audio_bytes=clip_path.read_bytes(),
        baby_name=BABY_NAME,
        baby_age_months=BABY_AGE_MONTHS,
        events_today=[],
        last_clip_summary="",
        clip_timestamp=TEST_TIMESTAMP,
    )
    assert events == [], (
        f"{clip_id}: expected empty filtered events, got {[e.get('detail') for e in events]}"
    )


@pytest.mark.asyncio
@pytest.mark.skipif(not _has_fixtures("luca_*.webm"), reason="No luca_*.webm fixtures")
@pytest.mark.parametrize("clip_path,clip_id", _LUCA_ALL, ids=[x[1] for x in _LUCA_ALL])
async def test_usage_is_positive_for_real_clips(clip_path, clip_id):
    """Real API calls must return positive token counts and a non-zero cost."""
    _, usage, _ = await gemini.analyze_audio(
        audio_bytes=clip_path.read_bytes(),
        baby_name=BABY_NAME,
        baby_age_months=BABY_AGE_MONTHS,
        events_today=[],
        last_clip_summary="",
        clip_timestamp=TEST_TIMESTAMP,
    )
    assert usage["input_tokens"] > 0,  f"{clip_id}: input_tokens should be > 0"
    assert usage["output_tokens"] > 0, f"{clip_id}: output_tokens should be > 0"
    assert usage["cost_usd"] > 0,      f"{clip_id}: cost_usd should be > 0"


# ---------------------------------------------------------------------------
# Unit tests — pure logic, no API calls
# ---------------------------------------------------------------------------

def test_is_vague_babble():
    """_is_vague_babble must return True only for activity events with babble/coo/vocaliz details."""
    assert gemini._is_vague_babble({"type": "activity", "detail": "Luca was babbling happily"})
    assert gemini._is_vague_babble({"type": "activity", "detail": "Luca was cooing"})
    assert gemini._is_vague_babble({"type": "activity", "detail": "Luca vocalized loudly"})
    assert gemini._is_vague_babble({"type": "activity", "detail": "lots of BABBLING"})  # case-insensitive

    # Not vague babble — different activity
    assert not gemini._is_vague_babble({"type": "activity", "detail": "Luca was laughing"})
    assert not gemini._is_vague_babble({"type": "activity", "detail": "Luca was crawling"})

    # Wrong type — even with babble keyword, not an activity
    assert not gemini._is_vague_babble({"type": "cry", "detail": "Luca was babbling and then crying"})
    assert not gemini._is_vague_babble({"type": "milestone", "detail": "Luca babbled first consonant"})

    # Edge cases
    assert not gemini._is_vague_babble({"type": "activity", "detail": None})
    assert not gemini._is_vague_babble({"type": "activity"})  # missing detail key
    assert not gemini._is_vague_babble({})  # empty event


def test_parse_json_strips_code_fences():
    """_parse_json_response must handle ```json, ```, and plain JSON strings."""
    assert gemini._parse_json_response("[]") == []
    assert gemini._parse_json_response("```json\n[]\n```") == []
    assert gemini._parse_json_response("```\n[]\n```") == []
    assert gemini._parse_json_response('```json\n{"a": 1}\n```') == {"a": 1}
    assert gemini._parse_json_response('{"a": 1}') == {"a": 1}


def test_extract_usage_calculates_cost():
    """_extract_usage must compute cost_usd = (inp * 0.075 + out * 0.30) / 1_000_000."""
    mock_meta = builtin_types.SimpleNamespace(
        prompt_token_count=1_000_000,
        candidates_token_count=1_000_000,
    )
    mock_response = builtin_types.SimpleNamespace(usage_metadata=mock_meta)
    usage = gemini._extract_usage(mock_response)
    assert usage["input_tokens"] == 1_000_000
    assert usage["output_tokens"] == 1_000_000
    assert usage["cost_usd"] == pytest.approx(0.075 + 0.30)

    # Missing usage_metadata → zeros, no exception
    empty = gemini._extract_usage(builtin_types.SimpleNamespace(usage_metadata=None))
    assert empty == {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0}


@pytest.mark.asyncio
@pytest.mark.skipif(not _has_fixtures("luca_*.webm"), reason="No luca_*.webm fixtures")
async def test_raw_events_are_deep_copied_from_events():
    """Popping a key from events[0] must NOT affect raw_events[0] (deep copy at line 327)."""
    clip_path = sorted(FIXTURES.glob("luca_*.webm"))[0]
    events, _, raw = await gemini.analyze_audio(
        audio_bytes=clip_path.read_bytes(),
        baby_name=BABY_NAME,
        baby_age_months=BABY_AGE_MONTHS,
        events_today=[],
        last_clip_summary="",
        clip_timestamp=TEST_TIMESTAMP,
    )
    if not events:
        pytest.skip("No filtered events returned — cannot test deep copy")
    key = next(iter(events[0]))
    events[0].pop(key)
    assert key in raw[0], (
        f"Deep copy broken: popping '{key}' from events[0] also removed it from raw_events[0]"
    )
