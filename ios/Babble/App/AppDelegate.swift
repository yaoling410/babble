import UIKit
import AVFoundation

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAudioSession()
        return true
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .measurement mode disables automatic gain control and noise reduction
            // so audio reaches Gemini / RNNoise unprocessed.
            // .allowBluetooth lets the app use BT microphones.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetooth, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            print("[AppDelegate] AVAudioSession setup failed: \(error)")
        }

        // Re-configure after interruptions (e.g. phone call ends)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionEnd),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
    }

    @objc private func handleInterruptionEnd(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .ended {
            let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }
                .map { $0.contains(.shouldResume) } ?? false

            if shouldResume {
                try? AVAudioSession.sharedInstance().setActive(true)
                NotificationCenter.default.post(name: .audioSessionResumed, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let audioSessionResumed = Notification.Name("audioSessionResumed")
}
