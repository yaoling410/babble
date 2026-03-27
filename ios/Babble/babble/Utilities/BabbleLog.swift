import Foundation
import os.log

// ============================================================
//  BabbleLog — structured debug logging
// ============================================================
//
//  All runtime events flow through one of these subsystem categories.
//  In Console.app or Xcode's log stream, filter by subsystem
//  "com.babble.app" and pick a category to narrow the view.
//
//  CATEGORIES (each maps to a tag you'll see in every log line):
//    [VAD]     Speech-band Voice Activity Detection gate transitions
//    [ACTIVE]  Active-period enter/exit (2-min window after baby's name)
//    [CAPTURE] Clip lifecycle: trigger → buffer → flush / abort
//    [FILTER]  On-device TranscriptFilter decisions (local relevance gate)
//    [GEMINI]  Backend analysis: what is sent, what comes back
//    [APP]     General app lifecycle (start, stop, errors)
//
//  HOW TO READ A LIVE LOG
//  -----------------------
//  Xcode: open the "Debug Navigator" (⌘6) → Console output
//    or: xcrun simctl spawn booted log stream --predicate 'subsystem == "com.babble.app"'
//
//  Console.app: filter by subsystem "com.babble.app"
//    Click a category chip (VAD / ACTIVE / CAPTURE / FILTER / GEMINI) to
//    isolate just that part of the pipeline.
//
//  TYPICAL EVENT SEQUENCE (happy path):
//    [VAD]     Speech detected (energy=0.032 threshold=0.015)
//    [APP]     Wake word heard — "Amelia" — active period set 120s
//    [ACTIVE]  Entered active period
//    [CAPTURE] Started — pre-capture=10s transcript='…'
//    [FILTER]  Clip received — trigger=name words=42 active=YES transcript='…'
//    [FILTER]  Local filter PASSED → proceeding to diarize
//    [CAPTURE] Flushing clip — audio=28s | words=42
//    [GEMINI]  Sending to Gemini — trigger=name transcript=42w/210c
//    [GEMINI]  Response — events=2 corrections=0 | tokens in=812 out=94
//    [VAD]     Silence — ML pipelines OFF
//    [ACTIVE]  Active period expired

enum BabbleLog {
    // os.Logger instances — one per category.
    // The subsystem lets Console.app and log filters identify this app.
    static let vad     = Logger(subsystem: "com.babble.app", category: "VAD")
    static let active  = Logger(subsystem: "com.babble.app", category: "ACTIVE")
    static let capture = Logger(subsystem: "com.babble.app", category: "CAPTURE")
    static let filter  = Logger(subsystem: "com.babble.app", category: "FILTER")
    static let gemini  = Logger(subsystem: "com.babble.app", category: "GEMINI")
    static let app     = Logger(subsystem: "com.babble.app", category: "APP")

    // ── Inline timestamp helper ───────────────────────────────────────
    // os.Logger shows timestamps in a separate Xcode column that disappears
    // when you copy/paste. Embed "HH:mm:ss.SSS" directly in every message
    // so log lines are self-contained when shared out of Xcode.
    //
    // Usage: BabbleLog.vad.info("\(BabbleLog.ts) 🎙 ...")
    static var ts: String {
        let c = Calendar.current
        let n = Date()
        let h  = c.component(.hour,        from: n)
        let m  = c.component(.minute,      from: n)
        let s  = c.component(.second,      from: n)
        let ms = c.component(.nanosecond,  from: n) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
