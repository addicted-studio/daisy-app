//
//  VoiceMemoLibrary.swift
//  Daisy
//
//  Locates the macOS Voice Memos library and lists its `.m4a`
//  recordings (including iCloud-synced ones from iPhone). READ-ONLY —
//  Daisy never modifies or deletes the originals.
//
//  Daisy is non-sandboxed (see Daisy.entitlements), so it can read
//  arbitrary user files — but the Voice Memos container is TCC-
//  protected, so reading it requires the user to grant Full Disk
//  Access. `accessStatus()` distinguishes "no library on this Mac"
//  from "library is there but we're blocked" so Settings can guide
//  the user to the right place.
//
//  Path is NOT hardcoded to one location: Voice Memos has used a
//  couple of containers across macOS versions, so we probe known
//  candidates and use the first that resolves.
//

import Foundation
import os

enum VoiceMemoLibrary {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "VoiceMemos")

    /// One recording in the Voice Memos library.
    struct VoiceMemo: Sendable, Identifiable, Equatable {
        /// The real `.m4a` URL to read (for an un-downloaded iCloud
        /// placeholder this is the materialised path, not the dotfile).
        let url: URL
        /// Stable identifier for dedup — the recording's on-disk base
        /// name (without extension). Stable across transcript re-runs.
        let id: String
        /// User-visible title — derived from the filename.
        let title: String
        /// When the memo was recorded (file creation date, falling back
        /// to modification date).
        let recordedAt: Date
    }

    /// Whether Daisy can currently read the library — drives the
    /// Settings status row.
    enum AccessStatus: Equatable, Sendable {
        case ok                    // directory readable
        case needsFullDiskAccess   // directory exists but read denied
        case noLibrary             // no Voice Memos library found
        case error(String)
    }

    // MARK: - Location

    /// Candidate container paths, probed in order.
    private static func candidateDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.VoiceMemos/Recordings", isDirectory: true),
        ]
    }

    /// First candidate that exists as a directory, or nil. Note: when
    /// Full Disk Access is denied, `fileExists` may report false for a
    /// path that's really there — so callers should treat a nil here
    /// together with `accessStatus()` rather than as a hard "no library".
    static func resolveRecordingsDirectory() -> URL? {
        let fm = FileManager.default
        for dir in candidateDirectories() {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
        }
        return nil
    }

    // MARK: - Access status

    /// Probe each candidate by actually trying to list it, and map the
    /// failure: a permission error anywhere ⇒ `.needsFullDiskAccess`;
    /// otherwise (only not-found errors) ⇒ `.noLibrary`.
    static func accessStatus() -> AccessStatus {
        var sawPermissionDenied = false
        for dir in candidateDirectories() {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                return .ok
            } catch let err as NSError {
                if isPermissionError(err) { sawPermissionDenied = true }
                // else: no-such-file / not-a-directory → try next.
            }
        }
        return sawPermissionDenied ? .needsFullDiskAccess : .noLibrary
    }

    private static func isPermissionError(_ err: NSError) -> Bool {
        if err.domain == NSCocoaErrorDomain {
            if err.code == NSFileReadNoPermissionError { return true }
            if let underlying = err.userInfo[NSUnderlyingErrorKey] as? NSError {
                return isPermissionError(underlying)
            }
        }
        if err.domain == NSPOSIXErrorDomain {
            return err.code == Int(EPERM) || err.code == Int(EACCES)
        }
        return false
    }

    // MARK: - Enumeration

    /// List every `.m4a` recording with metadata, oldest first.
    /// `.failure` carries a status the UI can act on (most importantly
    /// `.needsFullDiskAccess`). iCloud placeholders (`.<name>.m4a.icloud`)
    /// are included and mapped to their real `.m4a` path; the actual
    /// download is deferred to `ensureDownloaded` at ingest time.
    static func enumerate() -> Result<[VoiceMemo], AccessStatus> {
        guard let dir = resolveRecordingsDirectory() else {
            let status = accessStatus()
            return .failure(status == .ok ? .noLibrary : status)
        }

        let fm = FileManager.default
        let contents: [URL]
        do {
            // No `.skipsHiddenFiles`: un-downloaded iCloud memos appear
            // as a hidden `.<name>.m4a.icloud` placeholder we still want.
            contents = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: []
            )
        } catch let err as NSError {
            return .failure(isPermissionError(err) ? .needsFullDiskAccess : .error(err.localizedDescription))
        }

        var memos: [VoiceMemo] = []
        for entry in contents {
            let name = entry.lastPathComponent
            let realURL: URL
            let id: String
            if name.hasSuffix(".m4a") {
                realURL = entry
                id = entry.deletingPathExtension().lastPathComponent
            } else if name.hasPrefix("."), name.hasSuffix(".m4a.icloud") {
                // ".<base>.m4a.icloud" → real file is "<base>.m4a"
                let trimmed = String(name.dropFirst().dropLast(".icloud".count))
                guard trimmed.hasSuffix(".m4a") else { continue }
                realURL = dir.appendingPathComponent(trimmed)
                id = (trimmed as NSString).deletingPathExtension
            } else {
                continue
            }
            let vals = try? entry.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let recordedAt = vals?.creationDate ?? vals?.contentModificationDate ?? .distantPast
            let title = id.isEmpty ? "Voice Memo" : id
            memos.append(VoiceMemo(url: realURL, id: id, title: title, recordedAt: recordedAt))
        }

        // De-dupe by id (a memo could surface as both file + placeholder)
        // and order oldest-first so a backfill imports chronologically.
        var seen = Set<String>()
        memos = memos.filter { seen.insert($0.id).inserted }
        memos.sort { $0.recordedAt < $1.recordedAt }
        return .success(memos)
    }

    // MARK: - iCloud materialisation

    /// Ensure `url` is downloaded locally (iCloud memos can be dataless
    /// placeholders). Best-effort with a bounded wait. Returns true when
    /// the file is readable. Safe to call on a non-`.m4a`/non-iCloud
    /// file — it just checks existence.
    ///
    /// Blocking (`Thread.sleep`) — intended to run on a background
    /// queue (the ingestor calls it inside `Task.detached`).
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 90) -> Bool {
        let fm = FileManager.default
        func isReady() -> Bool {
            let vals = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if let status = vals?.ubiquitousItemDownloadingStatus {
                return status == .current
            }
            // Not an iCloud-tracked item → existence is readiness.
            return fm.fileExists(atPath: url.path)
        }
        if isReady() { return true }
        try? fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReady() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return isReady()
    }
}
