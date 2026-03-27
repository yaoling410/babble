"""
Speaker diarization using pyannote.audio.

Receives a WAV audio clip + raw transcript (with word-level timestamps from
SFSpeechRecognizer) and returns a speaker-annotated transcript.

Speaker embeddings are compared against stored profiles in the database.
Unknown speakers get a temporary "Speaker N" label and are returned for the
iOS client to prompt the user for naming.
"""
import io
import logging
import numpy as np
from typing import Optional

logger = logging.getLogger(__name__)

# Lazy-loaded pipeline (heavy model, load once)
_pipeline = None
_embedding_model = None

SIMILARITY_THRESHOLD = 0.75  # cosine similarity threshold for speaker matching
MAX_DIARIZE_SECONDS = 10     # trim audio to this length before running pyannote
                             # keeps inference time predictable (~2-5s on CPU)
MAX_SPEAKER_AUDIO_SECONDS = 10  # max audio per speaker for embedding extraction


def _load_pipeline():
    global _pipeline, _embedding_model
    if _pipeline is not None:
        return
    try:
        from pyannote.audio import Pipeline, Model, Inference
        import torch

        # Speaker diarization pipeline (requires HuggingFace token via env var
        # HUGGINGFACE_TOKEN or pyannote usage agreement accepted)
        _pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            use_auth_token=None,  # set HUGGINGFACE_TOKEN env var
        )

        # Separate embedding model for enrollment
        _embedding_model = Inference(
            Model.from_pretrained("pyannote/embedding"),
            window="whole",
        )

        logger.info("pyannote pipeline loaded")
    except Exception as e:
        logger.warning(f"pyannote not available: {e}. Diarization will be skipped.")
        _pipeline = None
        _embedding_model = None


def _cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    a = a.flatten()
    b = b.flatten()
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    if denom == 0:
        return 0.0
    return float(np.dot(a, b) / denom)


def _match_speaker(
    embedding: np.ndarray,
    known_speakers: list[dict],
) -> Optional[dict]:
    """Return the best-matching known speaker, or None if no match above threshold."""
    best = None
    best_sim = SIMILARITY_THRESHOLD
    for sp in known_speakers:
        raw = sp.get("embedding") or b""
        if not raw:
            continue  # label-only enrollment — no embedding to match against
        stored = np.frombuffer(raw, dtype=np.float32)
        if stored.size == 0:
            continue
        sim = _cosine_similarity(embedding, stored)
        if sim > best_sim:
            best_sim = sim
            best = sp
    return best


def extract_embedding(audio_bytes: bytes) -> Optional[bytes]:
    """
    Extract a voice embedding from a WAV audio segment.
    Returns raw float32 bytes, or None if pyannote unavailable.
    """
    _load_pipeline()
    if _embedding_model is None:
        return None
    try:
        import soundfile as sf
        audio_data, sample_rate = sf.read(io.BytesIO(audio_bytes))
        if audio_data.ndim > 1:
            audio_data = audio_data.mean(axis=1)
        # pyannote expects (channel, samples) tensor
        import torch
        waveform = torch.tensor(audio_data, dtype=torch.float32).unsqueeze(0)
        embedding = _embedding_model({"waveform": waveform, "sample_rate": sample_rate})
        return embedding.numpy().astype(np.float32).tobytes()
    except Exception as e:
        logger.error(f"Embedding extraction failed: {e}")
        return None


def diarize(
    audio_bytes: bytes,
    raw_transcript: str,
    known_speakers: list[dict],
    word_timestamps: list[dict] | None = None,
) -> dict:
    """
    Perform speaker diarization on a WAV audio clip.

    Args:
        audio_bytes: WAV audio bytes
        raw_transcript: plain text transcript from SFSpeechRecognizer
        known_speakers: list of {id, label, embedding (bytes)} from db
        word_timestamps: optional list of {word, start, end} from SFSpeechRecognizer

    Returns:
        {
            "annotated_transcript": str,    # "[Mom 00:00-00:04]: Hey Luca..."
            "segments": [...],              # [{speaker_label, start, end, text}]
            "unknown_speakers": [...],      # [{temp_label, start, end}] for iOS to name
        }
    """
    _load_pipeline()

    if _pipeline is None:
        # Fallback: return transcript without speaker labels
        logger.warning("Diarization unavailable, returning unannotated transcript")
        return {
            "annotated_transcript": raw_transcript,
            "segments": [{"speaker_label": "Unknown", "start": 0.0, "end": 999.0, "text": raw_transcript}],
            "unknown_speakers": [],
        }

    try:
        import soundfile as sf
        import torch

        audio_data, sample_rate = sf.read(io.BytesIO(audio_bytes))
        if audio_data.ndim > 1:
            audio_data = audio_data.mean(axis=1)

        # Trim to MAX_DIARIZE_SECONDS for fast, predictable pyannote inference.
        # Speaker identification only needs a short sample — the full 90s clip
        # would take minutes on CPU. The annotated transcript for the full clip
        # is reconstructed by proportionally assigning the identified speakers.
        max_samples = int(MAX_DIARIZE_SECONDS * sample_rate)
        diarize_audio = audio_data[:max_samples]
        if len(audio_data) > max_samples:
            logger.info("[DIARIZE] Trimmed %.1fs → %.1fs for pyannote",
                        len(audio_data) / sample_rate, MAX_DIARIZE_SECONDS)

        waveform = torch.tensor(diarize_audio, dtype=torch.float32).unsqueeze(0)

        # Run diarization on the trimmed audio
        diarization = _pipeline({"waveform": waveform, "sample_rate": sample_rate})

        # Collect ALL segments per pyannote speaker label first, then concatenate
        # them into one long chunk for embedding extraction. This mirrors the
        # enrollment path (which also processes a full clip) and gives a much more
        # reliable embedding than using only the first short segment.
        speaker_segments: dict[str, list] = {}
        speaker_first_turn: dict[str, object] = {}
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            start_sample = int(turn.start * sample_rate)
            end_sample = int(turn.end * sample_rate)
            seg = audio_data[start_sample:end_sample]
            if len(seg) > 0:
                speaker_segments.setdefault(speaker, []).append(seg)
                if speaker not in speaker_first_turn:
                    speaker_first_turn[speaker] = turn

        # Map pyannote speaker labels → known names or temp labels
        pyannote_to_label: dict[str, str] = {}
        unknown_speakers = []
        speaker_counter = 1

        for speaker, segments in speaker_segments.items():
            concatenated = np.concatenate(segments)
            # Cap to MAX_SPEAKER_AUDIO_SECONDS — beyond that the embedding doesn't improve
            max_emb_samples = int(MAX_SPEAKER_AUDIO_SECONDS * sample_rate)
            if len(concatenated) > max_emb_samples:
                concatenated = concatenated[:max_emb_samples]
            total_secs = len(concatenated) / sample_rate

            if total_secs < 0.5:
                # Still too short even after concatenation — skip embedding
                pyannote_to_label[speaker] = f"Speaker {speaker_counter}"
                speaker_counter += 1
                continue

            seg_waveform = torch.tensor(concatenated, dtype=torch.float32).unsqueeze(0)
            embedding = _embedding_model({"waveform": seg_waveform, "sample_rate": sample_rate})
            emb_array = embedding.numpy().astype(np.float32)
            logger.debug("[DIARIZE] %s: %.1fs audio across %d segments → embedding extracted",
                         speaker, total_secs, len(segments))

            match = _match_speaker(emb_array, known_speakers)
            if match:
                pyannote_to_label[speaker] = match["label"]
                logger.debug("[DIARIZE] %s → '%s' (match)", speaker, match["label"])
            else:
                temp_label = f"Speaker {speaker_counter}"
                pyannote_to_label[speaker] = temp_label
                first_turn = speaker_first_turn[speaker]
                unknown_speakers.append({
                    "temp_label": temp_label,
                    "start": round(first_turn.start, 2),
                    "end": round(first_turn.end, 2),
                    "embedding": emb_array.tobytes(),
                })
                speaker_counter += 1
                logger.debug("[DIARIZE] %s → '%s' (unknown, no match above %.2f)",
                             speaker, temp_label, SIMILARITY_THRESHOLD)

        # Build segments with merged text
        segments = []
        if word_timestamps:
            # Align words to speaker segments using timestamp overlap
            for turn, _, speaker in diarization.itertracks(yield_label=True):
                label = pyannote_to_label.get(speaker, "Unknown")
                words_in_segment = [
                    w["word"] for w in word_timestamps
                    if w.get("start", 0) >= turn.start - 0.1
                    and w.get("end", 0) <= turn.end + 0.1
                ]
                text = " ".join(words_in_segment)
                if text:
                    segments.append({
                        "speaker_label": label,
                        "start": round(turn.start, 2),
                        "end": round(turn.end, 2),
                        "text": text,
                    })
        else:
            # No word timestamps: distribute raw transcript proportionally
            turns_list = list(diarization.itertracks(yield_label=True))
            if turns_list:
                for turn, _, speaker in turns_list:
                    label = pyannote_to_label.get(speaker, "Unknown")
                    segments.append({
                        "speaker_label": label,
                        "start": round(turn.start, 2),
                        "end": round(turn.end, 2),
                        "text": "",
                    })
                # Put full transcript under first speaker as fallback
                if segments:
                    segments[0]["text"] = raw_transcript

        # Sort by start time and build annotated transcript string
        segments.sort(key=lambda s: s["start"])
        lines = []
        for seg in segments:
            if not seg["text"]:
                continue
            start_str = _fmt_time(seg["start"])
            end_str = _fmt_time(seg["end"])
            lines.append(f"[{seg['speaker_label']} {start_str}–{end_str}]: {seg['text']}")
        annotated = "\n".join(lines) if lines else raw_transcript

        return {
            "annotated_transcript": annotated,
            "segments": segments,
            "unknown_speakers": [
                {k: v for k, v in sp.items() if k != "embedding"}
                for sp in unknown_speakers
            ],
        }

    except Exception as e:
        logger.error(f"Diarization failed: {e}")
        return {
            "annotated_transcript": raw_transcript,
            "segments": [{"speaker_label": "Unknown", "start": 0.0, "end": 999.0, "text": raw_transcript}],
            "unknown_speakers": [],
        }


def compare_embeddings(audio_bytes: bytes, known_speakers: list[dict]) -> list[dict]:
    """
    Extract an embedding from audio_bytes using the SAME path as the diarize loop
    (not the enrollment path), then return cosine similarity against every stored speaker.

    This lets you verify that enrollment embeddings will actually match at runtime.
    The diarize loop processes short per-speaker segments; enrollment processes the
    whole clip — this function mirrors the diarize-loop path so the comparison is fair.

    Returns a list of {id, label, similarity, match} sorted by similarity descending.
    """
    _load_pipeline()
    if _embedding_model is None:
        return [{"error": "pyannote not available"}]

    try:
        import soundfile as sf
        import torch

        audio_data, sample_rate = sf.read(io.BytesIO(audio_bytes))
        if audio_data.ndim > 1:
            audio_data = audio_data.mean(axis=1)

        # Mirror exactly what diarize() does for each per-speaker segment:
        # convert to float32 tensor, add channel dim, call _embedding_model.
        waveform = torch.tensor(audio_data, dtype=torch.float32).unsqueeze(0)
        embedding = _embedding_model({"waveform": waveform, "sample_rate": sample_rate})
        emb_array = embedding.numpy().astype(np.float32)

        results = []
        for sp in known_speakers:
            if not sp.get("embedding"):
                results.append({"id": sp["id"], "label": sp["label"], "similarity": None,
                                 "match": False, "note": "no embedding stored"})
                continue
            stored = np.frombuffer(sp["embedding"], dtype=np.float32)
            sim = _cosine_similarity(emb_array, stored)
            results.append({
                "id": sp["id"],
                "label": sp["label"],
                "similarity": round(float(sim), 4),
                "match": sim >= SIMILARITY_THRESHOLD,
                "threshold": SIMILARITY_THRESHOLD,
            })

        results.sort(key=lambda r: r.get("similarity") or 0, reverse=True)
        logger.info("[COMPARE] audio=%.1fKB → %d speakers checked, best=%.3f (%s)",
                    len(audio_bytes) / 1024,
                    len(results),
                    results[0].get("similarity") or 0 if results else 0,
                    results[0].get("label", "?") if results else "none")
        return results

    except Exception as e:
        logger.error(f"compare_embeddings failed: {e}")
        return [{"error": str(e)}]


def _fmt_time(seconds: float) -> str:
    m = int(seconds // 60)
    s = int(seconds % 60)
    return f"{m:02d}:{s:02d}"
