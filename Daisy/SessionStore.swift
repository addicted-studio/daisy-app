//
//  SessionStore.swift
//  Daisy
//
//  Enumerates past recording sessions persisted on disk:
//      ~/Library/Containers/app.essazanov.Daisy/Data/Library/
//          Application Support/Daisy/Sessions/<ISO-timestamp>/
//          ├── microphone.caf
//          ├── system_audio.caf       (optional)
//          ├── screenshots/           (optional)
//          ├── transcript.md
//          └── summary.json           (optional)
//
//  Each session folder is parsed into a `StoredSession` value with the
//  YAML frontmatter from `transcript.md` providing title, locale, start
//  time, and duration. UI reads `SessionStore.shared.sessions`.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [StoredSession] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SessionStore")
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    private init() {}

    /// Re-scan the sessions folder. Cheap — typically <100 ms even for
    /// hundreds of sessions because we only read each transcript's
    /// frontmatter, not the full body.
    func refresh() async {
        // Coalesce concurrent refreshes.
        if let existing = refreshTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // Scan BOTH the default container location AND the user-
        // picked folder (if set). Old sessions don't get auto-moved
        // when the user changes the folder — they stay where they
        // were and History continues to list them.
        var roots: [(url: URL, ticket: SessionsFolder.AccessTicket?)] = []
        if let defaultDir = try? Self.defaultSessionsDirectory() {
            roots.append((defaultDir, nil))
        }
        if let userBase = SessionsFolder.resolveUserFolder() {
            // Acquire security scope just for the scan; release at
            // function exit via the ticket array's cleanup below.
            if userBase.startAccessingSecurityScopedResource() {
                let userSessionsDir = userBase
                    .appendingPathComponent("Daisy/Sessions", isDirectory: true)
                // Touch-create — the dir may not exist yet if the
                // user picked the folder but hasn't recorded anything
                // there yet.
                try? FileManager.default.createDirectory(
                    at: userSessionsDir,
                    withIntermediateDirectories: true
                )
                let ticket = SessionsFolder.AccessTicket(url: userBase, securityScoped: true)
                roots.append((userSessionsDir, ticket))
            } else {
                log.warning("Couldn't acquire security scope for user sessions folder during scan")
            }
        }
        defer {
            for root in roots { root.ticket?.release() }
        }

        guard !roots.isEmpty else {
            lastError = "Couldn't resolve any sessions folder."
            sessions = []
            return
        }

        var loaded: [StoredSession] = []
        var orphansToTrash: [URL] = []
        for root in roots {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: root.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
            } catch {
                log.error("Could not list \(root.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            for url in entries {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                switch Self.classify(directory: url) {
                case .valid(let session):
                    loaded.append(session)
                case .orphan:
                    orphansToTrash.append(url)
                case .unreadable:
                    break
                }
            }
        }
        // Most recent first. Session ids are directory names — the
        // ISO timestamps — so cross-folder collisions are essentially
        // impossible (two recordings starting at the same millisecond
        // would have to come from different installs of Daisy).
        sessions = loaded.sorted(by: { $0.startedAt > $1.startedAt })

        // Best-effort cleanup of empty stub directories — they get
        // created when start() runs the prepare phase but the user
        // pressed Stop before any audio was captured, or when an
        // earlier crash left a husk behind. Use removeItem rather
        // than trashItem because sandbox containers can't surface
        // items in Finder's Trash UI anyway — the stub has zero
        // user-recoverable content, so straight delete is correct.
        for url in orphansToTrash {
            try? FileManager.default.removeItem(at: url)
            log.info("Removed orphan session: \(url.lastPathComponent, privacy: .public)")
        }
    }

    /// Result of classifying a directory inside `Sessions/`. Either a
    /// real session we want to show, an empty stub to clean up, or
    /// unreadable (don't touch, don't show).
    nonisolated enum ParseResult {
        case valid(StoredSession)
        case orphan
        case unreadable
    }

    nonisolated static func classify(directory: URL) -> ParseResult {
        let fm = FileManager.default
        let micURL    = directory.appendingPathComponent("microphone.caf")
        let systemURL = directory.appendingPathComponent("system_audio.caf")
        let transcriptURL = directory.appendingPathComponent("transcript.md")

        let hasMic    = fm.fileExists(atPath: micURL.path)
        let hasSystem = fm.fileExists(atPath: systemURL.path)
        let hasTranscript = fm.fileExists(atPath: transcriptURL.path)

        // Examine transcript.md once up-front — needed both to decide
        // husk-vs-valid and (later) for parseSession.
        var transcriptBodyEmpty = true
        var hasMeaningfulFrontmatter = false
        if hasTranscript,
           let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            let parsed = parseFrontmatter(in: text)
            transcriptBodyEmpty = parsed.body
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            // `title` and `started` are the two fields stop() writes
            // on a successful finish. If either is present we treat
            // the transcript as "real" even if the body is empty
            // (e.g. zero-segment recording that nonetheless completed
            // its lifecycle and deserves a History entry).
            hasMeaningfulFrontmatter = parsed.title != nil || parsed.started != nil
        }

        // Orphan = directory that exists on disk but represents no
        // recoverable session. Three shapes occur in the wild:
        //
        //  (a) Empty folder — start() created the directory but never
        //      wrote audio or transcript (immediate crash / force-quit
        //      before AudioRecorder.start, or stop() pressed before
        //      capture began).
        //  (b) Audio-only, no transcript.md — recording captured
        //      .caf data but the app died before stop() could flush
        //      transcript.md. The .caf alone has no metadata and no
        //      playback UI in Daisy, so it'd render as "Untitled,
        //      0:00, today" — actively misleading.
        //  (c) Audio + transcript.md with empty body AND no
        //      meaningful frontmatter — partial stop(), aborted
        //      between file creation and content write.
        //  (d) No audio + transcript.md with empty body — start()
        //      wrote the YAML shell, then user reset() before any
        //      audio arrived.
        //
        // All four are husks. Auto-delete them so they don't pile up
        // in the user's History (observed during QA 2026-05-17: two
        // (b)-shaped husks from dev crashes on May 16 / 17 showed up
        // alongside a single real recording, looking like dupes).
        //
        // The 5-minute age guard avoids racing against an in-flight
        // recording: between `mkdir` and the first audio frame there's
        // a window where a freshly-started session looks like (a),
        // and we never want to nuke that.
        let isEmpty   = !hasMic && !hasSystem && !hasTranscript
        let audioOnly = (hasMic || hasSystem) && !hasTranscript
        let audioPlusEmptyShell = (hasMic || hasSystem)
            && hasTranscript
            && transcriptBodyEmpty
            && !hasMeaningfulFrontmatter
        let transcriptShellOnly = !hasMic && !hasSystem
            && hasTranscript
            && transcriptBodyEmpty

        let isHusk = isEmpty || audioOnly || audioPlusEmptyShell || transcriptShellOnly
        if isHusk {
            if directoryAgeSeconds(directory) >= 300 {
                return .orphan
            }
            // Young husk — possibly an in-flight recording. Don't
            // delete, don't show in History either (would just flash
            // a confusing "Untitled · 0:00" row during the window).
            return .unreadable
        }

        guard let session = parseSession(at: directory) else {
            return .unreadable
        }
        return .valid(session)
    }

    /// Seconds since `directory` was last modified. Used as the age
    /// guard for husk cleanup. Returns `.greatestFiniteMagnitude` if
    /// mtime can't be read — that errs on the side of "old enough to
    /// delete" rather than leaking husks indefinitely on systems with
    /// quirky filesystem metadata.
    nonisolated static func directoryAgeSeconds(_ directory: URL) -> TimeInterval {
        let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
        guard let mtime = values?.contentModificationDate else {
            return .greatestFiniteMagnitude
        }
        return Date().timeIntervalSince(mtime)
    }

    /// Permanently delete a session's folder + its contents.
    func delete(_ session: StoredSession) async {
        do {
            try FileManager.default.removeItem(at: session.directoryURL)
            await refresh()
        } catch {
            log.error("Delete failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    /// Bulk delete — used by the History view's multi-select shortcut.
    /// One refresh at the end instead of N to avoid UI thrash.
    /// Per-session errors are logged but don't stop the loop.
    func deleteMany(_ sessions: [StoredSession]) async {
        var firstError: String?
        for session in sessions {
            do {
                try FileManager.default.removeItem(at: session.directoryURL)
            } catch {
                log.error("Delete failed for \(session.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }
        await refresh()
        if let firstError {
            lastError = firstError
        }
    }

    /// Persist a speaker-to-attendee mapping for a session. Rewrites
    /// the `daisy_speaker_map:` frontmatter line as a YAML inline
    /// dict (`{A: "Alex", B: "Maria"}`) and refreshes the store so
    /// the Detail view re-renders with the new names.
    func updateSpeakerMap(_ map: [String: String], for session: StoredSession) async {
        guard let url = session.transcriptURL else { return }
        do {
            var text = try String(contentsOf: url, encoding: .utf8)
            let encoded = Self.encodeYAMLDict(map)
            text = Self.upsertFrontmatter(in: text, key: "daisy_speaker_map", value: encoded)
            try text.write(to: url, atomically: true, encoding: .utf8)
            await refresh()
        } catch {
            log.error("Speaker map save failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    nonisolated static func encodeYAMLDict(_ map: [String: String]) -> String {
        if map.isEmpty { return "{}" }
        let pairs = map.keys.sorted().map { k in
            let v = map[k] ?? ""
            return "\(k): \"\(v.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "{\(pairs.joined(separator: ", "))}"
    }

    /// Move a session to a folder. Rewrites the `daisy_folder:` line
    /// in the transcript markdown frontmatter (adding it if missing)
    /// and reloads the store so chips / lists update.
    func moveSession(_ session: StoredSession, to folder: SessionFolder) async {
        guard let url = session.transcriptURL else { return }
        do {
            var text = try String(contentsOf: url, encoding: .utf8)
            text = Self.upsertFrontmatter(in: text, key: "daisy_folder", value: folder.slug)
            try text.write(to: url, atomically: true, encoding: .utf8)
            await refresh()
        } catch {
            log.error("Move failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    /// Mutate (or insert) one `key: value` line inside the YAML
    /// frontmatter at the top of `text`. If there's no frontmatter
    /// at all, a fresh `---` block is prepended.
    nonisolated static func upsertFrontmatter(in text: String, key: String, value: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) != "---" {
            return "---\n\(key): \(value)\n---\n\n\(text)"
        }
        var closeIdx: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closeIdx = i
                break
            }
        }
        guard let endIdx = closeIdx else {
            return "---\n\(key): \(value)\n---\n\n\(text)"
        }
        var copy = lines
        let newLine = "\(key): \(value)"
        if let existing = (1..<endIdx).first(where: { copy[$0].hasPrefix("\(key):") }) {
            copy[existing] = newLine
        } else {
            copy.insert(newLine, at: endIdx)
        }
        return copy.joined(separator: "\n")
    }

    /// Replace a session's `summary.json` and reload metadata.
    func updateSummary(_ summary: MeetingSummary, for session: StoredSession) async {
        let url = session.directoryURL.appendingPathComponent("summary.json")
        do {
            let data = try JSONEncoder().encode(summary)
            try data.write(to: url, options: .atomic)
            await refresh()
        } catch {
            log.error("Save summary failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Filesystem helpers

    /// Sessions directory inside the app's container. Always
    /// readable, used as the fallback when no user-picked folder
    /// is set AND also scanned alongside the user folder so old
    /// sessions remain visible after the user reroutes.
    static func defaultSessionsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Daisy/Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func parseSession(at directory: URL) -> StoredSession? {
        let fm = FileManager.default
        let id = directory.lastPathComponent

        let transcriptURL = directory.appendingPathComponent("transcript.md")
        let summaryURL = directory.appendingPathComponent("summary.json")
        let micURL = directory.appendingPathComponent("microphone.caf")
        let systemURL = directory.appendingPathComponent("system_audio.caf")
        let screenshotsDir = directory.appendingPathComponent("screenshots", isDirectory: true)

        // Read transcript.md (lazily — only frontmatter + body for search).
        var title = id
        var startedAt = Self.dateFromFolderName(id) ?? Date()
        var durationSec = 0
        var locale = "auto"
        var transcriptBody = ""
        var transcriptPreview = ""
        if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            let parsed = parseFrontmatter(in: text)
            title = parsed.title ?? title
            if let dateStr = parsed.started,
               let parsedDate = Self.iso.date(from: dateStr) {
                startedAt = parsedDate
            }
            durationSec = parsed.durationSec ?? 0
            locale = parsed.locale ?? locale
            transcriptBody = parsed.body
            transcriptPreview = Self.preview(from: parsed.body)
        }

        // Load summary if present.
        var summary: MeetingSummary?
        if let data = try? Data(contentsOf: summaryURL) {
            summary = try? JSONDecoder().decode(MeetingSummary.self, from: data)
        }

        // Screenshot files (sorted by filename — they're zero-padded).
        var screenshots: [URL] = []
        if let entries = try? fm.contentsOfDirectory(at: screenshotsDir, includingPropertiesForKeys: nil) {
            screenshots = entries
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        // Folder slug + speaker mapping — parsed once at load.
        var folderSlug = "inbox"
        var attendees: [String] = []
        var speakerMap: [String: String] = [:]
        if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            let fm = parseFrontmatter(in: text)
            folderSlug = fm.folder ?? "inbox"
            attendees = fm.attendees
            speakerMap = fm.speakerMap
        }

        return StoredSession(
            id: id,
            directoryURL: directory,
            title: title,
            startedAt: startedAt,
            durationSec: durationSec,
            locale: locale,
            transcriptPreview: transcriptPreview,
            transcriptText: transcriptBody,
            hasMicAudio: fm.fileExists(atPath: micURL.path),
            hasSystemAudio: fm.fileExists(atPath: systemURL.path),
            screenshotURLs: screenshots,
            summary: summary,
            transcriptURL: fm.fileExists(atPath: transcriptURL.path) ? transcriptURL : nil,
            folderSlug: folderSlug,
            meetingAttendees: attendees,
            speakerMap: speakerMap
        )
    }

    nonisolated private static func preview(from body: String) -> String {
        // Skip leading "# Title", quote-style metadata, and section
        // headings. Grab the first chunk of plain prose, trim to 220 chars.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var collected: [String] = []
        var charCount = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("---") {
                continue
            }
            collected.append(line)
            charCount += line.count
            if charCount > 220 { break }
        }
        let joined = collected.joined(separator: " ")
        if joined.count <= 220 { return joined }
        return String(joined.prefix(217)) + "…"
    }

    nonisolated private static func dateFromFolderName(_ name: String) -> Date? {
        // Folder names come from `ISO8601DateFormatter` with the
        // `:` characters in time/offset replaced by `-` for FAT/
        // sandbox safety. Two shapes occur depending on whether the
        // formatter's timeZone was UTC (Z suffix) or local (offset).
        // The current production format is UTC → Z suffix, but older
        // folders may still carry an explicit offset, so we accept
        // both.
        //
        //   2026-05-17T12-37-36Z           (UTC, Z suffix)
        //   2026-05-16T22-30-00+08-00      (explicit offset)
        //
        // Restore colons before handing off to ISO8601DateFormatter.
        let zRegex      = /^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})Z$/
        let offsetRegex = /^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})([+-])(\d{2})-(\d{2})$/

        if let m = name.wholeMatch(of: zRegex) {
            let restored = "\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)Z"
            return iso.date(from: restored)
        }
        if let m = name.wholeMatch(of: offsetRegex) {
            let restored = "\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)\(m.7)\(m.8):\(m.9)"
            return iso.date(from: restored)
        }
        return nil
    }

    // ISO8601DateFormatter is documented as thread-safe but not declared
    // `Sendable` in Foundation, so we have to mark this `unsafe`.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Stored session value

struct StoredSession: Identifiable, Sendable {
    let id: String          // = directory name
    let directoryURL: URL
    let title: String
    let startedAt: Date
    let durationSec: Int
    let locale: String
    let transcriptPreview: String
    /// Full transcript body for search. Trimmed of frontmatter.
    let transcriptText: String
    let hasMicAudio: Bool
    let hasSystemAudio: Bool
    let screenshotURLs: [URL]
    let summary: MeetingSummary?
    let transcriptURL: URL?
    /// Folder slug, taken from `daisy_folder:` frontmatter. Defaults
    /// to "inbox" for transcripts that predate folder support.
    let folderSlug: String
    /// Attendees captured from the bound EKEvent when this session
    /// was started from the calendar. Empty otherwise.
    let meetingAttendees: [String]
    /// User-supplied mapping from speaker id (`"A"`, `"B"`, …) to
    /// real attendee name. Read from `daisy_speaker_map:`
    /// frontmatter. Empty until user fills it in via Detail view.
    let speakerMap: [String: String]

    var hasSummary: Bool { summary != nil }
    var hasScreenshots: Bool { !screenshotURLs.isEmpty }

    /// Cheap full-text search across title, body, and summary.
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        if title.lowercased().contains(q) { return true }
        if transcriptText.lowercased().contains(q) { return true }
        if let s = summary {
            if s.summary.lowercased().contains(q) { return true }
            if s.actionItems.contains(where: { $0.lowercased().contains(q) }) { return true }
            if s.clientFollowUp.lowercased().contains(q) { return true }
        }
        return false
    }
}

// MARK: - Frontmatter parser

nonisolated private struct ParsedFrontmatter {
    var title: String?
    var locale: String?
    var started: String?
    var durationSec: Int?
    var folder: String?
    var attendees: [String] = []
    var speakerMap: [String: String] = [:]
    /// Markdown body after the closing `---`. Empty if no frontmatter.
    var body: String
}

nonisolated private func parseFrontmatter(in markdown: String) -> ParsedFrontmatter {
    var parsed = ParsedFrontmatter(body: markdown)
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
        return parsed
    }
    // Find the closing "---".
    var closeIdx: Int?
    for i in 1..<lines.count {
        if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closeIdx = i
            break
        }
    }
    guard let endIdx = closeIdx else { return parsed }

    for i in 1..<endIdx {
        let line = String(lines[i])
        guard let colonIdx = line.firstIndex(of: ":") else { continue }
        let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces)
        var valueRaw = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
        // Strip surrounding quotes.
        if valueRaw.hasPrefix("\"") && valueRaw.hasSuffix("\"") && valueRaw.count >= 2 {
            valueRaw = String(valueRaw.dropFirst().dropLast())
        }
        switch key {
        case "title":         parsed.title = valueRaw
        case "locale":        parsed.locale = valueRaw
        case "started":       parsed.started = valueRaw
        case "duration_sec":  parsed.durationSec = Int(valueRaw)
        case "daisy_folder":  parsed.folder = valueRaw.lowercased()
        case "daisy_event_attendees":
            parsed.attendees = parseYAMLArray(valueRaw)
        case "daisy_speaker_map":
            parsed.speakerMap = parseYAMLDict(valueRaw)
        default:              break
        }
    }
    let body = lines[(endIdx + 1)...].joined(separator: "\n")
    parsed.body = body
    return parsed
}

/// Parse a YAML-style inline array — `["Alex", "Maria", "Boris"]`.
/// Tolerant: ignores quotes, trims whitespace, drops empties.
nonisolated private func parseYAMLArray(_ raw: String) -> [String] {
    var trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
        trimmed = String(trimmed.dropFirst().dropLast())
    }
    return trimmed
        .split(separator: ",")
        .map { item in
            var s = item.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
                s = String(s.dropFirst().dropLast())
            }
            return s
        }
        .filter { !$0.isEmpty }
}

/// Parse a YAML-style inline dict — `{A: "Alex", B: "Maria"}`.
nonisolated private func parseYAMLDict(_ raw: String) -> [String: String] {
    var trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
        trimmed = String(trimmed.dropFirst().dropLast())
    }
    var out: [String: String] = [:]
    for pair in trimmed.split(separator: ",") {
        guard let colon = pair.firstIndex(of: ":") else { continue }
        let key = String(pair[..<colon]).trimmingCharacters(in: .whitespaces)
        var value = String(pair[pair.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        if !key.isEmpty, !value.isEmpty {
            out[key] = value
        }
    }
    return out
}
