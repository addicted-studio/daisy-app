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
        // Free-form tag — empty when untagged. History sidebar
        // selector groups by this value. Renamed from `daisy_client`
        // in 1.0.5.2; parser still reads the legacy key for older
        // sessions and replaces with the new key on next edit.
        if !session.tag.isEmpty {
            lines.append("daisy_tag: \(yamlQuote(session.tag))")
        }
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
        }
        // daisy_speaker_map — always written when there's diarization
        // available (regardless of calendar binding). Pre-populated
        // with auto-matched profile names ("Alex" / "Mom") when the
        // SpeakerProfileStore recognized this session's clusters
        // from prior recordings; empty {} otherwise so the
        // SessionDetailView edit path still has somewhere to write.
        if !session.initialSpeakerMap.isEmpty {
            lines.append("daisy_speaker_map: \(yamlInlineDict(session.initialSpeakerMap))")
        } else {
            lines.append("daisy_speaker_map: {}")
        }
        // When a mic route change mid-session forced a format
        // rollover (see AudioRecorder.handleConfigurationChange),
        // the archive is split across `microphone.caf` plus
        // `microphone.part2.caf` (etc) instead of one continuous
        // file. Surface the part list here so the user (and any
        // downstream tooling reading the frontmatter) knows where
        // to find the full audio. Only emit the key when there's
        // actually more than one part — the common case is one
        // file and the frontmatter stays clean.
        let archivedParts = session.archivedAudioParts
        if archivedParts.count > 1 {
            let parts = archivedParts
                .map { yamlQuote($0.lastPathComponent) }
                .joined(separator: ", ")
            lines.append("daisy_audio_parts: [\(parts)]")
        }

        // Persistent audit of system-audio capture outcome. Three
        // states surface support-side debugging:
        //   off       — user had the toggle disabled, mic-only run
        //   captured  — SystemAudioCapture received at least one frame
        //   empty     — toggle on, capture armed, zero frames received
        //               (BT output, denied Screen Recording grant,
        //               or other macOS-side block)
        // When status == empty, the user already saw a warning toast
        // at session end; the frontmatter line is the post-hoc proof
        // for grepping across a folder of sessions.
        let sysAudioLabel: String
        if !session.settings.captureSystemAudio {
            sysAudioLabel = "off"
        } else if session.hasCapturedSystemAudio {
            sysAudioLabel = "captured"
        } else {
            sysAudioLabel = "empty"
        }
        lines.append("daisy_system_audio_status: \(sysAudioLabel)")
        lines.append("tags: [meeting, transcript, daisy]")
        lines.append("---")
        lines.append("")
        lines.append("# \(session.title)")
        lines.append("")

        if let started = session.startedAt {
            lines.append("> recorded \(humanDate(started)) · \(formatDuration(session.elapsed))")
            lines.append("")
        }

        // AI summary, if available. Lede + Granola-style topical
        // outline + flat next-actions checklist + optional follow-up
        // draft for the client / partner. Legacy summaries (pre-
        // 1.0.2) have `sections == []`, in which case the lede
        // carries the full paragraph and the outline block is
        // skipped — preserves the old layout exactly for sessions
        // saved on the previous schema.
        if let summary = session.summarizer.lastSummary {
            // Detect summary language from its content for the
            // structural H3 headers, so a Russian summary saved as
            // transcript.md uses "## Сводка / ### Встреча / ###
            // Следующие шаги" rather than English headers stamped
            // on top of Russian content. The "## Summary" wrapper
            // also follows.
            var sample = summary.summary
            if sample.count < 60, let firstBullet = summary.sections.first?.bullets.first?.text {
                sample += " " + firstBullet
            }
            let labels = SummaryLabels.for(language: LanguageDetector.detect(sample))
            let summaryHeader: String = {
                switch (LanguageDetector.detect(sample) ?? "").lowercased() {
                case "ru": return "Сводка"
                case "uk": return "Зведення"
                case "pl": return "Podsumowanie"
                case "es": return "Resumen"
                case "fr": return "Résumé"
                case "de": return "Zusammenfassung"
                case "it": return "Riepilogo"
                case "pt": return "Resumo"
                case "ja": return "サマリー"
                case "ko": return "요약"
                case "zh": return "摘要"
                default:   return "Summary"
                }
            }()
            lines.append("## \(summaryHeader)")
            lines.append("")
            if !summary.summary.isEmpty {
                lines.append("### \(labels.meeting)")
                lines.append("")
                lines.append(summary.summary)
                lines.append("")
            }
            for section in summary.sections {
                lines.append("### \(section.title)")
                lines.append("")
                appendBullets(section.bullets, level: 0, into: &lines)
                lines.append("")
            }
            if !summary.actionItems.isEmpty {
                lines.append("### \(labels.nextActions)")
                lines.append("")
                for item in summary.actionItems {
                    lines.append("- [ ] \(item)")
                }
                lines.append("")
            }
            if !summary.clientFollowUp.isEmpty {
                lines.append("### \(labels.followUp)")
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
        let myName = session.settings.userDisplayName
        for segment in session.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let offset = max(0, segment.startedAt.timeIntervalSince(origin))
            let label = segment.speakerLabel(displayName: myName)
            let prefix = "**[\(formatDuration(offset)) · \(label)]**"
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
            log.info("Saved transcript to \(url.path, privacy: .private)")
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

    /// Append a Granola-style hierarchical bullet list to the
    /// markdown output. Indentation uses two spaces per level — the
    /// standard CommonMark contract for nested lists, which
    /// Obsidian, Notion, GitHub, and most other renderers respect.
    /// Recursion depth is whatever the prompt produces; in practice
    /// it caps at ~3 levels.
    nonisolated private static func appendBullets(
        _ bullets: [SummaryBullet],
        level: Int,
        into lines: inout [String]
    ) {
        let indent = String(repeating: "  ", count: level)
        for bullet in bullets {
            lines.append("\(indent)- \(bullet.text)")
            if !bullet.children.isEmpty {
                appendBullets(bullet.children, level: level + 1, into: &lines)
            }
        }
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

    /// Render a `[String: String]` as a YAML inline map:
    /// `{"A": "Alex", "B": "Bob"}`. Keys sorted alphabetically so
    /// diffs across runs stay stable (otherwise Codable / dict
    /// iteration order drifts). Format matches what
    /// `SessionStore.parseYAMLDict` already parses on the read
    /// side, so writes round-trip cleanly.
    nonisolated private static func yamlInlineDict(_ dict: [String: String]) -> String {
        if dict.isEmpty { return "{}" }
        let pairs = dict.keys.sorted().map { key in
            "\(yamlQuote(key)): \(yamlQuote(dict[key] ?? ""))"
        }
        return "{\(pairs.joined(separator: ", "))}"
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
