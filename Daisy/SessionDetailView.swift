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
        // macOS 26: ToolbarItemGroup renders the contained items inside
        // ONE shared Liquid Glass capsule. Symmetry on the leading and
        // trailing edges comes from (a) uniform horizontal padding per
        // icon in `toolbarIcon(_:)` and (b) `.fixedSize()` on the
        // ellipsis Menu to collapse the hidden chevron's phantom width.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                attemptReSummarize()
            } label: {
                toolbarIcon("sparkles")
            }
            .buttonStyle(.borderless)
            .help("Re-summarize via current provider")

            Button {
                attemptCopyMarkdown()
            } label: {
                toolbarIcon("doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy markdown to clipboard")

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
                mcpIntegrationsMenuItems
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
            .fixedSize()
            // Padding INSIDE the Menu label is eaten by Menu's
            // own size measurement (the previous attempt put it
            // on `toolbarIcon` directly and didn't survive).
            // Applying it OUTSIDE the Menu, after `.fixedSize()`,
            // pushes the entire Menu view inward from its
            // ToolbarItemGroup slot — which is the gap we actually
            // see on screen. 16pt overshoots the phantom chevron
            // (~12pt) by a few points so the visible gap matches
            // the 12pt sparkles has on the leading side.
            .padding(.trailing, 16)
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
    /// User-configured MCP integrations — one menu item per enabled
    /// integration. Empty when the user hasn't set anything up;
    /// nothing renders in that case (no spacer Divider).
    @ViewBuilder
    private var mcpIntegrationsMenuItems: some View {
        let store = MCPIntegrationStore.shared
        let enabled = store.enabledIntegrations
        if !enabled.isEmpty {
            Divider()
            ForEach(enabled) { integration in
                Button {
                    Task { await MCPDispatcher.send(integration, for: session) }
                } label: {
                    Label("Send to \(integration.name)", systemImage: "paperplane")
                }
            }
        }
    }

    /// One toolbar glyph. Uniform 6pt horizontal padding on every
    /// icon, full stop — the shared Liquid Glass capsule supplies its
    /// own inner inset on top of this, so each icon ends up with the
    /// same gap to the pill edge whether it's leading, middle, or
    /// trailing. Earlier `outerEdge` asymmetric padding only existed
    /// to compensate for the `Menu` chevron's phantom reservation;
    /// that's now handled at the call-site via `.fixedSize()`.
    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.daisyTextPrimary)
            .font(.body.weight(.medium))
            // 12pt mirrors the brand pill in `MainView.swift:118`
            // (its comment: "bumped from 6 → 12 so the mark +
            // wordmark have room from the pill's left and right
            // edges instead of hugging them"). 6pt was producing
            // the exact same "icons hug the capsule edge" symptom
            // the brand pill fix was originally written to solve.
            .padding(.horizontal, 12)
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

    // Summary sections rendered as a plain MD-style document — no
    // coloured AI card, no sparkles header, no border. The user reads
    // this like a normal write-up: H2 heading, body text, bullets.
    // Each section is independent so the gestalt is "one document"
    // rather than "a feature card".
    @ViewBuilder
    private func summarySection(_ summary: MeetingSummary) -> some View {
        mdSection(title: "Meeting") {
            Text(summary.summary)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !summary.actionItems.isEmpty {
            mdSection(title: "Next actions") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "square")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                            Text(item)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        if !summary.clientFollowUp.isEmpty {
            mdSection(title: "Follow-up for client / partner") {
                HStack(alignment: .top, spacing: 8) {
                    Text(summary.clientFollowUp)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary.clientFollowUp, forType: .string)
                        ToastCenter.shared.show("Follow-up draft copied", style: .success)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy the draft message")
                }
            }
        }
    }

    /// Document-style section: H2-weight heading, hairline rule under
    /// it, body content. Used for Meeting / Next actions / Follow-up /
    /// Transcript so the whole detail view reads as a single MD doc.
    @ViewBuilder
    private func mdSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.daisyTextPrimary)
                Rectangle()
                    .fill(Color.daisyDivider)
                    .frame(height: 0.5)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Screenshots

    private var screenshotsSection: some View {
        mdSection(title: "Screenshots (\(session.screenshotURLs.count))") {
            screenshotStrip
        }
    }

    private var screenshotStrip: some View {
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

    // MARK: - Transcript

    private var transcriptSection: some View {
        mdSection(title: "Transcript") {
            VStack(alignment: .leading, spacing: 12) {
                speakerMappingSection

                if session.transcriptText.isEmpty {
                    Text("No transcript text on disk.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(mappedTranscriptText)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
