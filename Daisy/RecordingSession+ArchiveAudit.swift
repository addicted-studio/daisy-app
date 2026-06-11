//
//  RecordingSession+ArchiveAudit.swift
//  Daisy
//
//  Post-stop audit of the on-disk .caf archives (1.0.7.1
//  silent-write-death fix): classifies each stream's archive as
//  off / captured / empty / truncated so the transcript frontmatter
//  and the post-stop toasts tell the truth about what actually
//  landed on disk. Pure code motion out of RecordingSession.swift —
//  the `ArchiveStatus` enum itself stays in the main file.
//

import Foundation

extension RecordingSession {
    /// Proxy for `systemAudio.hasReceivedAudio` so MarkdownExporter
    /// (and other read-only consumers outside this type) can persist
    /// the system-audio capture outcome without us widening
    /// `systemAudio`'s visibility. True == at least one PCM frame
    /// landed during the session; false == capture was armed but
    /// stayed silent (usually BT output, or the macOS 26 SCStream
    /// regression) OR was never armed.
    var hasCapturedSystemAudio: Bool {
        systemAudio.hasReceivedAudio
    }

    // MARK: - Archive truncation audit (1.0.7.1)

    /// Minimum on-disk byte count for a CAF file to be considered
    /// "has actual audio data". CAF header + format/data chunk
    /// metadata is typically 100-200 bytes; we use a comfortable
    /// 4 KB threshold so a file that's just chunk-headers-and-nothing
    /// gets correctly classified as truncated. Picked conservatively
    /// — even a 1-second mono float32 capture at 16 kHz is 64 KB,
    /// well above this floor.
    private static let archiveDataFloorBytes: Int64 = 4096

    /// Render-thread write-error tolerance before flipping captured →
    /// truncated. A few transient errors (disk pressure, momentary
    /// device handover) are tolerable; >25 means systemic failure
    /// and the file is almost certainly partial. Matches the toast
    /// threshold the recorder uses for its post-stop summary
    /// (CoreAudioMicRecorder.stop() `if errCount > 25`).
    private static let archiveWriteErrorTolerance: Int = 25

    /// Read on-disk byte count for an archive URL. Returns 0 for
    /// missing file (FileManager throws → treat as nothing on disk).
    /// Synchronous file-system stat — only called once per stream
    /// per stop(), not in a hot loop.
    private static func archiveBytesOnDisk(_ url: URL?) -> Int64 {
        guard let url else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Post-stop audit of the system-audio archive. See `ArchiveStatus`
    /// docs for the four states and the failure mode each one names.
    /// Called from `stop()` after Final pass + from `MarkdownExporter`
    /// for the frontmatter line. Idempotent and side-effect-free —
    /// only reads counters + file size.
    var systemAudioArchiveStatus: ArchiveStatus {
        guard settings.captureSystemAudio, currentMode == .meeting else {
            return .off
        }
        let bytes = Self.archiveBytesOnDisk(systemArchiveURL)
        let receivedAnything = systemAudio.hasReceivedAudio
        let receivedAudible = systemAudio.receivedAudibleAudio
        let framesWritten = systemAudio.archivedFrameCount
        let (errCount, _) = systemAudio.archiveWriteErrorsSummary

        if !receivedAnything {
            // SCKit never delivered a buffer. Same case the existing
            // silenceMonitor surfaces mid-recording.
            return .empty
        }
        // Buffers arrived but EVERY one was silence (DRM-protected
        // playback, or the macOS Tahoe all-zero-buffer glitch). The file
        // can be non-trivial in size — silence still writes frames — but
        // it holds no remote audio, so report `.empty`, not `.captured`,
        // and let the frontmatter + post-stop toast tell the truth.
        if !receivedAudible {
            return .empty
        }
        // Buffer(s) arrived. Now check whether ANY of them landed on
        // disk. Three truncation paths:
        //   1. File is missing or below the data floor — open failed
        //      silently, or every write threw before the writer
        //      could grow the data chunk beyond headers.
        //   2. Frames-written counter is zero despite hasReceivedAudio
        //      — open succeeded but every write throw triggered the
        //      catch branch. The Billions 2026-05-25 failure mode.
        //   3. Write errors above tolerance — even if some frames
        //      landed, the file is so partial that the user needs
        //      to know before they try to re-summarize.
        if bytes < Self.archiveDataFloorBytes
            || framesWritten == 0
            || errCount > Self.archiveWriteErrorTolerance
        {
            return .truncated(
                bytes: bytes,
                framesWritten: framesWritten,
                writeErrors: errCount
            )
        }
        return .captured(bytes: bytes)
    }

    /// Post-stop audit of the microphone archive. Symmetric to
    /// `systemAudioArchiveStatus` — mic almost always exists in
    /// meeting/voiceNote/dictation modes; `.off` is mostly a future
    /// hook for hypothetical mic-disabled modes.
    var micAudioArchiveStatus: ArchiveStatus {
        // Mic is always recorded in all three modes (meeting, voice
        // note, dictation). There's no setting to disable it — the
        // recorder is the entire point. So the .off case is reserved
        // for the no-permission early-return path; we surface it as
        // "empty" instead here, since "no permission to record mic"
        // is a real failure the user should know about.
        let bytes = Self.archiveBytesOnDisk(micArchiveURL)
        let framesWritten = recorder.archivedFrameCount
        let (errCount, _) = recorder.archiveWriteErrorsSummary
        let receivedAnything = framesWritten > 0 || bytes > 0

        if !receivedAnything {
            return .empty
        }
        if bytes < Self.archiveDataFloorBytes
            || framesWritten == 0
            || errCount > Self.archiveWriteErrorTolerance
        {
            return .truncated(
                bytes: bytes,
                framesWritten: framesWritten,
                writeErrors: errCount
            )
        }
        return .captured(bytes: bytes)
    }

    /// Convenience: the same three-state status MarkdownExporter
    /// writes to `daisy_system_audio_status:` frontmatter, surfaced
    /// here so the in-process `StoredSession` snapshots used by
    /// auto-send and Send-to carry the same flag. `"ok"` /
    /// `"empty"` / `nil` (capture was off, no opinion to record).
    var systemAudioStatusValue: String? {
        guard settings.captureSystemAudio else { return nil }
        return systemAudio.hasReceivedAudio ? "ok" : "empty"
    }
}
