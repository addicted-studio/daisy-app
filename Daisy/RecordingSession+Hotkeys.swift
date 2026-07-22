//
//  RecordingSession+Hotkeys.swift
//  Daisy
//
//  Global-hotkey / widget entry points for the three recording
//  modes (meeting toggle, voice-note toggle, dictation
//  push-to-record). Pure code motion out of RecordingSession.swift —
//  the lifecycle itself (start/pause/resume/stop) stays in the main
//  file; these are the thin mode-aware wrappers around it.
//

import Foundation
import os

extension RecordingSession {
    // MARK: - Hotkey / mode entry points

    /// Convenience for global hotkey / widget tap: start if idle/
    /// finished/failed, pause if recording, resume if paused.
    /// Transitional states (preparing/stopping/summarizing) are
    /// ignored so a hammered hotkey can't interrupt in-flight work.
    /// Note: the hotkey/widget never *fully stops* a session — that
    /// requires the explicit Stop & save action from the popover or
    /// the widget's right-click menu.
    func toggleByHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            await start()
        case .recording:
            await pause()
        case .paused:
            await resume()
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    /// Voice-notes — TOGGLE on tap. Single press starts a
    /// `.voiceNote` session (mic only, no system audio, no LLM
    /// summary, kind = note); next press of the same hotkey
    /// stops it. Different from dictation (hold-to-talk) because
    /// voice notes can be longer than the user wants to keep a
    /// finger on the key — meeting yourself, dictating ideas
    /// over 5–10 min, etc.
    func toggleVoiceNoteByHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            pendingMode = .voiceNote
            // No folder hint: a voice note is now identified by
            // `daisy_kind: note`, not by living in the Notes folder, so it
            // defaults to Inbox like any capture and still lands in the
            // Notes tab (which filters by kind). Was `pendingFolderHint =
            // .notes`, which forced every note into the Notes folder.
            await start()
        case .recording, .paused:
            if currentMode == .voiceNote {
                await stop()
            } else if currentMode == .meeting {
                // Layer a side note over the live meeting instead of
                // refusing: mark a window now, close it on the next
                // press. Finalize splits it into its own Notes session
                // and cuts it from the meeting transcript.
                toggleSideNoteCapture()
            } else {
                ToastCenter.shared.show(
                    String(localized: "Daisy is already recording. Stop the current session first."),
                    style: .warning
                )
            }
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    /// Dictation — push-to-record. Called on hotkey-down edge.
    /// Starts a `.dictation` session (mic only, ephemeral, no
    /// History entry). On release, the transcript is copied to
    /// the clipboard and a toast prompts ⌘V. Wispr-Flow-lite.
    func startDictationHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            pendingMode = .dictation
            // Warm the selected fast dictation engine during the hold so
            // release→paste isn't blocked on a cold load.
            switch settings.dictationEngine {
            case .whisper:
                break
            case .parakeet:
                // First-ever use still pays a one-time ~600 MB download.
                Task { await ParakeetEngine.shared.ensureLoaded() }
            case .appleSpeech:
                if #available(macOS 26, *) {
                    let localeID = settings.dictationLocale.isEmpty
                        ? settings.defaultTranscriptionLocale
                        : settings.dictationLocale
                    if localeID != "auto", !localeID.isEmpty {
                        let locale = Locale(identifier: localeID)
                        // Ensures the OS model is installed (background
                        // download on first use); no in-app weight.
                        Task { await AppleSpeechEngine.ensureModelReady(locale: locale) }
                    }
                }
            }
            if settings.dictationUseNemotronLive {
                // Warm the streaming preview engine during the hold so the
                // first partials land within the first chunk (~0.6 s).
                Task { await NemotronLiveEngine.shared.ensureLoaded() }
            }
            await start()
        case .recording, .paused:
            ToastCenter.shared.show(
                String(localized: "Daisy is already recording. Stop the current session first."),
                style: .warning
            )
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    /// Dictation — release. Triggers the stop() path which, when
    /// `currentMode == .dictation`, copies the final transcript
    /// to the clipboard and deletes the session directory before
    /// returning to idle.
    func stopDictationHotkey() async {
        guard currentMode == .dictation else { return }
        guard status == .recording || status == .paused else { return }
        // End-to-end dictation latency: hotkey release → paste. `stop()`
        // runs the whole dictation branch inline (stopCapture → final
        // Whisper pass → DictationPaste.handle → cleanup), so wrapping
        // it measures exactly what the user feels. Same subsystem/
        // category as the finalizePostStop spans so Instruments and
        // `log show --signpost` line up in one lane.
        let signposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "PostStop")
        let releaseState = signposter.beginInterval("dictation_release_to_paste", id: signposter.makeSignpostID())
        let t_release = Date()
        await stop()
        signposter.endInterval("dictation_release_to_paste", releaseState)
        log.info("dictation release→paste: \(Int(Date().timeIntervalSince(t_release) * 1000), privacy: .public)ms")
    }
}
