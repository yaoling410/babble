import AVFoundation
import Speech
import Combine

/// Continuously streams audio through SFSpeechRecognizer to detect the baby's name.
/// Automatically restarts the recognition task every ~55 seconds (tasks expire at ~60s).
final class WakeWordService {
    var babyName: String = ""   // lowercased comparison
    var onWakeWordDetected: ((String) -> Void)?  // passes partial transcript

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var isRunning: Bool = false
    private var lastPartialTranscript: String = ""

    // MARK: - Public

    func start(babyName: String) throws {
        self.babyName = babyName.lowercased()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw WakeWordError.notAuthorized
        }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        isRunning = true
        startTask()
        scheduleRestart()
    }

    func stop() {
        isRunning = false
        restartTimer?.invalidate()
        restartTimer = nil
        cancelTask()
    }

    /// Feed audio from AudioCaptureService's tap.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    // MARK: - Task lifecycle

    private func startTask() {
        cancelTask()
        guard isRunning, let recognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false  // allow cloud for better accuracy
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let transcript = result.bestTranscription.formattedString
                self.lastPartialTranscript = transcript
                self.checkForWakeWord(in: transcript)
            }

            if error != nil || (result?.isFinal == true) {
                // Task ended — restart if still running
                if self.isRunning {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.startTask()
                    }
                }
            }
        }
    }

    private func cancelTask() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        lastPartialTranscript = ""
    }

    private func scheduleRestart() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.speechTaskRestartSeconds,
            repeats: true
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.startTask()
        }
    }

    // MARK: - Wake word check

    private var lastTriggerTime: Date = .distantPast

    private func checkForWakeWord(in transcript: String) {
        let lower = transcript.lowercased()
        guard lower.contains(babyName),
              Date().timeIntervalSince(lastTriggerTime) > Constants.triggerCooldownSeconds
        else { return }

        lastTriggerTime = Date()
        let capturedTranscript = lastPartialTranscript
        DispatchQueue.main.async { [weak self] in
            self?.onWakeWordDetected?(capturedTranscript)
        }
    }

    // MARK: - Authorization helper

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

enum WakeWordError: Error {
    case notAuthorized
}
