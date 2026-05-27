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
//  Safe-by-default: `audioRetentionDays == 0` ⇒ no-op. Default
//  changed from 0 to 1 (24-hour retention) in 1.0.6.9; users
//  who explicitly picked a value keep it. `runNow()` ignores
//  the cutoff entirely and purges all audio archives (for the
//  Settings → Clear audio cache button — manual flush after the
//  user accepts a destructive confirm alert).
//

import Foundation
import os

@MainActor
enum AudioRetentionSweep {
    // 2026-05-25 — three constants marked `nonisolated`. The enum is
    // `@MainActor` so its members default to MainActor isolation, but
    // these three are immutable + Sendable (Logger conforms to
    // Sendable since macOS 11; Set<String> and [String] are Sendable
    // because String is). Marking them nonisolated lets the off-
    // actor Task.detached closures in `purgeOneSession` and `sweep`
    // read them without warnings (Swift 6 strict concurrency would
    // otherwise flag the access). No safety loss — constants can't
    // race.
    nonisolated private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "AudioRetention")

    /// Audio filenames the sweep is allowed to remove. Anything else
    /// in a session directory (transcript.md, summary.json,
    /// speakers.json, screenshots/) is preserved.
    nonisolated private static let purgeableNames: Set<String> = [
        "microphone.caf",
        "system_audio.caf",
    ]
    /// Multi-part archive prefix — `microphone.part2.caf`,
    /// `microphone.part3.caf`, etc., produced when a mid-session
    /// route change forced an archive rollover. All of them are
    /// safe to purge when the session itself is past the cutoff.
    nonisolated private static let purgeablePrefixes: [String] = [
        "microphone.part",
        "system_audio.part",
    ]

    /// Run the sweep with the current user setting. Background queue;
    /// returns immediately. No-op for retention == 0 (keep forever)
    /// or retention == -1 (delete-after-transcription — that mode is
    /// per-session and fires from `RecordingSession.finalizePostStop`
    /// once the pipeline is done with that specific session's audio,
    /// so the timer sweep has nothing to do at launch).
    static func runIfNeeded(retentionDays: Int) {
        guard retentionDays > 0 else {
            log.info("retention sweep skipped (retentionDays=\(retentionDays, privacy: .public))")
            return
        }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        Task.detached(priority: .utility) {
            await sweep(cutoff: cutoff)
        }
    }

    /// Per-session purge — deletes raw audio archives in ONE session
    /// directory immediately. Backs the "Delete after transcription"
    /// retention option (`AppSettings.audioRetentionDeleteAfterTranscription`).
    /// Called from `RecordingSession` right after the post-stop
    /// pipeline writes transcript.md and (optionally) summary.json:
    /// at that point Daisy has nothing else to do with the raw audio,
    /// so a privacy-first user wants it gone immediately rather than
    /// waiting 24h+ for the timer sweep. Best-effort, fire-and-
    /// forget; per-file failures are logged and skipped.
    static func purgeOneSession(at directory: URL) {
        let dirName = directory.lastPathComponent
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let inner = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                log.info("per-session purge: unable to list \(dirName, privacy: .private)")
                return
            }
            var purged = 0
            var freed: Int64 = 0
            for fileURL in inner {
                let name = fileURL.lastPathComponent
                let shouldPurge =
                    purgeableNames.contains(name) ||
                    purgeablePrefixes.contains(where: { name.hasPrefix($0) })
                guard shouldPurge else { continue }
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                do {
                    try fm.removeItem(at: fileURL)
                    purged += 1
                    freed += Int64(size)
                } catch {
                    log.error("per-session purge failed for \(name, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
            if purged > 0 {
                let mb = Double(freed) / 1_048_576.0
                log.info("per-session purge done for \(dirName, privacy: .private) — \(purged, privacy: .public) files, \(mb, privacy: .public) MB freed")
            }
        }
    }

    /// Immediate manual purge — deletes all known audio archives in
    /// every session directory, ignoring the user's retention
    /// setting. Backs the Settings → "Clear audio cache" button.
    /// Returns the freed-bytes count via the optional callback so
    /// the UI can display "Freed X MB". Best-effort: per-file
    /// failures are logged and skipped.
    static func runNow(completion: (@MainActor @Sendable (Int, Int64) -> Void)? = nil) {
        // `Date.distantFuture` cutoff matches every session.
        let cutoff = Date.distantFuture
        Task.detached(priority: .userInitiated) {
            let result = await sweep(cutoff: cutoff)
            if let completion {
                await MainActor.run { completion(result.purgedFiles, result.freedBytes) }
            }
        }
    }

    /// Compute current on-disk size of all known audio archives,
    /// across every session. For the Settings row caption — lets
    /// the user see how much they'd reclaim before clicking
    /// "Clear audio cache". Returns (file count, total bytes).
    /// Best-effort: unreadable directories are skipped silently.
    static func currentCacheSize() async -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let ticket = await MainActor.run(body: { SessionsFolder.acquireBase() }) else {
            return (0, 0)
        }
        defer { Task { @MainActor in ticket.release() } }
        let sessionsDir = ticket.url.appendingPathComponent("Sessions", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var fileCount = 0
        var totalBytes: Int64 = 0
        for sessionDir in entries {
            let isDir = (try? sessionDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let inner = try? fm.contentsOfDirectory(
                at: sessionDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for fileURL in inner {
                let name = fileURL.lastPathComponent
                let isAudio =
                    purgeableNames.contains(name) ||
                    purgeablePrefixes.contains(where: { name.hasPrefix($0) })
                guard isAudio else { continue }
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                fileCount += 1
                totalBytes += Int64(size)
            }
        }
        return (fileCount, totalBytes)
    }

    /// Result of one sweep pass — surfaced to callers (the manual
    /// "Clear audio cache" button uses these for the toast). The
    /// scheduled `runIfNeeded` path ignores them and just logs.
    private struct SweepResult: Sendable {
        var purgedFiles: Int
        var freedBytes: Int64
    }

    @discardableResult
    private static func sweep(cutoff: Date) async -> SweepResult {
        let fm = FileManager.default
        guard let ticket = await MainActor.run(body: { SessionsFolder.acquireBase() }) else {
            log.info("retention sweep: no sessions root acquired")
            return SweepResult(purgedFiles: 0, freedBytes: 0)
        }
        defer { Task { @MainActor in ticket.release() } }
        let sessionsDir = ticket.url.appendingPathComponent("Sessions", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SweepResult(purgedFiles: 0, freedBytes: 0)
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
        return SweepResult(purgedFiles: purgedFiles, freedBytes: freedBytes)
    }
}
