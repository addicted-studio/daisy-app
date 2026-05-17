//
//  ContentView.swift
//  Daisy
//
//  Main popover view. Title, locale, record button, live transcript with
//  source labels (you / system), Apple Intelligence summary card, export
//  controls (Save .md, Copy, Send to Notion / Claude), settings.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var session: RecordingSession
    @Environment(\.openWindow) private var openWindow

    @State private var lastSavedURL: URL?
    @State private var lastNotionURL: URL?
    @State private var sendError: String?
    @State private var notionSending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCard
                    transcriptList
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            errorBanner
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if session.localeIdentifier.isEmpty {
                session.localeIdentifier = "auto"
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Daisy")
                    .font(.headline)
                Text("· local meeting capture")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                LocalePicker(localeIdentifier: $session.localeIdentifier)
                    .disabled(session.status == .recording || session.status == .summarizing)
            }

            TextField("Meeting title", text: $session.title, prompt: Text("Untitled meeting"))
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium))

            statusRow
            recordButton
        }
        .padding(16)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusDot
            Text(statusLabel)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if session.status == .recording || session.status == .finished || session.status == .summarizing {
                Text(formatTime(session.elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .scaleEffect(pulseScale)
            .animation(.easeOut(duration: 0.18), value: session.levelDB)
    }

    private var pulseScale: CGFloat {
        guard session.status == .recording else { return 1 }
        let normalized = max(0, min(1, (CGFloat(session.levelDB) + 60) / 60))
        return 1.0 + normalized * 0.6
    }

    private var statusColor: Color {
        switch session.status {
        case .idle: return .daisyTextTertiary
        case .preparing, .stopping: return .daisyWarning
        case .recording: return .daisyRecording
        case .summarizing: return .daisyWarning
        case .finished: return .daisySuccess
        case .failed: return .daisyError
        }
    }

    private var statusLabel: String {
        switch session.status {
        case .idle: return "Ready"
        case .preparing:
            // Surface the underlying Whisper load state so the user
            // knows what they're waiting on (mostly a slow download).
            switch WhisperEngine.shared.state {
            case .downloading(let progress):
                return "Downloading Whisper model… \(Int(progress * 100))%"
            case .loading(let status):
                return status
            default:
                return "Preparing…"
            }
        case .recording: return "Recording locally · on-device transcription"
        case .stopping: return "Stopping…"
        case .summarizing: return "Apple Intelligence is summarizing…"
        case .finished: return "Done"
        case .failed(let msg): return msg
        }
    }

    // MARK: - Record button

    private var recordButton: some View {
        Button {
            handlePrimaryAction()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: primaryIcon)
                Text(primaryLabel).fontWeight(.medium)
                Spacer()
                Text("Space")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(primaryTint.opacity(0.16))
            .foregroundStyle(primaryTint)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(disablePrimary)
    }

    private var primaryLabel: String {
        switch session.status {
        case .recording: return "Stop"
        case .preparing: return "Asking…"
        case .stopping: return "Stopping…"
        case .summarizing: return "Summarizing…"
        default: return "Record"
        }
    }

    private var primaryIcon: String {
        switch session.status {
        case .recording: return "stop.fill"
        case .summarizing: return "sparkles"
        case .preparing, .stopping: return "hourglass"
        default: return "record.circle"
        }
    }

    private var primaryTint: Color {
        switch session.status {
        case .recording: return .daisyRecording
        case .summarizing: return .daisyWarning
        case .preparing, .stopping: return .secondary
        default: return .accentColor
        }
    }

    private var disablePrimary: Bool {
        switch session.status {
        case .preparing, .stopping, .summarizing: return true
        default: return false
        }
    }

    // MARK: - Summary card

    @ViewBuilder
    private var summaryCard: some View {
        if let summary = session.summarizer.lastSummary {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("Summary")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("On-device")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }

                Text(summary.summary)
                    .font(.callout)
                    .textSelection(.enabled)

                if !summary.actionItems.isEmpty {
                    listSection(title: "Action items", items: summary.actionItems, symbol: "checkmark.circle")
                }
                if !summary.decisions.isEmpty {
                    listSection(title: "Decisions", items: summary.decisions, symbol: "flag")
                }
                if !summary.followUps.isEmpty {
                    listSection(title: "Follow-ups", items: summary.followUps, symbol: "questionmark.circle")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.purple.opacity(0.25), lineWidth: 1)
            )
        } else if session.summarizer.isSummarizing {
            HStack {
                ProgressView().controlSize(.small)
                Text("Summarizing locally…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func listSection(title: String, items: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                    Text(item)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !session.segments.isEmpty {
                    Text("\(filteredSegments.count) line\(filteredSegments.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if filteredSegments.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredSegments) { segment in
                            SegmentRow(segment: segment, origin: session.startedAt ?? Date())
                                .id(segment.id)
                        }
                    }
                    .onChange(of: session.segments.last?.text) { _, _ in
                        if let last = session.segments.last?.id {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredSegments: [TranscriptSegment] {
        session.segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(emptyStateTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Audio and transcription stay on your Mac. Nothing is sent to any server.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyStateTitle: String {
        switch session.status {
        case .recording: return "Listening…"
        case .finished: return "No speech was captured."
        default: return "Press Space or click Record to begin."
        }
    }

    // MARK: - Error banner

    @ViewBuilder
    private var errorBanner: some View {
        if let err = sendError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.daisyError)
                Text(err)
                    .font(.caption)
                    .lineLimit(3)
                Spacer()
                Button {
                    sendError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color.daisyError.opacity(0.08))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                MarkdownExporter.copyToClipboard(session: session)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(!hasSegments)
            .help("Copy markdown to clipboard")

            Button {
                if let url = MarkdownExporter.saveWithPanel(session: session) {
                    lastSavedURL = url
                }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!hasSegments)
            .help("Save .md to a folder (Obsidian vault, etc.)")

            sendMenu

            Spacer()

            if let url = lastSavedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal saved transcript in Finder")
            }

            ellipsisMenu
        }
        .padding(12)
    }

    private var sendMenu: some View {
        Menu {
            Button {
                Task { await sendToNotion() }
            } label: {
                Label("Send to Notion", systemImage: "doc.text")
            }
            .disabled(notionSending)

            Button {
                let opened = ClaudeExporter.sendToClaude(data: session.exportData())
                if !opened {
                    sendError = "Couldn't find Claude.app — opened claude.ai in browser. Press ⌘V to paste."
                }
            } label: {
                Label("Send to Claude", systemImage: "sparkles")
            }
        } label: {
            HStack(spacing: 4) {
                Text("Send to")
                if notionSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!hasSegments)
    }

    private var ellipsisMenu: some View {
        Menu {
            Button {
                Task { await session.runSummary() }
            } label: {
                Label("Summarize now", systemImage: "sparkles")
            }
            .disabled(!hasSegments || session.summarizer.isSummarizing)

            Button {
                AppNavigation.shared.section = .history
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Transcript history…", systemImage: "list.bullet.rectangle")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button {
                AppNavigation.shared.section = .settings
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Button("New session", role: .destructive) {
                session.reset()
                lastSavedURL = nil
                lastNotionURL = nil
                sendError = nil
            }
            .disabled(session.status == .recording)

            Divider()

            Button("Quit Daisy") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var hasSegments: Bool {
        session.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
        switch session.status {
        case .recording:
            Task { await session.stop() }
        default:
            Task { await session.start() }
        }
    }

    private func sendToNotion() async {
        notionSending = true
        sendError = nil
        do {
            let url = try await NotionExporter.shared.createMeetingPage(session.exportData())
            lastNotionURL = url
            NSWorkspace.shared.open(url)
        } catch {
            sendError = error.localizedDescription
        }
        notionSending = false
    }

    private func formatTime(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Subviews

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let origin: Date

    var body: some View {
        let offset = max(0, segment.startedAt.timeIntervalSince(origin))
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatOffset(offset))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                sourceBadge
            }
            .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.text)
                    .font(.callout)
                    .foregroundStyle(segment.isFinal ? .primary : .secondary)
                    .textSelection(.enabled)
                if !segment.isFinal && !segment.text.isEmpty {
                    Text("…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var sourceBadge: some View {
        Text(segment.speakerLabel.lowercased())
            .font(.caption2.weight(.medium))
            .foregroundStyle(sourceColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(sourceColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }

    private var sourceColor: Color {
        switch segment.source {
        case .microphone: return .blue
        case .systemAudio: return .green
        }
    }

    private func formatOffset(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let m = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", m, sec)
    }
}

private struct LocalePicker: View {
    @Binding var localeIdentifier: String

    var body: some View {
        Menu {
            ForEach(Transcriber.availableLocales, id: \.id) { item in
                Button {
                    localeIdentifier = item.id
                } label: {
                    HStack {
                        Text(item.label)
                        if item.id == localeIdentifier {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text(currentLabel)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentLabel: String {
        Transcriber.availableLocales.first(where: { $0.id == localeIdentifier })?.label ?? localeIdentifier
    }
}

#Preview {
    ContentView(session: RecordingSession(settings: AppSettings()))
        .frame(width: 420, height: 580)
}
