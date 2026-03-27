import Foundation
import Accelerate

@available(iOS 13.0, *)
enum AudioResampler {
    static func resample48to16(samples: [Int16]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let srcCount = samples.count
        var srcFloats = [Float](repeating: 0, count: srcCount)
        var srcI16 = samples
        srcI16.withUnsafeBufferPointer { srcPtr in
            vDSP_vflt16(srcPtr.baseAddress!, 1, &srcFloats, 1, vDSP_Length(srcCount))
        }
        var divisor: Float = Float(Int16.max)
        vDSP_vsdiv(srcFloats, 1, &divisor, &srcFloats, 1, vDSP_Length(srcCount))

        let factor = 3 // 48k -> 16k
        let destCount = srcCount / factor
        var dest = [Float](repeating: 0, count: destCount)
        srcFloats.withUnsafeBufferPointer { srcBuf in
            dest.withUnsafeMutableBufferPointer { dstBuf in
                vDSP_desamp(srcBuf.baseAddress!, vDSP_Stride(factor), [Float](repeating: 1.0/Float(factor), count: factor), dstBuf.baseAddress!, vDSP_Length(destCount), vDSP_Length(factor))
            }
        }
        return dest
    }

    static func resample48to16(wavData: Data) -> [Float] {
        // Strip WAV header if present (assume 44 bytes)
        let samplesData: Data
        if wavData.count > 44 {
            samplesData = wavData.subdata(in: 44..<wavData.count)
        } else {
            samplesData = wavData
        }

        let sampleCount = samplesData.count / MemoryLayout<Int16>.size
        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { ptr in
            samplesData.copyBytes(to: ptr)
        }
        return resample48to16(samples: samples)
    }


    // TODO: Move to vDSP.downsample (Modern Swift API)
    // TODO: Add VAD energy check via vDSP_rmsq before sending to WhisperKit
    // TODO: Handle FIR state between buffers (save last 30 samples to prevent clicks at chunk boundaries)
}
