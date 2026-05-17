//
//  UserDefaultsMigration.swift
//  Daisy
//
//  One-shot migration of `hola.*` UserDefaults keys to `daisy.*`.
//
//  Background: a handful of preference keys carried `hola.*` prefixes
//  from a previous internal codename. Renaming them in source without
//  migrating would silently reset every existing install (the new key
//  doesn't exist yet, so AppSettings falls back to defaults).
//
//  Strategy: copy the old value to the new key on first launch after
//  the rename, then remove the old key. Guarded by a sentinel so we
//  only run once — re-running would overwrite any change the user
//  made via Settings after the rename.
//

import Foundation
import os

enum UserDefaultsMigration {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "Migration")
    private static let sentinelKey = "daisy.migration.holaPrefixDone_v1"

    private static let keyMapping: [(old: String, new: String)] = [
        ("hola.captureSystemAudio",       "daisy.captureSystemAudio"),
        ("hola.screenshotsEnabled",       "daisy.screenshotsEnabled"),
        ("hola.screenshotIntervalSec",    "daisy.screenshotIntervalSec"),
        ("hola.autoSummarize",            "daisy.autoSummarize"),
        ("hola.whisperModelID",           "daisy.whisperModelID"),
        ("hola.lastExportFolderBookmark", "daisy.lastExportFolderBookmark"),
    ]

    /// Run the migration if it hasn't been run yet. Idempotent — the
    /// sentinel ensures repeat calls are no-ops. Safe to call at any
    /// point during launch; call BEFORE constructing AppSettings so
    /// the new keys are populated by the time it reads them.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: sentinelKey) else { return }

        var migratedCount = 0
        for (old, new) in keyMapping {
            // Only copy if the new key isn't already set — protects any
            // value the user might have set via a build that already
            // wrote the new key.
            if defaults.object(forKey: new) == nil,
               let value = defaults.object(forKey: old) {
                defaults.set(value, forKey: new)
                migratedCount += 1
            }
            // Always remove the legacy key, whether we copied or not,
            // so it stops cluttering the prefs plist.
            defaults.removeObject(forKey: old)
        }

        defaults.set(true, forKey: sentinelKey)

        if migratedCount > 0 {
            log.info("Migrated \(migratedCount, privacy: .public) hola.* preference key(s) to daisy.*")
        }
    }
}
