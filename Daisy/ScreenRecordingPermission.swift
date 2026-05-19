//
//  ScreenRecordingPermission.swift
//  Daisy
//
//  Thin wrapper around macOS Screen Recording (TCC) permission for
//  ScreenCaptureKit. Daisy needs this granted to capture the "other
//  side" of meetings — the system audio stream coming out of Zoom /
//  Meet / Teams. Without it, SCStream.startCapture() throws and the
//  user silently gets a mic-only recording.
//
//  CGPreflightScreenCaptureAccess() does NOT trigger a system prompt
//  — that only fires on the first SCStream.startCapture() call. We
//  call it BEFORE starting capture so we can show a clear toast +
//  Settings deeplink instead of letting the user start a 60-minute
//  meeting that quietly records only their voice.
//

import Foundation
import CoreGraphics
import AppKit

@MainActor
enum ScreenRecordingPermission {
    /// True if Screen Recording access has already been granted via
    /// the TCC database. No system prompt is shown — this is a pure
    /// inspection call.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Open System Settings → Privacy & Security → Screen Recording.
    /// The URL is documented as the canonical anchor; on macOS 14+
    /// it lands on the exact pane, on older versions it falls back
    /// to the general Privacy & Security tab.
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
