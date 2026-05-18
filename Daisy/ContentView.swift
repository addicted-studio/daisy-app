//
//  ContentView.swift
//  Daisy
//
//  Main popover view. Title field with calendar event picker, locale,
//  record button (badge shows the configured global hotkey), live
//  transcript with source labels (you / system), Apple Intelligence
//  summary card, export controls (Copy markdown / Send to Notion or
//  Claude), kebab for history / settings / reveal-in-Finder. The
//  transcript auto-saves to the session folder on stop — there is no
//  Save button.
//

import SwiftUI
import AppKit
import EventKit

struct ContentView: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    @State private var lastNotionURL: URL?
    @State private var sendError: String?
    @State private var notionSending = false
    /// Calendar event the user picked for this session, if any. Sent
    /// to `session.startFromMeeting(_:)` so the transcript markdown
    /// carries the event binding in its frontmatter.
    @State private var selectedMeeting: DaisyMeeting?

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
        .background(Color.daisyBgPrimary)
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
                Spacer()
                LocalePicker(localeIdentifier: $session.localeIdentifier)
                    .disabled(session.status == .recording || session.status == .summarizing)
            }

            HStack(spacing: 6) {
                TextField("Meeting title", text: $session.title, prompt: Text("Untitled meeting"))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.medium))
                meetingPicker
            }

            statusRow
            HStack(spacing: 8) {
                recordButton
                    .frame(maxWidth: .infinity)
                if showsStopButton {
                    stopButton
                }
            }
        }
        .padding(16)
    }

    /// Companion to the primary pause/resume capsule. Visible only
    /// when a session is active (recording or paused) — full stop &
    /// save is destructive (runs final transcribe + summary + writes
    /// markdown) so it gets its own deliberate button rather than
    /// hiding behind the same tap target as pause.
    private var stopButton: some View {
        Button {
            Task { await session.stop() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.callout.weight(.semibold))
                Text("Stop & save")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(Color.daisyTextPrimary)
            .background(
                Capsule(style: .continuous).fill(Color.daisyBgElevated)
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Finish the session: run the final transcribe, save markdown, and (if enabled) summarize.")
    }

    /// Calendar pull-down — lets the user bind this session to an
    /// upcoming event. Selecting prefills the title and tells
    /// `handlePrimaryAction` to use `startFromMeeting(_:)`.
    private var meetingPicker: some View {
        Menu {
            if CalendarService.shared.authorizationStatus != .fullAccess {
                Button {
                    AppNavigation.shared.section = .settings
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Connect Calendar in Settings…", systemImage: "gear")
                }
            } else if upcomingMeetingChoices.isEmpty {
                Text("No upcoming meetings")
            } else {
                if selectedMeeting != nil {
                    Button {
                        selectedMeeting = nil
                        session.title = ""
                    } label: {
                        Label("Clear selection", systemImage: "xmark.circle")
                    }
                    Divider()
                }
                ForEach(upcomingMeetingChoices) { meeting in
                    Button {
                        selectedMeeting = meeting
                        session.title = meeting.title
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(meeting.title)
                                Text(meetingTimeLabel(meeting))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if selectedMeeting?.id == meeting.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: selectedMeeting == nil ? "calendar" : "calendar.badge.checkmark")
                .foregroundStyle(selectedMeeting == nil ? Color.secondary : Color.daisyAccent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(meetingPickerHelp)
        .disabled(session.status == .recording || session.status == .summarizing)
    }

    /// Upcoming events with a meeting URL, capped to the next 6 hours
    /// — anything further out clutters the picker and isn't what the
    /// user is about to join right now.
    private var upcomingMeetingChoices: [DaisyMeeting] {
        let now = Date()
        let cutoff = now.addingTimeInterval(6 * 3600)
        return CalendarService.shared.upcomingMeetings
            .filter { $0.startDate <= cutoff && $0.endDate >= now }
    }

    private var meetingPickerHelp: String {
        switch CalendarService.shared.authorizationStatus {
        case .fullAccess:
            return selectedMeeting == nil
                ? "Bind this recording to an upcoming calendar event"
                : "Selected: \(selectedMeeting?.title ?? "")"
        default:
            return "Connect Calendar to bind recordings to events"
        }
    }

    private func meetingTimeLabel(_ meeting: DaisyMeeting) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        let start = f.string(from: meeting.startDate)
        let mins = Int(meeting.startDate.timeIntervalSinceNow / 60)
        if mins > 60 {
            return "\(start) · in \(mins / 60)h \(mins % 60)m"
        } else if mins > 0 {
            return "\(start) · in \(mins)m"
        } else if mins > -60 {
            return "\(start) · now"
        } else {
            return "\(start) · started \(-mins)m ago"
        }
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
        case .paused: return .daisyPaused
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
        case .paused: return "Paused · capture stopped, session held"
        case .stopping: return "Stopping…"
        case .summarizing: return "Apple Intelligence is summarizing…"
        case .finished: return "Done"
        case .failed(let msg): return msg
        }
    }

    // MARK: - Record button

    /// Solid-orange capsule that mirrors the sidebar `RecordCapsule`
    /// in the main window — same visual grammar (Apple system orange
    /// = mic-active), so the user reads "this is THE record button"
    /// the same way whether they're in the popover or the main app.
    private var recordButton: some View {
        Button {
            handlePrimaryAction()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: primaryIcon)
                    .font(.callout.weight(.semibold))
                Text(primaryLabel)
                    .font(.callout.weight(.medium))
                Spacer()
                if let label = hotkeyBadgeLabel {
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(.white.opacity(0.18))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(
                Capsule(style: .continuous).fill(primaryFill)
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
            .glassEffect(in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disablePrimary)
    }

    /// Configured global hotkey label, or nil if the user disabled it.
    /// The badge inside the Record button mirrors what's in Settings →
    /// Hotkey — the *actual* shortcut, not a hardcoded "Space".
    private var hotkeyBadgeLabel: String? {
        let choice = settings.recordHotkey
        guard choice.keyCode != nil else { return nil }
        return choice.label
    }

    private var primaryLabel: String {
        switch session.status {
        case .recording: return "Pause"
        case .paused: return "Resume"
        case .preparing: return "Preparing…"
        case .stopping:  return "Stopping…"
        case .summarizing: return "Summarizing…"
        default:         return "Record"
        }
    }

    private var primaryIcon: String {
        switch session.status {
        case .recording: return "pause.fill"
        case .paused: return "play.fill"
        case .summarizing: return "sparkles"
        case .preparing, .stopping: return "hourglass"
        default: return "record.circle"
        }
    }

    /// Solid capsule fill. Colour signals what happens ON CLICK,
    /// not the current state:
    ///   • Recording → the button reads "Pause"; clicking it puts
    ///     the session into a calm paused state, so the button itself
    ///     is grey (no urgency to act).
    ///   • Paused → the button reads "Resume"; clicking it re-enters
    ///     active recording, so the button is orange (warm, the
    ///     recording dot is about to come back).
    /// Start (idle) and resting / unknown states default to orange,
    /// matching `RecordCapsule.fill` in the main sidebar so the
    /// primary CTA reads as one consistent control.
    private var primaryFill: Color {
        switch session.status {
        case .recording: return .daisyPaused
        case .paused:    return .daisyRecording
        case .summarizing, .preparing, .stopping: return Color.gray.opacity(0.55)
        case .failed: return .daisyError
        default: return .daisyRecording
        }
    }

    private var disablePrimary: Bool {
        switch session.status {
        case .preparing, .stopping, .summarizing: return true
        default: return false
        }
    }

    /// Whether the popover shows the Stop & save button alongside
    /// the primary pause/resume control. Visible during an active
    /// session (recording OR paused) — full finalize is destructive
    /// so it lives outside the click-to-toggle widget.
    private var showsStopButton: Bool {
        switch session.status {
        case .recording, .paused: return true
        default: return false
        }
    }

    // MARK: - Summary (MD-document style)
    //
    // No coloured "AI" card, no sparkles header, no provider badge —
    // the summary reads as plain document sections so it sits naturally
    // above the transcript and feels like one working write-up.

    @ViewBuilder
    private var summaryCard: some View {
        if let summary = session.summarizer.lastSummary {
            VStack(alignment: .leading, spacing: 16) {
                mdSection(title: "Meeting") {
                    Text(summary.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !summary.actionItems.isEmpty {
                    mdSection(title: "Next actions") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "square")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(item)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                if !summary.clientFollowUp.isEmpty {
                    mdSection(title: "Follow-up for client / partner") {
                        HStack(alignment: .top, spacing: 6) {
                            Text(summary.clientFollowUp)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(summary.clientFollowUp, forType: .string)
                                ToastCenter.shared.show("Follow-up draft copied", style: .success)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Copy the draft message")
                        }
                    }
                }
            }
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

    /// MD-style section header: H3 weight + hairline divider. Mirrors
    /// `mdSection` in SessionDetailView so the popover and the main
    /// window read with the same typographic grammar.
    @ViewBuilder
    private func mdSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.daisyTextPrimary)
                Rectangle()
                    .fill(Color.daisyDivider)
                    .frame(height: 0.5)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        default:
            if let label = hotkeyBadgeLabel {
                return "Press \(label) or click Record to begin."
            }
            return "Click Record to begin."
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
    //
    // All bottom controls share one visual grammar: `.bordered`
    // capsules, `.regular` control size. Save was removed — sessions
    // auto-persist their transcript.md to the session folder on stop,
    // so an explicit Save was duplicate work the user shouldn't think
    // about. Reveal-in-Finder lives on the kebab now.

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                MarkdownExporter.copyToClipboard(session: session)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(!hasSegments)
            .help("Copy markdown to clipboard")

            sendMenu

            Spacer()

            ellipsisMenu
        }
        // Symmetric padding-12 was leaving the kebab visually flush
        // with the right edge — the bordered chrome on the menu draws
        // a fraction past its hit-rect at the rounded corners, eating
        // perceived breathing room. Bumping trailing to 16 restores
        // the same optical gutter Copy has on the left.
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
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
                Image(systemName: "paperplane")
                Text("Send to")
                if notionSending {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.regular)
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

            if let url = autoSavedTranscriptURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal transcript in Finder", systemImage: "folder")
                }
            }

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
                selectedMeeting = nil
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
            // `Label(..).iconOnly` (vs a bare `Image`) keeps the
            // text-line slot reserved in layout, so the bordered
            // chrome inherits the same intrinsic height as Copy /
            // Send to. The explicit `.frame(width:height:)` below
            // then forces that height onto the *width* as well, so
            // the capsule renders as a square — matching the visual
            // weight of the two sibling pill buttons instead of
            // floating as a wider ellipsis chip.
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .menuIndicator(.hidden)
        // 22pt is the standard height of `.controlSize(.regular)`
        // bordered buttons on macOS 14+. Equal width = square.
        .frame(width: 22, height: 22)
    }

    private var hasSegments: Bool {
        session.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// Path of the auto-saved transcript markdown for the current
    /// session, if it has been written. RecordingSession writes
    /// `transcript.md` next to the audio archive on stop — the kebab
    /// uses this so the user can pop the file open without going
    /// through a Save dialog.
    private var autoSavedTranscriptURL: URL? {
        guard session.status == .finished,
              let dir = session.sessionDirectory else { return nil }
        let url = dir.appendingPathComponent("transcript.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
        switch session.status {
        case .recording:
            session.pause()
        case .paused:
            Task { await session.resume() }
        case .preparing, .stopping, .summarizing:
            return
        case .idle, .finished, .failed:
            if let meeting = selectedMeeting {
                Task { await session.startFromMeeting(meeting) }
            } else {
                Task { await session.start() }
            }
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
    let s = AppSettings()
    ContentView(session: RecordingSession(settings: s), settings: s)
        .frame(width: 420, height: 580)
}
