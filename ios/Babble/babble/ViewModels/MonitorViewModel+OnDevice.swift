import Combine
import Foundation

// ============================================================
//  MonitorViewModel+OnDevice.swift — On-device pipeline delegation
// ============================================================
//
//  PIPELINE (BABBLE_ON_DEVICE build only)
//  -------
//  AVAudioEngine → WhisperKit (continuous, VAD-gated windows)
//    → RelevanceGate (is this about the baby?)
//    → SpeakerKit (on-device diarization + speaker ID)
//    → Foundation Models 3B (event extraction)
//    → EventStore.apply()
//
//  No wake word. No clips. No backend calls.
//  CryDetector fires independently → direct event creation.
//  Auto-completion timer closes stale in_progress events.
//
//  MonitorViewModel just mirrors OnDevicePipeline.state for the UI
//  and delegates start/stop. All logic lives in OnDevicePipeline.

#if BABBLE_ON_DEVICE
extension MonitorViewModel {

    // MARK: - Pipeline setup

    /// Creates OnDevicePipeline, injects dependencies, and bridges its state
    /// to MonitorViewModel.State so the UI layer doesn't need to know which
    /// pipeline is active.
    func setupOnDevicePipeline() {
        if #available(iOS 26.0, *) {
            let pipeline = OnDevicePipeline()
            pipeline.profile = profile
            pipeline.eventStore = eventStore
            pipeline.speakerStore = speakerStore
            pipeline.audioCapture = audioCapture
            pipeline.cryDetector = cryDetector
            self.onDevicePipeline = pipeline

            // Map OnDevicePipeline.State → MonitorViewModel.State
            // .idle → .idle
            // .listening → .listening (WhisperKit streaming)
            // .processing → .analyzing (analyzing a relevant window)
            // .error → .error
            pipeline.$state
                .receive(on: RunLoop.main)
                .sink { [weak self] s in
                    switch s {
                    case .idle:            self?.state = .idle
                    case .listening:       self?.state = .listening
                    case .processing:     self?.state = .analyzing
                    case .error(let msg): self?.state = .error(msg)
                    }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Start / Stop

    func startOnDeviceMonitoring() async {
        if #available(iOS 26.0, *) {
            await onDevicePipeline?.start()
        }
    }

    func stopOnDeviceMonitoring() {
        if #available(iOS 26.0, *) {
            onDevicePipeline?.stop()
            state = .idle
        }
    }
}
#endif
