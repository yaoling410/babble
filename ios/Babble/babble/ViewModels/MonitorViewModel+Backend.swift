import AVFoundation
import Foundation
import os
import Speech

// ============================================================
//  MonitorViewModel+Backend.swift — Backend clip pipeline
// ============================================================
//
//  PIPELINE
//  --------
//  SFSpeechRecognizer (wake word) ──┐
//  SNAudioStreamAnalyzer (cry) ─────┼→ triggerCapture()
//  Manual button ───────────────────┘     │
//    → record clip (10s silence / 90s cap)
//    → TranscriptFilter (local, free)
//    → /diarize (pyannote on server)
//    → /analyze (Gemini on server)       ← or Foundation Models 3B if useOnDeviceAnalysis
//    → EventStore.apply()

extension MonitorViewModel {

    // MARK: - Backend start/stop

    func startBackendMonitoring() async {
        switch state {
        case .idle, .error: break
        case .listening:
            BabbleLog.app.warning("\(BabbleLog.ts) ⚠️ startMonitoring called while .listening — restarting")
            stopBackendMonitoring()
        default: return
        }

        guard await requestPermissions() else { return }

        do {
            audioCapture.wakeWordService = wakeWord
            audioCapture.cryDetector = cryDetector
            try wakeWord.start(babyName: profile.babyName, locales: profile.speechLocales, aliases: profile.nameAliases)
            try audioCapture.startListening()
            state = .listening
            BabbleLog.app.info("\(BabbleLog.ts) ✅ Monitoring started — listening for '\(self.profile.babyName, privacy: .public)'")
        } catch {
            BabbleLog.app.error("\(BabbleLog.ts) ❌ startMonitoring failed: \(error.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
        }
    }

    func stopBackendMonitoring() {
        wakeWord.stop()
        cryDetector.stop()
        audioCapture.stopListening()
        state = .idle
    }

    // MARK: - Manual recording

    func startManualRecording() {
        guard state == .listening else { return }
        manualAudioData = nil
        lastTriggerKind = "manual"
        state = .recording
        NSLog("[Babble] 🎙️ Manual recording started")
        audioCapture.onClipReady = { [weak self] data, time, transcript in
            Task { @MainActor in
                self?.handleManualClip(wavData: data, transcript: transcript)
            }
        }
        audioCapture.triggerCapture(at: Date(), transcriptSoFar: "")
    }

    func stopManualRecording(mode: String) async {
        NSLog("[Babble] 🛑 Manual recording stopped, mode=\(mode)")
        audioCapture.forceFlush()
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let audioData = manualAudioData else {
            BabbleLog.app.warning("\(BabbleLog.ts) ⚠️ No audio data captured for manual recording")
            wireServices()
            if state == .recording { state = .listening }
            return
        }
        await sendManualNote(audioData: audioData, mode: mode)
        wireServices()
    }

    func sendManualNote(audioData: Data, mode: String) async {
        state = .analyzing
        let dateStr = todayStr()
        do {
            let response = try await analysisService.sendVoiceNote(
                audioData: audioData,
                mode: mode,
                babyName: profile.babyName,
                ageMonths: profile.babyAgeMonths,
                dateStr: dateStr
            )
            if mode == "edit" {
                let analyzeResp = AnalyzeResponse(
                    newEvents: response.newEvents ?? [],
                    corrections: response.corrections ?? [],
                    correctionsApplied: nil,
                    usage: nil
                )
                eventStore.apply(response: analyzeResp, dateStr: dateStr)
            } else {
                replyText = response.reply
            }
        } catch {
            print("[MonitorVM] voice note failed: \(error)")
        }
        state = .listening
    }

    // MARK: - Clip handling

    func handleClip(wavData: Data, triggerTime: Date, rawTranscript: String) async {
        guard state == .capturing || state == .wakeDetected else {
            BabbleLog.capture.warning("\(BabbleLog.ts) ⚠️ Clip dropped — state=\(String(describing: self.state)) (expected .capturing or .wakeDetected)")
            return
        }
        state = .analyzing
        let dateStr = todayStr()

        // TranscriptFilter — local keyword check, free
        let wordCount = rawTranscript.split(separator: " ").count
        BabbleLog.filter.info("\(BabbleLog.ts) 🎤 Clip — trigger=\(self.lastTriggerKind, privacy: .public) words=\(wordCount, privacy: .public) active=\(self.isInActivePeriod ? "YES" : "NO", privacy: .public) transcript='\(rawTranscript.prefix(100), privacy: .public)'")
        let passes = TranscriptFilter.shouldAnalyze(
            transcript: rawTranscript,
            babyName: profile.babyName,
            triggerKind: lastTriggerKind,
            isActivePeriod: isInActivePeriod
        )
        guard passes else {
            BabbleLog.filter.info("\(BabbleLog.ts) 🚫 BLOCKED — not baby-related, skipping backend")
            state = .listening
            return
        }
        BabbleLog.filter.info("\(BabbleLog.ts) ✅ PASSED → diarize")

        // Route: on-device Foundation Models (free) or backend Gemini (paid)
        #if canImport(FoundationModels)
        if shouldUseOnDevice {
            await handleClipOnDevice(rawTranscript: rawTranscript, triggerTime: triggerTime, dateStr: dateStr, wavData: wavData)
        } else {
            await handleClipBackend(rawTranscript: rawTranscript, wavData: wavData, triggerTime: triggerTime, dateStr: dateStr)
        }
        #else
        await handleClipBackend(rawTranscript: rawTranscript, wavData: wavData, triggerTime: triggerTime, dateStr: dateStr)
        #endif

        state = .listening
    }

    // MARK: - Backend analysis (Gemini)

    private func handleClipBackend(
        rawTranscript: String, wavData: Data, triggerTime: Date, dateStr: String
    ) async {
        // Diarize — skip if no speakers enrolled
        let annotatedTranscript: String
        if speakerStore.speakers.isEmpty {
            BabbleLog.gemini.info("\(BabbleLog.ts) ⚡ No speakers enrolled — skipping diarize")
            annotatedTranscript = rawTranscript
        } else {
            do {
                let diarResult = try await analysisService.diarize(audioData: wavData, rawTranscript: rawTranscript)
                annotatedTranscript = diarResult.annotatedTranscript
                if !diarResult.segments.isEmpty {
                    let summary = diarResult.segments.map { "\($0.speakerLabel) (\(String(format: "%.1f", $0.start))–\(String(format: "%.1f", $0.end))s)" }.joined(separator: ", ")
                    BabbleLog.gemini.info("\(BabbleLog.ts) 🎙 Speakers: \(summary, privacy: .public)")
                }
                if !diarResult.unknownSpeakers.isEmpty {
                    BabbleLog.gemini.info("\(BabbleLog.ts) ❓ Unknown: \(diarResult.unknownSpeakers.map { $0.tempLabel }.joined(separator: ", "), privacy: .public)")
                }
            } catch {
                BabbleLog.app.error("\(BabbleLog.ts) Diarize failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // Gemini analysis with 10-min rolling context
        let transcriptContext = last10MinTranscript()
        do {
            let response = try await analysisService.analyze(
                transcript: annotatedTranscript,
                transcriptLast10min: transcriptContext,
                triggerHint: lastTriggerKind,
                babyName: profile.babyName,
                ageMonths: profile.babyAgeMonths,
                clipTimestamp: triggerTime,
                dateStr: dateStr
            )
            BabbleLog.gemini.info("\(BabbleLog.ts) ✅ Response — events=\(response.newEvents.count, privacy: .public) corrections=\(response.corrections.count, privacy: .public)")
            eventStore.apply(response: response, dateStr: dateStr)
        } catch {
            BabbleLog.app.error("\(BabbleLog.ts) ❌ Analysis failed: \(error.localizedDescription, privacy: .public)")
        }

        appendToTranscriptBuffer(text: annotatedTranscript)
        vault.store(audioData: wavData, triggerKind: lastTriggerKind, transcript: annotatedTranscript, capturedAt: triggerTime)
    }

    // MARK: - On-device analysis fallback (backend build, iOS 26+)

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func handleClipOnDevice(
        rawTranscript: String, triggerTime: Date, dateStr: String, wavData: Data
    ) async {
        BabbleLog.gemini.info("\(BabbleLog.ts) 🧠 On-device analysis — \(rawTranscript.split(separator: " ").count, privacy: .public) words")
        do {
            let response = try await onDevice.analyze(
                transcript: rawTranscript,
                babyName: profile.babyName,
                ageMonths: profile.babyAgeMonths,
                triggerHint: lastTriggerKind,
                clipTimestamp: triggerTime
            )
            BabbleLog.gemini.info("\(BabbleLog.ts) ✅ On-device — events=\(response.newEvents.count, privacy: .public) (free)")
            eventStore.apply(response: response, dateStr: dateStr)
        } catch {
            BabbleLog.app.error("\(BabbleLog.ts) ❌ On-device failed — falling back to backend")
            await handleClipBackend(rawTranscript: rawTranscript, wavData: wavData, triggerTime: triggerTime, dateStr: dateStr)
            return
        }
        appendToTranscriptBuffer(text: rawTranscript)
        vault.store(audioData: wavData, triggerKind: lastTriggerKind, transcript: rawTranscript, capturedAt: triggerTime)
    }
    #endif

    // MARK: - Backend wiring (callbacks)

    func wireServices() {
        audioCapture.onClipReady = { [weak self] data, time, transcript in
            Task { @MainActor in
                await self?.handleClip(wavData: data, triggerTime: time, rawTranscript: transcript)
            }
        }

        wakeWord.onWakeWordDetected = { [weak self] transcript in
            guard let self else { return }
            self.lastTriggerKind = "name"
            self.currentTranscript = transcript
            let newEnd = Date().addingTimeInterval(Constants.activePeriodSeconds)
            self.activePeriodEnd = newEnd
            self.audioCapture.activePeriodEnd = newEnd
            BabbleLog.active.info("\(BabbleLog.ts) 🔔 Wake word — active period set \(Int(Constants.activePeriodSeconds), privacy: .public)s")
            self.flashWakeDetected()
            self.audioCapture.triggerCapture(at: Date(), transcriptSoFar: transcript)
        }

        audioCapture.onSecondaryTrigger = { [weak self] transcript in
            guard let self else { return }
            self.lastTriggerKind = "name"
            self.flashWakeDetected()
            self.audioCapture.triggerCapture(at: Date(), transcriptSoFar: transcript)
        }

        cryDetector.onCryDetected = { [weak self] in
            guard let self else { return }
            self.lastTriggerKind = "cry"
            let seed = self.getCrySeed()
            self.flashWakeDetected()
            self.audioCapture.triggerCapture(at: Date(), transcriptSoFar: seed)
        }
    }

    func handleManualClip(wavData: Data, transcript: String) {
        manualAudioData = wavData
    }

    func flashWakeDetected() {
        state = .wakeDetected
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.state == .wakeDetected { self?.state = .capturing }
        }
    }
}
