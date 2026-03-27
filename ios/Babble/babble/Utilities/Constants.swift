import AVFoundation

// ============================================================
//  Constants.swift — Low-level fixed values (not user-tunable)
// ============================================================
//
//  PURPOSE
//  -------
//  Two-tier configuration system:
//    - AppConfig.swift: everything you might want to tune between
//      environments (thresholds, timeouts, buffer sizes).
//    - Constants.swift (this file): hardware/framework constraints
//      that don't change between environments.
//
//  WHY TWO FILES?
//  --------------
//  Call sites that use Constants don't need to import AppConfig,
//  and the names are shorter. Constants also includes a few truly
//  fixed values (tapBufferSize) that have no AppConfig equivalent.
//
//  RULE: if you find yourself wanting to change a value here for
//  production vs. development, it belongs in AppConfig instead.

enum Constants {

    // ── Audio engine ─────────────────────────────────────────────────
    // AVAudioEngine uses the native format of the input node.
    // On modern iPhones this is 48 kHz; older devices may use 44.1 kHz.
    // 4096 frames at 48 kHz ≈ 85 ms per buffer callback.

    /// Number of audio frames per engine tap callback.
    /// Smaller = lower latency; larger = fewer callbacks = less CPU overhead.
    static let tapBufferSize: AVAudioFrameCount = 4096   // ~85ms @ 48 kHz

    // ── Forwarded from AppConfig ──────────────────────────────────────
    // These are mirrors of AppConfig values so call sites only need
    // one import. Change the values in AppConfig, not here.
    static let ringBufferSeconds:        Double  = AppConfig.ringBufferSeconds
    static let preCaptureSeconds:        Double  = AppConfig.preCaptureSeconds
    static let silenceFlushSeconds:      Double  = AppConfig.silenceFlushSeconds
    static let maxCaptureSeconds:       Double  = AppConfig.maxCaptureSeconds
    static let triggerCooldownSeconds:  Double  = AppConfig.triggerCooldownSeconds
    static let activePeriodSeconds:     Double  = AppConfig.activePeriodSeconds
    static let speechTaskRestartSeconds: Double = AppConfig.speechTaskRestartSeconds
    static let cryConfidenceThreshold:        Double  = AppConfig.cryConfidenceThreshold
    static let cryAnalysisInterval:           Int     = AppConfig.cryAnalysisInterval
    static let speechGateConfidenceThreshold: Double  = AppConfig.speechGateConfidenceThreshold
    static let speechGateHoldSeconds:         Double  = AppConfig.speechGateHoldSeconds
    static let silenceThreshold:        Float   = AppConfig.silenceThreshold
    static let silenceThresholdActive:  Float   = AppConfig.silenceThresholdActive
    static let silenceHoldBuffers:      Int     = AppConfig.silenceHoldBuffers
}

typealias AVAudioChannelCount = AVFoundation.AVAudioChannelCount
typealias AVAudioFrameCount   = AVFoundation.AVAudioFrameCount
