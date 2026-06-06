//
//  MeetingDetector.swift
//  Daisy
//
//  Watches NSWorkspace for known meeting apps launching and fires a
//  callback so RecordingSession can auto-start. v0.1 limitation:
//  browser-based meetings (Google Meet in Chrome / Safari) aren't
//  detectable this way — bundle id stays "com.google.Chrome"
//  regardless of the tab. EventKit / Calendar integration (Phase 7)
//  will cover that case by reacting to scheduled meeting events
//  rather than process launches.
//
//  Only NEW launches during Daisy's lifetime trigger auto-start: if
//  Zoom is already running when Daisy starts we DON'T auto-start (the
//  user is treated as already in a meeting they didn't ask to record).
//  NSWorkspace's didLaunchApplicationNotification gives us that for
//  free — it only fires for launches after the observer is installed.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class MeetingDetector {
    static let shared = MeetingDetector()

    /// Bundle identifiers of apps we consider "a meeting is happening"
    /// when they launch. Conservative list — better to miss a niche
    /// app than to auto-record someone's FaceTime to grandma.
    nonisolated static let knownMeetingBundleIDs: Set<String> = [
        "us.zoom.xos",                        // Zoom
        "com.microsoft.teams2",               // Microsoft Teams (modern)
        "com.microsoft.teams",                // Microsoft Teams (legacy)
        "com.webex.meetingmanager",           // Webex
        "com.cisco.webexmeetingsapp",         // Webex Meetings
        "com.logmein.GoToMeeting",            // GoToMeeting
        "com.bluejeansnet.BlueJeans",         // BlueJeans
        "com.skype.skype",                    // Skype
        "ru.keepcoder.Telegram",              // Telegram macOS (calls)
        "org.telegram.desktop",               // Telegram Desktop alt id
        "com.hnc.Discord",                    // Discord
    ]

    /// Last detected bundle id, for UI display ("Auto-started: Zoom").
    var lastDetected: String? = nil

    private var observer: NSObjectProtocol?
    private var onMeetingStart: ((String) -> Void)?

    private init() {}

    /// Begin watching for meeting-app launches. Replaces any existing
    /// observer. Fires the callback immediately when a known meeting app
    /// launches — no debounce (the old user-tunable "detection delay" was
    /// removed in 1.0.7.16; a rare false start is undone via the
    /// "Recording started · Stop & save" banner). Only NEW launches during
    /// Daisy's lifetime trigger it — `didLaunchApplicationNotification`
    /// never fires for apps already running when the observer is installed.
    func start(onMeetingStart: @escaping (String) -> Void) {
        stop()
        self.onMeetingStart = onMeetingStart
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let info = note.userInfo,
                let app = info[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier,
                Self.knownMeetingBundleIDs.contains(bundleID)
            else { return }
            // Hop onto the main actor — observer fires on the main
            // queue but the closure capture context isn't isolated.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastDetected = bundleID
                self.onMeetingStart?(bundleID)
            }
        }
    }

    /// Stop observing. Safe to call multiple times.
    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        onMeetingStart = nil
    }

    /// Pretty name for a known bundle id, for UI display.
    nonisolated static func displayName(for bundleID: String) -> String {
        switch bundleID {
        case "us.zoom.xos":                                    return "Zoom"
        case "com.microsoft.teams2", "com.microsoft.teams":    return "Microsoft Teams"
        case "com.webex.meetingmanager",
             "com.cisco.webexmeetingsapp":                     return "Webex"
        case "com.logmein.GoToMeeting":                        return "GoToMeeting"
        case "com.bluejeansnet.BlueJeans":                     return "BlueJeans"
        case "com.skype.skype":                                return "Skype"
        case "ru.keepcoder.Telegram",
             "org.telegram.desktop":                           return "Telegram"
        case "com.hnc.Discord":                                return "Discord"
        default:                                               return bundleID
        }
    }
}
