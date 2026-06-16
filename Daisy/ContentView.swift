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

// MARK: - Live transcript autoscroll plumbing

/// True when the bottom of the scrollable content sits within the pin
/// threshold of the visible container bottom — i.e. the user is parked at
/// the newest line. Reduced to a `Bool` so `onPreferenceChange` only fires
/// (and state only flips) on threshold crossings, not on every scroll frame.
private struct PinnedToBottomKey: PreferenceKey {
    static var defaultValue: Bool = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

/// Global-space maxY of the live transcript scroll container, the reference
/// edge for `PinnedToBottomKey`. Changes on layout/resize, not on scroll.
private struct ContainerBottomYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Captures the hosting `NSWindow` of a SwiftUI view — used by the
/// MenuBarExtra popover's close button to `orderOut` itself, since
/// `MenuBarExtra(.window)` exposes no dismissal API of its own.
private struct PopoverWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onResolve(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

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

    /// Live-transcript autoscroll gate. `true` ⇒ stick to the newest line
    /// on each update; flips to `false` when the user scrolls up to read
    /// back, so incoming segments don't yank them down. Driven by
    /// `PinnedToBottomKey` off the sentinel below the transcript.
    @State private var isPinnedToBottom = true
    /// Global-space bottom edge of the transcript scroll container; updated
    /// only on layout/resize (not per scroll frame), feeds the pin predicate.
    @State private var liveContainerBottomY: CGFloat = 0
    /// Hosting NSWindow of the MenuBarExtra popover, captured via
    /// `PopoverWindowAccessor`, so the close button can dismiss it.
    @State private var popoverWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            systemAudioBanner
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCard
                    transcriptList
                    // Sentinel parked at the very bottom of the content.
                    // Its global maxY vs. the container bottom tells us
                    // whether the user is pinned to the latest line. Mapped
                    // straight to a Bool so scrolling within a zone doesn't
                    // churn state — only crossing the 24pt threshold does.
                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: PinnedToBottomKey.self,
                                    value: geo.frame(in: .global).maxY <= liveContainerBottomY + 24
                                )
                            }
                        )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ContainerBottomYKey.self,
                        value: geo.frame(in: .global).maxY
                    )
                }
            )
            .onPreferenceChange(ContainerBottomYKey.self) { liveContainerBottomY = $0 }
            .onPreferenceChange(PinnedToBottomKey.self) { isPinnedToBottom = $0 }
            Divider()
            errorBanner
            footer
            Divider()
            consentReminder
        }
        .background(Color.daisyBgPrimary)
        .background(PopoverWindowAccessor { popoverWindow = $0 })
        .onAppear {
            if session.localeIdentifier.isEmpty {
                session.localeIdentifier = "auto"
            }
        }
        // 2026-05-26 — pull live changes to Settings → Transcription
        // language into the popover while the session is idle. The
        // popover's `LocalePicker` is bound to `session.localeIdentifier`,
        // which is seeded from `settings.defaultTranscriptionLocale`
        // at RecordingSession.init and otherwise serves as a per-
        // session override (popover-driven). Without this onChange,
        // switching the default in Settings → Transcription left the
        // popover still showing the old language, which read as a
        // broken sync. Only mirror when the session is idle / finished
        // / failed — never yank the locale of a live recording.
        //
        // 2026-05-27 — extended to all three locale settings + mode.
        // Pre-fix this only listened to `defaultTranscriptionLocale`,
        // which meant changing the per-mode override in Settings →
        // Voice notes / Dictation didn't pull through to the toolbar
        // even when the session was in that mode. `currentMode`
        // changes also resync because the effective locale depends
        // on mode (voiceNote/dictation read overrides if set, else
        // fall back to default).
        .onChange(of: settings.defaultTranscriptionLocale) { _, _ in syncToolbarLocaleFromSettings() }
        .onChange(of: settings.voiceNoteLocale) { _, _ in syncToolbarLocaleFromSettings() }
        .onChange(of: settings.dictationLocale) { _, _ in syncToolbarLocaleFromSettings() }
        .onChange(of: session.currentMode) { _, _ in syncToolbarLocaleFromSettings() }
    }

    /// Mirror the appropriate settings slot into `session.localeIdentifier`
    /// while the session is idle. Mirrors the same effective-locale
    /// logic `RecordingSession.start()` uses (per-mode override if
    /// set, else default), so the toolbar always shows what the
    /// NEXT Record press will actually use. Never runs during active
    /// capture — we don't yank Whisper's locale mid-stream.
    private func syncToolbarLocaleFromSettings() {
        switch session.status {
        case .idle, .finished, .failed:
            let effective = effectiveLocaleFromSettings()
            if session.localeIdentifier != effective {
                session.localeIdentifier = effective
            }
        case .preparing, .recording, .paused, .stopping, .summarizing:
            break
        }
    }

    /// Resolve the locale identifier that `start()` would pick for
    /// the current mode. Keep in lock-step with the switch in
    /// `RecordingSession.start()` (line ~696) so toolbar + start()
    /// can never disagree.
    private func effectiveLocaleFromSettings() -> String {
        let raw: String
        switch session.currentMode {
        case .meeting:
            raw = settings.defaultTranscriptionLocale
        case .voiceNote:
            raw = settings.voiceNoteLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.voiceNoteLocale
        case .dictation:
            raw = settings.dictationLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.dictationLocale
        }
        return raw.isEmpty ? "auto" : raw
    }

    /// Custom binding for the toolbar `LocalePicker`. Reads
    /// `session.localeIdentifier` so the picker reflects the
    /// session's current effective locale. On write, mirrors the
    /// pick into the matching Settings slot (defaults for meeting,
    /// voiceNoteLocale / dictationLocale for the other modes) so:
    ///   1. The pick survives `start()` — which re-reads from
    ///      Settings and would otherwise clobber a session-only
    ///      override (Egor caught: "наоборот не работает и потом
    ///      язык настроек возвращает язык в тулбаре", 2026-05-27).
    ///   2. The pick shows up next time the user opens Settings →
    ///      Transcription, so the two surfaces are symmetric editors
    ///      of the same value.
    ///   3. The pick survives popover close + reopen (settings are
    ///      persisted via @AppStorage-style `UserDefaults`).
    /// Guard on equality so we don't trigger a `didSet → write`
    /// loop with the `.onChange(of: settings.*)` mirror above.
    private var toolbarLocaleBinding: Binding<String> {
        Binding(
            get: { session.localeIdentifier },
            set: { newValue in
                session.localeIdentifier = newValue
                switch session.currentMode {
                case .meeting:
                    if settings.defaultTranscriptionLocale != newValue {
                        settings.defaultTranscriptionLocale = newValue
                    }
                case .voiceNote:
                    if settings.voiceNoteLocale != newValue {
                        settings.voiceNoteLocale = newValue
                    }
                case .dictation:
                    if settings.dictationLocale != newValue {
                        settings.dictationLocale = newValue
                    }
                }
            }
        )
    }

    // MARK: - Consent reminder

    /// Always-on subtle privacy line at the very top of the popover.
    /// Pattern mirrors Granola's pre-record consent disclaimer (added
    /// 2026 spring as part of an industry-wide consent push driven
    /// by EU/CA regulators).
    ///
    /// Daisy's positioning leans hard on "audio never leaves your
    /// Mac" — but recording other PEOPLE without their knowledge is
    /// still a thing the user (not the app) is responsible for, and
    /// silently shipping a meeting-recorder with zero on-screen
    /// reminder of that responsibility reads as cavalier.
    /// Deliberately NOT dismissible — this is a standing reminder
    /// that lives next to the Record button, not a banner that
    /// "expires" once the user has seen it. Subtle styling (caption
    /// font + secondary foreground + low-contrast cream chip) keeps
    /// it out of the visual hierarchy of actionable controls.
    /// The Learn-more link opens mydaisy.io/privacy in the user's
    /// default browser via NSWorkspace.
    private var consentReminder: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("Always get consent when transcribing others.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                if let url = URL(string: "https://mydaisy.io/privacy") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 2) {
                    Text("Learn more")
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Daisy's privacy notes on mydaisy.io")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.daisyBgSidebar)
    }

    // MARK: - Header

    /// Dismiss the menu-bar popover. `MenuBarExtra(.window)` has no native
    /// close control, so we order out the hosting NSWindow (captured via
    /// `PopoverWindowAccessor`). The menu-bar icon reopens it; recording is
    /// unaffected — the session lives in `RecordingSession`, not this view.
    private var closeButton: some View {
        Button {
            popoverWindow?.orderOut(nil)
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close this window — recording keeps running; reopen from the menu bar")
    }

    /// Error-only system-audio banner for the popover ("toolbar"): shows
    /// when the other side isn't actually being captured (Screen Recording
    /// denied, or no audio reaching Daisy). The main-window sidebar shows
    /// the full pill incl. the green "both sides" state; here we keep it to
    /// errors only so the popover stays clean.
    @ViewBuilder
    private var systemAudioBanner: some View {
        switch session.systemAudioStatus {
        case .denied, .failed:
            // Muted when the user opted out of meeting-permission
            // reminders (Settings → Permissions → "Don't remind me").
            if !settings.suppressMeetingPermissionReminders {
                SystemAudioStatusPill(session: session)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
        default:
            EmptyView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Daisy")
                    .font(.headline)
                Spacer()
                LocalePicker(localeIdentifier: toolbarLocaleBinding)
                    .disabled(session.status == .recording || session.status == .summarizing)
                closeButton
            }

            HStack(spacing: 6) {
                TextField("Meeting title", text: $session.title, prompt: Text("Untitled meeting"))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.medium))
                meetingPicker
            }

            statusRow
            modelDownloadBar
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
        .help("Finish the recording: run the final transcribe, save markdown, and (if enabled) summarize.")
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
                Text("No upcoming events")
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

    /// Upcoming calendar entries within `CalendarService.upcomingWindowSec`
    /// — the SAME window the menu-bar next-meeting label uses, so the
    /// picker can always select whatever the menu bar names. This was 6h
    /// here while the label was 8h, so an event 6–8h out showed in the
    /// menu bar but returned "No upcoming events" in the picker.
    ///
    /// 2026-05-25 — source switched from `upcomingMeetings` (Zoom /
    /// Meet / Teams URL-only filter via `.isMeeting`) → `upcomingEvents`
    /// (all calendar entries). Egor flagged the bug: Home shows
    /// every today's event but the widget popover's picker hid
    /// URL-less ones, returning "No upcoming meetings" when there
    /// were obviously events on the same day (e.g. a "Test" entry
    /// with no Zoom link). Binding is just `session.title =
    /// meeting.title` + a meta tag — no platform-detection
    /// depends on the URL, so the filter was invisible engineering
    /// noise that broke user mental model ("if it's in my calendar
    /// today, let me bind to it").
    private var upcomingMeetingChoices: [DaisyMeeting] {
        let now = Date()
        let cutoff = now.addingTimeInterval(CalendarService.upcomingWindowSec)
        return CalendarService.shared.upcomingEvents
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

    /// Hidden entirely while recording (user feedback 2026-06-12):
    /// the caption is gone, the pulsing dot read as clutter, and the
    /// elapsed timer now lives inside the record button itself — so
    /// an active session has nothing left to say here.
    @ViewBuilder
    private var statusRow: some View {
        // Only surface states the Record button does NOT already convey:
        // model-download progress (preparing), paused context, the
        // summarizer engine, and failures. Recording / idle / stopping /
        // finished are all shown by the button itself, so their status
        // line was pure duplication — Egor 2026-06-16.
        switch session.status {
        case .preparing, .paused, .summarizing, .failed:
            HStack(spacing: 8) {
                statusDot
                Text(statusLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if session.status == .summarizing {
                    Text(formatTime(session.elapsed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        default:
            EmptyView()
        }
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
        // Recording: no caption — the pulsing orange dot + running
        // timer already say it, and "Recording locally · on-device
        // transcription" was privacy-pitch noise on every session
        // (user feedback 2026-06-12). The consent footer keeps the
        // privacy message.
        case .recording: return ""
        case .paused: return "Paused · capture stopped, session held"
        case .stopping: return "Stopping…"
        case .summarizing: return "Apple Intelligence is summarizing…"
        case .finished: return "Done"
        case .failed(let msg): return msg
        }
    }

    /// Thin determinate bar under the status row while a speech model
    /// downloads — the visual counterpart to the "Downloading … NN%"
    /// status text, which only appears while `.preparing`; the big
    /// first-launch Whisper download mostly runs while the session is
    /// still idle and the label just says "Ready". Same engine-priority
    /// logic as the sidebar's `ModelDownloadPill` (via
    /// `ModelLoadActivity`, defined in MainView.swift). The brief
    /// `.loading` CoreML-init phase has no meaningful fraction → no
    /// bar; the status text covers it. Reading the `@Observable`
    /// engine state here re-renders the popover as progress ticks —
    /// no timers.
    @ViewBuilder
    private var modelDownloadBar: some View {
        switch ModelLoadActivity.current(settings: settings) {
        case .checking?:
            // Cache-check / repo-resolve phase — no meaningful
            // fraction yet, indeterminate bar (matches the sidebar
            // pill's "Checking models…" state).
            ProgressView(value: nil, total: 1.0)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(Color.daisyAccent)
                .help("Checking speech models…")
        case .downloading(let progress)?:
            ProgressView(value: min(max(progress, 0), 1), total: 1.0)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(Color.daisyAccent)
                .help("One-time setup: Daisy transcribes on-device, so the model has to download first.")
        case .loading?, nil:
            EmptyView()
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
                // During an active session the badge slot shows the
                // elapsed timer (moved here from the old status row —
                // user feedback 2026-06-12); when idle it shows the
                // configured hotkey hint. Same chip styling so the
                // button reads as one control either way.
                if session.status == .recording || session.status == .paused {
                    Text(formatTime(session.elapsed))
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(primaryForeground.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(.white.opacity(0.18))
                        )
                } else if let label = hotkeyBadgeLabel {
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(primaryForeground.opacity(0.75))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(.white.opacity(0.18))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(primaryForeground)
            .background(
                Capsule(style: .continuous).fill(primaryFill)
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
            .daisyGlass(in: Capsule(style: .continuous))
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
    /// Start (idle) and resting / unknown states are a warm BEIGE
    /// (`daisyRecordIdle`) — NOT green, NOT the recording orange —
    /// matching `RecordCapsule.fill` in the main sidebar. Orange is
    /// reserved for "mic is (about to be) live"; an orange idle button
    /// read as "already recording" (user feedback, 1.0.7.18). (Was sage
    /// green / daisySuccess through 1.0.7.21 — calm-palette pass 2026-06-15.)
    private var primaryFill: Color {
        switch session.status {
        case .recording: return .daisyPaused
        case .paused:    return .daisyRecording
        case .summarizing, .preparing, .stopping: return Color.gray.opacity(0.55)
        case .failed: return .daisyError
        default: return .daisyRecordIdle
        }
    }

    /// White on sage is ~2:1 — idle/finished switch to near-black
    /// ink (see `RecordCapsule.foreground`); live states stay white.
    private var primaryForeground: Color {
        switch session.status {
        case .idle, .finished: return Color.black.opacity(0.85)
        default: return .white
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
    //
    // 2026-06-12 — the whole textual body (Meeting lede + sections +
    // Next actions + Follow-up, headers included) is ONE attributed
    // string inside ONE NSTextView. Before, every block was its own
    // SwiftUI `Text` and macOS selection can't cross view boundaries —
    // drag-select / ⌘A topped out at a single line (Egor, release
    // blocker). `compact: true` keeps the popover's `.callout`
    // typography and tighter indents (the old homeBulletTree
    // constants); headers are localised inside the builder via the
    // same language sniffing this card used to do inline. See
    // summaryAttributedString(_:compact:) in SelectableTextView.swift.
    // Only the follow-up copy button stays as a SwiftUI control — an
    // NSTextView can't host buttons inline, so it sits as a trailing
    // footer row under the text.

    @ViewBuilder
    private var summaryCard: some View {
        if let summary = session.summarizer.lastSummary {
            VStack(alignment: .leading, spacing: 8) {
                SelectableTextView(attributed: summaryAttributedString(summary, compact: true))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Same defense-in-depth as the detail view: never
                    // paint outside the card on a mis-measured line.
                    .clipped()
                if !summary.clientFollowUp.isEmpty {
                    // Copy affordance for the draft message — the draft
                    // itself is the last block of the text body above.
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            // Two-flavor write — HTML <p> blocks for
                            // mail / Slack, verbatim text for plain
                            // targets (MarkdownClipboard.swift).
                            RichClipboard.copy(markdown: summary.clientFollowUp)
                            ToastCenter.shared.show("Follow-up draft copied", style: .success)
                        } label: {
                            Label("Copy follow-up", systemImage: "envelope")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Copy the draft message")
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

    // MARK: - Transcript

    /// Live popover renders only the most recent N lines. The full
    /// transcript is still saved/exported in full — this cap just keeps the
    /// LazyVStack diff and first-open layout flat on long sessions.
    private static let liveWindowCount = 200

    private var transcriptList: some View {
        let display = session.displaySegments
        let windowed = display.count > Self.liveWindowCount
            ? Array(display.suffix(Self.liveWindowCount))
            : display
        // Composite key fires autoscroll both when a new segment is appended
        // (count changes) and when the live last segment grows in place (text
        // changes). Keying on text alone would miss a new segment whose text
        // duplicates the previous last line. \u{1F} (unit separator) keeps
        // count and text from colliding.
        let autoscrollKey = "\(display.count)\u{1F}\(display.last?.text ?? "")"

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !display.isEmpty {
                    Text("\(display.count) line\(display.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if windowed.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(windowed) { segment in
                            SegmentRow(
                                segment: segment,
                                origin: session.startedAt ?? Date(),
                                displayName: session.settings.userDisplayName
                            )
                            .id(segment.id)
                        }
                    }
                    .onChange(of: autoscrollKey) { _, _ in
                        guard isPinnedToBottom, let last = display.last?.id else { return }
                        proxy.scrollTo(last, anchor: .bottom)   // no withAnimation
                    }
                    .onAppear {
                        // Open the popover already at the newest line.
                        // LazyVStack rows aren't realised on the first
                        // onAppear pass, so hop a runloop before scrolling.
                        guard let last = display.last?.id else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
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
            // Hotkey is already shown in the Record button's badge — no
            // need to repeat it in the empty state.
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
        .padding(12)
    }

    /// Returns the action to run when the user taps the Send-to
    /// button itself (vs expanding the dropdown). nil when no
    /// default destination is configured — the button then opens
    /// the menu normally on tap.
    private func defaultSendAction() -> (() -> Void)? {
        let id = settings.defaultDestinationID
        guard !id.isEmpty else { return nil }
        if id == "notion" {
            guard settings.hasNotionCredentials, hasSegments else { return nil }
            return { Task { await sendToNotion() } }
        }
        // Treat anything else as an MCPIntegration UUID — silently
        // bail if the integration's been deleted / disabled since
        // the user picked it. (Settings would normally clear the
        // stale ID, but the resilient fallback here keeps the
        // button from going dead-no-op if it lags.)
        guard
            let integration = MCPIntegrationStore.shared.enabledIntegrations
                .first(where: { $0.id.uuidString == id })
        else { return nil }
        guard hasSegments else { return nil }
        return {
            Task {
                let stored = session.snapshotStoredSession()
                _ = await MCPDispatcher.send(integration, for: stored)
            }
        }
    }

    private var sendMenu: some View {
        Menu {
            // Notion item is shown only when the user has actually
            // wired up token + parent ID — otherwise the click would
            // 401, which the user can't recover from inside the menu.
            // Keeping a dead option in the dropdown is worse than
            // an "absent" option they can enable from Settings.
            if settings.hasNotionCredentials {
                Button {
                    Task { await sendToNotion() }
                } label: {
                    Label("Send to Notion", systemImage: "doc.text")
                }
                .disabled(notionSending)
            } else {
                // Affordance to fix the missing config without
                // hunting through Settings yourself.
                Button {
                    AppNavigation.shared.section = .settings
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Connect Notion in Settings…", systemImage: "doc.text")
                }
            }

            // Send to Claude is always available — it doesn't hit an
            // API, it opens Claude.app (or claude.ai as fallback) and
            // pastes the markdown into a fresh chat. No credentials,
            // no failure mode beyond "user doesn't have Claude
            // installed", which the fallback covers.
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
        } primaryAction: {
            // Default-destination one-click: if the user picked a
            // destination in Settings, clicking the Send-to button
            // (vs the dropdown arrow) fires that directly. nil
            // primaryAction means the click expands the menu as
            // usual — Apple's default behaviour when the action
            // is a no-op.
            defaultSendAction()?()
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
                AppNavigation.shared.section = .library
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Library…", systemImage: "books.vertical")
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

            Button("New recording", role: .destructive) {
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
            // `Label(..).iconOnly` keeps the text-line slot
            // reserved in layout — without it, an icon-only
            // bordered control collapses to glyph height and
            // ends up visibly shorter than its text-bearing
            // siblings. Reserving the text slot guarantees the
            // chrome takes the same intrinsic height the system
            // gives Copy / Send to under `controlSize(.regular)`.
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .menuIndicator(.hidden)
        // No `.frame(width:height:)` — earlier attempts to pin a
        // square via `PreferenceKey`-measured sibling height kept
        // coming up short because GeometryReader sees the bordered
        // chrome's logical bounds, not the visual outer envelope
        // (chrome adds ~2pt top/bottom invisible padding on top of
        // the logical size). Letting the system size the menu via
        // its intrinsic content gives a pill that's natively the
        // same height as Copy / Send to. `.fixedSize()` keeps it
        // from expanding sideways into the Spacer.
        .fixedSize()
    }

    private var hasSegments: Bool {
        !session.displaySegments.isEmpty
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
            Task { await session.pause() }
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
    /// User's configured display name (Settings → Profile → Your
    /// name). Routed through to `segment.speakerLabel(displayName:)`
    /// so the mic-side badge reads "egor" instead of the generic
    /// "me" fallback. Empty string preserves the legacy "Me" label —
    /// matches behaviour for users who haven't set a name yet.
    let displayName: String

    var body: some View {
        let offset = max(0, segment.startedAt.timeIntervalSince(origin))
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatOffset(offset))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                sourceBadge
            }
            // 2026-05-25 — column width 52 → 72 per Egor's pass. 52pt
            // fit "5:54" timer fine but truncated any 2-word badge
            // ("speaker e", "remote b") to 2 lines, which made the
            // transcript scroll feel inconsistent (some rows tall,
            // some short). 72pt holds "speaker X" / "remote X" on
            // one line at .caption2 weight; the body text column to
            // the right loses 20pt of width which is invisible at
            // typical popover widths (~500pt).
            .frame(width: 72, alignment: .leading)

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
        // 2026-05-25 — pass `displayName` so the mic badge resolves
        // to the user's configured "Your name" (Settings → Profile)
        // instead of the generic "me" fallback. Egor flagged the
        // bug: he had "Egor" set in Settings but the live transcript
        // still showed "me" on every mic-side segment. Root cause:
        // SegmentRow was calling the no-arg `segment.speakerLabel`
        // overload (which never reads settings). System-audio
        // segments are unaffected — those are remote voices, not
        // the user's.
        Text(segment.speakerLabel(displayName: displayName).lowercased())
            .font(.caption2.weight(.medium))
            .foregroundStyle(sourceColor)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .truncationMode(.tail)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(sourceColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }

    private var sourceColor: Color {
        // Daisy-palette tones rather than generic system blue/green —
        // those felt like stock SwiftUI chrome. Microphone = cinnamon
        // accent ("the user, on the mic side"); system audio = the
        // recording-orange we use everywhere else for incoming-active.
        switch segment.source {
        case .microphone:  return .daisyAccent
        case .systemAudio: return .daisyRecording
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
