//
//  DaisyAppDelegate.swift
//  Daisy
//
//  Lifecycle override: closing the main window does NOT quit the app.
//  Daisy keeps living in the menu bar (and as the floating petal widget
//  during a recording). The user explicitly quits via menu-bar item or
//  the floating-widget right-click menu.
//
//  Clicking the Dock icon while no windows are visible re-opens the
//  main window (standard reopen handling).
//

import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class DaisyAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Silence-prompt notification category needs to be on file
        // before the first time `SilenceMonitor` decides to fire
        // one. We also take over as the UN delegate so action taps
        // (Stop & save / Not yet) route through us into the
        // Foundation NotificationCenter bus — which the active
        // SilenceMonitor subscribes to.
        UNUserNotificationCenter.current().delegate = self
        SilencePromptNotification.register()
        // 1.0.5: calendar-driven lifecycle banners.
        AutoStartNotification.register()
        AutoStopNotification.register()
        // 1.0.7.9: Prompt-mode "record this call?" ask.
        AutoStartPromptNotification.register()

        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                self.applyWarmChrome(to: window)
            }
        }

        // SwiftUI's scene delegate keeps resetting
        // `presentationOptions` AFTER we set them — at unpredictable
        // points during the fullscreen transition. Single-shot
        // asyncAfter(N) is racy. Solution: a repeating Timer that
        // re-forces `autoHideMenuBar + autoHideToolbar` every 0.5s
        // for the first 5 seconds after entering fullscreen. By the
        // 5-second mark SwiftUI has finished its transition dance
        // and our flags stick.
        // Note on fullscreen + menubar: macOS 26 doesn't let
        // third-party apps tint the system menubar (NSMainMenu is
        // system-managed). Earlier attempts to force `.hideMenuBar`
        // / `.autoHideMenuBar` were silently reverted by SwiftUI's
        // scene delegate. We accept the native behaviour — system
        // menubar appears at the top of fullscreen with its own
        // material backdrop. Our cream `containerBackground` still
        // tints everything below it.
    }

    // MARK: - Chrome

    /// Minimum-viable chrome to make NSWindow wear our cream colour.
    /// Per macOS-dev agent audit, the previous extras
    /// (`titlebarSeparatorStyle = .none`, `toolbarStyle = .unified`,
    /// the recursive NSVisualEffectView walk) were no-ops in Tahoe
    /// — Liquid Glass uses a private `_NSGlassBackdropView`, not
    /// NSVisualEffectView, so traversal couldn't touch it.
    private func applyWarmChrome(to window: NSWindow) {
        window.backgroundColor = Self.warmCream
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }

    /// Cream window-background NSColor matching `daisyBgPrimary`.
    /// Dynamic by appearance so it tracks light/dark mode.
    private static let warmCream: NSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0x1C/255, green: 0x1A/255, blue: 0x17/255, alpha: 1)
            : NSColor(srgbRed: 0xFA/255, green: 0xF7/255, blue: 0xF0/255, alpha: 1)
    }

    // Keep the process alive after the last window closes — we still
    // have a menu-bar item and possibly the floating widget.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Guard Quit against an in-progress recording. If the user quits
    /// (⌘Q, menu, or the widget's "Quit Daisy") while capture is live,
    /// confirm first — and on confirm, finalize the session so the audio
    /// archive + transcript-so-far are saved before the process exits.
    /// Without this, `NSApp.terminate` kills the process immediately and
    /// the in-progress recording is lost.
    ///
    /// Note: this is the QUIT path only. Closing the main window does not
    /// reach here — Daisy keeps running in the menu bar / floating widget
    /// (see `applicationShouldTerminateAfterLastWindowClosed`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = RecordingSession.current,
              session.status == .recording || session.status == .paused else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Daisy is still recording"
        alert.informativeText =
            "Quit and save this recording? Daisy will finalize the audio and transcript captured so far."
        alert.addButton(withTitle: "Save & Quit")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")         // .alertSecondButtonReturn

        // Bring Daisy forward so the modal isn't lost behind other apps
        // (the user is likely in another window when they hit ⌘Q).
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        // Defer termination until the session has persisted the audio
        // archive + transcript.md. `stop()` writes those synchronously and
        // kicks the summary off detached; the summary won't finish before
        // we exit, but the recording is saved and re-summarizable from the
        // Library on next launch.
        Task { @MainActor in
            await session.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even when Daisy is the frontmost app — by
    /// default macOS suppresses banners for the active app, but the
    /// silence prompt is most useful exactly when the user is in
    /// some other window and hasn't noticed they're still recording.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Route the user's tap on Stop & save / Not yet into the
    /// Foundation NotificationCenter bus. SilenceMonitor on the
    /// active session listens there and runs the matching action.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        Task { @MainActor in
            switch actionID {
            case SilencePromptNotification.actionStop:
                NotificationCenter.default.post(
                    name: SilencePromptNotification.stopRequested, object: nil
                )
            case SilencePromptNotification.actionSnooze:
                NotificationCenter.default.post(
                    name: SilencePromptNotification.snoozeRequested, object: nil
                )
            case AutoStartNotification.actionStop:
                // User tapped "Stop & save" on the auto-start banner.
                // RecordingSession.subscribeToLifecycleNotifications
                // listens and routes to stop().
                NotificationCenter.default.post(
                    name: AutoStartNotification.stopRequested, object: nil
                )
            case AutoStartPromptNotification.actionRecord:
                // Prompt mode: user said yes — start the pending trigger.
                NotificationCenter.default.post(
                    name: AutoStartPromptNotification.recordRequested, object: nil
                )
            case AutoStartPromptNotification.actionIgnore:
                // Prompt mode: user said no — drop the pending trigger.
                NotificationCenter.default.post(
                    name: AutoStartPromptNotification.ignoreRequested, object: nil
                )
            default:
                // Tap on the banner body of a silence-prompt category —
                // treat as "Not yet" so the silence clock resets.
                // For other categories (auto-start tapped body, auto-
                // stop tapped body) we just dismiss; the broadcast
                // only fires when an explicit action button is hit.
                let cat = response.notification.request.content.categoryIdentifier
                if cat == SilencePromptNotification.categoryID {
                    NotificationCenter.default.post(
                        name: SilencePromptNotification.snoozeRequested, object: nil
                    )
                } else if cat == AutoStartPromptNotification.categoryID {
                    // Body tap on the "record this call?" banner with no
                    // explicit action — treat as Ignore so the pending
                    // trigger doesn't linger.
                    NotificationCenter.default.post(
                        name: AutoStartPromptNotification.ignoreRequested, object: nil
                    )
                }
            }
            completionHandler()
        }
    }

    // When the user clicks the Dock icon and no windows are visible,
    // bring the main window back. macOS calls this with
    // hasVisibleWindows == false in that case; returning `true` tells
    // AppKit to handle the default reopen (it'll restore the closed
    // Window scene).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Force activation policy back to .regular in case anything
            // demoted us, and ask AppKit to restore the main scene.
            NSApp.setActivationPolicy(.regular)

            // Fallback: surface any existing main-capable window if the
            // default reopen path didn't fire for some reason.
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }
}
