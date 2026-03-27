import Foundation
import OSLog

// ============================================================
//  LogFileWriter — mirror os.Logger output to a plain file
// ============================================================
//
//  WHY
//  ---
//  BabbleLog uses os.Logger (unified logging). Those entries are only
//  accessible via the Xcode console or `sudo log collect --device`, which
//  fails on this machine with "Device not configured (6)".
//
//  This class reads our own process's unified log store via
//  OSLogStore(scope: .currentProcessIdentifier) — available iOS 15+ — and
//  appends new entries to Documents/babble.log every 2 seconds.
//
//  Note: when reading from your own process, all `privacy: .public`
//  and `privacy: .private` values are fully visible (unlike reading
//  system logs, which redacts private values without entitlements).
//
//  ACCESS WITHOUT XCODE
//  --------------------
//  Pull the file from the device sandbox:
//
//    xcrun devicectl device file pull \
//      --device DE232601-EF40-5EE3-9FD5-0EDE8A56CC2D \
//      --domain-type appDataContainer \
//      --domain-identifier com.babble.app \
//      /Documents/babble.log /tmp/babble_app.log
//
//  Or tap "Share Logs" in Settings to AirDrop / Mail the file directly.
//
//  ROTATION
//  --------
//  File is capped at 2 MB. When exceeded, the oldest half is dropped and
//  the file is rewritten from the midpoint — so the most recent ~1 MB
//  is always available. Each session appends a startup banner.

@MainActor
final class LogFileWriter {

    static let shared = LogFileWriter()

    // ── Public ────────────────────────────────────────────────────────

    /// Path to the log file — pass to ShareLink or show in UI.
    let fileURL: URL

    // ── Private ───────────────────────────────────────────────────────

    private var flushTask: Task<Void, Never>?
    /// GCD timer — survives iOS background suspension better than Task.sleep.
    /// Task.sleep is paused when the process is suspended; DispatchSourceTimer
    /// fires as soon as the process resumes, catching up on missed intervals.
    private var gcdTimer: DispatchSourceTimer?
    /// Date of the last entry we wrote — used to avoid duplicates between flushes.
    private var lastEntryDate: Date
    private static let maxFileBytes   = 2 * 1024 * 1024   // 2 MB cap
    private static let flushInterval  = UInt64(2_000_000_000)  // 2 s in nanoseconds

    private init() {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("babble.log")
        // Start reading from 30 s before launch so we capture startup logs.
        lastEntryDate = Date().addingTimeInterval(-30)
    }

    // MARK: - Public API

    func start() {
        writeBanner()
        // Use GCD timer instead of Task.sleep — GCD timers fire as soon as the
        // process resumes from iOS suspension, whereas Task.sleep stays paused.
        // This ensures logs are written even when the app runs in background.
        gcdTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        gcdTimer = timer
    }

    func stop() {
        flushTask?.cancel()
        flushTask = nil
        gcdTimer?.cancel()
        gcdTimer = nil
    }

    // MARK: - Flush

    private func flush() {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }
        let position = store.position(date: lastEntryDate)
        guard let allEntries = try? store.getEntries(
            at: position,
            matching: NSPredicate(format: "subsystem == 'com.babble.app'")
        ) else { return }

        var lines: [String] = []
        var latestDate = lastEntryDate

        for entry in allEntries {
            guard let log = entry as? OSLogEntryLog,
                  log.date > lastEntryDate
            else { continue }
            let ts   = formatDate(log.date)
            let lvl  = levelTag(log.level)
            let cat  = log.category.padding(toLength: 7, withPad: " ", startingAt: 0)
            lines.append("[\(ts)] \(lvl) [\(cat)] \(log.composedMessage)")
            if log.date > latestDate { latestDate = log.date }
        }

        guard !lines.isEmpty else { return }
        lastEntryDate = latestDate
        append(lines: lines)
    }

    // MARK: - File helpers

    private func writeBanner() {
        let date = DateFormatter.localizedString(
            from: Date(), dateStyle: .medium, timeStyle: .medium
        )
        append(lines: [
            String(repeating: "-", count: 60),
            "Babble session started \(date)",
            String(repeating: "-", count: 60),
        ])
    }

    private func append(lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }

        let fm = FileManager.default

        // Rotate if over cap: keep the second half (most recent ~1 MB)
        if fm.fileExists(atPath: fileURL.path),
           let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size  = attrs[.size] as? Int,
           size > Self.maxFileBytes,
           let handle = try? FileHandle(forReadingFrom: fileURL) {
            handle.seek(toFileOffset: UInt64(size / 2))
            let tail = handle.readDataToEndOfFile()
            try? handle.close()
            // Find first newline so we don't start mid-line
            if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) {
                let trimmed = tail[(nl + 1)...]
                try? Data(trimmed).write(to: fileURL, options: .atomic)
            }
        }

        if fm.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Formatting helpers

    private func formatDate(_ date: Date) -> String {
        let c  = Calendar.current
        let h  = c.component(.hour,       from: date)
        let m  = c.component(.minute,     from: date)
        let s  = c.component(.second,     from: date)
        let ms = c.component(.nanosecond, from: date) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private func levelTag(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:   return "DEBUG"
        case .info:    return "INFO "
        case .notice:  return "NOTE "
        case .error:   return "ERROR"
        case .fault:   return "FAULT"
        default:       return "     "
        }
    }
}
