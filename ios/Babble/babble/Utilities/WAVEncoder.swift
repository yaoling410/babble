import Foundation

// ============================================================
//  WAVEncoder.swift — Packs PCM samples into a WAV/RIFF byte stream
// ============================================================
//
//  PURPOSE
//  -------
//  The backend (FastAPI + Gemini) expects audio as a .wav file.
//  This encoder wraps raw Int16 PCM samples in the standard
//  RIFF/WAV container format so any audio library can decode them.
//
//  CRITICAL: Pass sampleRate: 48_000 when AVAudioEngine is the source.
//  AVAudioEngine captures at the device's native rate (48 kHz on modern
//  iPhones). Using the wrong rate in the WAV header causes playback at
//  the wrong speed — 16 kHz header on 48 kHz audio = 3x fast playback,
//  making speech unintelligible and transcription wrong.
//
//  WAV FORMAT STRUCTURE (PCM, 44-byte header + raw samples)
//  ---------------------------------------------------------
//  Offset  Size  Field
//   0       4    "RIFF" magic
//   4       4    chunk size = 36 + data size  (little-endian uint32)
//   8       4    "WAVE" format identifier
//  12       4    "fmt " sub-chunk marker
//  16       4    fmt sub-chunk size = 16 for PCM
//  20       2    audio format = 1 (PCM, uncompressed)
//  22       2    number of channels
//  24       4    sample rate (Hz)
//  28       4    byte rate = sampleRate * channels * (bitsPerSample/8)
//  32       2    block align = channels * (bitsPerSample/8)
//  34       2    bits per sample (16)
//  36       4    "data" sub-chunk marker
//  40       4    data size = numSamples * channels * (bitsPerSample/8)
//  44+      N    raw PCM samples, little-endian Int16

enum WAVEncoder {

    /// Encode Int16 PCM samples into a WAV byte stream.
    ///
    /// - Parameters:
    ///   - samples: Raw PCM audio as Int16 values (output of AudioBuffer.snapshot()).
    ///   - sampleRate: The sample rate at which audio was captured.
    ///                 **Must match AVAudioEngine's native format** (48 kHz on iPhone).
    ///                 Default is 16000 — change to 48000 when using AVAudioEngine.
    ///   - channels: Number of audio channels. 1 = mono (we always tap mono). Default 1.
    /// - Returns: A complete WAV file as Data, ready to upload or write to disk.
    static func encode(samples: [Int16], sampleRate: Int = 16_000, channels: Int = 1) -> Data {
        let bitsPerSample = 16   // Int16 = 16 bits per sample

        // Derived header fields
        let bytesPerSample = bitsPerSample / 8             // 2 bytes per sample
        let byteRate       = sampleRate * channels * bytesPerSample  // bytes per second
        let blockAlign     = channels * bytesPerSample     // bytes per frame (all channels)
        let dataSize       = samples.count * bytesPerSample          // total PCM bytes
        let chunkSize      = 36 + dataSize  // total RIFF chunk size (excludes 8-byte RIFF header)

        var data = Data()
        data.reserveCapacity(44 + dataSize)  // 44-byte header + PCM payload

        // --- RIFF header ---
        data.append(contentsOf: "RIFF".utf8)   // magic: identifies this as a RIFF file
        data.appendLE32(UInt32(chunkSize))      // total file size minus 8 (RIFF + chunkSize fields)
        data.append(contentsOf: "WAVE".utf8)   // RIFF type: this is a WAV file

        // --- fmt sub-chunk (describes the audio format) ---
        data.append(contentsOf: "fmt ".utf8)   // sub-chunk marker (note trailing space)
        data.appendLE32(16)                     // fmt sub-chunk size is always 16 for PCM
        data.appendLE16(1)                      // audio format: 1 = PCM (uncompressed)
        data.appendLE16(UInt16(channels))       // number of channels (1 = mono)
        data.appendLE32(UInt32(sampleRate))     // samples per second (e.g. 48000)
        data.appendLE32(UInt32(byteRate))       // bytes per second (for buffer sizing)
        data.appendLE16(UInt16(blockAlign))     // bytes per multi-channel frame
        data.appendLE16(UInt16(bitsPerSample))  // bits per sample (16)

        // --- data sub-chunk (the actual audio) ---
        data.append(contentsOf: "data".utf8)   // sub-chunk marker
        data.appendLE32(UInt32(dataSize))       // number of PCM bytes that follow

        // Append all Int16 samples as raw little-endian bytes.
        // `withUnsafeBytes` gives a zero-copy view of the Int16 array as raw bytes.
        // Int16 is already little-endian on all Apple platforms (ARM + x86).
        samples.withUnsafeBytes { rawPtr in
            data.append(contentsOf: rawPtr)
        }

        return data
    }
}

// ============================================================
//  Data helpers — write little-endian integers
// ============================================================
//  WAV requires all multi-byte integers in little-endian byte order.
//  These helpers make the header construction above readable.

private extension Data {
    /// Append a 16-bit unsigned integer in little-endian byte order.
    mutating func appendLE16(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    /// Append a 32-bit unsigned integer in little-endian byte order.
    mutating func appendLE32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
