//
//  SessionsFolder.swift
//  Daisy
//
//  Resolves the user's chosen folder for storing meeting sessions
//  (audio archives, transcript markdown, summary JSON, screenshots)
//  via a security-scoped bookmark. Sandbox-friendly: we hold the
//  bookmark Data in UserDefaults and resolve it to a URL on demand;
//  callers MUST pair `startAccessingSecurityScopedResource()` with a
//  matching `stop` when they're done touching files.
//
//  Default behaviour (no folder picked): sessions live inside the
//  app's container at `~/Library/Containers/.../Application Support/
//  Daisy/Sessions/`. Picking a folder reroutes new sessions there
//  (think Obsidian vault). Existing sessions stay where they were —
//  SessionStore reads from both locations so History continues to
//  list them.
//

import Foundation
import AppKit
import os

@MainActor
enum SessionsFolder {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "SessionsFolder")
    private static let bookmarkKey = "daisy.sessionsFolderBookmark"

    /// Path displayed in Settings when no folder is picked.
    static let defaultContainerLabel = String(localized: "Inside Daisy's container (default)")

    // MARK: - Persistence

    /// Store a security-scoped bookmark for the user's chosen folder.
    /// Caller has just received `url` from NSOpenPanel — we encode
    /// + persist. Returns false if bookmark creation failed (rare —
    /// usually means the URL isn't actually file-scoped).
    @discardableResult
    static func setUserFolder(_ url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            log.info("Stored sessions folder bookmark for \(url.path, privacy: .private)")
            return true
        } catch {
            log.error("Bookmark creation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Drop the stored bookmark — new sessions revert to the
    /// default container location until the user picks again.
    static func clearUserFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        log.info("Cleared sessions folder bookmark")
    }

    /// Resolve the stored bookmark to a URL. Returns nil if no
    /// bookmark stored, the bookmark resolved to an invalid path,
    /// or the volume is unmounted. If the bookmark is stale (folder
    /// moved within the same volume) we transparently refresh it.
    ///
    /// IMPORTANT: the returned URL is NOT yet accessible — callers
    /// MUST `startAccessingSecurityScopedResource()` before any file
    /// I/O, and match with a `stop` when done.
    static func resolveUserFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                log.info("Bookmark stale, refreshing for \(url.path, privacy: .private)")
                _ = setUserFolder(url)
            }
            return url
        } catch {
            log.warning("Couldn't resolve sessions folder bookmark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Display path for Settings UI. Returns nil when nothing is
    /// stored (caller shows `defaultContainerLabel` instead).
    static func userFolderDisplayPath() -> String? {
        resolveUserFolder()?.path
    }

    /// Whether a user folder is currently configured (regardless of
    /// whether it resolves right now — UI uses this to decide
    /// "Reset to default" vs "Choose folder".)
    static var hasUserFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    // MARK: - Picker

    /// Open the system folder picker, store the result as a
    /// security-scoped bookmark, and return the URL. Sync API —
    /// blocks while the panel is up, returns when the user picks
    /// (or cancels → nil).
    static func presentPicker(window: NSWindow? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder for Daisy sessions")
        panel.message = String(localized: "Audio, transcripts, summaries and screenshots will be saved into a `Daisy/Sessions/` subfolder here.")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return setUserFolder(url) ? url : nil
    }

    // MARK: - Base resolution

    /// Resolve the base URL where a new session directory should be
    /// created. Returns either the user-picked folder (security-scope
    /// acquired) or the default container location. Caller MUST call
    /// `release` on the returned ticket when done so we stop holding
    /// the security scope.
    static func acquireBase() -> AccessTicket? {
        if let userURL = resolveUserFolder() {
            let acquired = userURL.startAccessingSecurityScopedResource()
            if acquired {
                return AccessTicket(url: userURL, securityScoped: true)
            }
            log.warning("Failed to start accessing user folder — falling back to default")
        }
        // Default: inside the app container's Application Support.
        if let defaultURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return AccessTicket(url: defaultURL, securityScoped: false)
        }
        return nil
    }

    /// Default base URL used by SessionStore even when no user
    /// folder is set — points at the app's Application Support dir.
    /// Returns nil only if Foundation can't resolve it (essentially
    /// never on macOS).
    static func defaultBase() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// One-shot access ticket. Holds onto the URL and releases the
    /// security scope when discarded. Lifetime tied to the recording
    /// session for RecordingSession, or to a scan loop for SessionStore.
    final class AccessTicket {
        let url: URL
        private let securityScoped: Bool
        private var released = false

        init(url: URL, securityScoped: Bool) {
            self.url = url
            self.securityScoped = securityScoped
        }

        func release() {
            guard !released else { return }
            released = true
            if securityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        deinit {
            if !released, securityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}
