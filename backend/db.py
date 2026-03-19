"""
SQLite persistence layer via aiosqlite.
Replaces firestore_client.py.
"""
import uuid
import json
import aiosqlite
from datetime import datetime, timezone
from pathlib import Path

DB_PATH = Path(__file__).parent / "babble.db"

_CREATE_EVENTS = """
CREATE TABLE IF NOT EXISTS events (
    id              TEXT PRIMARY KEY,
    date            TEXT NOT NULL,
    type            TEXT NOT NULL,
    timestamp       TEXT NOT NULL,
    detail          TEXT NOT NULL,
    notable         INTEGER NOT NULL DEFAULT 0,
    speaker         TEXT,
    created_at      TEXT NOT NULL
);
"""

_CREATE_SUMMARIES = """
CREATE TABLE IF NOT EXISTS summaries (
    date            TEXT PRIMARY KEY,
    data            TEXT NOT NULL,
    generated_at    TEXT NOT NULL
);
"""

_CREATE_SPEAKERS = """
CREATE TABLE IF NOT EXISTS speaker_profiles (
    id              TEXT PRIMARY KEY,
    label           TEXT NOT NULL,
    embedding       BLOB NOT NULL,
    sample_count    INTEGER NOT NULL DEFAULT 1,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);
"""

_IDX_EVENTS_DATE = """
CREATE INDEX IF NOT EXISTS idx_events_date ON events(date);
"""


async def init_db() -> None:
    """Create tables if they don't exist. Call once at startup."""
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(_CREATE_EVENTS)
        await db.execute(_CREATE_SUMMARIES)
        await db.execute(_CREATE_SPEAKERS)
        await db.execute(_IDX_EVENTS_DATE)
        await db.commit()


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

def _row_to_event(row) -> dict:
    return {
        "id": row[0],
        "date": row[1],
        "type": row[2],
        "timestamp": row[3],
        "detail": row[4],
        "notable": bool(row[5]),
        "speaker": row[6],
        "created_at": row[7],
    }


async def get_events(date_str: str) -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT id, date, type, timestamp, detail, notable, speaker, created_at "
            "FROM events WHERE date = ? ORDER BY timestamp ASC",
            (date_str,),
        ) as cursor:
            rows = await cursor.fetchall()
    return [_row_to_event(r) for r in rows]


async def get_events_since(date_str: str, since_timestamp: str) -> list[dict]:
    """Return events on date_str at or after since_timestamp (ISO 8601)."""
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT id, date, type, timestamp, detail, notable, speaker, created_at "
            "FROM events WHERE date = ? AND timestamp >= ? ORDER BY timestamp ASC",
            (date_str, since_timestamp),
        ) as cursor:
            rows = await cursor.fetchall()
    return [_row_to_event(r) for r in rows]


async def add_event(event: dict, date_str: str) -> str:
    """Insert a single event. Returns the event id."""
    event_id = event.get("id") or str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT OR REPLACE INTO events "
            "(id, date, type, timestamp, detail, notable, speaker, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                event_id,
                date_str,
                event.get("type", "observation"),
                event.get("timestamp", now),
                event.get("detail", ""),
                int(event.get("notable", False)),
                event.get("speaker"),
                event.get("created_at", now),
            ),
        )
        await db.commit()
    return event_id


async def add_events(events: list[dict], date_str: str) -> list[str]:
    """Insert multiple events in a single transaction. Returns list of ids."""
    if not events:
        return []
    now = datetime.now(timezone.utc).isoformat()
    ids = []
    async with aiosqlite.connect(DB_PATH) as db:
        for event in events:
            event_id = event.get("id") or str(uuid.uuid4())
            ids.append(event_id)
            await db.execute(
                "INSERT OR REPLACE INTO events "
                "(id, date, type, timestamp, detail, notable, speaker, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    event_id,
                    date_str,
                    event.get("type", "observation"),
                    event.get("timestamp", now),
                    event.get("detail", ""),
                    int(event.get("notable", False)),
                    event.get("speaker"),
                    event.get("created_at", now),
                ),
            )
        await db.commit()
    return ids


async def apply_corrections(corrections: list[dict]) -> int:
    """Apply a list of corrections from Gemini (update or delete). Returns count applied."""
    if not corrections:
        return 0
    applied = 0
    async with aiosqlite.connect(DB_PATH) as db:
        for correction in corrections:
            event_id = correction.get("event_id")
            action = correction.get("action")
            if not event_id or not action:
                continue
            if action == "delete":
                await db.execute("DELETE FROM events WHERE id = ?", (event_id,))
                applied += 1
            elif action == "update":
                fields = correction.get("fields", {})
                if not fields:
                    continue
                allowed = {"type", "detail", "notable", "speaker", "timestamp"}
                updates = {k: v for k, v in fields.items() if k in allowed}
                if not updates:
                    continue
                set_clause = ", ".join(f"{k} = ?" for k in updates)
                values = list(updates.values()) + [event_id]
                await db.execute(
                    f"UPDATE events SET {set_clause} WHERE id = ?", values
                )
                applied += 1
        await db.commit()
    return applied


async def update_event(event_id: str, fields: dict) -> None:
    allowed = {"type", "detail", "notable", "speaker", "timestamp"}
    updates = {k: v for k, v in fields.items() if k in allowed}
    if not updates:
        return
    set_clause = ", ".join(f"{k} = ?" for k in updates)
    values = list(updates.values()) + [event_id]
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(f"UPDATE events SET {set_clause} WHERE id = ?", values)
        await db.commit()


async def delete_event(event_id: str) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM events WHERE id = ?", (event_id,))
        await db.commit()


async def get_event(event_id: str) -> dict | None:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT id, date, type, timestamp, detail, notable, speaker, created_at "
            "FROM events WHERE id = ?",
            (event_id,),
        ) as cursor:
            row = await cursor.fetchone()
    return _row_to_event(row) if row else None


# ---------------------------------------------------------------------------
# Summaries
# ---------------------------------------------------------------------------

async def get_summary(date_str: str) -> dict | None:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT data FROM summaries WHERE date = ?", (date_str,)
        ) as cursor:
            row = await cursor.fetchone()
    return json.loads(row[0]) if row else None


async def set_summary(summary: dict, date_str: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT OR REPLACE INTO summaries (date, data, generated_at) VALUES (?, ?, ?)",
            (date_str, json.dumps(summary), now),
        )
        await db.commit()


# ---------------------------------------------------------------------------
# Speaker profiles
# ---------------------------------------------------------------------------

def _row_to_speaker(row) -> dict:
    return {
        "id": row[0],
        "label": row[1],
        "embedding": row[2],  # raw bytes
        "sample_count": row[3],
        "created_at": row[4],
        "updated_at": row[5],
    }


async def get_speakers() -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT id, label, embedding, sample_count, created_at, updated_at "
            "FROM speaker_profiles ORDER BY label ASC"
        ) as cursor:
            rows = await cursor.fetchall()
    # Return without embedding bytes for listing
    return [
        {
            "id": r[0],
            "label": r[1],
            "sample_count": r[3],
            "created_at": r[4],
            "updated_at": r[5],
        }
        for r in rows
    ]


async def get_speaker_embeddings() -> list[dict]:
    """Return all speakers WITH their embedding bytes (for diarization matching)."""
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT id, label, embedding, sample_count, created_at, updated_at "
            "FROM speaker_profiles"
        ) as cursor:
            rows = await cursor.fetchall()
    return [_row_to_speaker(r) for r in rows]


async def upsert_speaker(
    label: str,
    embedding: bytes,
    speaker_id: str | None = None,
) -> dict:
    """Insert or update a speaker. If speaker_id given, updates that record (running avg)."""
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(DB_PATH) as db:
        if speaker_id:
            # Update existing: increment sample_count, update embedding + timestamp
            await db.execute(
                "UPDATE speaker_profiles SET embedding = ?, sample_count = sample_count + 1, "
                "updated_at = ?, label = ? WHERE id = ?",
                (embedding, now, label, speaker_id),
            )
            sid = speaker_id
        else:
            sid = str(uuid.uuid4())
            await db.execute(
                "INSERT INTO speaker_profiles (id, label, embedding, sample_count, created_at, updated_at) "
                "VALUES (?, ?, ?, 1, ?, ?)",
                (sid, label, embedding, now, now),
            )
        await db.commit()
    return {"id": sid, "label": label, "updated_at": now}


async def rename_speaker(speaker_id: str, label: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "UPDATE speaker_profiles SET label = ?, updated_at = ? WHERE id = ?",
            (label, now, speaker_id),
        )
        await db.commit()


async def delete_speaker(speaker_id: str) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM speaker_profiles WHERE id = ?", (speaker_id,))
        await db.commit()
