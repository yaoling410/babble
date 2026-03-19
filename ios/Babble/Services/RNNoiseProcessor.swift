import Foundation

/// Swift wrapper around the RNNoise C library for voice enhancement.
///
/// RNNoise operates at 48 kHz, 10ms frames (480 samples).
/// Input is 16 kHz Int16; we upsample to 48 kHz, process, then downsample.
///
/// Integration steps:
///   1. Clone https://github.com/xiph/rnnoise and run `autoreconf -fi && ./configure && make`
///   2. Add the compiled `librnnoise.a` and `rnnoise.h` to the Xcode target.
///   3. Create a bridging header `Babble-Bridging-Header.h` with: `#include "rnnoise.h"`
///
/// Until the C library is linked, `process()` is a no-op passthrough so the app
/// compiles and runs — noise reduction simply won't be applied yet.

#if canImport(rnnoise)
import rnnoise
#endif

final class RNNoiseProcessor {
    // 48 kHz, 10 ms = 480 samples per frame
    private static let rnnoiseRate = 48_000
    private static let frameSize = 480

    /// Process 16 kHz Int16 samples through RNNoise.
    /// Returns cleaned samples at the same 16 kHz / Int16 format.
    static func process(samples16k: [Int16]) -> [Int16] {
        #if canImport(rnnoise)
        return processWithRNNoise(samples16k: samples16k)
        #else
        // Passthrough: RNNoise not linked yet
        return samples16k
        #endif
    }

    #if canImport(rnnoise)
    private static func processWithRNNoise(samples16k: [Int16]) -> [Int16] {
        guard let state = rnnoise_create(nil) else { return samples16k }
        defer { rnnoise_destroy(state) }

        // Upsample 16k → 48k (simple 3x repeat)
        let samples48k: [Float] = samples16k.flatMap { s -> [Float] in
            let f = Float(s) / 32768.0
            return [f, f, f]
        }

        var output48k = [Float](repeating: 0, count: samples48k.count)
        var offset = 0

        samples48k.withUnsafeBufferPointer { inputPtr in
            output48k.withUnsafeMutableBufferPointer { outputPtr in
                while offset + frameSize <= samples48k.count {
                    let inFrame = inputPtr.baseAddress! + offset
                    let outFrame = outputPtr.baseAddress! + offset
                    rnnoise_process_frame(state, outFrame, inFrame)
                    offset += frameSize
                }
            }
        }

        // Downsample 48k → 16k (take every 3rd sample)
        var result = [Int16]()
        result.reserveCapacity(samples16k.count)
        var i = 0
        while i < output48k.count {
            let clamped = max(-1.0, min(1.0, output48k[i]))
            result.append(Int16(clamped * 32767))
            i += 3
        }
        return result
    }
    #endif
}
