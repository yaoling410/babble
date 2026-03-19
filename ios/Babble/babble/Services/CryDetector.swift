import AVFoundation
import SoundAnalysis

/// Detects infant crying using Apple's SoundAnalysis framework.
/// Fires `onCryDetected` when confidence exceeds the threshold.
final class CryDetector: NSObject {
    var onCryDetected: (() -> Void)?

    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private var observerToken: SNClassificationResultsObserving?
    private let analysisQueue = DispatchQueue(label: "com.babble.crydetector")
    private var lastTriggerTime: Date = .distantPast

    func start(format: AVAudioFormat) throws {
        streamAnalyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let observer = CryObserver(threshold: Constants.cryConfidenceThreshold) { [weak self] in
            self?.handleCry()
        }
        self.observerToken = observer
        try streamAnalyzer?.add(request, withObserver: observer)
    }

    func stop() {
        streamAnalyzer = nil
        observerToken = nil
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        analysisQueue.async { [weak self] in
            guard let analyzer = self?.streamAnalyzer else { return }
            analyzer.analyze(buffer, atAudioFramePosition: buffer.frameLength)
        }
    }

    private func handleCry() {
        guard Date().timeIntervalSince(lastTriggerTime) > Constants.triggerCooldownSeconds else { return }
        lastTriggerTime = Date()
        DispatchQueue.main.async { [weak self] in
            self?.onCryDetected?()
        }
    }
}

// MARK: - Observer

private final class CryObserver: NSObject, SNResultsObserving {
    private let threshold: Double
    private let onDetected: () -> Void

    init(threshold: Double, onDetected: @escaping () -> Void) {
        self.threshold = threshold
        self.onDetected = onDetected
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }
        // Apple's identifier for infant crying
        let identifiers = ["infant_cry", "baby_cry", "crying"]
        for id in identifiers {
            if let observation = classificationResult.classification(forIdentifier: id),
               observation.confidence >= threshold {
                onDetected()
                return
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        print("[CryDetector] SoundAnalysis error: \(error)")
    }
}
