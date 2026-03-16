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
Current local time: {local_now} (UTC offset: {tz_offset_minutes} minutes)
Today's log: {events_json}

Your role:
- Help the parent correct, add, or remove events from the log
- Confirm each change clearly before applying: "Got it — I'll update the 8am feeding to heavy."
- Ask for clarification if ambiguous: "Did you mean the first nap or the second?"
- Keep responses brief (voice interaction — no long explanations)
- After all edits, say: "All done! Your log is updated." then end the session

Timestamp rules:
- All timestamps must be ISO 8601 format: YYYY-MM-DDTHH:MM:SS (use today's date)
- "just now" or "right now" → use {local_now} as the timestamp
- "at 3pm", "around noon", "this morning at 9" → convert using today's local date and the UTC offset above
- "an hour ago" → subtract from {local_now}
- Never use UTC unless explicitly told to; always use the parent's local time

Use the provided tools (update_event, delete_event, add_event) to apply changes to the log."""

COMPANION_SYSTEM = """You are a warm, enthusiastic parenting companion reviewing {baby_name}'s day
with their parent. Today's summary: {summary_structured}

Your role:
- Open warmly with: "Hi! Is there anything you'd like to update or add to {baby_name}'s log today?"
- Celebrate milestones with genuine warmth: "Oh wow, they said mama today?! That must
  have been such a magical moment! I'm noting that right now."
- Accept corrections cheerfully: "Got it — I'll update that. Sounds like a busy morning!"
- Ask gentle follow-up questions to enrich the log when relevant
- Keep responses short (voice, not text)
- Stay in the conversation — keep asking gentle questions and listening until the parent
  ends the session. Never close the session yourself.

Tone: warm, celebratory, emotionally supportive — like a fellow parent genuinely excited
to hear about {baby_name}'s journey."""


# Function declarations for edit-log tool calling
_EDIT_TOOLS = [types.Tool(function_declarations=[
    types.FunctionDeclaration(
        name="update_event",
        description="Update fields of an existing event in the log",
        parameters=types.Schema(
            type="OBJECT",
            properties={
                "event_id": types.Schema(type="STRING", description="ID of the event to update"),
                "fields":   types.Schema(type="OBJECT", description="Fields to update, e.g. {detail, timestamp, type}"),
            },
            required=["event_id", "fields"],
        ),
    ),
    types.FunctionDeclaration(
        name="delete_event",
        description="Remove an event from the log",
        parameters=types.Schema(
            type="OBJECT",
            properties={
                "event_id": types.Schema(type="STRING", description="ID of the event to delete"),
            },
            required=["event_id"],
        ),
    ),
    types.FunctionDeclaration(
        name="add_event",
        description="Add a new event to the log",
        parameters=types.Schema(
            type="OBJECT",
            properties={
                "type":      types.Schema(type="STRING", description="Event type: feeding|nap|cry|diaper|outing|health_note|activity|milestone|observation"),
                "timestamp": types.Schema(type="STRING", description="ISO 8601 timestamp in local time"),
                "detail":    types.Schema(type="STRING", description="Warm description of the event"),
                "notable":   types.Schema(type="BOOLEAN", description="True if this is a milestone"),
            },
            required=["type", "timestamp", "detail"],
        ),
    ),
])]


def _get_live_client() -> genai.Client:
    api_key = os.environ.get("GOOGLE_API_KEY")
    if api_key:
        return genai.Client(api_key=api_key)
    return genai.Client()


async def run_edit_log_session(
    baby_name: str,
    events: list[dict],
    audio_in: AsyncGenerator[bytes, None],
    audio_out_callback,        # async callable(bytes) — send audio back to browser
    text_out_callback,         # async callable(str) — send Gemini transcript to browser
    edit_cmd_callback,         # async callable(dict) — apply edit command
    input_transcript_callback, # async callable(str) — send user speech transcript to browser
    local_now: str = None,
    tz_offset_minutes: int = 0,
):
    """
    Bridge a browser WebSocket <-> Gemini Live for the Edit Log session.

    audio_in: async generator yielding raw PCM 16-bit 16kHz mono chunks from browser
    audio_out_callback: called with PCM audio bytes to send back to browser
    text_out_callback: called with text transcript chunks for display
    edit_cmd_callback: called with {action, event_id, fields} dicts to apply to Firestore
    input_transcript_callback: called with transcription of user's spoken input
    """
    client = _get_live_client()
    from datetime import datetime, timezone
    if not local_now:
        local_now = datetime.now(timezone.utc).isoformat()
    system_prompt = EDIT_LOG_SYSTEM.format(
        baby_name=baby_name,
        events_json=json.dumps(events, default=str),
        local_now=local_now,
        tz_offset_minutes=tz_offset_minutes,
    )

    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        output_audio_transcription=types.AudioTranscriptionConfig(),
        input_audio_transcription=types.AudioTranscriptionConfig(),
        tools=_EDIT_TOOLS,
        system_instruction=system_prompt,
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
            )
        ),
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(disabled=True)
        ),
    )

    async with client.aio.live.connect(model=MODEL_LIVE, config=config) as session:
        async def send_audio():
            async for chunk in audio_in:
                if chunk == "ACTIVITY_START":
                    await session.send_realtime_input(activity_start=types.ActivityStart())
                elif chunk == "ACTIVITY_END":
                    await session.send_realtime_input(activity_end=types.ActivityEnd())
                else:
                    await session.send_realtime_input(
                        audio=types.Blob(data=chunk, mime_type="audio/pcm;rate=16000")
                    )

        async def receive():
            async for response in session.receive():
                # Audio response
                if response.data:
                    await audio_out_callback(response.data)

                # Tool call — Gemini wants to edit an event
                if response.tool_call:
                    tool_responses = []
                    for fn in response.tool_call.function_calls:
                        args = dict(fn.args) if fn.args else {}
                        try:
                            if fn.name == "update_event":
                                await edit_cmd_callback({"action": "update", "event_id": args["event_id"], "fields": args.get("fields", {})})
                            elif fn.name == "delete_event":
                                await edit_cmd_callback({"action": "delete", "event_id": args["event_id"]})
                            elif fn.name == "add_event":
                                await edit_cmd_callback({"action": "add", "fields": {**args, "confidence": 90, "notable": args.get("notable", False)}})
                            tool_responses.append(types.FunctionResponse(
                                id=fn.id, name=fn.name, response={"result": "success"}
                            ))
                        except Exception as e:
                            tool_responses.append(types.FunctionResponse(
                                id=fn.id, name=fn.name, response={"result": "error", "message": str(e)}
                            ))
                    await session.send_tool_response(function_responses=tool_responses)

                # Transcripts via server_content
                sc = getattr(response, "server_content", None)
                if sc:
                    ot = getattr(sc, "output_transcription", None)
                    if ot and getattr(ot, "text", None):
                        await text_out_callback(ot.text.strip())
                    it = getattr(sc, "input_transcription", None)
                    if it and getattr(it, "text", None):
                        await input_transcript_callback(it.text.strip())

        send_task = asyncio.create_task(send_audio())
        try:
            await receive()
        finally:
            send_task.cancel()
            try:
                await send_task
            except asyncio.CancelledError:
                pass


async def run_companion_session(
    baby_name: str,
    summary_structured: str,
    audio_in: AsyncGenerator[bytes, None],
    audio_out_callback,
    text_out_callback,
    input_transcript_callback, # async callable(str) — send user speech transcript to browser
    summary_update_callback,   # async callable(str) — updated narrative text
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
        output_audio_transcription=types.AudioTranscriptionConfig(),
        input_audio_transcription=types.AudioTranscriptionConfig(),
        system_instruction=system_prompt,
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
            )
        ),
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(disabled=True)
        ),
    )

    collected_updates = []

    print(f"[companion] session connecting for {baby_name} model={MODEL_LIVE}")
    try:
        async with client.aio.live.connect(model=MODEL_LIVE, config=config) as session:
            print(f"[companion] session connected")
            # Trigger the opening greeting immediately — without this Gemini waits
            # silently for the parent to speak first.
            await session.send_client_content(
                turns=types.Content(role="user", parts=[types.Part(text=".")]),
                turn_complete=True,
            )

            async def send_audio():
                n_chunks = 0
                try:
                    async for chunk in audio_in:
                        if chunk == "ACTIVITY_START":
                            print(f"[companion] activity_start")
                            await session.send_realtime_input(activity_start=types.ActivityStart())
                        elif chunk == "ACTIVITY_END":
                            print(f"[companion] activity_end sent after {n_chunks} audio chunks")
                            n_chunks = 0
                            await session.send_realtime_input(activity_end=types.ActivityEnd())
                        else:
                            n_chunks += 1
                            await session.send_realtime_input(
                                audio=types.Blob(data=chunk, mime_type="audio/pcm;rate=16000")
                            )
                except Exception as e:
                    print(f"[companion] send_audio error: {e!r}")
                    raise

            async def receive():
                async for response in session.receive():
                    if response.data:
                        await audio_out_callback(response.data)
                    sc = getattr(response, "server_content", None)
                    if sc:
                        ot = getattr(sc, "output_transcription", None)
                        if ot and getattr(ot, "text", None):
                            text = ot.text.strip()
                            if text:
                                await text_out_callback(text)
                                collected_updates.append(text)
                        it = getattr(sc, "input_transcription", None)
                        if it and getattr(it, "text", None):
                            await input_transcript_callback(it.text.strip())

            send_task = asyncio.create_task(send_audio())
            try:
                await receive()
            finally:
                send_task.cancel()
                try:
                    await send_task
                except asyncio.CancelledError:
                    pass
                except Exception as e:
                    print(f"[companion] send_task raised: {e!r}")
    except Exception as e:
        print(f"[companion] session error {type(e).__name__}: {e!r}")
        raise

    # After session ends, notify caller with all the conversation text
    if collected_updates and summary_update_callback:
        await summary_update_callback("\n".join(collected_updates))
