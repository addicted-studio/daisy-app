//
//  VersionInfo.swift
//  Daisy
//
//  Tiny shared helper for "what version is this app + put it on the
//  clipboard". Used by the click-to-copy affordance on the sidebar
//  version pill (MainView) and the About header version line
//  (AboutView). Pre-1.0.7.3 both sites had inlined identical copies
//  of the implementation; lifted out here so a future change (e.g.
//  add a debug-build flag to the copied string) lands once.
//

import AppKit
import Foundation

@MainActor
enum VersionInfo {

    /// "1.0.7.3" — the marketing version shown in tight UI like the
    /// sidebar footer pill.
    static var marketingVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// "30" — the build number Sparkle uses to compare appcast
    /// entries. This is the authoritative "what binary is running"
    /// identifier; marketingVersion alone can ship across multiple
    /// builds (e.g. a re-signed bundle).
    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    /// "Daisy 1.0.7.3 (30)" — the format we paste to clipboard for
    /// support pastes. App name prefix removes context ambiguity
    /// once the string lands in someone else's Slack / inbox; build
    /// number disambiguates re-signed or hotfixed binaries.
    static var supportPayload: String {
        "Daisy \(marketingVersion) (\(buildNumber))"
    }

    /// Copy the support payload to clipboard and show a toast
    /// confirmation. Wired to the sidebar version pill tap handler
    /// in MainView and the About header version line in AboutView.
    static func copyToClipboardWithToast() {
        let payload = supportPayload
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload, forType: .string)
        ToastCenter.shared.show(String(localized: "Copied \(payload)"), style: .success)
    }
}
