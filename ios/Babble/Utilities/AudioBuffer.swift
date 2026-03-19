import AVFoundation

/// Thread-safe circular ring buffer storing Int16 PCM samples.
/// Capacity = sampleRate * windowSeconds (default 12 s @ 16 kHz = 192 000 samples).
final class AudioBuffer {
    private let capacity: Int
    private var buffer: [Int16]
    private var writeHead: Int = 0
    private var totalWritten: Int = 0
    private let lock = NSLock()

    init(sampleRate: Double = 16_000, windowSeconds: Double = 12) {
        capacity = Int(sampleRate * windowSeconds)
        buffer = [Int16](repeating: 0, count: capacity)
    }

    /// Append PCM samples from an AVAudioPCMBuffer (Float32 format).
    func append(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }
        let frameCount = Int(pcmBuffer.frameLength)
        let samples = channelData[0]

        lock.lock()
        defer { lock.unlock() }

        for i in 0 ..< frameCount {
            // Convert float32 [-1, 1] → Int16
            let clamped = max(-1.0, min(1.0, samples[i]))
            buffer[writeHead] = Int16(clamped * 32767)
            writeHead = (writeHead + 1) % capacity
            totalWritten += 1
        }
    }

    /// Snapshot the most recent `seconds` of audio in chronological order.
    /// If fewer samples are available, returns all written samples.
    func snapshot(lastSeconds: Double = 10) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }

        let requestedSamples = Int(16_000 * lastSeconds)
        let available = min(totalWritten, capacity)
        let count = min(requestedSamples, available)

        var result = [Int16](repeating: 0, count: count)
        for i in 0 ..< count {
            let idx = ((writeHead - count + i) % capacity + capacity) % capacity
            result[i] = buffer[idx]
        }
        return result
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return totalWritten == 0
    }
}
