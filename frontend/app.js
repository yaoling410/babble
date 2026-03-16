/**
 * Babble — PWA app logic
 *
 * OVERALL FLOW:
 *   1. On load: check localStorage for baby profile.
 *      - If profile exists → go to Home screen and start passive monitoring.
 *      - If not → show Setup screen.
 *   2. Passive monitoring (always running in background on Home screen):
 *      - VAD (Voice Activity Detection) reads mic volume every animation frame (~60fps).
 *      - When volume exceeds VAD_THRESHOLD → MediaRecorder starts capturing audio.
 *      - When volume drops below threshold for SILENCE_MS → clip ends.
 *      - Clip is base64-encoded and POST'd to /analyze (via FIFO queue, so clips don't overlap).
 *      - /analyze calls Gemini 2.5 Flash with the audio → returns detected events.
 *      - Events are saved to Firestore by the backend.
 *      - Frontend polls GET /events every 3s → new events flash green in the list.
 *   3. Summary screen: shows AI-generated daily narrative; can be regenerated on demand.
 *   4. Voice overlays: WebSocket sessions to Gemini Live API.
 *      - "Edit Log" (from Home): parent talks to Gemini to correct/add events; Gemini edits Firestore.
 *      - "Talk to Gemini" (from Summary): warm companion reviews and updates summary.
 *   5. Social card: shows tweet text in baby's voice; opens Twitter intent to share.
 */

// ─────────────────────────────────────────────────────────────
// Config constants
// ─────────────────────────────────────────────────────────────

// API_BASE: backend URL — localhost for dev, same origin for Cloud Run deploy
const API_BASE = window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1'
  ? `http://${window.location.host}`
  : window.location.origin;

// WS_BASE: WebSocket base URL (ws:// for http, wss:// for https)
const WS_BASE = API_BASE.replace(/^http/, 'ws');

// VAD_THRESHOLD: RMS volume level (0–255) above which we start recording.
// Higher = less sensitive (ignores quiet background noise).
// Lower = more sensitive (triggers on any sound).
// Typical values: 15 = very sensitive, 30–50 = moderate, 80+ = loud only.
// If the bar is always red/always recording, raise this until the bar is mostly
// green at rest and only goes red when you speak.
const VAD_THRESHOLD = 35;

// SILENCE_MS: how long (ms) the volume must drop below VAD_THRESHOLD before we stop recording.
// 2000ms = 2 seconds of silence ends the clip.
const SILENCE_MS = 2000;

// MAX_CLIP_MS: maximum clip length. If audio never drops below threshold for this duration,
// force-stop and immediately restart recording. 15s gives Gemini enough context for sustained
// sounds (crying, feeding narration) while still preventing infinite clips.
// Aligns with MIN_VARIANCE_CLIP_MS: a 15s cap-triggered clip hits the variance check exactly —
// machine noise (flat RMS) gets filtered, baby crying (burst pattern) passes.
const MAX_CLIP_MS = 15000;

// ── VAD pre-filter (applied after recording stops, before sending to Gemini) ──
// MIN_CLIP_MS: discard clips shorter than this. A brief noise spike (keyboard, door slam)
// triggers VAD but produces a clip too short to contain meaningful speech or baby sounds.
// Every clip has a built-in 2s silence tail (SILENCE_MS), so a door slam (0.1s) → 2.1s clip.
// 3s threshold catches sounds where the actual trigger was < 1s — never real speech or crying.
const MIN_CLIP_MS = 3000;
// MIN_CLIP_BYTES: discard clips smaller than this. webm/opus encodes ~10–15 KB/s of
// speech at typical mic quality. A 3s clip of real speech is ~30–50 KB.
// Clips under 15 KB are almost certainly just noise artefacts.
const MIN_CLIP_BYTES = 15000;
// MIN_RMS_VARIANCE: for long clips (≥ MIN_VARIANCE_CLIP_MS), discard if RMS barely changes.
// Steady-state noise (washing machine, airplane, fan) produces long clips with flat RMS.
// Baby sounds produce short clips (silence fires between sounds) — the duration gate below
// protects them: variance check is SKIPPED for clips under 15s.
const MIN_RMS_VARIANCE = 50;
const MIN_VARIANCE_CLIP_MS = 15000; // only apply variance check to clips ≥ 15s
// MAX_QUIET_CLIP_MS / MIN_PEAK_RMS_SHORT_CLIP: Check 1.5 — quiet short clips.
// Short clips (< 8s) where the loudest moment never exceeded 45 are soft ambient sounds
// (breathing, AC hum) that crossed VAD_THRESHOLD only barely. Not worth sending to Gemini.
// Missing baby murmuring is acceptable — reducing false positives is the priority.
const MAX_QUIET_CLIP_MS = 8000;
const MIN_PEAK_RMS_SHORT_CLIP = 30;
// Clip cache: keep last 20 clips in RAM for voice comparison context
const MAX_CLIP_CACHE = 20;
// Minimum confidence for a clip to be considered a confirmed Luca sound (used for cache + voice ref)
const MIN_CACHE_CONFIDENCE = 60;
// Confidence threshold to auto-save a clip as the permanent voice reference (0-100)
const AUTO_SAVE_CONFIDENCE = 95;
// Spectral pre-filter: if median fraction of FFT energy in bins 0-3 (0-375Hz) exceeds this,
// clip is likely mechanical noise (washing machine motor hum, fan, AC compressor).
// Applied only to clips under 10s — long clips use variance check instead.
const LOW_FREQ_DOMINANCE = 0.50;

// POLL_INTERVAL_MS: how often (ms) we fetch the latest events from /events.
const POLL_INTERVAL_MS = 3000;

// ─────────────────────────────────────────────────────────────
// Token / cost counters — seeded from Firestore on load, then incremented locally
// ─────────────────────────────────────────────────────────────
const tokenStats = { inputTokens: 0, outputTokens: 0, costUsd: 0 };

async function loadInitialStats() {
  try {
    const res = await fetch(`${API_BASE}/stats`);
    if (!res.ok) return;
    const { stats } = await res.json();
    tokenStats.inputTokens  = stats.input_tokens  || 0;
    tokenStats.outputTokens = stats.output_tokens || 0;
    tokenStats.costUsd      = stats.cost_usd      || 0;
    updateCostDisplay();
  } catch (e) { /* non-critical */ }
}

// ─────────────────────────────────────────────────────────────
// App state — single source of truth for all runtime data
// ─────────────────────────────────────────────────────────────
const state = {
  babyName: '',         // from localStorage / setup form
  babyAgeMonths: 0,    // used in Gemini prompts for age-appropriate detection
  currentScreen: 'setup',
  events: [],           // latest event list from /events (used to avoid duplicate flash)
  eventIds: new Set(),  // IDs we've already seen; used to detect and flash new events
  summary: null,        // latest summary object from /summary
  wakeLock: null,       // WakeLock object to keep screen on (prevents phone sleep)

  // VAD / MediaRecorder state
  audioCtx: null,       // Web Audio API context for analysing mic volume
  analyser: null,       // AnalyserNode: reads frequency data from mic stream
  mediaStream: null,    // raw mic stream from getUserMedia
  recorder: null,       // MediaRecorder: captures webm/opus chunks
  isRecording: false,       // true while MediaRecorder is active
  recordingStartTime: 0,   // Date.now() when recording started; used for MIN_CLIP_MS filter
  silenceTimer: null,       // setTimeout handle: fires after SILENCE_MS of quiet
  clipTimer: null,          // setTimeout handle: fires after MAX_CLIP_MS to force-end clip
  recordingChunks: [],      // array of Blob chunks collected during one recording session
  rmsLog: [],               // RMS samples collected during recording (for variance check)
  rmsFrameCount: 0,         // frame counter used to sub-sample RMS (1 sample per 6 frames)
  _rmsDisplayCount: 0,      // frame counter for throttling the live RMS display update

  // FIFO send queue — ensures only one /analyze call in-flight at a time
  sendQueue: [],        // array of {blob, cacheId} tuples waiting to be sent
  isSending: false,     // true while a sendClip() call is in progress
  lastClipSummary: '',  // short text summary of what the last clip contained (sent as context)

  // Clip cache — last MAX_CLIP_CACHE clips in RAM (ephemeral, cleared on refresh)
  // Each entry: {id, blob, timestamp, durationMs, hasLucaSound, maxConfidence}
  clipCache: [],
    voiceReferenceConfidence: 0,
  // Voice reference — best confirmed Luca clip, persisted in IndexedDB across refreshes
  voiceReferenceBlob: null,

  // Spectral log — low-freq energy ratio samples (0–1) collected during each recording.
  // Used by Check 2.5 to filter mechanical noise (washing machines, motors).
  spectralLog: [],

  // Caregiver identification — namespaced per baby in IndexedDB
  caregiverVoices: {},      // {name: blob} — confirmed caregivers (baby-directed voice)
  caregiverPending: {},     // {name: count} — seen but not yet confirmed (needs 2 clips)
  caregiverNormalTones: {}, // {name: blob} — caregiver's normal adult-voice clip (not talking to baby)

  isPaused: false,      // true while monitoring is paused (no VAD, no Gemini calls)

  // Event polling
  pollInterval: null,   // setInterval handle for pollEvents()

  // Voice session (Edit Log / Companion overlays)
  voiceWs: null,           // active WebSocket connection to backend /ws/voice/*
  voiceCtx: null,          // AudioContext for push-to-talk recording
  voiceProcessor: null,    // ScriptProcessorNode: converts float32 mic → int16 PCM for WS
  voiceStream: null,       // MediaStream for voice overlay mic
  voiceVolRaf: null,       // requestAnimationFrame handle for voice volume meter
  activeVoiceSession: null, // 'edit' | 'companion' — which overlay is open
};

// ─────────────────────────────────────────────────────────────
// Expose selected functions to HTML inline event handlers (onclick, etc.)
// ─────────────────────────────────────────────────────────────
window.app = {
  holdStart: (session) => voiceHoldStart(session), // called on mousedown/touchstart of hold-to-speak button
  holdEnd: (session) => voiceHoldEnd(session),     // called on mouseup/touchend
  saveVoiceReference: () => saveVoiceReference(),  // called from "Save Voice Reference" button
  downloadClipCache: () => downloadClipCache(),    // called from "Export Test Clips" button
  togglePause: () => togglePause(),                // called from "Pause" button
};

// ─────────────────────────────────────────────────────────────
// Utility helpers
// ─────────────────────────────────────────────────────────────

// Returns today's date as "March 15" for display in headers
function today() {
  return new Date().toLocaleDateString('en-US', { month: 'long', day: 'numeric' });
}

// Returns today's date as "YYYY-MM-DD" for API requests
function todayISO() {
  return new Date().toISOString().slice(0, 10);
}

// Returns yesterday's date as "YYYY-MM-DD"
function yesterdayISO() {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return d.toISOString().slice(0, 10);
}

// Returns current timestamp as ISO 8601 in LOCAL time with timezone offset.
// e.g. "2026-03-15T20:16:07-07:00" — so Gemini writes times that match the event log display.
function nowISO() {
  const now = new Date();
  const pad = n => String(n).padStart(2, '0');
  const off = now.getTimezoneOffset();         // minutes behind UTC (positive = behind)
  const sign = off <= 0 ? '+' : '-';
  const absOff = Math.abs(off);
  return `${now.getFullYear()}-${pad(now.getMonth()+1)}-${pad(now.getDate())}` +
    `T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}` +
    `${sign}${pad(Math.floor(absOff/60))}:${pad(absOff%60)}`;
}

// Formats an ISO timestamp as "9:30 AM" for event list display
function formatTime(isoStr) {
  try {
    return new Date(isoStr).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  } catch {
    return isoStr;
  }
}

// Maps Firestore event types to display emojis
const EVENT_ICONS = {
  feeding: '🍼',
  nap: '😴',
  cry: '😢',
  diaper: '🩺',
  outing: '🌳',
  health_note: '💊',
  activity: '🎮',
  new_food: '🥑',
  milestone: '🎉',
  observation: '👀',
};

// Returns emoji for a given event type, or a generic icon as fallback
function eventIcon(type) {
  return EVENT_ICONS[type] || '📝';
}

// Converts a Blob to a base64 string.
// Chunked in 8192-byte pieces to avoid "Maximum call stack size exceeded"
// when spreading large Uint8Arrays as function arguments.
async function blobToBase64(blob) {
  const uint8 = new Uint8Array(await blob.arrayBuffer());
  let binary = '';
  for (let i = 0; i < uint8.length; i += 8192) {
    binary += String.fromCharCode(...uint8.subarray(i, i + 8192));
  }
  return btoa(binary);
}

// Converts a base64 string back to a Blob (complement of blobToBase64)
function base64ToBlob(b64, mimeType) {
  const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
  return new Blob([bytes], { type: mimeType });
}

// ─────────────────────────────────────────────────────────────
// Voice segment extraction — trims a blob to [startSec, endSec]
// using WebAudio and re-encodes as PCM WAV.
// Falls back to the original blob on any error.
// WAV is used because Gemini accepts it and OfflineAudioContext
// cannot re-encode to WebM directly.
// ─────────────────────────────────────────────────────────────
function audioBufferToWav(buffer) {
  const numChannels = buffer.numberOfChannels;
  const sampleRate  = buffer.sampleRate;
  const numFrames   = buffer.length;
  const bytesPerSample = 2; // 16-bit PCM
  const blockAlign  = numChannels * bytesPerSample;
  const dataBytes   = numFrames * blockAlign;
  const arrayBuf    = new ArrayBuffer(44 + dataBytes);
  const view        = new DataView(arrayBuf);
  const writeStr    = (off, s) => { for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i)); };
  writeStr(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, true);
  writeStr(8, 'WAVE');
  writeStr(12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);           // PCM
  view.setUint16(22, numChannels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * blockAlign, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, 16, true);          // bits per sample
  writeStr(36, 'data');
  view.setUint32(40, dataBytes, true);
  let off = 44;
  for (let i = 0; i < numFrames; i++) {
    for (let ch = 0; ch < numChannels; ch++) {
      const s = Math.max(-1, Math.min(1, buffer.getChannelData(ch)[i]));
      view.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
      off += 2;
    }
  }
  return new Blob([arrayBuf], { type: 'audio/wav' });
}

async function extractAudioSegment(blob, startSec, endSec) {
  try {
    const arrayBuffer = await blob.arrayBuffer();
    const tempCtx = new (window.AudioContext || window.webkitAudioContext)();
    const audioBuffer = await tempCtx.decodeAudioData(arrayBuffer);
    await tempCtx.close();
    const sr = audioBuffer.sampleRate;
    const startSample = Math.max(0, Math.floor(startSec * sr));
    const endSample   = Math.min(audioBuffer.length, Math.ceil(endSec * sr));
    const frameCount  = endSample - startSample;
    if (frameCount <= 0) return blob;
    const trimmed = new (window.AudioContext || window.webkitAudioContext)()
      .createBuffer(audioBuffer.numberOfChannels, frameCount, sr);
    for (let ch = 0; ch < audioBuffer.numberOfChannels; ch++) {
      trimmed.copyToChannel(audioBuffer.getChannelData(ch).subarray(startSample, endSample), ch);
    }
    const wavBlob = audioBufferToWav(trimmed);
    console.log(`[voice-seg] Extracted ${startSec.toFixed(1)}s–${endSec.toFixed(1)}s → ${wavBlob.size}B WAV (was ${blob.size}B)`);
    return wavBlob;
  } catch (err) {
    console.warn('[voice-seg] extractAudioSegment failed, using full clip:', err);
    return blob;
  }
}

// ─────────────────────────────────────────────────────────────
// Screen routing — shows one screen at a time by toggling .active class
// ─────────────────────────────────────────────────────────────
function showScreen(id) {
  // Remove .active from all screens, then add it to the target screen
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById(`screen-${id}`).classList.add('active');
  state.currentScreen = id;
}

// ─────────────────────────────────────────────────────────────
// Voice reference — persistent best Luca audio clip (IndexedDB)
//
// The "voice profile" is not text — it's the actual audio of Luca's best clip.
// Gemini can hear his voice directly and use it for comparison when analyzing new clips.
// Stored in IndexedDB so it survives page refresh (unlike the RAM clip cache).
// ─────────────────────────────────────────────────────────────

// Open (or create) the voice reference IndexedDB
function openVoiceRefDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open('babble-voice-ref', 1);
    req.onupgradeneeded = e => e.target.result.createObjectStore('ref');
    req.onsuccess = e => resolve(e.target.result);
    req.onerror = () => reject(req.error);
  });
}

// Persist the voice reference blob to IndexedDB (overwrites any previous)
async function persistVoiceReference(blob) {
  const db = await openVoiceRefDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction('ref', 'readwrite');
    tx.objectStore('ref').put(blob, 'current');
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

// Load the voice reference blob from IndexedDB; returns null if not saved
async function loadVoiceReference() {
  try {
    const db = await openVoiceRefDB();
    return new Promise(resolve => {
      const tx = db.transaction('ref', 'readonly');
      const req = tx.objectStore('ref').get('current');
      req.onsuccess = e => resolve(e.target.result || null);
      req.onerror = () => resolve(null);
    });
  } catch {
    return null;
  }
}

// saveVoiceReference — picks the highest-confidence confirmed Luca clip from the cache
// and stores it as the permanent voice reference in IndexedDB.
// Called from the "Save Voice Reference" button in the debug panel.
async function saveVoiceReference() {
  const statusEl = document.getElementById('voice-profile-status');
  const best = [...state.clipCache]
    .filter(e => e.hasLucaSound && e.maxConfidence > 50)
    .sort((a, b) => b.maxConfidence - a.maxConfidence)[0];

  if (!best) {
    if (statusEl) statusEl.textContent = '⚠ No confirmed Luca clip yet — keep listening!';
    return;
  }

  if (statusEl) statusEl.textContent = '⏳ Saving...';
  state.voiceReferenceBlob = best.blob;
  await persistVoiceReference(best.blob);
  if (statusEl) statusEl.textContent = `✅ Voice reference saved (confidence: ${best.maxConfidence})`;
}

// buildReferenceNote — mirrors the backend reference_note logic from gemini_client.py.
// Returns a string describing what reference audio is currently available in state.
function buildReferenceNote() {
  const nVoice = state.voiceReferenceBlob ? 1 : 0;
  const recentHigh = state.clipCache.filter(e => e.hasLucaSound && e.maxConfidence > MIN_CACHE_CONFIDENCE);
  const nRecent = Math.min(recentHigh.length, 2);
  const caregiverNames = Object.keys(state.caregiverVoices);
  const normalNames = Object.keys(state.caregiverNormalTones);

  const parts = [];
  if (nVoice) parts.push(`${nVoice} permanent voice reference clip(s) of ${state.babyName}`);
  if (nRecent) parts.push(
    `${nRecent} recent clip(s) already analyzed and logged ` +
    `(use for voice comparison AND to refine past events via enriches_event_id if this clip adds context)`
  );
  if (caregiverNames.length) parts.push(`voice clips of known caregivers (${caregiverNames.join(', ')})`);
  if (normalNames.length) parts.push(`normal-tone (adult-to-adult) voice clips of ${normalNames.join(', ')}`);

  return parts.length
    ? '\nReference audio provided before the current clip: ' + parts.join('; ') + '.'
    : '';
}

// downloadClipCache — bundles all cached clips + current ANALYZE_SYSTEM context into a .zip.
// Includes context.json with events_json, last_clip_summary, and reference_note so the full
// prompt state can be reproduced offline.
// Workflow: run app 10–15 min → click button → move clips + context from zip to backend/tests/fixtures/
async function downloadClipCache() {
  if (state.clipCache.length === 0) {
    alert('No clips cached yet — let the app run for a few minutes first.');
    return;
  }

  // Build context snapshot — everything the ANALYZE_SYSTEM prompt needs at this moment
  const contextSnapshot = {
    exported_at: new Date().toISOString(),
    baby_name: state.babyName,
    baby_age_months: state.babyAgeMonths,
    events_json: state.events,
    last_clip_summary: state.lastClipSummary || '',
    reference_note: buildReferenceNote(),
    known_caregivers: Object.keys(state.caregiverVoices),
  };
  const contextJson = JSON.stringify(contextSnapshot, null, 2);

  if (typeof JSZip === 'undefined') {
    // Fallback if CDN unavailable: sequential downloads with a long stagger
    for (const entry of state.clipCache) {
      const url = URL.createObjectURL(entry.blob);
      const a = document.createElement('a');
      a.href = url;
      const label = entry.hasLucaSound ? `luca_conf${entry.maxConfidence}` : 'no_luca';
      const summary = entry.summary ? `_${entry.summary}` : '';
      a.download = `${label}${summary}_${entry.id}.webm`;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      await new Promise(r => setTimeout(r, 1000));
    }
    // Download context.json separately in fallback mode
    const ctxBlob = new Blob([contextJson], { type: 'application/json' });
    const ctxUrl = URL.createObjectURL(ctxBlob);
    const ca = document.createElement('a');
    ca.href = ctxUrl;
    ca.download = `babble_context_${new Date().toISOString().slice(0, 10)}.json`;
    document.body.appendChild(ca);
    ca.click();
    document.body.removeChild(ca);
    URL.revokeObjectURL(ctxUrl);
    return;
  }

  const zip = new JSZip();
  for (const entry of state.clipCache) {
    const label = entry.hasLucaSound ? `luca_conf${entry.maxConfidence}` : 'no_luca';
    const summary = entry.summary ? `_${entry.summary}` : '';
    zip.file(`${label}${summary}_${entry.id}.webm`, entry.blob);
  }
  zip.file('context.json', contextJson);

  const zipBlob = await zip.generateAsync({ type: 'blob' });
  const url = URL.createObjectURL(zipBlob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `babble_clips_${new Date().toISOString().slice(0, 10)}.zip`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

// ─────────────────────────────────────────────────────────────
// Social card photo — IndexedDB persistence (survives page refresh)
// ─────────────────────────────────────────────────────────────

function openPhotoRefDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open('babble-photo-ref', 1);
    req.onupgradeneeded = e => e.target.result.createObjectStore('photo');
    req.onsuccess = e => resolve(e.target.result);
    req.onerror = () => reject(req.error);
  });
}

async function persistPhotoBlob(blob) {
  try {
    const db = await openPhotoRefDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction('photo', 'readwrite');
      tx.objectStore('photo').put(blob, 'current');
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  } catch (e) { console.warn('[photo] IDB save failed:', e); }
}

async function loadPersistedPhoto() {
  try {
    const db = await openPhotoRefDB();
    return new Promise(resolve => {
      const tx = db.transaction('photo', 'readonly');
      const req = tx.objectStore('photo').get('current');
      req.onsuccess = e => resolve(e.target.result || null);
      req.onerror = () => resolve(null);
    });
  } catch { return null; }
}

// ─────────────────────────────────────────────────────────────
// Clip cache — IndexedDB persistence (survives page refresh)
// DB: babble-clip-cache, store: clips, keyPath: id
// ─────────────────────────────────────────────────────────────

function openClipDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open('babble-clip-cache', 1);
    req.onupgradeneeded = e => e.target.result.createObjectStore('clips', { keyPath: 'id' });
    req.onsuccess = e => resolve(e.target.result);
    req.onerror = () => reject(req.error);
  });
}

async function persistClipEntry(entry) {
  try {
    const db = await openClipDB();
    const tx = db.transaction('clips', 'readwrite');
    const store = tx.objectStore('clips');
    store.put(entry);
    // prune to MAX_CLIP_CACHE oldest entries
    store.getAll().onsuccess = e => {
      const all = e.target.result.sort((a, b) => a.id - b.id);
      if (all.length > MAX_CLIP_CACHE) {
        all.slice(0, all.length - MAX_CLIP_CACHE).forEach(old => store.delete(old.id));
      }
    };
  } catch (e) { console.warn('[clip-cache] IDB save failed:', e); }
}

async function loadPersistedClips() {
  try {
    const db = await openClipDB();
    return new Promise(resolve => {
      const tx = db.transaction('clips', 'readonly');
      tx.objectStore('clips').getAll().onsuccess = e => {
        resolve(e.target.result.sort((a, b) => a.id - b.id).slice(-MAX_CLIP_CACHE));
      };
    });
  } catch { return []; }
}

// ─────────────────────────────────────────────────────────────
// Caregiver voice identification — IndexedDB, namespaced per baby
//
// DB name: babble-caregivers-{babyName} (e.g. babble-caregivers-luca)
// Namespacing ensures separate stores per baby — switching profiles starts fresh.
// Caregivers are identified automatically by Gemini (caregiver_hint field) after
// appearing in 2+ separate clips (guards against jokes / one-off mentions).
// ─────────────────────────────────────────────────────────────

function caregiverDbName() {
  return `babble-caregivers-${state.babyName.toLowerCase().replace(/\s+/g, '-')}`;
}

function openCaregiverDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(caregiverDbName(), 2);
    req.onupgradeneeded = e => {
      const db = e.target.result;
      if (!db.objectStoreNames.contains('voices')) db.createObjectStore('voices');
      if (!db.objectStoreNames.contains('normal_tones')) db.createObjectStore('normal_tones');
    };
    req.onsuccess = e => resolve(e.target.result);
    req.onerror = () => reject(req.error);
  });
}

async function saveCaregiverClip(name, blob) {
  const db = await openCaregiverDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction('voices', 'readwrite');
    tx.objectStore('voices').put(blob, name.toLowerCase());
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

async function loadAllCaregivers() {
  try {
    const db = await openCaregiverDB();
    return new Promise(resolve => {
      const result = {};
      const tx = db.transaction('voices', 'readonly');
      tx.objectStore('voices').openCursor().onsuccess = e => {
        const cursor = e.target.result;
        if (cursor) { result[cursor.key] = cursor.value; cursor.continue(); }
        else resolve(result);
      };
      tx.onerror = () => resolve({});
    });
  } catch {
    return {};
  }
}

async function saveCaregiverNormalTone(name, blob) {
  const db = await openCaregiverDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction('normal_tones', 'readwrite');
    tx.objectStore('normal_tones').put(blob, name.toLowerCase());
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

async function loadAllNormalTones() {
  try {
    const db = await openCaregiverDB();
    return new Promise(resolve => {
      const result = {};
      const tx = db.transaction('normal_tones', 'readonly');
      tx.objectStore('normal_tones').openCursor().onsuccess = e => {
        const cursor = e.target.result;
        if (cursor) { result[cursor.key] = cursor.value; cursor.continue(); }
        else resolve(result);
      };
      tx.onerror = () => resolve({});
    });
  } catch {
    return {};
  }
}

// Restore confirmed caregivers from Firestore backend → populate state + IDB cache.
// Called on startup in applyProfile(). Safe to call if no caregivers saved yet.
async function restoreCaregiversFromBackend() {
  try {
    const res = await fetch(`${API_BASE}/caregivers?baby=${encodeURIComponent(state.babyName)}`);
    if (!res.ok) return;
    const { caregivers } = await res.json();
    for (const [name, data] of Object.entries(caregivers)) {
      if (data.voice_b64 && !state.caregiverVoices[name]) {
        const blob = base64ToBlob(data.voice_b64, 'audio/webm');
        state.caregiverVoices[name] = blob;
        await saveCaregiverClip(name, blob);
      }
      if (data.normal_tone_b64 && !state.caregiverNormalTones[name]) {
        const blob = base64ToBlob(data.normal_tone_b64, 'audio/webm');
        state.caregiverNormalTones[name] = blob;
        await saveCaregiverNormalTone(name, blob);
      }
    }
    const count = Object.keys(caregivers).length;
    if (count > 0) console.log(`[caregiver] Restored ${count} caregiver(s) from cloud`);
  } catch (e) {
    console.warn('[caregiver] Could not restore from backend:', e);
  }
}

// Sync a newly confirmed caregiver's voice blobs to Firestore (best-effort, non-blocking).
// Called when a caregiver reaches 2+ clips and is confirmed.
async function syncCaregiverToBackend(name, voiceBlob, normalBlob) {
  try {
    const payload = { baby_name: state.babyName, clip_count: 2 };
    if (voiceBlob) payload.voice_b64 = await blobToBase64(voiceBlob);
    if (normalBlob) payload.normal_tone_b64 = await blobToBase64(normalBlob);
    fetch(`${API_BASE}/caregivers/${encodeURIComponent(name)}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).catch(() => {});
  } catch (e) {
    console.warn('[caregiver] Could not sync to backend:', e);
  }
}

// ─────────────────────────────────────────────────────────────
// Setup screen — first-launch profile entry
// ─────────────────────────────────────────────────────────────

// Called at boot: if profile exists in localStorage, skip setup and go straight to Home
function initSetup() {
  const saved = loadProfile();
  if (saved) {
    applyProfile(saved.name, saved.age);
    showScreen('home');
    startMonitoring();  // immediately start passive listening
    return;
  }
  showScreen('setup'); // first launch: show setup form
}

// Reads babyName + babyAgeMonths from localStorage; returns null if not set
function loadProfile() {
  const name = localStorage.getItem('babyName');
  const age = localStorage.getItem('babyAgeMonths');
  if (name) return { name, age: parseInt(age) || 0 };
  return null;
}

// Persists profile to localStorage and updates in-memory state
function saveProfile(name, age) {
  localStorage.setItem('babyName', name);
  localStorage.setItem('babyAgeMonths', String(age));
  applyProfile(name, age);
}

// Updates all UI elements that display baby name/age, and sets state.babyName/babyAgeMonths
function applyProfile(name, age) {
  state.babyName = name;
  state.babyAgeMonths = age;
  const label = `${name} · ${today()}`;
  document.getElementById('home-header-center').textContent = label;
  document.getElementById('summary-header-center').textContent = label;
  document.getElementById('social-card-header').textContent = `👶 ${name} · ${today()} · Babble`;
  document.getElementById('settings-name').value = name;
  document.getElementById('settings-age').value = String(age);

  // Load voice reference: try IndexedDB first, then fall back to Firestore via backend.
  loadVoiceReference().then(async blob => {
    const el = document.getElementById('voice-profile-status');
    if (blob) {
      state.voiceReferenceBlob = blob;
      state.voiceReferenceConfidence = AUTO_SAVE_CONFIDENCE;
      if (el) el.textContent = '✅ Voice reference loaded';
    } else {
      // IDB empty (cleared storage, new browser, etc.) — try to restore from Firestore
      try {
        const res = await fetch(`${API_BASE}/voice-reference?baby=${encodeURIComponent(state.babyName)}`);
        if (res.ok) {
          const { audio_b64 } = await res.json();
          const bytes = Uint8Array.from(atob(audio_b64), c => c.charCodeAt(0));
          const restored = new Blob([bytes], { type: 'audio/webm' });
          state.voiceReferenceBlob = restored;
          state.voiceReferenceConfidence = AUTO_SAVE_CONFIDENCE;
          await persistVoiceReference(restored); // cache locally in IDB
          if (el) el.textContent = '✅ Voice reference restored from cloud';
          console.log('[voice-ref] Restored from Firestore');
        } else {
          if (el) el.textContent = 'No voice reference yet — will auto-save at conf ≥ 95';
        }
      } catch {
        if (el) el.textContent = 'No voice reference yet — will auto-save at conf ≥ 95';
      }
    }
  });

  // Load known caregiver voice blobs from IndexedDB (namespaced per baby name).
  // Caregivers are auto-identified by Gemini after 2+ clip mentions.
  // After IDB load, also restore from Firestore backend (fills in any IDB-cleared caregivers).
  loadAllCaregivers().then(voices => {
    state.caregiverVoices = voices;
    const names = Object.keys(voices);
    if (names.length > 0) {
      console.log(`[caregiver] Loaded ${names.length} known caregiver(s): ${names.join(', ')}`);
    }
    restoreCaregiversFromBackend(); // best-effort: fills in any missing from Firestore
  });

  // Load normal-tone reference clips (how caregivers sound when NOT talking to the baby).
  loadAllNormalTones().then(tones => { state.caregiverNormalTones = tones; });

  // Load persisted clip cache from IndexedDB (survives page refresh).
  loadPersistedClips().then(clips => {
    state.clipCache = clips;
    if (clips.length > 0) console.log(`[clip-cache] Loaded ${clips.length} clips from IDB`);
  });
}

// Validates name + age inputs; returns {name, age} or null (shows alert on failure)
function validateProfileInputs(nameVal, ageVal) {
  const name = nameVal.trim();
  const age = parseInt(ageVal) || 0;
  if (!name) { alert('Please enter your baby\'s name'); return null; }
  if (age < 0 || age > 36) { alert('Please enter an age between 0 and 36 months'); return null; }
  return { name, age };
}

// "Start Listening" button on Setup screen
document.getElementById('setup-start').addEventListener('click', () => {
  const inputs = validateProfileInputs(
    document.getElementById('setup-name').value,
    document.getElementById('setup-age').value,
  );
  if (!inputs) return;
  saveProfile(inputs.name, inputs.age);
  showScreen('home');
  startMonitoring();
});

// ─────────────────────────────────────────────────────────────
// Settings overlay — accessible from Home and Summary headers via ⚙
// ─────────────────────────────────────────────────────────────
function openSettings() {
  document.getElementById('settings-overlay').classList.add('active');
}
function closeSettings() {
  document.getElementById('settings-overlay').classList.remove('active');
}
document.getElementById('home-settings-btn').addEventListener('click', openSettings);
document.getElementById('summary-settings-btn').addEventListener('click', openSettings);
document.getElementById('settings-save').addEventListener('click', () => {
  const inputs = validateProfileInputs(
    document.getElementById('settings-name').value,
    document.getElementById('settings-age').value,
  );
  if (!inputs) return;
  saveProfile(inputs.name, inputs.age);
  closeSettings();
});
document.getElementById('settings-close').addEventListener('click', closeSettings);
document.getElementById('settings-logout').addEventListener('click', () => {
  localStorage.clear();
  location.reload();
});

// ─────────────────────────────────────────────────────────────
// Navigation between screens
// ─────────────────────────────────────────────────────────────
document.getElementById('btn-go-summary').addEventListener('click', () => {
  showScreen('summary');
  loadSummary(); // fetch latest summary from backend when navigating to Summary screen
});
document.getElementById('summary-back').addEventListener('click', () => showScreen('home'));
document.getElementById('btn-share').addEventListener('click', () => {
  showScreen('social');
  loadSocialCard(); // populate tweet text from current summary
});
document.getElementById('social-back').addEventListener('click', () => showScreen('summary'));
document.getElementById('btn-generate-summary').addEventListener('click', generateSummary);

// ─────────────────────────────────────────────────────────────
// Wake lock — prevents phone screen from sleeping during passive monitoring
// ─────────────────────────────────────────────────────────────
async function acquireWakeLock() {
  if ('wakeLock' in navigator) {
    try {
      state.wakeLock = await navigator.wakeLock.request('screen');
    } catch {
      // Not critical — app still works if wake lock is unavailable (e.g. Safari)
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Passive monitoring — VAD + MediaRecorder pipeline
//
// HOW IT WORKS:
//   startMonitoring()
//     → requests mic permission
//     → creates Web Audio API AnalyserNode connected to mic
//     → calls runVAD() to start the detection loop
//
//   runVAD() — runs every animation frame (≈60 times/sec)
//     → reads frequency data from AnalyserNode
//     → calculates RMS (root mean square = overall volume level)
//     → if rms > VAD_THRESHOLD: call startRecording() if not already recording
//     → always resets silence timer so recording continues while loud
//     → updates the volume bar UI every frame
//
//   startRecording()
//     → creates a MediaRecorder on the mic stream
//     → collects audio chunks in state.recordingChunks every 100ms
//     → sets a 60-second hard cap (sends clip and restarts)
//
//   stopRecording()
//     → called when: (a) silence timer fires, or (b) 60s cap reached
//     → stops MediaRecorder → triggers onRecordingStop()
//
//   onRecordingStop()
//     → assembles chunks into a single Blob
//     → calls enqueueClip() to add to send queue
//
//   enqueueClip() / drainQueue()
//     → FIFO queue: only one /analyze call in-flight at a time
//     → if busy: clip waits in queue; no clips dropped
//     → calls sendClip() for each blob in order
//
//   sendClip()
//     → base64-encodes the audio blob
//     → POST /analyze with {audio_base64, baby_name, baby_age_months, timestamp, context}
//     → context includes all today's events + last clip summary (for deduplication)
//     → if events returned: triggers immediate pollEvents() to refresh the UI
// ─────────────────────────────────────────────────────────────
async function startMonitoring() {
  await acquireWakeLock();
  loadInitialStats();   // seed token counter from Firestore accumulated totals
  startEventPolling(); // begin polling /events every 3s
  loadYesterdaySummary(); // show previous day's tweet on home screen
  scheduleMidnightReset(); // auto-clear log and refresh yesterday card at midnight

  // Request microphone access from the browser
  try {
    state.mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
  } catch (err) {
    updateListeningStatus('MIC DENIED', false);
    return;
  }

  // Set up Web Audio API analysis chain: mic → AnalyserNode
  // AnalyserNode gives us frequency/time domain data for volume calculation
  state.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  const source = state.audioCtx.createMediaStreamSource(state.mediaStream);
  state.analyser = state.audioCtx.createAnalyser();
  state.analyser.fftSize = 512; // frequency resolution; 512 gives 256 frequency bins
  source.connect(state.analyser); // mic → analyser (not connected to speakers — no feedback)

  updateListeningStatus('LISTENING...', true);
  runVAD(); // start the detection loop
}

// runVAD — the main audio detection loop, runs every animation frame
// Reads mic volume and decides when to start/stop recording
function runVAD() {
  // Uint8Array to hold frequency data from AnalyserNode (values 0–255 per bin)
  const buf = new Uint8Array(state.analyser.frequencyBinCount);
  const volFill = document.getElementById('vol-bar-fill'); // volume bar DOM element

  function tick() {
    // Read latest frequency data into buf (replaces previous values in-place)
    state.analyser.getByteFrequencyData(buf);

    // Calculate RMS: square root of the average of squared values.
    // This gives a single 0–255 number representing overall volume.
    // Quiet room: ~5–15. Normal speech: ~20–60. Loud speech: ~60–120.
    const rms = Math.sqrt(buf.reduce((s, v) => s + v * v, 0) / buf.length);

    // Update volume bar: scale rms to 0–100% width (cap at 80 = full bar)
    if (volFill) {
      const pct = Math.min(100, (rms / 80) * 100).toFixed(1);
      volFill.style.width = pct + '%';
      // Red (loud) when above threshold → recording will start; green when below
      if (rms > VAD_THRESHOLD) {
        volFill.classList.add('loud');
      } else {
        volFill.classList.remove('loud');
      }
    }

    // Core VAD decision: if loud enough, start/continue recording (skip when paused)
    if (!state.isPaused && rms > VAD_THRESHOLD) {
      if (!state.isRecording) startRecording(); // first loud frame → start capture
      resetSilenceTimer();                       // reset the 2s silence countdown
    }

    // While recording, sample RMS and spectral ratio every 6 frames (~10 samples/sec)
    if (state.isRecording) {
      state.rmsFrameCount++;
      if (state.rmsFrameCount % 6 === 0) {
        state.rmsLog.push(rms);
        // Low-freq ratio: fraction of total FFT energy in bins 0–3 (≈0–375 Hz)
        // High ratio → energy concentrated in motor-hum range → likely mechanical noise
        const totalEnergy = buf.reduce((a, b) => a + b, 0) || 1;
        const lowFreqEnergy = buf[0] + buf[1] + buf[2] + buf[3];
        state.spectralLog.push(lowFreqEnergy / totalEnergy);
      }
    }

    // Update live RMS readout in debug panel every 6 frames (throttled)
    state._rmsDisplayCount++;
    if (state._rmsDisplayCount % 6 === 0) {
      const rmsEl = document.getElementById('debug-rms');
      if (rmsEl) {
        const recLabel = state.isRecording ? ' 🔴 recording' : '';
        rmsEl.textContent = `VAD RMS: ${rms.toFixed(1)} (threshold: ${VAD_THRESHOLD})${recLabel}`;
        rmsEl.style.color = rms > VAD_THRESHOLD ? '#c06030' : '';
      }
    }

    // If below threshold: don't stop immediately — silenceTimer fires after SILENCE_MS

    requestAnimationFrame(tick); // schedule next tick (≈60fps in Chrome)
  }

  requestAnimationFrame(tick); // kick off the loop
}

// startRecording — creates a MediaRecorder and begins capturing audio
function startRecording() {
  if (state.isRecording) return; // guard: already recording
  state.isRecording = true;
  state.recordingStartTime = Date.now(); // used by onRecordingStop to check clip duration
  state.recordingChunks = [];
  state.rmsLog = [];       // reset RMS sample log for this clip
  state.rmsFrameCount = 0; // reset frame counter for sub-sampling

  // Prefer webm/opus (smaller, Gemini-native); fall back to plain webm
  const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
    ? 'audio/webm;codecs=opus'
    : 'audio/webm';

  state.recorder = new MediaRecorder(state.mediaStream, { mimeType });

  // ondataavailable fires every 100ms (configured at start(100) below)
  // Each chunk is pushed to the array; assembled into a Blob on stop
  state.recorder.ondataavailable = (e) => {
    if (e.data && e.data.size > 0) state.recordingChunks.push(e.data);
  };
  state.recorder.onstop = onRecordingStop; // fires when recorder.stop() is called
  state.recorder.start(100); // collect data in 100ms slices
  state.spectralLog = []; // reset spectral log for this clip

  setPulseDot('recording'); // update UI: red pulsing dot + "RECORDING..."

  // 3-second hard cap: if audio never drops below threshold, send what we have and restart
  // (short cap reduces latency and relies on pre-filters to discard noise)
  state.clipTimer = setTimeout(() => {
    if (state.isRecording) {
      stopRecording(true); // restart=true → immediately begin next clip
    }
  }, MAX_CLIP_MS);
}

// stopRecording — ends the current clip
// restart=true: used for the hard-cap case (3s) to seamlessly continue recording
function stopRecording(restart = false) {
  if (!state.isRecording) return;
  clearTimeout(state.silenceTimer); // cancel pending silence-stop
  clearTimeout(state.clipTimer);    // cancel pending 60s cap
  state.isRecording = false;
  state.recorder.stop(); // triggers ondataavailable (final chunk) then onstop
  if (restart) {
    // For 60s cap: brief pause then start fresh clip without dropping audio
    setTimeout(() => startRecording(), 50);
  } else {
    setPulseDot('active'); // back to green "LISTENING..."
  }
}

// onRecordingStop — called after recorder.stop() completes
// Assembles chunks into a Blob, runs 3 pre-filters, then queues for Gemini if it passes.
function onRecordingStop() {
  if (state.recordingChunks.length === 0) return; // nothing recorded (e.g. mic error)
  const blob = new Blob(state.recordingChunks, { type: 'audio/webm' });
  state.recordingChunks = [];

  const durationMs = Date.now() - state.recordingStartTime;
  const clipKB = (blob.size / 1024).toFixed(1);
  const clipTime = new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const audioUrl = URL.createObjectURL(blob);

  // Check 1: too short — door slam, single bang. Every clip has a 2s silence tail, so
  // clips under 3s had < 1s of actual triggering audio. Safe for speech (2–10s) and
  // baby sounds (even a 1s murmur + 2s tail = 3s, right at the boundary).
  if (durationMs < MIN_CLIP_MS) {
    appendDebugEntry(clipTime, clipKB, audioUrl, 'filtered', `too short (${(durationMs / 1000).toFixed(1)}s < ${MIN_CLIP_MS / 1000}s)`);
    return;
  }

  // Check 1.5: short quiet clips → soft ambient noise, not baby sounds.
  // Applied only to clips under 8s: checks if the loudest moment ever exceeded MIN_PEAK_RMS_SHORT_CLIP.
  // A short clip where the peak RMS never reached 45 crossed VAD_THRESHOLD only barely
  // (hum, AC, faint breathing). Missing baby murmuring is acceptable — false positives are worse.
  // Long clips (≥ 8s) skip this check — sustained sounds need the variance check instead.
  if (durationMs < MAX_QUIET_CLIP_MS && state.rmsLog.length > 0) {
    const peakRms = Math.max(...state.rmsLog);
    if (peakRms < MIN_PEAK_RMS_SHORT_CLIP) {
      appendDebugEntry(clipTime, clipKB, audioUrl, 'filtered',
        `quiet short clip (peak RMS ${peakRms.toFixed(0)} < ${MIN_PEAK_RMS_SHORT_CLIP}, ${(durationMs / 1000).toFixed(1)}s)`);
      return;
    }
  }

  // Check 1.75: keyboard / typing pattern — isolated RMS spikes with no sustained runs.
  // Keyboard: each keystroke = 1–3 loud RMS samples (~100–300ms), then silence.
  // Speech/crying: sustained runs of 5+ consecutive loud samples (≥ 500ms).
  // Only applied to short clips (< 8s) — long speech clips always produce sustained runs.
  if (durationMs < 8000 && state.rmsLog.length >= 10) {
    let isolatedSpikes = 0, sustainedRuns = 0, runLen = 0;
    const HIGH = 40, MIN_SUSTAINED = 5;
    for (let i = 0; i < state.rmsLog.length; i++) {
      if (state.rmsLog[i] >= HIGH) {
        runLen++;
      } else {
        if (runLen >= MIN_SUSTAINED) sustainedRuns++;
        else if (runLen >= 1) isolatedSpikes++;
        runLen = 0;
      }
    }
    if (runLen >= MIN_SUSTAINED) sustainedRuns++;
    else if (runLen >= 1) isolatedSpikes++;

    if (isolatedSpikes >= 4 && sustainedRuns === 0) {
      appendDebugEntry(clipTime, clipKB, audioUrl, 'filtered',
        `keyboard pattern (${isolatedSpikes} spikes, 0 sustained runs, ${(durationMs / 1000).toFixed(1)}s)`);
      return;
    }
  }

  // Check 2: too small — silent artefact. Real audio (speech, crying, murmuring) encodes
  // to at least 15 KB at typical mic bitrate.
  if (blob.size < MIN_CLIP_BYTES) {
    appendDebugEntry(clipTime, clipKB, audioUrl, 'filtered', `too small (${clipKB} KB < ${(MIN_CLIP_BYTES / 1024).toFixed(0)} KB)`);
    return;
  }

  // Check 2.5: mechanical noise — washing machine motor, compressor, fan.
  // Short clips (< 10s) where the median low-freq energy fraction exceeds LOW_FREQ_DOMINANCE
  // are likely motor hum, not baby sounds. Baby crying has low-freq content too, but spreads
  // broadly across speech bins; a washing machine concentrates in 0–375 Hz.
  // Requires at least 5 spectral samples (~3s of recording) to be reliable.
  if (durationMs < 10000 && state.spectralLog.length >= 5) {
    const sorted = [...state.spectralLog].sort((a, b) => a - b);
    const medianRatio = sorted[Math.floor(sorted.length / 2)];
    if (medianRatio > LOW_FREQ_DOMINANCE) {
      appendDebugEntry(clipTime, clipKB, audioUrl, 'filtered',
        `mechanical noise (low-freq ${(medianRatio * 100).toFixed(0)}% > ${LOW_FREQ_DOMINANCE * 100}%, ${(durationMs / 1000).toFixed(1)}s)`);
      return;
    }
  }

  // Check 3: steady-state noise — washing machine, airplane, fan.
  // Only applied to clips ≥ 15s: baby murmuring triggers SILENCE_MS between sounds
  // so it produces short clips and never reaches this gate. Machine noise never
  // triggers silence (constant above threshold) → always hits the 2-min cap → long clip.
  if (durationMs >= MIN_VARIANCE_CLIP_MS && state.rmsLog.length >= 10) {
    const mean = state.rmsLog.reduce((a, b) => a + b, 0) / state.rmsLog.length;
    const variance = state.rmsLog.reduce((a, b) => a + (b - mean) ** 2, 0) / state.rmsLog.length;
    if (variance < MIN_RMS_VARIANCE) {
      appendDebugEntry(clipTime, clipKB, audioUrl, 'filtered', `steady noise (variance ${variance.toFixed(1)} < ${MIN_RMS_VARIANCE}, ${(durationMs / 1000).toFixed(0)}s clip)`);
      return;
    }
  }

  // Add to clip cache (RAM + IndexedDB, max 20 entries) — survives page refresh
  const cacheId = Date.now();
  const cacheEntry0 = { id: cacheId, blob, timestamp: nowISO(), durationMs, hasLucaSound: false, maxConfidence: 0, summary: '' };
  state.clipCache.push(cacheEntry0);
  if (state.clipCache.length > MAX_CLIP_CACHE) state.clipCache.shift(); // drop oldest
  persistClipEntry(cacheEntry0); // persist to IDB

  enqueueClip(blob, cacheId, durationMs); // passed all checks → queue for Gemini
}

// resetSilenceTimer — restarts the countdown to stop recording.
// Called every frame while loud; if no call for SILENCE_MS, stopRecording fires.
function resetSilenceTimer() {
  clearTimeout(state.silenceTimer);
  state.silenceTimer = setTimeout(() => {
    if (state.isRecording) stopRecording(); // silence for 2s → end clip
  }, SILENCE_MS);
}

// togglePause — pauses or resumes VAD + Gemini sending
function togglePause() {
  state.isPaused = !state.isPaused;
  const btn = document.getElementById('pause-btn');
  if (state.isPaused) {
    if (state.isRecording) stopRecording(); // finish & discard current clip
    clearTimeout(state.silenceTimer);
    clearTimeout(state.clipTimer);
    document.getElementById('pulse-dot').className = 'pulse-dot'; // grey, no animation
    document.getElementById('listening-status').textContent = 'PAUSED';
    document.getElementById('vol-bar-fill').style.width = '0%';
    if (btn) { btn.textContent = '▶ Resume'; btn.classList.add('paused'); }
  } else {
    setPulseDot('active');
    if (btn) { btn.textContent = '⏸ Pause'; btn.classList.remove('paused'); }
  }
}

// setPulseDot — updates the pulsing status dot + text label
// mode: 'active' (green, LISTENING) or 'recording' (red, RECORDING)
function setPulseDot(mode) {
  const dot = document.getElementById('pulse-dot');
  dot.className = `pulse-dot ${mode}`;
  document.getElementById('listening-status').textContent =
    mode === 'recording' ? 'RECORDING...' : 'LISTENING...';
}

// updateListeningStatus — used for one-off status messages (e.g. "MIC DENIED")
function updateListeningStatus(text, ok) {
  document.getElementById('listening-status').textContent = text;
  const dot = document.getElementById('pulse-dot');
  dot.className = ok ? 'pulse-dot active' : 'pulse-dot'; // no animation if error
}

// ─────────────────────────────────────────────────────────────
// FIFO send queue — ensures clips are sent sequentially, never in parallel
//
// WHY SEQUENTIAL: Gemini /analyze calls can take 3–10 seconds each.
// If two clips arrive during one API call, we queue the second one.
// No clips are ever dropped — they just wait their turn.
// ─────────────────────────────────────────────────────────────

// enqueueClip — adds a {blob, cacheId} tuple to the queue and tries to send immediately
function enqueueClip(blob, cacheId, durationMs) {
  state.sendQueue.push({ blob, cacheId, durationMs });
  drainQueue(); // attempt to send (no-op if already sending)
}

// drainQueue — sends the next clip in the queue if nothing is in-flight
async function drainQueue() {
  if (state.isSending || state.sendQueue.length === 0) return; // busy or empty
  state.isSending = true;
  const { blob, cacheId, durationMs } = state.sendQueue.shift(); // take the oldest clip (FIFO)
  try {
    await sendClip(blob, cacheId, durationMs);
  } catch (err) {
    console.error('Analyze error:', err);
  } finally {
    state.isSending = false;
    drainQueue(); // process next clip if any
  }
}

// sendClip — encodes a Blob and POST's it to /analyze along with reference audio.
// cacheId: the id of this clip in state.clipCache — used to mark it after Gemini responds.
// The backend decodes the audio, calls Gemini 2.5 Flash, and returns detected events.
// Also updates the token/cost display and appends a debug log entry with an audio link.
async function sendClip(blob, cacheId, durationMs = 0) {
  // Create a playable URL for this clip (for debug log)
  const audioUrl = URL.createObjectURL(blob);
  const clipTime = new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const clipKB = (blob.size / 1024).toFixed(1);

  // Encode current clip using shared helper
  const b64 = await blobToBase64(blob);

  // Build reference audio array:
  //   Type A: permanent voice reference (best confirmed Luca clip, stored in IndexedDB)
  //   Type B: up to 2 recent clips with confirmed Luca sounds (confidence > MIN_CACHE_CONFIDENCE)
  //   Recent clips serve dual purpose: voice comparison + re-evaluation of past logged events
  const referenceAudio = [];

  if (state.voiceReferenceBlob) {
    referenceAudio.push({
      audio_base64: await blobToBase64(state.voiceReferenceBlob),
      type: 'voice_reference',
    });
  }

  const recentHigh = [...state.clipCache]
    .reverse()
    .filter(e => e.hasLucaSound && e.maxConfidence > MIN_CACHE_CONFIDENCE && e.id !== cacheId)
    .slice(0, 2);
  for (const e of recentHigh) {
    referenceAudio.push({ audio_base64: await blobToBase64(e.blob), type: 'recent' });
  }

  // Type C: confirmed caregiver voice clips — help Gemini put names to voices
  for (const [name, caregiverBlob] of Object.entries(state.caregiverVoices)) {
    referenceAudio.push({
      audio_base64: await blobToBase64(caregiverBlob),
      type: 'caregiver',
      label: name,
      mime_type: caregiverBlob.type || 'audio/webm',
    });
  }

  // Type D: caregiver normal-tone clips — how they sound when NOT talking to the baby.
  // Gemini uses these to detect the parentese shift (higher pitch, slower pace) that
  // indicates baby-directed speech even when the baby's name is never said.
  for (const [name, normalBlob] of Object.entries(state.caregiverNormalTones)) {
    referenceAudio.push({
      audio_base64: await blobToBase64(normalBlob),
      type: 'caregiver_normal',
      label: name,
      mime_type: normalBlob.type || 'audio/webm',
    });
  }

  // Build the request payload
  // context.events_today: lets Gemini know what's already logged (avoid duplicates)
  // context.last_clip_summary: brief text of what the previous clip contained (continuity)
  // context.known_caregivers: list of confirmed caregiver names → passed into system prompt
  const payload = {
    audio_base64: b64,
    baby_name: state.babyName,
    baby_age_months: state.babyAgeMonths,
    timestamp: nowISO(),
    clip_duration_sec: durationMs / 1000,
    context: {
      events_today: state.events,
      last_clip_summary: state.lastClipSummary,
      known_caregivers: Object.keys(state.caregiverVoices),
    },
    reference_audio: referenceAudio, // may be empty [] if no confirmed clips yet
  };

  const res = await fetch(`${API_BASE}/analyze`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const err = await res.text();
    console.error('Analyze failed:', err);
    appendDebugEntry(clipTime, clipKB, audioUrl, null, null);
    return;
  }

  const data = await res.json();

  // Accumulate token usage and refresh the cost display
  if (data.usage) {
    tokenStats.inputTokens  += data.usage.input_tokens  || 0;
    tokenStats.outputTokens += data.usage.output_tokens || 0;
    tokenStats.costUsd      += data.usage.cost_usd      || 0;
    updateCostDisplay();
  }

  // Update cache entry with detection results and a content summary for the filename
  const cacheEntry = state.clipCache.find(e => e.id === cacheId);
  if (cacheEntry && data.raw_events?.length > 0) {
    const maxConf = Math.max(...data.raw_events.map(e => e.confidence || 0));
    if (maxConf > MIN_CACHE_CONFIDENCE) {
      cacheEntry.hasLucaSound = true;
      cacheEntry.maxConfidence = maxConf;
    }
    // Store first event detail as a short filename-safe summary
    const firstDetail = data.raw_events[0]?.detail || '';
    cacheEntry.summary = firstDetail.slice(0, 40)
      .replace(/[^a-zA-Z0-9 ]/g, '').trim()
      .replace(/\s+/g, '-').toLowerCase();
  }
  if (cacheEntry) persistClipEntry(cacheEntry); // update IDB with Gemini results

  // If this clip had no baby events, save it as a normal-tone reference for known caregivers.
  // These clips capture how caregivers sound in regular adult conversation (not parentese).
  if ((data.raw_events || []).length === 0 && Object.keys(state.caregiverVoices).length > 0) {
    for (const name of Object.keys(state.caregiverVoices)) {
      if (!state.caregiverNormalTones[name]) {
        state.caregiverNormalTones[name] = blob;
        await saveCaregiverNormalTone(name, blob);
        console.log(`[caregiver] Saved normal tone for ${name}`);
        break; // one save per empty clip
      }
    }
  }

  // Extract caregiver hints from Gemini's response.
  // Confirmation requires 2+ separate clips mentioning the same name — guards against
  // jokes, sarcasm, or Gemini over-inferring from a single ambiguous mention.
  const hints = [...new Set(
    (data.raw_events || [])
      .map(e => e.caregiver_hint)
      .filter(h => h && typeof h === 'string')
      .map(h => h.toLowerCase().trim())
  )];
  for (const name of hints) {
    if (state.caregiverVoices[name]) continue; // already confirmed
    state.caregiverPending[name] = (state.caregiverPending[name] || 0) + 1;
    if (state.caregiverPending[name] >= 2) {
      // Confirmed — extract the caregiver's voice segment if Gemini returned timestamps
      const seg = (data.raw_events || [])
        .find(e => e.caregiver_hint === name && e.caregiver_voice_segment)
        ?.caregiver_voice_segment;
      const voiceBlob = seg
        ? await extractAudioSegment(blob, seg.start_sec, seg.end_sec)
        : blob;
      state.caregiverVoices[name] = voiceBlob;
      await saveCaregiverClip(name, voiceBlob);
      delete state.caregiverPending[name];
      // Sync to Firestore so caregiver survives browser clear
      syncCaregiverToBackend(name, voiceBlob, state.caregiverNormalTones[name] || null);
      const statusEl = document.getElementById('voice-profile-status');
      if (statusEl) statusEl.textContent = `🧑 Caregiver confirmed: ${name}`;
      console.log(`[caregiver] Confirmed: ${name} (2+ clips)`);
    } else {
      console.log(`[caregiver] Pending: ${name} (${state.caregiverPending[name]}/2)`);
    }
  }

  // AUTO-SAVE: if this clip contained a very high-confidence Luca detection,
  // automatically persist it as the permanent voice reference and record a
  // caregiver entry for 'mom' when appropriate. This helps users who don't
  // want to manually click "Save Voice Reference".
  try {
    const cacheEntry = state.clipCache.find(e => e.id === cacheId);
    const maxConf = cacheEntry?.maxConfidence || 0;
    if (maxConf >= AUTO_SAVE_CONFIDENCE) {
      // Save as permanent voice reference if it's better than any previously saved
      if (!state.voiceReferenceBlob || maxConf > (state.voiceReferenceConfidence || 0)) {
        state.voiceReferenceBlob = blob;
        state.voiceReferenceConfidence = maxConf;
        await persistVoiceReference(blob);
        // Also sync to Firestore so it survives browser storage clearing / device changes
        blobToBase64(blob).then(b64 => {
          fetch(`${API_BASE}/voice-reference`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ baby_name: state.babyName, audio_b64: b64 }),
          }).catch(() => {}); // best-effort
        });
        const statusEl = document.getElementById('voice-profile-status');
        if (statusEl) statusEl.textContent = `✅ Auto-saved voice reference (conf ${maxConf})`;
        console.log(`[voice-ref] Auto-saved voice reference (conf ${maxConf})`);
      }

      // If Gemini hinted this was a caregiver named 'mom'/'mother', or no caregivers
      // have been confirmed yet, save this clip as the mom caregiver reference.
      const lowerHints = hints || [];
      const hintedMom = lowerHints.includes('mom') || lowerHints.includes('mother');
      if (hintedMom || Object.keys(state.caregiverVoices).length === 0) {
        const caregiverName = 'mom';
        if (!state.caregiverVoices[caregiverName] || maxConf > (state.caregiverVoices[caregiverName]?.conf || 0)) {
          // Extract mom's voice segment if Gemini provided timestamps
          const momSeg = (data.raw_events || [])
            .find(e => (e.caregiver_hint === 'mom' || e.caregiver_hint === 'mother') && e.caregiver_voice_segment)
            ?.caregiver_voice_segment;
          const momVoiceBlob = momSeg
            ? await extractAudioSegment(blob, momSeg.start_sec, momSeg.end_sec)
            : blob;
          state.caregiverVoices[caregiverName] = momVoiceBlob;
          try { await saveCaregiverClip(caregiverName, momVoiceBlob); } catch (e) { console.error(e); }
          const statusEl = document.getElementById('voice-profile-status');
          if (statusEl) statusEl.textContent = `🧑 Caregiver saved: ${caregiverName} (conf ${maxConf})`;
          console.log(`[caregiver] Auto-saved caregiver '${caregiverName}' (conf ${maxConf})`);
        }
      }
    }
  } catch (e) {
    console.error('Auto-save voice reference failed', e);
  }

  // Append a debug log entry showing the clip audio + Gemini result
  appendDebugEntry(clipTime, clipKB, audioUrl, data.raw_events || [], data.events || []);

  // data.events: array of events that were detected AND saved to Firestore this call
  // data.events_added: count of new events written (vs events that enriched existing ones)
  if (data.events && data.events.length > 0) {
    // Optimistically merge new events into state.events immediately — no Firestore round-trip.
    // This ensures the next clip in the queue sees these events in events_today before it sends,
    // preventing Gemini from creating duplicates for consecutive clips of the same moment.
    for (const ev of data.events) {
      if (!state.eventIds.has(ev.id)) {
        state.events.push(ev);
        state.eventIds.add(ev.id);
      }
    }
    pollEvents(); // still fire (non-blocking) to sync UI + pick up any server-side enrichments
    state.lastClipSummary = data.events.map(e => `[${e.timestamp}] ${e.detail}`).join('; ');
  }
}

// updateCostDisplay — refreshes the token/cost line in the listening badge
function updateCostDisplay() {
  const el = document.getElementById('cost-display');
  if (!el) return;
  const totalTok = tokenStats.inputTokens + tokenStats.outputTokens;
  const tokLabel = totalTok >= 1000 ? `${(totalTok / 1000).toFixed(1)}K` : String(totalTok);
  el.textContent = `🔢 ${tokLabel} tok · $${tokenStats.costUsd.toFixed(6)}`;
}

// appendDebugEntry — adds one row to the debug log panel for a clip that was sent
// Shows: time, size, playable audio link, and what Gemini found (pre/post filter)
function appendDebugEntry(time, kb, audioUrl, rawEvents, filteredEvents) {
  const log = document.getElementById('debug-log');
  if (!log) return;

  const entry = document.createElement('div');
  entry.style.cssText = 'margin-bottom:0.5rem;border-bottom:1px solid rgba(0,0,0,0.06);padding-bottom:0.4rem;';

  let eventsHtml = '';
  if (rawEvents === 'filtered') {
    eventsHtml = `<span style="color:#e0a070">⏭ VAD filtered — ${escHtml(filteredEvents)}</span>`;
  } else if (rawEvents === null) {
    eventsHtml = '<span style="color:#e07070">❌ Request failed</span>';
  } else if (rawEvents.length === 0) {
    eventsHtml = '<span style="opacity:0.6">No events detected</span>';
  } else {
    eventsHtml = rawEvents.map(e => {
      const etype  = e.event_type;
      const detail = e.new_logging_detail || e.past_content_detail || '';
      const kept = filteredEvents.some(f => f.event_type === etype && (f.new_logging_detail || f.past_content_detail || '') === detail);
      const icon = kept ? '✅' : '❌';
      const style = kept ? '' : 'opacity:0.5;text-decoration:line-through;';
      const newLog = e.new_logging ? '[CURRENT]' : '[CONTEXT]';
      const src = e.evidence_source ? `[${e.evidence_source}]` : '';
      return `<div style="${style}">${icon} [${etype}] ${newLog} ${src} conf:${e.confidence} — ${escHtml(detail)}</div>`;
    }).join('');
  }

  entry.innerHTML = `
    <div><strong>${time}</strong> · ${kb} KB · <audio src="${audioUrl}" controls style="height:18px;vertical-align:middle;"></audio></div>
    <div style="margin-top:0.2rem;">${eventsHtml}</div>
  `;

  log.insertBefore(entry, log.firstChild); // newest first
  // Keep at most 20 entries
  while (log.children.length > 20) log.removeChild(log.lastChild);
}

// ─────────────────────────────────────────────────────────────
// Event polling — keeps the event list in sync with Firestore
//
// GET /events returns all today's events sorted by timestamp.
// We compare returned IDs against state.eventIds to detect new arrivals.
// New events get the CSS class 'new-event' which triggers a green flash animation.
// ─────────────────────────────────────────────────────────────

// startEventPolling — begins polling /events on POLL_INTERVAL_MS interval
function startEventPolling() {
  pollEvents(); // fetch immediately on start
  state.pollInterval = setInterval(pollEvents, POLL_INTERVAL_MS);
}

// pollEvents — fetches latest events and re-renders the list
async function pollEvents() {
  try {
    const res = await fetch(`${API_BASE}/events?date=${nowISO().slice(0, 10)}`);
    if (!res.ok) return;
    const data = await res.json();
    state.events = data.events || [];
    renderEventList(state.events);
  } catch {
    // Network error — silently skip; will retry on next interval
  }
}

// renderEventList — builds the event list DOM from the events array
// Events not previously in state.eventIds are treated as "new" and flash green
function renderEventList(events) {
  const list = document.getElementById('event-list');
  if (events.length === 0) {
    list.innerHTML = `<div class="empty-log">
      <span class="emoji">👂</span>
      Listening for activity — speak near the phone!
    </div>`;
    return;
  }

  list.innerHTML = '';
  for (const ev of events) {
    const isNew = !state.eventIds.has(ev.id); // true if we've never seen this event ID before
    if (isNew) state.eventIds.add(ev.id);     // mark as seen so next render won't flash it

    const item = document.createElement('div');
    item.className = `event-item${isNew ? ' new-event' : ''}`;
    item.dataset.id = ev.id;

    item.innerHTML = `
      <span class="event-icon">${eventIcon(ev.type)}</span>
      <div class="event-body">
        <div class="event-time">${formatTime(ev.timestamp)}</div>
        <div class="event-detail">${escHtml(ev.detail || '')}</div>
        ${ev.notable ? '<div class="event-notable">✨ Milestone</div>' : ''}
      </div>
      <button class="event-dismiss" data-id="${ev.id}" aria-label="Dismiss">✕</button>
    `;

    list.appendChild(item);
  }

  // Attach delete handlers to all ✕ buttons
  list.querySelectorAll('.event-dismiss').forEach(btn => {
    btn.addEventListener('click', () => dismissEvent(btn.dataset.id));
  });
}

// showToast — shows a temporary undo notification at the bottom of the screen
const _pendingDeletes = {}; // eventId → setTimeout handle
let _toastTimer = null;

function showToast(message, undoCallback) {
  clearTimeout(_toastTimer);
  const toast = document.getElementById('toast');
  document.getElementById('toast-msg').textContent = message;
  toast.classList.add('visible');
  document.getElementById('toast-undo').onclick = () => {
    toast.classList.remove('visible');
    clearTimeout(_toastTimer);
    undoCallback();
  };
  _toastTimer = setTimeout(() => toast.classList.remove('visible'), 5000);
}

// dismissEvent — removes an event from UI immediately; actual Firestore DELETE is deferred
// 5 seconds so the parent can undo if Gemini logged something incorrectly.
function dismissEvent(eventId) {
  const eventData = state.events.find(e => e.id === eventId);
  document.querySelector(`[data-id="${eventId}"]`)?.remove();
  state.events = state.events.filter(e => e.id !== eventId);
  state.eventIds.delete(eventId);

  let undone = false;
  showToast('Event removed', () => {
    undone = true;
    clearTimeout(_pendingDeletes[eventId]);
    delete _pendingDeletes[eventId];
    if (eventData) {
      state.events.push(eventData);
      state.eventIds.add(eventId);
      renderEventList([...state.events].sort((a, b) =>
        new Date(a.timestamp) - new Date(b.timestamp)));
    }
  });

  _pendingDeletes[eventId] = setTimeout(async () => {
    delete _pendingDeletes[eventId];
    if (undone) return;
    try {
      await fetch(`${API_BASE}/events/${eventId}`, { method: 'DELETE' });
    } catch {
      // Best-effort: if request fails, event will reappear on next poll
    }
  }, 5000);
}

// escHtml — sanitizes user-facing text to prevent XSS in innerHTML
function escHtml(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ─────────────────────────────────────────────────────────────
// Summary screen
// ─────────────────────────────────────────────────────────────

// loadSummary — fetches the cached summary from /summary and renders it
// Called when navigating to the Summary screen, and after voice companion session ends
async function loadSummary() {
  const el = document.getElementById('summary-content');
  el.textContent = 'Loading...';
  try {
    const res = await fetch(`${API_BASE}/summary`);
    if (!res.ok) { el.textContent = 'Could not load summary.'; return; }
    const data = await res.json();
    if (data.summary) {
      state.summary = data.summary;
      renderSummary(data.summary);
    } else {
      el.textContent = 'No summary yet — tap "Summarise Day" to create one!';
    }
  } catch {
    el.textContent = 'Network error.';
  }
}

// renderSummary — renders the structured JSON summary using a fixed template
function renderSummary(summary) {
  const el = document.getElementById('summary-content');
  const s = summary?.structured;

  // Fallback: no structured data yet (empty object, null, or old string format)
  if (!s || typeof s !== 'object' || Object.keys(s).length === 0) {
    el.textContent = summary?.narrative || 'No summary content.';
    return;
  }

  const lines = [];

  // Social tweet
  if (summary.social_tweet) {
    lines.push(`💬 "${summary.social_tweet}"\n`);
  }

  // Glance
  if (s.glance?.length) {
    lines.push('✨ Today at a Glance');
    s.glance.forEach(g => lines.push(g));
    lines.push('');
  }

  // Monitoring hours / gap
  if (s.monitored_hrs != null) {
    const gapNote = s.recording_gap ? ` · gap ${s.recording_gap}` : '';
    lines.push(`📵 Monitored ~${s.monitored_hrs} hrs${gapNote}\n`);
  }

  // Eating
  if (s.eating) {
    lines.push('🍽️ Eating');
    (s.eating.bullets || []).forEach(b => lines.push(`• ${b}`));
    if (s.eating.milk) {
      const amt = s.eating.milk.amount ? ` · ${s.eating.milk.amount}` : ' · amount unknown';
      lines.push(`🍼 ${s.eating.milk.type}${amt}`);
    }
    if (s.eating.new_food) lines.push(`🆕 New food: ${s.eating.new_food}`);
    if (s.eating.tip) lines.push(`💡 ${s.eating.tip}`);
    lines.push('');
  }

  // Nap
  if (s.nap) {
    lines.push('😴 Nap');
    (s.nap.bullets || []).forEach(b => lines.push(`• ${b}`));
    if (s.nap.tip) lines.push(`💡 ${s.nap.tip}`);
    lines.push('');
  }

  // Diaper
  if (s.diaper) {
    lines.push('🚼 Diaper');
    const wet = s.diaper.wet != null ? `${s.diaper.wet} wet` : null;
    const poop = s.diaper.poop != null ? `${s.diaper.poop} poop` : null;
    const uncertain = s.diaper.uncertain ? ' (uncertain)' : '';
    const color = s.diaper.color ? ` · ${s.diaper.color}` : '';
    const consistency = s.diaper.consistency ? ` · ${s.diaper.consistency}` : '';
    const parts = [wet, poop].filter(Boolean).join(' · ');
    if (parts) lines.push(`• ${parts}${uncertain}${color}${consistency}`);
    if (s.diaper.tip) lines.push(`💡 ${s.diaper.tip}`);
    lines.push('');
  }

  // Play & Mood
  if (s.play_mood) {
    lines.push('🧸 Play & Mood');
    (s.play_mood.bullets || []).forEach(b => lines.push(`• ${b}`));
    if (s.play_mood.tip) lines.push(`💡 ${s.play_mood.tip}`);
    lines.push('');
  }

  // Milestone
  if (s.milestone) {
    lines.push('🏆 Milestone');
    if (s.milestone.bullet) lines.push(`• ${s.milestone.bullet}`);
    if (s.milestone.tip) lines.push(`💡 ${s.milestone.tip}`);
    lines.push('');
  }

  // Outing
  if (s.outing) {
    lines.push('🌳 Outing');
    (s.outing.bullets || []).forEach(b => lines.push(`• ${b}`));
    if (s.outing.tip) lines.push(`💡 ${s.outing.tip}`);
    lines.push('');
  }

  // Health
  if (s.health) {
    lines.push('🩺 Health');
    (s.health.bullets || []).forEach(b => lines.push(`• ${b}`));
    if (s.health.tip) lines.push(`💡 ${s.health.tip}`);
    lines.push('');
  }

  el.textContent = lines.join('\n').trimEnd();
}

// generateSummary — manually triggers POST /summary/generate
// The backend fetches all today's events from Firestore and calls Gemini to write the summary
async function generateSummary() {
  const btn = document.getElementById('btn-generate-summary');
  btn.disabled = true;
  btn.textContent = '⏳ Generating...';
  document.getElementById('summary-updating').style.display = 'block';

  try {
    const res = await fetch(`${API_BASE}/summary/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        baby_name: state.babyName,
        baby_age_months: state.babyAgeMonths,
      }),
    });
    if (!res.ok) { alert('Failed to generate summary'); return; }
    const data = await res.json();
    state.summary = data.summary;
    renderSummary(data.summary);
  } catch {
    alert('Network error');
  } finally {
    btn.disabled = false;
    btn.textContent = '✨ Summarise Day';
    document.getElementById('summary-updating').style.display = 'none';
  }
}

// ─────────────────────────────────────────────────────────────
// Social card screen
// ─────────────────────────────────────────────────────────────

// loadSocialCard — populates the tweet text and restores any saved photo
function loadSocialCard() {
  const tweet = state.summary?.social_tweet || `Hello from ${state.babyName}! #Babble`;
  document.getElementById('social-tweet-text').textContent = tweet;
  loadPersistedPhoto().then(blob => {
    if (blob) {
      const img = document.getElementById('social-photo');
      img.src = URL.createObjectURL(blob);
      img.classList.add('visible');
    }
  });
}

// Share to Twitter/X: opens the Twitter intent URL with the tweet pre-filled
document.getElementById('btn-tweet').addEventListener('click', () => {
  const tweet = state.summary?.social_tweet || `Hello from ${state.babyName}! #Babble`;
  const url = `https://twitter.com/intent/tweet?text=${encodeURIComponent(tweet)}`;
  window.open(url, '_blank');
});

// Add Photo button: triggers a hidden <input type="file"> and previews the selected image
document.getElementById('btn-add-photo').addEventListener('click', () => {
  document.getElementById('photo-input').click();
});

document.getElementById('photo-input').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const img = document.getElementById('social-photo');
  img.src = URL.createObjectURL(file);
  img.classList.add('visible');
  persistPhotoBlob(file); // save to IndexedDB so it survives page refresh
});

// ─────────────────────────────────────────────────────────────
// Voice overlay helpers
// ─────────────────────────────────────────────────────────────

// addTranscript — appends a message bubble to the voice overlay transcript
// role: 'gemini' (right-aligned, sage) or 'user' (left-aligned, muted)
function addTranscript(containerId, role, text) {
  const container = document.getElementById(containerId);
  const msg = document.createElement('div');
  msg.className = `transcript-msg ${role}`;
  msg.textContent = text;
  container.appendChild(msg);
  container.scrollTop = container.scrollHeight; // auto-scroll to latest message
}

// ─────────────────────────────────────────────────────────────
// Voice Edit Log — Overlay 4a (opened from Home screen "Edit Log" button)
//
// Connects to WS /ws/voice/edit-log
// Backend loads today's events as context, opens a Gemini Live session.
// Parent speaks → Gemini understands corrections → emits EDIT_CMD JSON.
// Backend applies edits to Firestore and sends back "edit_applied" messages.
// On close: event list is refreshed to show the updated events.
// ─────────────────────────────────────────────────────────────
document.getElementById('btn-edit-log').addEventListener('click', openEditLogOverlay);
document.getElementById('btn-done-edit').addEventListener('click', closeEditLogOverlay);

async function openEditLogOverlay() {
  document.getElementById('edit-log-transcript').innerHTML = '';
  document.getElementById('overlay-edit-log').classList.add('active');
  state.activeVoiceSession = 'edit';
  await connectVoiceSession('edit-log', 'edit-log-transcript');
}

async function closeEditLogOverlay() {
  closeVoiceSession();
  document.getElementById('overlay-edit-log').classList.remove('active');
  state.activeVoiceSession = null;
  await pollEvents(); // refresh event list to show any edits made during the session
}

// ─────────────────────────────────────────────────────────────
// Voice Companion — Overlay 4b (opened from Summary screen "Talk to Gemini" button)
//
// Connects to WS /ws/voice/companion
// Backend loads today's narrative summary as context, opens a Gemini Live session.
// Gemini acts as a warm parenting companion: celebrates milestones, accepts corrections.
// On close: summary is refreshed (backend may have updated it based on conversation).
// ─────────────────────────────────────────────────────────────
document.getElementById('btn-companion').addEventListener('click', openCompanionOverlay);
document.getElementById('btn-done-companion').addEventListener('click', closeCompanionOverlay);

async function openCompanionOverlay() {
  document.getElementById('companion-transcript').innerHTML = '';
  document.getElementById('overlay-companion').classList.add('active');
  state.activeVoiceSession = 'companion';
  await connectVoiceSession('companion', 'companion-transcript');
}

async function closeCompanionOverlay() {
  closeVoiceSession();
  document.getElementById('overlay-companion').classList.remove('active');
  state.activeVoiceSession = null;
  await loadSummary(); // refresh summary screen after companion session may have updated it
}

// ─────────────────────────────────────────────────────────────
// WebSocket voice bridge — connects frontend to backend Gemini Live proxy
//
// Protocol:
//   1. Client → Server: first text message = JSON config {baby_name, baby_age_months, date}
//   2. Client → Server: binary messages = raw PCM 16-bit 16kHz audio chunks (push-to-talk)
//   3. Client → Server: text message {type: "done"} = end session
//   4. Server → Client: binary messages = PCM audio from Gemini (played via Web Audio API)
//   5. Server → Client: text messages = {type, ...} JSON control messages:
//      - {type: "transcript", role: "gemini", text: "..."} → show in transcript
//      - {type: "edit_applied", cmd: {...}} → show confirmation in transcript
//      - {type: "session_end", events/summary: {...}} → refresh data
// ─────────────────────────────────────────────────────────────

// connectVoiceSession — opens the WebSocket and sets up message handlers
async function connectVoiceSession(endpoint, transcriptId) {
  const wsUrl = `${WS_BASE}/ws/voice/${endpoint}`;
  state.voiceWs = new WebSocket(wsUrl);

  // As soon as WebSocket is open, send the config payload so backend can initialize Gemini Live
  state.voiceWs.onopen = () => {
    state.voiceWs.send(JSON.stringify({
      baby_name: state.babyName,
      baby_age_months: state.babyAgeMonths,
      date: todayISO(),
      local_now: new Date().toISOString(),
      tz_offset_minutes: -new Date().getTimezoneOffset(),
    }));
  };

  state.voiceWs.onmessage = async (event) => {
    if (event.data instanceof Blob) {
      // Binary message = PCM audio from Gemini → play through speakers
      playAudioBlob(event.data);
    } else {
      // Text message = JSON control message
      const msg = JSON.parse(event.data);
      if (msg.type === 'transcript' && msg.role === 'user') {
        // Replace the "🎤 Speaking..." placeholder with the real transcription
        const placeholder = document.getElementById('voice-user-speaking');
        if (placeholder) {
          placeholder.textContent = msg.text;
          placeholder.style.opacity = '';
          placeholder.removeAttribute('id'); // allow multiple user turns
        } else {
          addTranscript(transcriptId, 'user', msg.text);
        }
      } else if (msg.type === 'transcript' && msg.role === 'gemini') {
        document.getElementById('voice-thinking')?.remove(); // clear thinking placeholder
        addTranscript(transcriptId, 'gemini', msg.text);
      } else if (msg.type === 'edit_applied') {
        // Backend successfully applied a Gemini-requested edit to Firestore
        addTranscript(transcriptId, 'gemini', `✓ Log updated`);
      } else if (msg.type === 'session_end') {
        // Session ended (backend side) — update local state if fresh data provided
        if (msg.events) state.events = msg.events;
        if (msg.summary) state.summary = msg.summary;
      }
    }
  };

  state.voiceWs.onerror = (e) => {
    console.error('Voice WS error', e);
    document.getElementById('voice-thinking')?.remove();
    addTranscript(transcriptId, 'gemini', '⚠ Connection error — tap Done to close.');
  };

  state.voiceWs.onclose = (e) => {
    if (!e.wasClean) {
      document.getElementById('voice-thinking')?.remove();
      addTranscript(transcriptId, 'gemini', '⚠ Connection lost — tap Done to close.');
    }
  };
}

// closeVoiceSession — sends "done" signal and closes the WebSocket
function closeVoiceSession() {
  if (state.voiceWs) {
    try {
      state.voiceWs.send(JSON.stringify({ type: 'done' })); // tells backend to end Gemini session
    } catch {}
    state.voiceWs.close();
    state.voiceWs = null;
  }
  stopVoiceRecording(); // clean up microphone resources
}

// ─────────────────────────────────────────────────────────────
// Push-to-talk: Hold to Speak
//
// While the button is held, we capture mic audio and stream raw PCM over the WebSocket.
// The backend forwards it to Gemini Live in real-time.
// On release, we stop the mic capture (Gemini detects silence and processes the input).
// ─────────────────────────────────────────────────────────────

// voiceHoldStart — called on mousedown/touchstart of the "Hold to Speak" button
async function voiceHoldStart(session) {
  if (!state.voiceWs || state.voiceWs.readyState !== WebSocket.OPEN) return;

  const transcriptId = session === 'edit' ? 'edit-log-transcript' : 'companion-transcript';
  const volWrapId   = session === 'edit' ? 'voice-vol-edit'      : 'voice-vol-companion';
  const btnId       = session === 'edit' ? 'btn-hold-edit'       : 'btn-hold-companion';

  // Add a placeholder that will be replaced by the real transcript when Gemini returns it
  const container = document.getElementById(transcriptId);
  if (container) {
    const placeholder = document.createElement('div');
    placeholder.id = 'voice-user-speaking';
    placeholder.className = 'transcript-msg user';
    placeholder.style.opacity = '0.55';
    placeholder.textContent = '🎤 Speaking...';
    container.appendChild(placeholder);
    container.scrollTop = container.scrollHeight;
  }
  document.getElementById(btnId)?.classList.add('held');

  // Unlock / resume the playback AudioContext inside this user gesture.
  // Browsers suspend AudioContext created outside a user tap — doing it here
  // ensures Gemini's audio reply will actually play.
  if (!playbackCtx) {
    playbackCtx = new AudioContext();
  } else if (playbackCtx.state === 'suspended') {
    await playbackCtx.resume();
  }

  try {
    // Request mic at exactly 16kHz mono — required by Gemini Live API
    state.voiceStream = await navigator.mediaDevices.getUserMedia({
      audio: {
        sampleRate: 16000,
        channelCount: 1,
        echoCancellation: true,  // reduces echo from Gemini's audio playback
        noiseSuppression: true,  // reduces background noise
      }
    });

    // Use ScriptProcessorNode to access raw float32 PCM samples
    // Then convert to Int16 (PCM 16-bit) which is what Gemini Live expects
    const ctx = new AudioContext({ sampleRate: 16000 });
    const source = ctx.createMediaStreamSource(state.voiceStream);

    // ── Waveform visualizer ───────────────────────────────────
    // Uses AnalyserNode frequency data to draw animated bars on canvas.
    // Shown only while holding; hidden on release.
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 128; // 64 frequency bins — enough for bar chart
    analyser.smoothingTimeConstant = 0.75; // smooth transitions between frames
    const freqBuf = new Uint8Array(analyser.frequencyBinCount); // 64 bins
    source.connect(analyser);

    const canvas = document.getElementById(volWrapId);
    if (canvas) canvas.style.display = '';
    const canvasCtx = canvas ? canvas.getContext('2d') : null;

    function drawVolBars() {
      state.voiceVolRaf = requestAnimationFrame(drawVolBars);
      if (!canvasCtx) return;
      analyser.getByteFrequencyData(freqBuf);

      const W = canvas.offsetWidth || canvas.width;
      const H = canvas.height;
      canvas.width = W; // sync pixel width to layout width
      canvasCtx.clearRect(0, 0, W, H);

      // Draw 28 evenly-spaced bars using the lower 40 frequency bins (voice range)
      const numBars = 28;
      const useBins = 40; // bins 0–39 cover ~0–5kHz — the vocal range
      const barW = Math.floor((W - numBars * 2) / numBars);
      const gap = 2;

      for (let i = 0; i < numBars; i++) {
        const binIdx = Math.floor((i / numBars) * useBins);
        const value = freqBuf[binIdx] / 255; // 0–1
        const barH = Math.max(3, value * H * 0.92);
        const x = i * (barW + gap);
        const y = (H - barH) / 2; // center bars vertically

        // Gradient: sage green at low volume, coral at high
        const r = Math.round(122 + (224 - 122) * value);
        const g = Math.round(170 + (112 - 170) * value);
        const b = Math.round(138 + (96  - 138) * value);
        canvasCtx.fillStyle = `rgb(${r},${g},${b})`;
        canvasCtx.beginPath();
        canvasCtx.roundRect(x, y, barW, barH, 3);
        canvasCtx.fill();
      }
    }
    drawVolBars();
    // ─────────────────────────────────────────────────────────

    const processor = ctx.createScriptProcessor(4096, 1, 1); // 4096 sample buffer

    // Buffer PCM chunks while button is held; flush to WebSocket on release.
    state.voicePcmBuffer = [];
    processor.onaudioprocess = (e) => {
      const float32 = e.inputBuffer.getChannelData(0); // float32 samples in [-1, 1]
      const int16 = float32ToInt16(float32);           // convert to int16 PCM
      state.voicePcmBuffer.push(int16.buffer.slice(0)); // buffer — don't send yet
    };

    source.connect(processor);
    processor.connect(ctx.destination); // must connect to destination or onaudioprocess won't fire
    state.voiceCtx = ctx;
    state.voiceProcessor = processor;
  } catch (err) {
    console.error('Voice recording error:', err);
  }
}

// voiceHoldEnd — called on mouseup/touchend to stop push-to-talk
function voiceHoldEnd(session) {
  // Flush all buffered PCM chunks to Gemini, then signal end-of-turn.
  const ws = state.voiceWs;
  const buf = state.voicePcmBuffer || [];
  stopVoiceRecording();
  if (ws?.readyState === WebSocket.OPEN) {
    for (const chunk of buf) {
      ws.send(chunk); // send each buffered PCM chunk in order
    }
    ws.send(JSON.stringify({ type: 'activity_end' }));
  }
  state.voicePcmBuffer = [];
  // Show a "thinking" placeholder — removed when the first Gemini response token arrives
  const transcriptId = session === 'edit' ? 'edit-log-transcript' : 'companion-transcript';
  const container = document.getElementById(transcriptId);
  if (container && !container.querySelector('#voice-thinking')) {
    const thinking = document.createElement('div');
    thinking.id = 'voice-thinking';
    thinking.className = 'transcript-msg gemini';
    thinking.textContent = '...';
    container.appendChild(thinking);
    container.scrollTop = container.scrollHeight;
  }
}

// stopVoiceRecording — disconnects audio processing nodes and releases mic
function stopVoiceRecording() {
  // Cancel volume meter animation and hide canvas
  if (state.voiceVolRaf) {
    cancelAnimationFrame(state.voiceVolRaf);
    state.voiceVolRaf = null;
  }
  ['voice-vol-edit', 'voice-vol-companion'].forEach(id => {
    const el = document.getElementById(id);
    if (!el) return;
    el.style.display = 'none';
    // Clear canvas so it's blank next time it appears
    const c = el.getContext?.('2d');
    if (c) c.clearRect(0, 0, el.width, el.height);
  });
  // Remove held state from buttons
  document.getElementById('btn-hold-edit')?.classList.remove('held');
  document.getElementById('btn-hold-companion')?.classList.remove('held');

  state.voicePcmBuffer = []; // discard any buffered audio (e.g. closed mid-hold)

  if (state.voiceProcessor) {
    state.voiceProcessor.disconnect();
    state.voiceProcessor = null;
  }
  if (state.voiceCtx) {
    state.voiceCtx.close();
    state.voiceCtx = null;
  }
  if (state.voiceStream) {
    state.voiceStream.getTracks().forEach(t => t.stop()); // release mic hardware
    state.voiceStream = null;
  }
}

// float32ToInt16 — converts Web Audio API float32 PCM to int16 PCM
// Web Audio API outputs float32 in range [-1.0, 1.0]
// Gemini Live expects int16 in range [-32768, 32767]
function float32ToInt16(float32) {
  const int16 = new Int16Array(float32.length);
  for (let i = 0; i < float32.length; i++) {
    const s = Math.max(-1, Math.min(1, float32[i])); // clamp to [-1, 1]
    int16[i] = s < 0 ? s * 0x8000 : s * 0x7fff;     // scale to int16 range
  }
  return int16;
}

// ─────────────────────────────────────────────────────────────
// Audio playback — plays PCM audio responses from Gemini Live
//
// Gemini Live returns raw PCM 16-bit 24kHz audio.
// The Web Audio API can't decode raw PCM directly — we wrap it in a WAV header
// so decodeAudioData() can process it.
// Multiple audio chunks are queued and played sequentially (no overlap).
// ─────────────────────────────────────────────────────────────
let playbackCtx = null;  // shared AudioContext for all Gemini audio playback
const audioQueue = [];   // queue of ArrayBuffers waiting to be played
let isPlaying = false;   // true while a source is actively playing

// playAudioBlob — converts a Blob to ArrayBuffer and adds it to the playback queue
async function playAudioBlob(blob) {
  const ab = await blob.arrayBuffer();
  audioQueue.push(ab);
  if (!isPlaying) drainAudioQueue(); // start playing if not already
}

// drainAudioQueue — plays one chunk at a time; calls itself when each chunk finishes
async function drainAudioQueue() {
  if (audioQueue.length === 0) { isPlaying = false; return; }
  isPlaying = true;
  const ab = audioQueue.shift();

  if (!playbackCtx) playbackCtx = new AudioContext(); // fallback for desktop (no autoplay restriction)
  if (playbackCtx.state === 'suspended') await playbackCtx.resume();
  try {
    // Wrap raw PCM in a WAV container so decodeAudioData can decode it
    const wavAb = pcm16ToWav(new Int16Array(ab), 24000); // Gemini outputs 24kHz
    const audioBuffer = await playbackCtx.decodeAudioData(wavAb);
    const source = playbackCtx.createBufferSource();
    source.buffer = audioBuffer;
    source.connect(playbackCtx.destination);
    source.onended = drainAudioQueue; // play next chunk when this one finishes
    source.start();
  } catch (e) {
    console.error('Playback error', e);
    drainAudioQueue(); // skip bad chunk, continue
  }
}

// pcm16ToWav — wraps raw Int16 PCM samples in a WAV file header
// This is needed because Web Audio API's decodeAudioData requires a container format
// WAV format: 44-byte header + raw PCM data
function pcm16ToWav(samples, sampleRate) {
  const numChannels = 1;
  const bytesPerSample = 2;                               // int16 = 2 bytes per sample
  const byteRate = sampleRate * numChannels * bytesPerSample;
  const blockAlign = numChannels * bytesPerSample;
  const dataSize = samples.length * bytesPerSample;
  const buffer = new ArrayBuffer(44 + dataSize);          // 44-byte WAV header + data
  const view = new DataView(buffer);

  function writeString(offset, str) {
    for (let i = 0; i < str.length; i++) view.setUint8(offset + i, str.charCodeAt(i));
  }

  // WAV header fields (little-endian unless noted)
  writeString(0, 'RIFF');                                // ChunkID
  view.setUint32(4, 36 + dataSize, true);               // ChunkSize
  writeString(8, 'WAVE');                               // Format
  writeString(12, 'fmt ');                              // Subchunk1ID
  view.setUint32(16, 16, true);                         // Subchunk1Size (16 = PCM)
  view.setUint16(20, 1, true);                          // AudioFormat (1 = PCM, no compression)
  view.setUint16(22, numChannels, true);                // NumChannels
  view.setUint32(24, sampleRate, true);                 // SampleRate
  view.setUint32(28, byteRate, true);                   // ByteRate
  view.setUint16(32, blockAlign, true);                 // BlockAlign
  view.setUint16(34, bytesPerSample * 8, true);         // BitsPerSample (16)
  writeString(36, 'data');                              // Subchunk2ID
  view.setUint32(40, dataSize, true);                   // Subchunk2Size

  // Copy PCM samples into the buffer after the header
  const out = new Int16Array(buffer, 44);
  for (let i = 0; i < samples.length; i++) out[i] = samples[i];

  return buffer;
}

// ─────────────────────────────────────────────────────────────
// Yesterday's summary — shows social tweet from prior day on Home screen
// ─────────────────────────────────────────────────────────────

async function loadYesterdaySummary() {
  const card = document.getElementById('yesterday-summary-card');
  const tipsEl = document.getElementById('yesterday-tips');
  if (!card || !tipsEl) return;
  try {
    const res = await fetch(`${API_BASE}/summary?date=${yesterdayISO()}`);
    if (!res.ok) { card.style.display = 'none'; return; }
    const data = await res.json();
    const summary = data.summary;
    if (!summary) { card.style.display = 'none'; return; }
    // Show tagline if set, otherwise fall back to 2 tips from structured sections
    if (summary.tagline) {
      tipsEl.innerHTML = `<div style="font-style:italic;">${escHtml(summary.tagline)}</div>`;
    } else {
      const s = summary.structured;
      if (!s) { card.style.display = 'none'; return; }
      const tips = [
        s.eating?.tip, s.nap?.tip, s.play_mood?.tip,
        s.milestone?.tip, s.diaper?.tip, s.health?.tip, s.outing?.tip,
      ].filter(Boolean).slice(0, 2);
      if (tips.length === 0) { card.style.display = 'none'; return; }
      tipsEl.innerHTML = tips.map(t => `<div>• ${escHtml(t)}</div>`).join('');
    }
    card.style.display = 'block';
  } catch {
    card.style.display = 'none';
  }
}

// ─────────────────────────────────────────────────────────────
// Midnight reset — clears today's event log at midnight each day
// and refreshes the yesterday summary card for the new day
// ─────────────────────────────────────────────────────────────

function scheduleMidnightReset() {
  const now = new Date();
  const midnight = new Date(now);
  midnight.setHours(24, 0, 0, 0); // next midnight local time
  const msUntil = midnight - now;

  setTimeout(() => {
    // Clear the event log for the new day
    state.events = [];
    state.eventIds = new Set();
    renderEventList([]);
    // Reload the yesterday card (now shows what was "today")
    loadYesterdaySummary();
    // Schedule the next midnight reset
    scheduleMidnightReset();
  }, msUntil);
}

// ─────────────────────────────────────────────────────────────
// Boot — entry point, called when the DOM is ready
// ─────────────────────────────────────────────────────────────
initSetup(); // check localStorage and show the appropriate starting screen
