"""Gemini Live API session bridging for Babble voice features.

Two sessions:
  - edit_log:   log editor — returns structured edit commands
  - companion:  warm parenting companion — updates summary narrative
"""

import asyncio
import json
import os
from typing import AsyncGenerator

from google import genai
from google.genai import types

MODEL_LIVE = "gemini-2.5-flash-native-audio-latest"

EDIT_LOG_SYSTEM = """You are a precise, friendly log editor for {baby_name}'s daily activity log.
Today's log: {events_json}

Your role:
- Help the parent correct, add, or remove events from the log
- Confirm each change clearly before applying: "Got it — I'll update the 8am feeding to heavy."
- Ask for clarification if ambiguous: "Did you mean the first nap or the second?"
- Keep responses brief (voice interaction — no long explanations)
- After all edits, say: "All done! Your log is updated." then end the session

When an event is updated, emit a JSON edit command on its own line (not spoken aloud):
EDIT_CMD: {{"action": "update|delete|add", "event_id": "...", "fields": {{...}}}}"""

COMPANION_SYSTEM = """You are a warm, enthusiastic parenting companion reviewing {baby_name}'s day
with their parent. Today's summary: {summary_structured}

Your role:
- Open warmly, defer to the parent: "Hi! I've seen {baby_name}'s log. Anything to update?"
- Celebrate milestones with genuine warmth: "Oh wow, they said mama today?! That must
  have been such a magical moment! I'm noting that right now."
- Accept corrections cheerfully: "Got it — I'll update that. Sounds like a busy morning!"
- Ask gentle follow-up questions to enrich the log when relevant
- Keep responses short (voice, not text)
- Close encouragingly: "{baby_name}'s log is all up to date. You're doing a wonderful job!"

Tone: warm, celebratory, emotionally supportive — like a fellow parent genuinely excited
to hear about {baby_name}'s journey."""


def _get_live_client() -> genai.Client:
    api_key = os.environ.get("GOOGLE_API_KEY")
    if api_key:
        return genai.Client(api_key=api_key)
    return genai.Client()


async def run_edit_log_session(
    baby_name: str,
    events: list[dict],
    audio_in: AsyncGenerator[bytes, None],
    audio_out_callback,  # async callable(bytes) — send audio back to browser
    text_out_callback,   # async callable(str) — send transcript to browser
    edit_cmd_callback,   # async callable(dict) — apply edit command
):
    """
    Bridge a browser WebSocket <-> Gemini Live for the Edit Log session.

    audio_in: async generator yielding raw PCM 16-bit 16kHz mono chunks from browser
    audio_out_callback: called with PCM audio bytes to send back to browser
    text_out_callback: called with text transcript chunks for display
    edit_cmd_callback: called with {action, event_id, fields} dicts to apply to Firestore
    """
    client = _get_live_client()
    system_prompt = EDIT_LOG_SYSTEM.format(
        baby_name=baby_name,
        events_json=json.dumps(events, default=str),
    )

    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=system_prompt,
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
            )
        ),
    )

    async with client.aio.live.connect(model=MODEL_LIVE, config=config) as session:
        async def send_audio():
            async for chunk in audio_in:
                await session.send_realtime_input(
                    audio=types.Blob(data=chunk, mime_type="audio/pcm;rate=16000")
                )

        async def receive():
            async for response in session.receive():
                if response.data:
                    # Audio response — send to browser
                    await audio_out_callback(response.data)
                if response.text:
                    text = response.text
                    # Check for edit commands embedded in response
                    lines = text.split("\n")
                    for line in lines:
                        line = line.strip()
                        if line.startswith("EDIT_CMD:"):
                            try:
                                cmd_json = line[len("EDIT_CMD:"):].strip()
                                cmd = json.loads(cmd_json)
                                await edit_cmd_callback(cmd)
                            except (json.JSONDecodeError, ValueError) as e:
                                await text_out_callback(f"[debug] edit_cmd parse error: {e}")
                        else:
                            if line:
                                await text_out_callback(line)

        await asyncio.gather(send_audio(), receive())


async def run_companion_session(
    baby_name: str,
    summary_structured: str,
    audio_in: AsyncGenerator[bytes, None],
    audio_out_callback,
    text_out_callback,
    summary_update_callback,  # async callable(str) — updated narrative text
):
    """
    Bridge a browser WebSocket <-> Gemini Live for the Voice Companion session.
    """
    client = _get_live_client()
    system_prompt = COMPANION_SYSTEM.format(
        baby_name=baby_name,
        summary_structured=summary_structured,
    )

    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=system_prompt,
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
            )
        ),
    )

    collected_updates = []

    async with client.aio.live.connect(model=MODEL_LIVE, config=config) as session:
        async def send_audio():
            async for chunk in audio_in:
                await session.send_realtime_input(
                    audio=types.Blob(data=chunk, mime_type="audio/pcm;rate=16000")
                )

        async def receive():
            async for response in session.receive():
                if response.data:
                    await audio_out_callback(response.data)
                if response.text:
                    text = response.text.strip()
                    if text:
                        await text_out_callback(text)
                        collected_updates.append(text)

        await asyncio.gather(send_audio(), receive())

    # After session ends, notify caller with all the conversation text
    if collected_updates and summary_update_callback:
        await summary_update_callback("\n".join(collected_updates))
