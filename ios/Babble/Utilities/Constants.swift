import Foundation

enum Constants {
    // Audio capture
    static let sampleRate: Double = 16_000       // 16 kHz
    static let channelCount: AVAudioChannelCount = 1
    static let tapBufferSize: AVAudioFrameCount = 1600  // 100ms at 16kHz

    // Ring buffer
    static let ringBufferSeconds: Double = 12
    static let preCaptureSeconds: Double = 10

    // Capture window
    static let postCaptureSeconds: Double = 30
    static let maxCaptureSeconds: Double = 90

    // Cry detection
    static let cryConfidenceThreshold: Double = 0.85

    // Wake word cool-down after a clip is dispatched
    static let triggerCooldownSeconds: Double = 60

    // Wake word detection — restart SFSpeechRecognizer task interval
    static let speechTaskRestartSeconds: Double = 55
}

// Re-export AVFoundation typealias so Constants.swift can compile standalone
import AVFoundation
typealias AVAudioChannelCount = AVFoundation.AVAudioChannelCount
typealias AVAudioFrameCount = AVFoundation.AVAudioFrameCount
