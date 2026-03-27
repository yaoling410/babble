import UIKit
import AVFoundation

// ============================================================
//  AppDelegate.swift — Audio session setup and interruption handling
// ============================================================
//
//  WHERE IT FITS
//  -------------
//  BabbleApp.swift registers this via @UIApplicationDelegateAdaptor.
//  SwiftUI calls didFinishLaunchingWithOptions during the launch
//  sequence — after BabbleApp.init() but before the first view body.
//
//  RESPONSIBILITIES
//  ----------------
//  1. Configure AVAudioSession for background recording:
//     - Category: .playAndRecord (mic + speaker simultaneously)
//     - Options: .allowBluetooth (AirPods), .defaultToSpeaker,
//       .mixWithOthers (don't interrupt music/podcasts)
//
//  2. Handle audio interruptions (phone calls, Siri, FaceTime):
//     - .began → post .audioSessionInterrupted → MonitorViewModel stops
//     - .ended → post .audioSessionResumed → MonitorViewModel restarts
//
//  3. Start LogFileWriter — mirrors os.Logger to a file for debugging
//     without Xcode (see LogFileWriter.swift).
//
//  WHY NOT IN BABBLEAPP.INIT()?
//  -----------------------------
//  AVAudioSession must be configured BEFORE AVAudioEngine.start().
//  UIApplicationDelegate.didFinishLaunchingWithOptions runs before
//  any SwiftUI view body, guaranteeing correct ordering.

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAudioSession()
        Task { @MainActor in LogFileWriter.shared.start() }
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
                options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
            )
            try session.setActive(true)
        } catch {
            print("[AppDelegate] AVAudioSession setup failed: \(error)")
        }

        // Handle interruptions (phone calls, Siri, other apps taking audio session)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            // Phone call / Siri / other app took the audio session.
            // AVAudioEngine has already stopped — notify MonitorViewModel to
            // clean up state so it can restart cleanly when the session returns.
            NotificationCenter.default.post(name: .audioSessionInterrupted, object: nil)

        case .ended:
            let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }
                .map { $0.contains(.shouldResume) } ?? true  // default true: always try to resume

            if shouldResume {
                try? AVAudioSession.sharedInstance().setActive(true)
                NotificationCenter.default.post(name: .audioSessionResumed, object: nil)
            }

        @unknown default:
            break
        }
    }
}

extension Notification.Name {
    static let audioSessionResumed     = Notification.Name("audioSessionResumed")
    static let audioSessionInterrupted = Notification.Name("audioSessionInterrupted")
}
