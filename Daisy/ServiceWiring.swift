//
//  ServiceWiring.swift
//  Daisy
//
//  Single source of truth for wiring shared services (HotkeyManager,
//  MeetingDetector, CalendarService) to the current `RecordingSession`
//  and `AppSettings`. Called from two places:
//
//   1. `DaisyApp.init` — initial wiring at launch, so hotkeys + auto-
//      start work before the user opens the window.
//   2. `MainView` `.onChange` handlers — re-applied when the user flips
//      the relevant setting.
//
//  Centralising here prevents the two wiring sites from drifting apart
//  as services are added or their handler signatures change.
//

import Foundation

@MainActor
enum ServiceWiring {

    /// Backward-compat single-slot wiring of the meeting hotkey.
    /// Kept so legacy call sites compile; new code should call
    /// `applyAllHotkeys(settings:session:)` to wire all three slots.
    static func applyHotkey(choice: HotkeyChoice, session: RecordingSession) {
        HotkeyManager.shared.register(
            slot: .record,
            choice: choice,
            action: .toggle { [weak session] in
                Task { await session?.toggleByHotkey() }
            }
        )
    }

    /// Register meeting + voice-notes + dictation hotkeys from
    /// settings. Idempotent — calling again rewires all three
    /// slots from current settings.
    ///
    /// Modes:
    ///   - **Meeting** + **Voice notes** use `.toggle` (press
    ///     once to start, press again to stop). Zero permission
    ///     for Meeting (Carbon RegisterEventHotKey); Voice notes
    ///     needs Input Monitoring only if bound to Fn / globe.
    ///   - **Dictation** uses `.hold` (push-to-talk). Wispr Flow
    ///     parity: hold the key while speaking, release to drop
    ///     the transcript on the clipboard. Requires Input
    ///     Monitoring permission regardless of which key is bound.
    static func applyAllHotkeys(settings: AppSettings, session: RecordingSession) {
        HotkeyManager.shared.register(
            slot: .record,
            choice: settings.recordHotkey,
            action: .toggle { [weak session] in
                Task { await session?.toggleByHotkey() }
            }
        )
        HotkeyManager.shared.register(
            slot: .voiceNote,
            choice: settings.voiceNoteHotkey,
            action: .toggle { [weak session] in
                Task { await session?.toggleVoiceNoteByHotkey() }
            }
        )
        HotkeyManager.shared.register(
            slot: .dictation,
            choice: settings.dictationHotkey,
            action: .hold(
                onPress: { [weak session] in
                    Task { await session?.startDictationHotkey() }
                },
                onRelease: { [weak session] in
                    Task { await session?.stopDictationHotkey() }
                }
            )
        )
    }

    /// Enable or disable foreground-app meeting auto-detection
    /// (NSWorkspace-based — fires when Zoom / Teams / Meet etc. is
    /// launched). `enabled` is the derived `settings.autoStartOnMeeting`
    /// substrate flag (ON for Always / Prompt, OFF for Selective /
    /// Manual). The detector debounces by `recordingDetectionDelaySec`,
    /// and when `autoStartPromptMode` is on it asks before recording
    /// instead of starting directly.
    ///
    /// We deliberately do NOT call `session.start()` when a session
    /// is already recording or paused. Previously the call slipped
    /// through to `start()` and silently returned via its guard,
    /// leaving the user confused why a brand-new meeting app launch
    /// did nothing visible. Now we surface a toast so the user can
    /// stop the previous session intentionally if they want a fresh
    /// recording for the newly-launched app.
    ///
    /// Unlike the calendar path (`startFromMeeting`) we cannot auto-
    /// rotate here — NSWorkspace's notification gives us the app
    /// bundle ID, not a `DaisyMeeting`, so we have no idea if it's
    /// a "different" meeting from what's already being recorded.
    /// Surfacing rather than acting is the right move.
    static func applyMeetingAutoStart(settings: AppSettings, session: RecordingSession) {
        guard settings.autoStartOnMeeting else {
            MeetingDetector.shared.stop()
            return
        }
        let promptMode = settings.autoStartPromptMode
        MeetingDetector.shared.start(
            detectionDelaySec: settings.recordingDetectionDelaySec
        ) { [weak session] bundleID in
            Task { @MainActor in
                guard let session else { return }
                let appName = MeetingDetector.displayName(for: bundleID)
                if promptMode {
                    // Prompt policy: ask before recording (handles the
                    // already-recording case internally with a toast).
                    session.promptToStartFromAppLaunch(appName: appName)
                    return
                }
                if session.status == .recording || session.status == .paused {
                    ToastCenter.shared.show(
                        "\(appName) launched while Daisy is already recording — stop the current session first if you want a fresh one.",
                        style: .info
                    )
                    return
                }
                await session.start()
            }
        }
    }

    /// Configure CalendarService for the current permission +
    /// auto-start preference. Called both on app launch and whenever
    /// `autoStartFromCalendar` or `calendarAccessGranted` flips.
    ///
    /// Behaviour:
    ///   • No permission → stop the service.
    ///   • Permission granted → start (idempotent), passing the
    ///     auto-start preference and a meeting-start handler.
    ///   • Both branches above keep `upcomingMeetings` cache warm
    ///     for the Home view even when auto-start is off — the user
    ///     still wants to see what's coming.
    static func applyCalendar(settings: AppSettings, session: RecordingSession) {
        // CalendarService now multiplexes EventKit + Google OAuth.
        // Start the service if EITHER source is available — a
        // user might only have Google connected (no Internet
        // Accounts integration) and still want auto-start.
        let hasEventKit = settings.calendarAccessGranted
        let hasGoogle = GoogleAccountStore.shared.isConnected
        guard hasEventKit || hasGoogle else {
            CalendarService.shared.stop()
            return
        }
        CalendarService.shared.start(
            lookaheadHours: 24,
            autoStartOnMeeting: settings.autoStartFromCalendar
        ) { [weak session] meeting in
            Task { await session?.startFromMeeting(meeting) }
        }
    }

    /// Start or stop the local MCP server based on the user's
    /// preference. Loopback-only; opt-in. Idempotent.
    static func applyMCPServer(settings: AppSettings) {
        if settings.mcpServerEnabled {
            MCPServer.shared.start(port: settings.mcpServerPort)
        } else {
            MCPServer.shared.stop()
        }
    }

    /// Convenience for full initial wiring at launch.
    static func applyAll(settings: AppSettings, session: RecordingSession) {
        applyAllHotkeys(settings: settings, session: session)
        applyMeetingAutoStart(settings: settings, session: session)
        applyCalendar(settings: settings, session: session)
        applyMCPServer(settings: settings)
    }
}
