//
//  SparkleUpdater.swift
//  Daisy
//
//  Thin wrapper over Sparkle 2.x's SPUStandardUpdaterController. Owns
//  the singleton lifetime, exposes a SwiftUI-friendly API for the
//  "Check for Updates…" menu command and the Settings toggle, and
//  gates everything on `#if canImport(Sparkle)` so the project keeps
//  building during the brief window between this file landing in the
//  repo and the SPM dependency being added in Xcode.
//
//  Once Sparkle is added (Xcode → File → Add Package Dependencies →
//  https://github.com/sparkle-project/Sparkle, version "Up to Next
//  Major" from 2.6), the `canImport` evaluates to true and the real
//  implementation kicks in.
//
//  Configuration lives in build settings (because the project uses
//  GENERATE_INFOPLIST_FILE = YES — no physical Info.plist). The user
//  must add four custom `INFOPLIST_KEY_*` entries to the target's
//  Build Settings:
//
//    INFOPLIST_KEY_SUFeedURL          = https://mydaisy.io/appcast.xml
//    INFOPLIST_KEY_SUPublicEDKey      = <public EdDSA key, base64>
//    INFOPLIST_KEY_SUEnableAutomaticChecks = YES
//    INFOPLIST_KEY_SUEnableInstallerLauncherService = YES
//
//  The EdDSA key pair is generated once via Sparkle's `generate_keys`
//  CLI tool — private key goes into the local Keychain on the build
//  machine, public key into SUPublicEDKey above. Each future release
//  is signed with the private key via `sign_update` and the resulting
//  signature is embedded in `appcast.xml`.
//

import Foundation
import SwiftUI

#if canImport(Sparkle)
import Sparkle

/// SwiftUI-observable wrapper around Sparkle's updater controller.
/// The controller itself is an NSObject and lives for the lifetime of
/// the app — Sparkle's design assumes a single long-lived instance per
/// process, which is what `static let shared` gives us.
///
/// `@MainActor` because every Sparkle API that mutates updater state
/// (manual check, toggle automatic checks, fetch lastUpdateCheckDate)
/// must be called from the main thread per Sparkle's documentation.
@MainActor
@Observable
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController
    /// Strong reference — `SPUUpdater` holds its delegate weakly.
    private let channelDelegate = DaisyUpdaterDelegate()

    /// Update-channel opt-in. `false` (default) = stable releases only —
    /// appcast items without a `<sparkle:channel>` tag. `true` = also
    /// receive "beta"-channel builds (newest features, less soak time).
    /// Sparkle asks the delegate for allowed channels on EVERY check, so
    /// flipping this applies to the very next check — no restart needed.
    /// Stored straight in UserDefaults ("daisy.updates.betaChannel") so
    /// the nonisolated delegate can read it off-main without actor hops.
    var receiveBetaUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "daisy.updates.betaChannel") }
        set { UserDefaults.standard.set(newValue, forKey: "daisy.updates.betaChannel") }
    }

    /// Mirrored from `updater.automaticallyChecksForUpdates` so SwiftUI
    /// can observe the toggle and re-render the Settings row when
    /// Sparkle's preference changes externally (e.g., the user dismisses
    /// a prompt that flipped it). Two-way sync via the computed setter.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Whether a "Check for Updates" call can fire right now. Sparkle
    /// disables the menu item while an existing check is in flight, on
    /// the rationale that a second manual probe during a download would
    /// produce confusing UI. The Settings row reads this to grey out
    /// the explicit Check button.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// Last-checked timestamp surfaced in Settings ("Last checked: 2h
    /// ago"). Sparkle persists this in user defaults across launches.
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: channelDelegate,
            userDriverDelegate: nil
        )
    }

    /// Manual "Check for Updates…" — fired from the menu command + the
    /// Settings button. Sparkle shows its own UI: progress sheet during
    /// the check, then either "You're up to date" or the
    /// update-available prompt with release notes + Install / Skip /
    /// Remind Me Later.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Scopes Daisy's updater to Sparkle channels (2026-06-08). Stable =
/// appcast items with no `<sparkle:channel>` tag — every client sees
/// those. Beta = items tagged `<sparkle:channel>beta</sparkle:channel>`,
/// served only when the user opted in via About → "Get beta updates".
/// The UserDefaults key string is duplicated from
/// `SparkleUpdater.receiveBetaUpdates` on purpose: Sparkle may call the
/// delegate off the main thread, and reading a plain defaults bool from
/// a `nonisolated` method avoids any actor hop.
private final class DaisyUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: "daisy.updates.betaChannel") ? ["beta"] : []
    }
}

#else

// MARK: - Stub fallback when Sparkle isn't linked yet.
//
// Lets the rest of the codebase reference SparkleUpdater.shared without
// `#if` blocks at every call site. The stub disables itself everywhere
// so the absence of the framework is visible in UI (greyed buttons, no
// last-check timestamp) but never crashes.

@MainActor
@Observable
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    var automaticallyChecksForUpdates: Bool = false
    var receiveBetaUpdates: Bool = false
    let canCheckForUpdates: Bool = false
    let lastUpdateCheckDate: Date? = nil

    private init() {}

    func checkForUpdates() {
        // Intentionally empty — the menu item / settings button stays
        // disabled via `canCheckForUpdates == false` until Sparkle is
        // added as an SPM dependency.
    }
}

#endif
