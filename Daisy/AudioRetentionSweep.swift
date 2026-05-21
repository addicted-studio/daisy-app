//
//  AudioRetentionSweep.swift
//  Daisy
//
//  Disk hygiene — deletes raw `.caf` audio archives older than the
//  user-configured cutoff. Transcripts (transcript.md), summaries
//  (summary.json), screenshots and any other session artefacts are
//  left intact; only the raw audio is purged, since that's what
//  dominates the on-disk footprint.
//
//  Trigger points:
//    • App launch (after a short delay so it doesn't fight first-
//      paint contention)
//    • Whenever `settings.audioRetentionDays` is edited from a
//      non-zero value to a smaller one (catch-up sweep so the user
//      sees space reclaimed without waiting for next launch)
//
//  Safe-by-default: `audioRetentionDays == 0` ⇒ no-op. Pre-1.0.5.4
//  installs have no key set, so the migration value is 0; nothing
//  unexpected gets deleted for existing users until they opt in.
//

import Foundation
import os

@MainActor
enum AudioRetentionSweep {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "AudioRetention")

    /// Audio filenames the sweep is allowed to remove. Anything else
    /// in a session directory (transcript.md, summary.json,
    /// speakers.json, screenshots/) is preserved.
    private static let purgeableNames: Set<String> = [
        "microphone.caf",
        "system_audio.caf",
    ]
    /// Multi-part archive prefix — `microphone.part2.caf`,
    /// `microphone.part3.caf`, etc., produced when a mid-session
    /// route change forced an archive rollover. All of them are
    /// safe to purge when the session itself is past the cutoff.
    private static let purgeablePrefixes: [String] = [
        "microphone.part",
        "system_audio.part",
    ]

    /// Run the sweep with the current user setting. Background queue;
    /// returns immediately. No-op for retention == 0.
    static func runIfNeeded(retentionDays: Int) {
        guard retentionDays > 0 else {
            log.info("retention sweep skipped (retentionDays=0)")
            return
        }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        Task.detached(priority: .utility) {
            await sweep(cutoff: cutoff)
        }
    }

    private static func sweep(cutoff: Date) async {
        let fm = FileManager.default
        guard let ticket = await MainActor.run(body: { SessionsFolder.acquireBase() }) else {
            log.info("retention sweep: no sessions root acquired")
            return
        }
        defer { Task { @MainActor in ticket.release() } }
        let sessionsDir = ticket.url.appendingPathComponent("Sessions", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var purgedFiles = 0
        var freedBytes: Int64 = 0

        for sessionDir in entries {
            let isDir = (try? sessionDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }

            // Session age — use the directory's mtime as the proxy.
            // Stable across re-renames, and matches what the user
            // sees in Finder.
            let mtime = (try? sessionDir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let mtime, mtime < cutoff else { continue }

            guard let inner = try? fm.contentsOfDirectory(
                at: sessionDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in inner {
                let name = fileURL.lastPathComponent
                let shouldPurge =
                    purgeableNames.contains(name) ||
                    purgeablePrefixes.contains(where: { name.hasPrefix($0) })
                guard shouldPurge else { continue }
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                do {
                    try fm.removeItem(at: fileURL)
                    purgedFiles += 1
                    freedBytes += Int64(size)
                } catch {
                    // Best-effort — log and continue. Almost always a
                    // permission issue (user moved the folder out
                    // from under us); not worth crashing the sweep.
                    log.error("retention sweep failed to delete \(fileURL.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if purgedFiles > 0 {
            let mb = Double(freedBytes) / 1_048_576.0
            log.info("retention sweep purged \(purgedFiles, privacy: .public) audio files, freed \(mb, privacy: .public) MB")
        }
    }
}
