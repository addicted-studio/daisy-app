//
//  SessionClassifyTests.swift
//  DaisyTests
//
//  Regression locks for `SessionStore.classify` — the single function
//  standing between the refresh scan and user data. Its misjudgements
//  have historically been the app's worst bug class (husk-cleanup
//  deleting a live recording, pre-marker crash leftovers), so every
//  shape it distinguishes gets a table row here. Also locks
//  `upsertFrontmatter` and the QuitFinalizeRecovery helpers that
//  rewrite transcript.md in place.
//
//  All tests build real (temp) directories — classify is pure
//  filesystem-in, verdict-out, so this stays fast and deterministic.
//

import Testing
import Foundation
@testable import Daisy

@Suite("SessionStore.classify shapes")
struct SessionClassifyTests {

    // MARK: - Fixtures

    /// Fresh unique temp directory, removed by the OS eventually;
    /// tests also clean up behind themselves where it matters.
    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-classify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, as name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func writeBlob(bytes: Int, as name: String, in dir: URL) throws {
        try Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }

    /// Push the directory's mtime into the past — classify's husk age
    /// guard (300 s) reads the DIRECTORY mtime, and file writes bump
    /// it, so backdate AFTER all writes.
    private func backdate(_ dir: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)],
            ofItemAtPath: dir.path
        )
    }

    private let finishedTranscript = """
    ---
    title: "Test session"
    started: 2026-07-20T10:00:00Z
    duration_sec: 60
    ---

    # Test session

    Hello world transcript body.
    """

    // MARK: - Husk shapes

    @Test("Fresh empty dir is left alone (young husk → unreadable)")
    func emptyDirYoung() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .unreadable = SessionStore.classify(directory: dir) else {
            Issue.record("young empty dir must be .unreadable (not deleted, not shown)")
            return
        }
    }

    @Test("Old empty dir is an orphan (cleanup allowed)")
    func emptyDirOld() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try backdate(dir, by: 600)
        guard case .orphan = SessionStore.classify(directory: dir) else {
            Issue.record("old empty dir must be .orphan")
            return
        }
    }

    @Test("Old tiny audio-only dir is an orphan, not a recording")
    func tinyAudioOldIsOrphan() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Below minRecoverableAudioBytes and no marker → throwaway stub.
        try writeBlob(bytes: 1_024, as: "microphone.caf", in: dir)
        try backdate(dir, by: 600)
        guard case .orphan = SessionStore.classify(directory: dir) else {
            Issue.record("tiny old .caf without marker must be .orphan")
            return
        }
    }

    // MARK: - Interrupted (crash / power loss) — NEVER delete

    @Test("Marker + audio, no transcript → interrupted")
    func markerMakesInterrupted() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeBlob(bytes: 1_024, as: "microphone.caf", in: dir)
        try write("2026-07-20T10:00:00Z", as: SessionStore.recordingMarkerName, in: dir)
        try backdate(dir, by: 600)   // age must NOT flip this to orphan
        guard case .interrupted = SessionStore.classify(directory: dir) else {
            Issue.record("marker + audio must be .interrupted regardless of age/size")
            return
        }
    }

    @Test("Large audio without marker (pre-marker crash) → interrupted")
    func largeAudioFallbackInterrupted() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Above minRecoverableAudioBytes — the size fallback must catch
        // recordings from builds that predate the marker.
        try writeBlob(bytes: Int(SessionStore.minRecoverableAudioBytes) + 1, as: "system_audio.caf", in: dir)
        try backdate(dir, by: 600)
        guard case .interrupted = SessionStore.classify(directory: dir) else {
            Issue.record("large marker-less .caf must be .interrupted, never orphaned")
            return
        }
    }

    // MARK: - Valid

    @Test("Finished transcript → valid")
    func finishedTranscriptIsValid() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(finishedTranscript, as: "transcript.md", in: dir)
        guard case .valid(let session) = SessionStore.classify(directory: dir) else {
            Issue.record("finished transcript must classify .valid")
            return
        }
        #expect(session.title == "Test session")
    }

    @Test("Quit-saved shape (transcript + audio + leftover marker) → valid, not interrupted")
    func quitSavedShapeStaysValid() throws {
        // THE QuitFinalizeRecovery tell: stop() flushed transcript.md
        // but the process died before finalize removed the marker.
        // classify must treat the finished transcript as authoritative
        // (.valid) — recovery must NOT re-transcribe it as interrupted,
        // and cleanup must not touch it.
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(finishedTranscript, as: "transcript.md", in: dir)
        try writeBlob(bytes: Int(SessionStore.minRecoverableAudioBytes) + 1, as: "microphone.caf", in: dir)
        try write("2026-07-20T10:00:00Z", as: SessionStore.recordingMarkerName, in: dir)
        guard case .valid = SessionStore.classify(directory: dir) else {
            Issue.record("transcript + audio + marker must stay .valid (quit-saved, handled by QuitFinalizeRecovery)")
            return
        }
    }

    @Test("Meaningful frontmatter with empty body still valid (zero-segment recording)")
    func emptyBodyMeaningfulFrontmatterValid() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("---\ntitle: \"Silent one\"\nstarted: 2026-07-20T10:00:00Z\n---\n", as: "transcript.md", in: dir)
        guard case .valid = SessionStore.classify(directory: dir) else {
            Issue.record("title/started frontmatter must make the session .valid even with an empty body")
            return
        }
    }

    // MARK: - upsertFrontmatter

    @Test("Upsert replaces an existing key in place")
    func upsertReplacesKey() {
        let updated = SessionStore.upsertFrontmatter(
            in: finishedTranscript, key: "title", value: "\"Renamed\""
        )
        #expect(updated.contains("title: \"Renamed\""))
        #expect(!updated.contains("title: \"Test session\""))
        // Body untouched.
        #expect(updated.contains("Hello world transcript body."))
    }

    @Test("Upsert adds a missing key without disturbing the body")
    func upsertAddsKey() {
        let updated = SessionStore.upsertFrontmatter(
            in: finishedTranscript, key: "daisy_tag", value: "client-x"
        )
        #expect(updated.contains("daisy_tag: client-x"))
        #expect(updated.contains("Hello world transcript body."))
    }

    // MARK: - QuitFinalizeRecovery helpers

    @Test("replaceBody keeps frontmatter + heading verbatim, swaps the rest")
    func replaceBodyPreservesIdentity() {
        let updated = QuitFinalizeRecovery.replaceBody(
            in: finishedTranscript, with: "NEW BODY\n"
        )
        #expect(updated.hasPrefix("---\ntitle: \"Test session\""))
        #expect(updated.contains("started: 2026-07-20T10:00:00Z"))
        #expect(updated.contains("# Test session"))
        #expect(updated.contains("NEW BODY"))
        #expect(!updated.contains("Hello world transcript body."))
    }

    @Test("replaceBody without frontmatter falls back to the new body")
    func replaceBodyNoFrontmatter() {
        let updated = QuitFinalizeRecovery.replaceBody(in: "just text", with: "NEW\n")
        #expect(updated == "NEW\n")
    }

    @Test("transcriptUntouched: true right after save, false after a later edit")
    func transcriptUntouchedHeuristic() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-untouched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let caf = dir.appendingPathComponent("microphone.caf")
        try Data(count: 1_024).write(to: caf)
        let transcript = dir.appendingPathComponent("transcript.md")
        try Data("body".utf8).write(to: transcript)
        // Written moments after the audio → untouched.
        #expect(QuitFinalizeRecovery.transcriptUntouched(in: dir) == true)

        // Simulate a user edit long after the audio stopped.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3_600)],
            ofItemAtPath: transcript.path
        )
        #expect(QuitFinalizeRecovery.transcriptUntouched(in: dir) == false)
    }
}
