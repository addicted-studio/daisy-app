//
//  VoiceMemoFolder.swift
//  Daisy
//
//  Destination folder for imported Voice Memo transcripts — kept SEPARATE
//  from the meeting-sessions folder (`SessionsFolder`) so voice notes can
//  live in the user's notes area (e.g. an Obsidian "Notes" folder)
//  independent of where meeting sessions are stored (Egor, 2026-06-16).
//
//  Mirrors `SessionsFolder`'s security-scoped-bookmark pattern and reuses
//  its `AccessTicket`. Transcripts are written DIRECTLY into the chosen
//  folder (no extra subfolder) — the user picks exactly the folder they
//  want. Default when nothing is picked is a reliable, non-TCC-protected
//  `~/Library/Application Support/Daisy/Notes` fallback; the Settings UI
//  nudges the user to pick their vault's notes folder so they can find
//  the files.
//

import Foundation
import AppKit
import os

@MainActor
enum VoiceMemoFolder {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "VoiceMemos")
    private static let bookmarkKey = "daisy.voiceMemosFolderBookmark"

    // MARK: - Persistence

    @discardableResult
    static func setUserFolder(_ url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            log.info("Stored voice-memo folder bookmark for \(url.path, privacy: .private)")
            return true
        } catch {
            log.error("Voice-memo bookmark creation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func clearUserFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

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
            if isStale { _ = setUserFolder(url) }
            return url
        } catch {
            log.warning("Couldn't resolve voice-memo folder bookmark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static var hasUserFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// Reliable fallback when the user hasn't picked a folder. Inside the
    /// app's Application Support so background writes never hit TCC; hidden,
    /// so the UI pushes the user to pick a vault folder instead.
    static func defaultFolder() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Daisy/Notes", isDirectory: true)
    }

    // MARK: - Picker

    static func presentPicker(window: NSWindow? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for voice-memo transcripts"
        panel.message = "Imported Voice Memo transcripts (.md) are saved directly into this folder — pick your vault's notes folder."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return setUserFolder(url) ? url : nil
    }

    // MARK: - Base resolution

    /// The folder transcripts are written into. Caller MUST `release()` the
    /// returned ticket. Reuses `SessionsFolder.AccessTicket`.
    static func acquireBase() -> SessionsFolder.AccessTicket? {
        if let userURL = resolveUserFolder() {
            if userURL.startAccessingSecurityScopedResource() {
                return SessionsFolder.AccessTicket(url: userURL, securityScoped: true)
            }
            log.warning("Failed to start accessing voice-memo folder — using default")
        }
        return SessionsFolder.AccessTicket(url: defaultFolder(), securityScoped: false)
    }
}
