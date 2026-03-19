import Foundation

/// Encodes raw Int16 PCM samples into a WAV (RIFF) byte stream.
enum WAVEncoder {
    static func encode(samples: [Int16], sampleRate: Int = 16_000, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample
        let dataSize = samples.count * bytesPerSample
        let chunkSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + dataSize)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE32(UInt32(chunkSize))
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        data.appendLE32(16)                          // sub-chunk size
        data.appendLE16(1)                           // PCM = 1
        data.appendLE16(UInt16(channels))
        data.appendLE32(UInt32(sampleRate))
        data.appendLE32(UInt32(byteRate))
        data.appendLE16(UInt16(blockAlign))
        data.appendLE16(UInt16(bitsPerSample))

        // data sub-chunk
        data.append(contentsOf: "data".utf8)
        data.appendLE32(UInt32(dataSize))

        // PCM samples (little-endian Int16)
        samples.withUnsafeBufferPointer { ptr in
            data.append(UnsafeBufferPointer(start: ptr.baseAddress.map { UnsafePointer($0) }, count: ptr.count * 2)
                .baseAddress.map { Data(bytes: $0, count: ptr.count * MemoryLayout<Int16>.size) } ?? Data())
        }

        return data
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        var v = value.littleEndian
        append(contentsOf: withUnsafeBytes(of: &v, Array.init))
    }

    mutating func appendLE32(_ value: UInt32) {
        var v = value.littleEndian
        append(contentsOf: withUnsafeBytes(of: &v, Array.init))
    }
}
