//
//  VoiceMemoIngestor.swift
//  Daisy
//
//  Transcribes ONE Voice Memo into a flat Markdown note. No summary,
//  no LLM, no network — decode → Whisper → write `.md`. Reuses the
//  app's existing decode (`AudioArchiveDecoder.decodeToMono16k`, which
//  reads any `AVAudioFile`-decodable container incl. `.m4a`) and
//  transcription (`WhisperEngine.shared.transcribe`) so voice-memo
//  transcripts match recording quality.
//
//  Deliberately does NOT build a `RecordingSession` or a SessionStore
//  session: voice-memo notes are standalone files the user (or Claude
//  Cowork via scheduled tasks) consumes directly. One memo → one `.md`.
//

import Foundation
import os

@MainActor
enum VoiceMemoIngestor {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "VoiceMemos")

    enum IngestError: Error { case download, decode }

    /// Ingest `memo` into `destDir`. `language` is a two-letter code
    /// ("en", "ru") or nil for auto-detect. Returns the written file
    /// URL. The heavy decode + file IO run off the main actor; only the
    /// `WhisperEngine` call is awaited on the main actor (same as every
    /// other transcription caller in the app).
    @discardableResult
    static func ingest(_ memo: VoiceMemoLibrary.VoiceMemo, into destDir: URL, language: String?) async throws -> URL {
        let url = memo.url

        // 1. Materialise the file if it's an iCloud placeholder.
        let ready = await Task.detached(priority: .utility) {
            VoiceMemoLibrary.ensureDownloaded(url)
        }.value
        guard ready else { throw IngestError.download }

        // 2. Decode to 16 kHz mono off the main actor (CPU + IO heavy).
        // NB: the detached call is pulled into its own `let` — a trailing
        // closure inside a `guard`/`if` condition is parsed as the body
        // brace, so it can't live in the guard line.
        let decoded = await Task.detached(priority: .utility) {
            AudioArchiveDecoder.decodeToMono16k(urls: [url])
        }.value
        guard let samples = decoded, !samples.isEmpty else {
            throw IngestError.decode
        }

        // 3. Transcribe — Whisper self-loads via `ensureLoaded`.
        let segments = try await WhisperEngine.shared.transcribe(
            samples: samples,
            language: language,
            profile: .full
        )

        // 4. Render flat markdown + write off the main actor.
        let durationSec = Double(samples.count) / 16_000.0
        let markdown = renderMarkdown(memo: memo, segments: segments, durationSec: durationSec, language: language)
        let fileURL = try await Task.detached(priority: .utility) {
            try writeNote(markdown: markdown, memo: memo, into: destDir)
        }.value

        log.info("Ingested voice memo \(memo.id, privacy: .private) → \(fileURL.lastPathComponent, privacy: .private)")
        return fileURL
    }

    // MARK: - Rendering

    /// Obsidian-friendly flat note: YAML frontmatter + transcript body.
    nonisolated static func renderMarkdown(
        memo: VoiceMemoLibrary.VoiceMemo,
        segments: [WhisperSegment],
        durationSec: Double,
        language: String?
    ) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlQuote(memo.title))")
        lines.append("type: voice-memo")
        lines.append("source: Apple Voice Memos")
        lines.append("recorded: \(iso.string(from: memo.recordedAt))")
        lines.append("imported: \(iso.string(from: Date()))")
        lines.append("duration_sec: \(Int(durationSec.rounded()))")
        if let language, !language.isEmpty { lines.append("locale: \(language)") }
        lines.append("---")
        lines.append("")
        lines.append("# \(memo.title)")
        lines.append("")

        let body = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        lines.append(body.isEmpty ? "_No speech detected._" : body)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Writing

    nonisolated private static func writeNote(
        markdown: String,
        memo: VoiceMemoLibrary.VoiceMemo,
        into destDir: URL
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let base = fileBaseName(memo: memo)
        var candidate = destDir.appendingPathComponent(base + ".md")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = destDir.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        try Data(markdown.utf8).write(to: candidate, options: .atomic)
        return candidate
    }

    /// `2026-06-15 1430 — Title` (POSIX date, sanitised title).
    nonisolated private static func fileBaseName(memo: VoiceMemoLibrary.VoiceMemo) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HHmm"
        let datePart = df.string(from: memo.recordedAt)
        let safeTitle = sanitize(memo.title)
        return safeTitle.isEmpty ? datePart : "\(datePart) — \(safeTitle)"
    }

    /// Strip path-hostile characters so the title is filename-safe.
    nonisolated private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        return s.components(separatedBy: bad)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
