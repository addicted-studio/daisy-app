//
//  SessionDetailView.swift
//  Daisy
//
//  Detail pane in the History window. Shows summary (if any), full
//  transcript text, screenshots gallery, and actions: re-summarize via
//  the current provider, export markdown, send to Notion / Claude,
//  reveal in Finder, or delete.
//

import SwiftUI
import AppKit

struct SessionDetailView: View {
    let session: StoredSession

    @State private var isRunningAction = false
    @State private var actionStatus: ActionStatus = .idle
    @State private var confirmDelete = false

    enum ActionStatus: Equatable {
        case idle
        case message(String)
        case error(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !actionStatusText.isEmpty { actionBanner }
                if let summary = session.summary { summarySection(summary) }
                if session.hasScreenshots { screenshotsSection }
                transcriptSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Action buttons live in the window toolbar's trailing zone,
        // at the same vertical level as the Daisy brand pill on the
        // leading side. macOS 26 Liquid Glass wraps each ToolbarItem
        // in its own pill automatically — visual grammar matches the
        // Daisy mark + title pill on the left.
        .toolbar { detailToolbar }
        .alert("Delete this session?",
               isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSession() }
            }
        } message: {
            Text("Audio, transcript, summary and screenshots will be removed from disk. This can't be undone.")
        }
    }

    // MARK: - Toolbar items (top-right corner of window)

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                attemptReSummarize()
            } label: {
                toolbarIcon("sparkles")
            }
            .buttonStyle(.borderless)
            .help("Re-summarize via current provider")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                attemptCopyMarkdown()
            } label: {
                toolbarIcon("doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy markdown to clipboard")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Menu {
                    ForEach(FolderStore.shared.allFolders) { f in
                        Button {
                            Task { await moveTo(folder: f) }
                        } label: {
                            if f.slug == session.folderSlug {
                                Label(f.name, systemImage: "checkmark")
                            } else {
                                Text(f.name)
                            }
                        }
                    }
                } label: {
                    Label("Move to folder…", systemImage: "folder")
                }
                Divider()
                Button {
                    Task { await sendToNotion() }
                } label: {
                    Label("Send to Notion", systemImage: "doc.text")
                }
                Button {
                    sendToClaude()
                } label: {
                    Label("Send to Claude", systemImage: "sparkles")
                }
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.directoryURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                toolbarIcon("ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // Menu in macOS 26 toolbar inherits `.tint` colour for
            // its label glyph — bypasses Image.foregroundStyle. Pin
            // the tint locally so the ellipsis matches the other
            // toolbar icons instead of going orange via inherited
            // accent.
            .tint(Color.daisyTextPrimary)
        }
    }

    // MARK: - Action attempts (with toast feedback)

    /// Wraps reSummarize with pre-condition checks. When click
    /// can't proceed (no transcript / no provider), shows a toast
    /// so the user sees explicit feedback instead of a dead-button
    /// no-op.
    private func attemptReSummarize() {
        if isRunningAction {
            ToastCenter.shared.show("Already running — wait a moment", style: .info)
            return
        }
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show("No transcript to summarize yet", style: .warning)
            return
        }
        Task { await reSummarize() }
    }

    private func attemptCopyMarkdown() {
        guard !session.transcriptText.isEmpty,
              session.transcriptURL != nil else {
            ToastCenter.shared.show("No transcript on disk yet", style: .warning)
            return
        }
        copyMarkdown()
        ToastCenter.shared.show("Transcript copied to clipboard", style: .success)
    }

    /// Uniform toolbar icon. `Color.daisyTextPrimary` is an explicit
    /// black/cream-warm depending on appearance — bypasses macOS 26's
    /// Liquid Glass tint inheritance that was washing the icons into
    /// inconsistent grays. `.symbolRenderingMode(.monochrome)` kills
    /// SF Symbols' default multicolor on `sparkles`. Horizontal
    /// padding gives the auto-fitted Liquid Glass pill breathing
    /// room around the glyph instead of hugging the edge.
    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.daisyTextPrimary)
            .font(.body.weight(.medium))
            // Lateral padding gives the auto-fitted Liquid Glass pill
            // breathing room around the glyph instead of hugging the
            // edge. Bumped from 4 → 10 so the leftmost and rightmost
            // icons aren't kissing the capsule border.
            .padding(.horizontal, 10)
    }

    // MARK: - Header (title + metadata; actions live in toolbar)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(formattedDate)
                Text("·")
                Text(formattedDuration)
                Text("·")
                Text(session.locale.uppercased())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                if session.hasSystemAudio {
                    Label("System audio", systemImage: "speaker.wave.2")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }


    // MARK: - Summary

    private func summarySection(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Color.daisyAccent)
                Text("Summary").font(.headline)
            }
            Text(summary.summary)
                .font(.callout)
                .textSelection(.enabled)

            if !summary.actionItems.isEmpty {
                listBlock(title: "Action items", items: summary.actionItems)
            }
            if !summary.decisions.isEmpty {
                listBlock(title: "Decisions", items: summary.decisions)
            }
            if !summary.followUps.isEmpty {
                listBlock(title: "Follow-ups", items: summary.followUps)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.daisyAccent.opacity(0.18), lineWidth: 1)
        )
    }

    private func listBlock(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(item).font(.callout).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Screenshots

    private var screenshotsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
                Text("Screenshots").font(.headline)
                Text("(\(session.screenshotURLs.count))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.screenshotURLs, id: \.self) { url in
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.2)
                        }
                        .frame(width: 160, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture(count: 2) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                Text("Transcript").font(.headline)
            }

            speakerMappingSection

            if session.transcriptText.isEmpty {
                Text("No transcript text on disk.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(mappedTranscriptText)
                    .font(.system(.callout, design: .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Show "Map speakers" card only when the session was recorded
    /// from a calendar event WITH attendees AND the transcript has
    /// diarized speakers ("Remote A", "Remote B", ...). Without
    /// these conditions, mapping makes no sense.
    @ViewBuilder
    private var speakerMappingSection: some View {
        if !session.meetingAttendees.isEmpty,
           !detectedSpeakerIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(Color.daisyAccent)
                    Text("Map speakers to attendees")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !session.speakerMap.isEmpty {
                        Button("Clear") {
                            Task { await SessionStore.shared.updateSpeakerMap([:], for: session) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.daisyTextSecondary)
                    }
                }
                ForEach(detectedSpeakerIDs, id: \.self) { speakerID in
                    HStack(spacing: 10) {
                        Text("Remote \(speakerID)")
                            .font(.callout.weight(.medium))
                            .frame(width: 96, alignment: .leading)
                            .foregroundStyle(Color.daisyTextSecondary)
                        Menu(session.speakerMap[speakerID] ?? "Pick attendee…") {
                            Button("Unmapped") {
                                Task { await applyMapping(speakerID: speakerID, name: nil) }
                            }
                            Divider()
                            ForEach(session.meetingAttendees, id: \.self) { name in
                                Button(name) {
                                    Task { await applyMapping(speakerID: speakerID, name: name) }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.daisyAccent.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.daisyAccent.opacity(0.18), lineWidth: 0.5)
            )
        }
    }

    /// Speaker IDs ("A", "B", "C") that appear in the transcript body.
    /// Extracted from `[Remote A]` / `[Remote B]` markers — same
    /// format `MarkdownExporter` writes via `TranscriptSegment.speakerLabel`.
    private var detectedSpeakerIDs: [String] {
        let pattern = #/\bRemote\s+([A-Z])\b/#
        var seen: Set<String> = []
        for match in session.transcriptText.matches(of: pattern) {
            seen.insert(String(match.1))
        }
        return seen.sorted()
    }

    /// Substitute "Remote A" → mapped name inline. The on-disk .md
    /// stays in canonical "Remote A" form so the mapping is fully
    /// re-pluggable (just edit `daisy_speaker_map:` in frontmatter).
    private var mappedTranscriptText: String {
        guard !session.speakerMap.isEmpty else { return session.transcriptText }
        var text = session.transcriptText
        for (speakerID, name) in session.speakerMap {
            text = text.replacingOccurrences(
                of: "Remote \(speakerID)",
                with: name
            )
        }
        return text
    }

    private func applyMapping(speakerID: String, name: String?) async {
        var updated = session.speakerMap
        if let name {
            updated[speakerID] = name
        } else {
            updated.removeValue(forKey: speakerID)
        }
        await SessionStore.shared.updateSpeakerMap(updated, for: session)
    }

    // MARK: - Status banner

    @ViewBuilder
    private var actionBanner: some View {
        let isError: Bool = {
            if case .error = actionStatus { return true }
            return false
        }()
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.daisyError : Color.daisySuccess)
            Text(actionStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
            Button {
                actionStatus = .idle
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            (isError ? Color.daisyError : Color.daisySuccess).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private var actionStatusText: String {
        switch actionStatus {
        case .idle: return ""
        case .message(let m), .error(let m): return m
        }
    }

    // MARK: - Actions

    private func moveTo(folder: SessionFolder) async {
        isRunningAction = true
        actionStatus = .message("Moving to \(folder.name)…")
        await SessionStore.shared.moveSession(session, to: folder)
        actionStatus = .message("Moved to \(folder.name)")
        isRunningAction = false
    }

    private func reSummarize() async {
        guard !session.transcriptText.isEmpty else { return }
        isRunningAction = true
        actionStatus = .message("Summarizing via \(Summarizer.shared.providerKind.shortName)…")

        await Summarizer.shared.summarize(
            transcript: session.transcriptText,
            title: session.title,
            localeHint: session.locale == "auto" ? nil : session.locale
        )

        if let err = Summarizer.shared.lastError {
            actionStatus = .error(err)
        } else if let summary = Summarizer.shared.lastSummary {
            await SessionStore.shared.updateSummary(summary, for: session)
            actionStatus = .message("Summary updated.")
        } else {
            actionStatus = .error("No summary returned.")
        }
        isRunningAction = false
    }

    private func copyMarkdown() {
        guard let url = session.transcriptURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            actionStatus = .error("Couldn't read transcript file.")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        actionStatus = .message("Markdown copied to clipboard.")
    }

    private func sendToNotion() async {
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show("No transcript to send", style: .warning)
            return
        }
        if !AppSettings.notionConfigured {
            ToastCenter.shared.show("Set Notion token in Settings first", style: .warning)
            return
        }
        isRunningAction = true
        ToastCenter.shared.show("Sending to Notion…", style: .info)
        let data = exportData()
        do {
            let url = try await NotionExporter.shared.createMeetingPage(data)
            ToastCenter.shared.show("Notion page created", style: .success)
            NSWorkspace.shared.open(url)
        } catch {
            ToastCenter.shared.show("Notion: \(error.localizedDescription)", style: .error)
        }
        isRunningAction = false
    }

    private func sendToClaude() {
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show("No transcript to send", style: .warning)
            return
        }
        let opened = ClaudeExporter.sendToClaude(data: exportData())
        if opened {
            ToastCenter.shared.show("Prompt copied — switch to Claude and ⌘V", style: .success)
        } else {
            ToastCenter.shared.show("Prompt copied — claude.ai opened", style: .success)
        }
    }

    private func deleteSession() async {
        await SessionStore.shared.delete(session)
        // SwiftUI will pop us back to the empty state when the session
        // disappears from the store.
    }

    /// Build a MeetingExportData snapshot from this stored session so we
    /// can reuse the existing Notion + Claude exporters.
    private func exportData() -> MeetingExportData {
        let chunks = Self.chunkTranscript(session.transcriptText)
        return MeetingExportData(
            title: session.title,
            summary: session.summary,
            transcriptChunks: chunks,
            durationSeconds: session.durationSec,
            locale: session.locale,
            startedAt: session.startedAt
        )
    }

    private static func chunkTranscript(_ text: String) -> [String] {
        let limit = 1500
        var chunks: [String] = []
        var current = ""
        for paragraph in text.split(separator: "\n\n", omittingEmptySubsequences: true) {
            let line = String(paragraph)
            if current.count + line.count + 2 > limit {
                if !current.isEmpty { chunks.append(current) }
                current = line
            } else {
                current = current.isEmpty ? line : "\(current)\n\n\(line)"
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Formatting

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: session.startedAt)
    }

    private var formattedDuration: String {
        let total = max(0, session.durationSec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
