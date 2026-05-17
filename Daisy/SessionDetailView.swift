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

    // MARK: - Header (inline, with right-aligned actions)

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
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
            Spacer(minLength: 12)
            headerActions
        }
    }

    /// Right-aligned action cluster — used to be in `.toolbar`, but
    /// nested NavigationSplitView merges toolbars across panes and
    /// the buttons end up cramped next to the session-list title.
    /// Inline header puts them where they belong: right edge of the
    /// detail column itself.
    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await reSummarize() }
            } label: {
                Image(systemName: "sparkles")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(isRunningAction || session.transcriptText.isEmpty)
            .help("Re-summarize via current provider")

            Button {
                copyMarkdown()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Copy markdown")

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
                Image(systemName: "ellipsis")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            )
            .disabled(isRunningAction)
        }
    }

    // MARK: - Summary

    private func summarySection(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
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
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.purple.opacity(0.18), lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                Text("Transcript").font(.headline)
            }
            if session.transcriptText.isEmpty {
                Text("No transcript text on disk.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(session.transcriptText)
                    .font(.system(.callout, design: .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
                .foregroundStyle(isError ? .orange : .green)
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
        isRunningAction = true
        actionStatus = .message("Sending to Notion…")
        let data = exportData()
        do {
            let url = try await NotionExporter.shared.createMeetingPage(data)
            actionStatus = .message("Created Notion page — opening in browser.")
            NSWorkspace.shared.open(url)
        } catch {
            actionStatus = .error(error.localizedDescription)
        }
        isRunningAction = false
    }

    private func sendToClaude() {
        let opened = ClaudeExporter.sendToClaude(data: exportData())
        if opened {
            actionStatus = .message("Prompt copied. Switch to Claude and press ⌘V.")
        } else {
            actionStatus = .message("Prompt copied. Opened claude.ai — press ⌘V.")
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
