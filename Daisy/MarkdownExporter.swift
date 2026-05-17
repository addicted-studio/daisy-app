//
//  MarkdownExporter.swift
//  Daisy
//
//  Renders a RecordingSession to Obsidian-friendly markdown and writes it
//  to a user-chosen location. Remembers the last-used folder via a
//  security-scoped bookmark so the save panel opens there next time.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import os

enum MarkdownExporter {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "Exporter")
    private static let lastFolderBookmarkKey = "daisy.lastExportFolderBookmark"

    // MARK: - Render

    static func renderMarkdown(session: RecordingSession) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlQuote(session.title))")
        lines.append("type: meeting-transcript")
        lines.append("source: Daisy")
        lines.append("locale: \(session.localeIdentifier)")
        if let started = session.startedAt {
            lines.append("started: \(iso(started))")
        }
        lines.append("duration_sec: \(Int(session.elapsed))")
        lines.append("daisy_folder: \(session.folder.slug)")
        if let meeting = session.boundMeeting {
            // Bind transcript ↔ calendar event so future search can
            // resolve "show me the transcript of that Q3 review".
            // Both ids are persisted: external survives provider re-
            // sync, local is the runtime-resolvable handle.
            if let ext = meeting.externalID {
                lines.append("daisy_event_external_id: \(yamlQuote(ext))")
            }
            lines.append("daisy_event_local_id: \(yamlQuote(meeting.localID))")
            lines.append("daisy_event_title: \(yamlQuote(meeting.title))")
            lines.append("daisy_event_start: \(iso(meeting.startDate))")
            if let platform = meeting.meetingPlatform {
                lines.append("daisy_event_platform: \(platform)")
            }
            // Attendees from the EKEvent — powers the
            // "Speaker A → Alex" mapping UI in SessionDetailView.
            if !meeting.attendees.isEmpty {
                let quoted = meeting.attendees.map(yamlQuote).joined(separator: ", ")
                lines.append("daisy_event_attendees: [\(quoted)]")
            }
            // Empty placeholder — user fills via Detail view; we
            // upsert this same key when they pick a mapping.
            lines.append("daisy_speaker_map: {}")
        }
        lines.append("tags: [meeting, transcript, daisy]")
        lines.append("---")
        lines.append("")
        lines.append("# \(session.title)")
        lines.append("")

        if let started = session.startedAt {
            lines.append("> recorded \(humanDate(started)) · \(formatDuration(session.elapsed))")
            lines.append("")
        }

        // AI summary, if available. Three sections: meeting overview,
        // next actions, and a ready-to-send follow-up for client /
        // partner.
        if let summary = session.summarizer.lastSummary {
            lines.append("## Summary")
            lines.append("")
            lines.append("### Meeting")
            lines.append("")
            lines.append(summary.summary)
            lines.append("")
            if !summary.actionItems.isEmpty {
                lines.append("### Next actions")
                lines.append("")
                for item in summary.actionItems {
                    lines.append("- [ ] \(item)")
                }
                lines.append("")
            }
            if !summary.clientFollowUp.isEmpty {
                lines.append("### Follow-up for client / partner")
                lines.append("")
                lines.append(summary.clientFollowUp)
                lines.append("")
            }
        }

        // Screenshots gallery, if any.
        let shots = session.screenshots.screenshotURLs
        if !shots.isEmpty {
            lines.append("## Screenshots")
            lines.append("")
            for url in shots {
                lines.append("![\(url.lastPathComponent)](\(url.path))")
                lines.append("")
            }
        }

        lines.append("## Transcript")
        lines.append("")

        let origin = session.startedAt ?? Date()
        for segment in session.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let offset = max(0, segment.startedAt.timeIntervalSince(origin))
            let prefix = "**[\(formatDuration(offset)) · \(segment.speakerLabel)]**"
            lines.append("\(prefix) \(text)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Save flow

    @MainActor
    static func saveWithPanel(session: RecordingSession) -> URL? {
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename(for: session)
        panel.title = "Save Transcript"
        panel.message = "Choose where to save the meeting transcript (e.g. your Obsidian vault)."

        if let lastFolder = restoreLastFolder() {
            panel.directoryURL = lastFolder
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        rememberFolder(url.deletingLastPathComponent())

        let markdown = renderMarkdown(session: session)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            log.info("Saved transcript to \(url.path, privacy: .public)")
            return url
        } catch {
            log.error("Failed to write transcript: \(error.localizedDescription, privacy: .public)")
            NSAlert.daisyError("Couldn't save transcript", error.localizedDescription)
            return nil
        }
    }

    /// Copy the rendered markdown to the system pasteboard. Handy when the
    /// user wants to drop it straight into Claude or Notion.
    @MainActor
    static func copyToClipboard(session: RecordingSession) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(renderMarkdown(session: session), forType: .string)
    }

    // MARK: - Folder bookmark (security-scoped)

    private static func rememberFolder(_ folder: URL) {
        do {
            let data = try folder.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: lastFolderBookmarkKey)
        } catch {
            log.error("Bookmark save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func restoreLastFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: lastFolderBookmarkKey) else {
            return nil
        }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    // MARK: - Formatting helpers

    private static func suggestedFilename(for session: RecordingSession) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = f.string(from: session.startedAt ?? Date())
        let safeTitle = session.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(safeTitle).md"
    }

    nonisolated private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    nonisolated private static func humanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    nonisolated private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    nonisolated private static func yamlQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

extension NSAlert {
    @MainActor
    static func daisyError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
