"""
AppConfig — all tunable backend parameters in one place.

HOW TO USE
----------
Every value has a plain-English explanation and an "If you increase / decrease"
note so you can tune without guessing. Change the value here; no other files
need touching.

SECTIONS
--------
1. Models           — which Gemini models to use for each task
2. Context Limits   — how much history to send with each request
3. Pricing          — per-token cost constants used for cost logging
"""

# ================================================================
#  1. MODELS
# ================================================================

# Gemini model for full event analysis (transcribe → extract events).
# 2.5 Flash is the default — good accuracy at reasonable cost.
# Switch to "gemini-2.5-pro" if you need higher accuracy on ambiguous speech.
ANALYSIS_MODEL: str = "gemini-2.5-flash"

# Gemini model for cheap yes/no relevance gate.
# Only used when the local keyword filter is inconclusive.
# Flash-Lite is 5-10× cheaper than Flash and sufficient for single-shot decisions.
RELEVANCE_MODEL: str = "gemini-2.0-flash-lite"

# ================================================================
#  2. CONTEXT LIMITS
# ================================================================

# Maximum characters of the 10-minute rolling transcript context sent to
# Gemini with each analysis request. Older transcripts are trimmed from the
# front. Shorter = cheaper; longer = more conversational history for corrections.
#
# - Increase → Gemini has more context for pronoun resolution and corrections.
# - Decrease → lower token cost per request.
# - Default: 800 chars (~130–160 words).
TRANSCRIPT_CONTEXT_MAX_CHARS: int = 800

# Maximum number of today's events sent to Gemini in voice-note edit mode
# for correction context. Older events are dropped.
#
# - Increase → Gemini can correct events from earlier in the day.
# - Decrease → lower token cost per voice-note call.
# - Default: 20 events.
VOICE_NOTE_EVENT_CONTEXT_LIMIT: int = 20

# ================================================================
#  3. PRICING  (USD per token — update when Google changes rates)
# ================================================================
# Source: https://ai.google.dev/pricing  (as of 2025-Q1)
#
# gemini-2.5-flash  — standard context window (≤200K tokens)
COST_INPUT_FLASH:  float = 0.15  / 1_000_000   # $0.15 / 1M input tokens
COST_OUTPUT_FLASH: float = 0.60  / 1_000_000   # $0.60 / 1M output tokens

# gemini-2.0-flash-lite  — cheapest model, used for binary relevance gate
COST_INPUT_LITE:   float = 0.075 / 1_000_000   # $0.075 / 1M input tokens
COST_OUTPUT_LITE:  float = 0.30  / 1_000_000   # $0.30  / 1M output tokens
