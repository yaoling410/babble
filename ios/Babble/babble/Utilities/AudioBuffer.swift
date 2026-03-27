import AVFoundation

// ============================================================
//  AudioBuffer.swift — Thread-safe circular ring buffer
// ============================================================
//
//  PURPOSE
//  -------
//  Continuously stores the last N seconds of microphone audio so that
//  when a trigger fires (baby's name heard, cry detected), we can
//  prepend audio that was captured BEFORE the trigger.
//
//  Without this, a clip would start with "…Emma" — the beginning of
//  the baby's name already spoken. With it, we capture the full name
//  and several seconds of context before it.
//
//  HOW IT WORKS (circular / ring buffer)
//  ----------------------------------------
//  The buffer is a fixed-size array of Int16 samples. A `writeHead`
//  index advances with every new sample, wrapping back to 0 when it
//  reaches the end. Old samples are silently overwritten — the array
//  always holds exactly the most recent `windowSeconds` of audio.
//
//  Example at 48 kHz, 12 s window:
//    capacity = 48000 * 12 = 576,000 samples
//    After 15 s of audio, the first 3 s are gone — only 12 s remain.
//
//  THREAD SAFETY
//  -------------
//  AVAudioEngine calls the tap callback on a real-time audio thread.
//  The app reads `snapshot()` on the main thread when a trigger fires.
//  NSLock guards every read and write to prevent data races.
//
//  FORMAT
//  ------
//  AVAudioEngine provides Float32 samples in [-1.0, 1.0].
//  The buffer stores Int16 in [-32767, 32767] to save memory.
//  At 48 kHz mono Int16, 12 s ≈ 1.1 MB — negligible.

final class AudioBuffer {
    // Fixed-size storage. Allocated once in init — no dynamic resizing.
    private let capacity: Int

    // The circular array. writeHead walks through it indefinitely.
    private var buffer: [Int16]

    // Next index to write into. Wraps: writeHead = (writeHead + 1) % capacity.
    private var writeHead: Int = 0

    // Total samples ever written (not capped at capacity).
    // Used by snapshot() to know if fewer than `capacity` samples are available.
    private var totalWritten: Int = 0

    // Guards buffer, writeHead, and totalWritten from concurrent access.
    private let lock = NSLock()

    // Stored so snapshot() can calculate the samples-per-second ratio.
    private let windowSeconds: Double

    // ----------------------------------------------------------------
    //  init
    // ----------------------------------------------------------------
    /// - Parameters:
    ///   - sampleRate: Native sample rate of the audio engine (typically 48 kHz on modern iPhones).
    ///                 Must match the actual AVAudioEngine format — a mismatch causes pitch distortion.
    ///   - windowSeconds: How many seconds of audio to keep. Default 12 s.
    ///                    Must be ≥ AppConfig.preCaptureSeconds (default 10 s).
    init(sampleRate: Double = 16_000, windowSeconds: Double = 12) {
        self.windowSeconds = windowSeconds
        capacity = Int(sampleRate * windowSeconds)
        buffer = [Int16](repeating: 0, count: capacity)
    }

    // ----------------------------------------------------------------
    //  append(_:)
    // ----------------------------------------------------------------
    /// Convert Float32 samples from an AVAudioPCMBuffer and write them
    /// into the circular buffer, overwriting the oldest samples.
    ///
    /// Called from the AVAudioEngine tap callback — runs on the audio thread.
    /// Lock is held for the duration of the write.
    func append(_ pcmBuffer: AVAudioPCMBuffer) {
        // floatChannelData[0] = mono channel (we tap with format inputNode.outputFormat)
        guard let channelData = pcmBuffer.floatChannelData else { return }
        let frameCount = Int(pcmBuffer.frameLength)
        let samples = channelData[0]

        lock.lock()
        defer { lock.unlock() }

        for i in 0 ..< frameCount {
            // Clamp to [-1, 1] before conversion — clipping artifacts in
            // the Float32 domain would saturate Int16 and cause loud pops.
            let clamped = max(-1.0, min(1.0, samples[i]))
            buffer[writeHead] = Int16(clamped * 32767)
            // Advance and wrap: when writeHead reaches capacity it goes back to 0,
            // overwriting the oldest sample.
            writeHead = (writeHead + 1) % capacity
            totalWritten += 1
        }
    }

    // ----------------------------------------------------------------
    //  snapshot(lastSeconds:)
    // ----------------------------------------------------------------
    /// Return the most recent `lastSeconds` of audio as a chronological
    /// array of Int16 PCM samples.
    ///
    /// Called on the main thread when a trigger fires. Takes the lock
    /// briefly to copy the relevant slice.
    ///
    /// - Parameter lastSeconds: How many seconds to retrieve. Capped at
    ///   `windowSeconds` (can't retrieve more than what's stored).
    ///   If fewer samples have been recorded than requested, returns all
    ///   available samples.
    ///
    /// Returns: Chronological samples (oldest first), ready to pass to WAVEncoder.
    func snapshot(lastSeconds: Double = 10) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }

        // How many samples correspond to `lastSeconds`?
        // Uses windowSeconds as the denominator because capacity = sampleRate * windowSeconds.
        let requestedSamples = Int(Double(capacity) / windowSeconds * lastSeconds)

        // Can only return what's been written (avoids reading uninitialized zeros
        // at the start of recording).
        let available = min(totalWritten, capacity)
        let count = min(requestedSamples, available)

        // Read backwards from writeHead to reconstruct chronological order.
        // writeHead points to the NEXT write slot, so the most recent sample
        // is at writeHead - 1 (wrapping). We walk back `count` positions.
        var result = [Int16](repeating: 0, count: count)
        for i in 0 ..< count {
            // (writeHead - count + i) can be negative — the extra + capacity
            // and the final % capacity keep it in [0, capacity).
            let idx = ((writeHead - count + i) % capacity + capacity) % capacity
            result[i] = buffer[idx]
        }
        return result
    }

    /// True if no audio has been written yet (app just started).
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return totalWritten == 0
    }
}
