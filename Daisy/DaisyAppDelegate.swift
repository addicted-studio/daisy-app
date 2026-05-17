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
        // Explicit belt-and-braces: ensure we have a Dock icon and
        // Cmd+Tab presence even if SwiftUI's scene inference glitched.
        NSApp.setActivationPolicy(.regular)

        // Tint the main NSWindow's background to warm cream and make
        // the title bar transparent so it picks up the window
        // background instead of system white. This is the AppKit
        // path that SwiftUI's `.containerBackground(_:for: .window)`
        // doesn't reach on macOS 26 — `containerBackground` colors
        // the content view but the title bar zone remains painted
        // by NSTitlebarContainerView's default material until you
        // flip these NSWindow flags.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.backgroundColor = Self.warmCream
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
            }
        }
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
