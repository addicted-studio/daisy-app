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

@MainActor
final class DaisyAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

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
