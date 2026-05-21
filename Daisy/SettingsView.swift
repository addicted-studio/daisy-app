//
//  SettingsView.swift
//  Daisy
//
//  Four-tab settings window:
//   • Capture        — mic toggle (always on), system audio, screenshots
//   • Transcription  — Whisper model picker (size vs accuracy)
//   • Summary        — provider picker (Apple / Anthropic / OpenAI)
//                      + API keys + model per provider + auto-summarize toggle
//   • Notion         — token + parent ID
//

import EventKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var whisper = WhisperEngine.shared
    @Bindable var summarizer = Summarizer.shared
    // Calendar source state — needed by the General-tab Calendar
    // section (autoStart / autoStop / menu-bar next-meeting toggles).
    // Bound to the SAME observable the Permissions tab reads
    // (SystemPermissions.shared) so the two surfaces can't disagree
    // about "is calendar granted". SystemPermissions auto-refreshes
    // on `NSApplication.didBecomeActiveNotification`, so toggling the
    // grant in System Settings → Privacy & Security and tabbing back
    // to Daisy updates this view without manual refresh.
    @Bindable private var systemPermissions = SystemPermissions.shared
    @Bindable private var googleAccount = GoogleAccountStore.shared

    @State private var summaryTestResult: TestResult = .idle
    @State private var notionTestResult: TestResult = .idle

    enum TestResult: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    /// Last summary produced by Test summary — drives the preview
    /// block that shows up after a successful run. Cleared on each
    /// new test so the preview always matches the latest probe.
    @State private var summaryTestPreview: MeetingSummary?

    /// Bumped after the user picks / clears the sessions folder so
    /// the displayed path refreshes. `SessionsFolder` is plain
    /// UserDefaults under the hood — not @Observable — so SwiftUI
    /// needs a state nudge to re-read the path.
    @State private var storageRefreshTick: Int = 0
    /// Live list of input devices for the Capture-tab mic picker.
    /// Re-read on generalTab .task and on the Refresh button so the
    /// picker reflects current plugged-in hardware without us having
    /// to subscribe to CoreAudio hot-plug notifications (added in
    /// post-launch hardening).
    @State private var micDevices: [AudioInputDevice] = []
    /// Cumulative rotation degrees for the mic-refresh icon. Each tap
    /// adds 360° so the icon spins forward on every press, mirroring
    /// the calendar refresh affordance in HomeView. Same control,
    /// same feedback — different data source.
    @State private var micRefreshRotation: Double = 0
    /// On-disk Whisper cache stats — populated by an off-thread
    /// scan in `transcriptionTab.task`. `cacheRefreshTick` is the
    /// nudge the task watches; we bump it after Remove unused so
    /// the UI re-reads the freshly-shrunk cache.
    @State private var cachedModelsCount: Int = 0
    @State private var cachedModelsBytes: Int64 = 0
    @State private var cacheRefreshTick: Int = 0

    /// Cached `ByteCountFormatter` for the cache-size row. Building
    /// one per body recompute is wasteful; this one stays alive for
    /// the view lifetime.
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    /// Active sub-tab inside Settings. Bound to TabView's selection
    /// so external surfaces (FirstRunView, Home CTAs) can deep-link
    /// to a specific tab via `AppNavigation.shared.openInSettings(_:)`.
    /// Without an explicit binding TabView always lands on the first
    /// child — that's why early onboarding clicks felt broken
    /// (user wanted Summary, got Capture).
    @State private var settingsTab: SettingsTab = .general
    @Bindable private var nav = AppNavigation.shared

    var body: some View {
        TabView(selection: $settingsTab) {
            generalTab
                .tag(SettingsTab.general)
                // "General" — catch-all for app-level prefs (audio I/O,
                // hotkey, calendar gating, screenshots, storage). Was
                // "Capture" while Notion/MCP/Integrations also lived in
                // Settings; after they moved to Connections the tab
                // drifted into general-prefs territory and the label
                // followed. Mic icon stays — most rows are still
                // audio-recording-adjacent.
                .tabItem { Label("General", systemImage: "mic") }
                .scrollContentBackground(.hidden)

            transcriptionTab
                .tag(SettingsTab.transcription)
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .scrollContentBackground(.hidden)

            summaryTab
                .tag(SettingsTab.summary)
                .tabItem { Label("Summary", systemImage: "text.bubble") }
                .scrollContentBackground(.hidden)

            PermissionsView()
                .tag(SettingsTab.permissions)
                .tabItem { Label("Permissions", systemImage: "checkmark.shield") }
                .scrollContentBackground(.hidden)

            // Integrations + MCP server promoted out of Settings into
            // the top-level `Connections` sidebar destination — see
            // `MainSection.connections` + `ConnectionsView`. Settings
            // is now narrowly about "how the recorder processes a
            // session", Connections is "where Daisy talks to other
            // systems". About also moved to its own sidebar entry.
        }
        // Consume any one-shot deep-link from AppNavigation. Set on
        // appear (initial entry into Settings) AND on change (user
        // jumps from FirstRun while Settings sheet is already
        // mounted — rare but possible).
        .onAppear { consumePendingSettingsTab() }
        .onChange(of: nav.pendingSettingsTab) { _, _ in
            consumePendingSettingsTab()
        }
        // macOS Settings convention: ~700pt fixed-width per tab. Without
        // a minimum the form collapses and Hotkey rows cramp horizontally.
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, maxHeight: .infinity)
        .padding()
        .background(Color.daisyBgPrimary)
        .task { await summarizer.refreshAvailability() }
    }

    /// Pull any one-shot Settings-tab request from AppNavigation,
    /// apply it to local TabView selection, and clear the field so
    /// it doesn't fire again on subsequent appears. This is the
    /// hand-off that makes FirstRun CTAs land on the right tab
    /// instead of the default Capture.
    private func consumePendingSettingsTab() {
        guard let pending = nav.pendingSettingsTab else { return }
        settingsTab = pending
        nav.pendingSettingsTab = nil
    }

    /// Label shown on the preset Menu's trigger. Always reflects
    /// the currently-active shortcut — whether it's a canonical
    /// preset or a custom combo the user recorded via Press keys.
    /// "Custom · ⌥⌘X" makes the state legible at a glance; if
    /// nothing is configured (`.none`), fall back to a hint.
    private var presetMenuLabel: String {
        let current = settings.recordHotkey
        if current.keyCode == nil {
            return "Choose preset"
        }
        if current.isPreset {
            return current.label
        }
        return "Custom — \(current.label)"
    }

    /// Combined recorder + preset-menu editor for ANY hotkey
    /// binding. Recorder handles regular keys + Fn rising edge;
    /// the preset menu is the bullet-proof way to pick Fn, bare
    /// F-keys, or canonical combos without arguing with macOS
    /// event delivery. Pre-1.0.3 only the meeting hotkey had the
    /// preset menu — voice-note and dictation rows offered only
    /// the recorder, which was a dead end for Fn (Fn never fires
    /// .keyDown so the recorder silently ignored it).
    @ViewBuilder
    private func hotkeyEditor(binding: Binding<HotkeyChoice>) -> some View {
        HStack(spacing: 8) {
            HotkeyRecorder(value: binding)
            Menu {
                ForEach(HotkeyChoice.allPresets) { preset in
                    Button {
                        binding.wrappedValue = preset
                    } label: {
                        // Fn preset gets the SF Symbol globe icon
                        // — matches the modern Mac keyboard glyph
                        // for the same key (kVK_Function).
                        if preset.isFnOnly {
                            Label(preset.label, systemImage: preset == binding.wrappedValue ? "checkmark" : "globe")
                        } else if preset == binding.wrappedValue {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick from presets")
        }
    }

    // MARK: - MCP summarizer wrapper presets

    /// Known local-LLM MCP wrappers. Each defines a sensible
    /// `(baseURL, toolName, argumentsTemplate)` triple so the user
    /// can pick from a Menu instead of hand-writing JSON.
    private enum MCPSummarizerPreset {
        case ollama
        case lmStudio
        case llamaCpp

        var baseURL: String {
            switch self {
            case .ollama:   return "http://127.0.0.1:11435"
            case .lmStudio: return "http://127.0.0.1:1234"
            case .llamaCpp: return "http://127.0.0.1:8080"
            }
        }
        var toolName: String {
            switch self {
            case .ollama, .lmStudio: return "chat"
            case .llamaCpp:          return "complete"
            }
        }
        var template: String {
            switch self {
            case .ollama:
                return """
                {
                  "model": "qwen2.5:7b-instruct",
                  "messages": [
                    {"role": "system", "content": "{{system}}"},
                    {"role": "user", "content": "{{transcript}}"}
                  ],
                  "format": "json"
                }
                """
            case .lmStudio:
                return """
                {
                  "model": "qwen2.5-7b-instruct",
                  "messages": [
                    {"role": "system", "content": "{{system}}"},
                    {"role": "user", "content": "{{transcript}}"}
                  ],
                  "response_format": {"type": "json_object"}
                }
                """
            case .llamaCpp:
                return """
                {
                  "prompt": "{{system}}\\n\\n{{transcript}}",
                  "n_predict": 1024,
                  "temperature": 0.2
                }
                """
            }
        }
    }

    private func applyMCPSummarizerPreset(_ preset: MCPSummarizerPreset) {
        settings.mcpSummarizerURL = preset.baseURL
        settings.mcpSummarizerToolName = preset.toolName
        settings.mcpSummarizerArgumentsTemplate = preset.template
    }

    // MARK: - Storage (sessions folder)

    /// Row showing the currently-configured sessions folder + buttons
    /// to change or reset it. `storageRefreshTick` is bound to the
    /// HStack via `.id(...)` — that both reads the @State (so
    /// SwiftUI tracks it) and forces a fresh view identity each time
    /// the tick changes, which is exactly what we need since
    /// SessionsFolder reads UserDefaults directly (not @Observable).
    @ViewBuilder
    private var storageRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sessions folder")
                    .font(.callout.weight(.medium))
                Text(storageDisplayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("Choose folder…") {
                    if SessionsFolder.presentPicker() != nil {
                        storageRefreshTick &+= 1
                        ToastCenter.shared.show("New recordings will land here.", style: .success)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
                if SessionsFolder.hasUserFolder {
                    // Was .borderless + tertiary grey — read as plain
                    // text, not as an actionable control. Promoted to
                    // .bordered with primary tint so it sits visually
                    // adjacent to Choose folder… as a peer secondary
                    // action.
                    Button("Reset to default") {
                        SessionsFolder.clearUserFolder()
                        storageRefreshTick &+= 1
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                }
            }
        }
        .id(storageRefreshTick)
    }

    private var storageDisplayPath: String {
        SessionsFolder.userFolderDisplayPath()
            ?? SessionsFolder.defaultContainerLabel
    }

    // MARK: - Notion destination (under Storage)

    /// Notion destination row + auto-send toggle + DisclosureGroup
    /// containing the credentials, parent picker, and Test connection
    /// affordances. Lives next to `storageRow` because Notion is the
    /// same logical category — "where Daisy sends a finished meeting"
    /// — as the local sessions folder. Pre-1.0.5 this was a separate
    /// tab inside the Connections sidebar destination; testers found
    /// it hard to discover because they'd think of "where sessions
    /// go" as a single concept and end up looking in Settings first.
    @ViewBuilder
    private var notionDestinationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Notion")
                        .font(.callout.weight(.medium))
                    notionStatusBadge
                }
                Text(notionRowCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $settings.autoSendNotion)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!settings.hasNotionCredentials || settings.lastNotionTestPassedAt == nil)
                .help(notionToggleHelp)
        }

        // Folder filter — appears when auto-send is on, so a power
        // user can scope auto-push to e.g. "Work" folder and keep
        // personal voice notes off Notion.
        if settings.autoSendNotion {
            folderFilterPicker(
                title: "Only from folders",
                selection: Binding(
                    get: { settings.autoSendNotionFolders },
                    set: { settings.autoSendNotionFolders = $0 }
                )
            )
        }

        // Advanced configuration — secret, parent ID, type, Test.
        // DisclosureGroup keeps this collapsed by default so users
        // who never wire Notion up don't see a wall of fields.
        DisclosureGroup("Notion settings") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent {
                    SecureField("", text: $settings.notionToken, prompt: Text("secret_…"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                } label: {
                    labelWithCaption("Integration secret",
                                     caption: "Paste your Notion integration secret.")
                }

                LabeledContent {
                    TextField("", text: $settings.notionParentID, prompt: Text("a1b2c3d4…"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                } label: {
                    labelWithCaption("Parent ID",
                                     caption: "The 32-character ID at the end of the page or database URL — with or without dashes.")
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        Picker("", selection: $settings.notionParentKind) {
                            Text("Page").tag("page")
                            Text("Database").tag("database")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Spacer()
                        notionTestStatusView
                        Button("Test connection") {
                            Task { await testNotion() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.daisyAccent)
                        .disabled(notionTestResult == .testing || !settings.hasNotionCredentials)
                    }
                } label: {
                    labelWithCaption("Parent type",
                                     caption: "Page — Daisy adds the session as a child page underneath. Database — adds a row (title column must be named \"Name\").")
                }

                Text("Make an internal integration at notion.so/profile/integrations, then share the parent page or database with it. Test creates a probe page you can delete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    /// Right-of-title badge — same vocabulary as the old section
    /// header in Connections so returning users recognise the state.
    @ViewBuilder
    private var notionStatusBadge: some View {
        if settings.hasNotionCredentials && settings.lastNotionTestPassedAt != nil {
            Text("Connected")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.daisySuccess)
        } else if settings.hasNotionCredentials {
            Text("Needs test")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.daisyWarning)
        }
    }

    /// Caption text under the Notion title — flips depending on
    /// config state. Three meaningful states: unconfigured (call to
    /// action), configured-but-untested (warning to test first),
    /// configured-and-tested (passive confirmation).
    private var notionRowCaption: String {
        if !settings.hasNotionCredentials {
            return "Push finished sessions to Notion as a child page or a database row. Configure below to enable."
        }
        if settings.lastNotionTestPassedAt == nil {
            return "Pass Test connection first — auto-send needs a confirmed working setup."
        }
        return "Pushes the session to Notion the moment you stop recording."
    }

    private var notionToggleHelp: String {
        if !settings.hasNotionCredentials {
            return "Configure Notion settings below first."
        }
        if settings.lastNotionTestPassedAt == nil {
            return "Run Test connection before enabling auto-send."
        }
        return "Auto-push finished sessions to Notion."
    }

    @ViewBuilder
    private var notionTestStatusView: some View {
        switch notionTestResult {
        case .idle:             StatusBadge(state: .idle)
        case .testing:          StatusBadge(state: .busy)
        case .success(let m):   StatusBadge(state: .ok, message: m)
        case .failure(let m):   StatusBadge(state: .err, message: m)
        }
    }

    private func testNotion() async {
        notionTestResult = .testing
        let probe = MeetingExportData(
            title: "Daisy — Connection test",
            summary: nil,
            transcriptChunks: ["This page was created by Daisy as a connection test. You can safely delete it."],
            durationSeconds: 0,
            locale: "en",
            startedAt: Date()
        )
        do {
            let url = try await NotionExporter.shared.createMeetingPage(probe)
            notionTestResult = .success("Test page created in Notion.")
            // Mark proven-working — the auto-send toggle's enabled
            // gate flips only after this timestamp exists.
            settings.lastNotionTestPassedAt = Date()
            NSWorkspace.shared.open(url)
        } catch {
            notionTestResult = .failure("Couldn't reach Notion — \(error.localizedDescription)")
        }
    }

    /// Folder-filter picker for "Only from folders" — visible only
    /// when auto-send is ON. Multi-select via Menu so the row stays
    /// compact regardless of how many folders the user has.
    @ViewBuilder
    private func folderFilterPicker(
        title: String,
        selection: Binding<Set<String>>
    ) -> some View {
        let folders = FolderStore.shared.allFolders
        Menu {
            Button {
                selection.wrappedValue = []
            } label: {
                if selection.wrappedValue.isEmpty {
                    Label("All folders", systemImage: "checkmark")
                } else {
                    Text("All folders")
                }
            }
            Divider()
            ForEach(folders) { folder in
                Button {
                    var current = selection.wrappedValue
                    if current.contains(folder.slug) {
                        current.remove(folder.slug)
                    } else {
                        current.insert(folder.slug)
                    }
                    selection.wrappedValue = current
                } label: {
                    if selection.wrappedValue.contains(folder.slug) {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(folderFilterSummary(selection.wrappedValue, allFolders: folders))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func folderFilterSummary(_ slugs: Set<String>, allFolders: [SessionFolder]) -> String {
        if slugs.isEmpty { return "All folders" }
        let names = allFolders.filter { slugs.contains($0.slug) }.map(\.name)
        if names.count == 1 { return names[0] }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names.count) folders"
    }

    /// Label + caption stacked vertically in the LEADING column of
    /// a `LabeledContent` row. Keeps the input alone in the
    /// trailing column — which (1) lets every trailing field share
    /// the same width regardless of caption length, and (2) lets a
    /// segmented Picker stay on the same row as its label instead
    /// of falling into Form's two-line fallback.
    @ViewBuilder
    private func labelWithCaption(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Integrations (Notion + MCP destinations + default-destination
    // picker) and the MCP server tab live in the `Connections`
    // sidebar destination — see ConnectionsView.swift. The helpers
    // that supported them (testNotion, integrationRow, mcpStatusRow,
    // folderFilterPicker, autoSendNotionCaption, …) live alongside
    // them there. Calendar behaviour toggles came back to Settings →
    // General in 1.0.4, sitting next to the auto-start trigger they
    // conceptually neighbour; the EventKit grant + status badge are
    // in Settings → Permissions.

    // MARK: - General

    private var generalTab: some View {
        generalTabForm
            .task { refreshMicDevices() }
    }

    private var generalTabForm: some View {
        Form {
            // ── Group 0: You ──────────────────────────────────
            // Identity used to label the mic-side of transcripts.
            // Empty by default → falls back to the generic "Me".
            // First section in General because it answers the
            // narrative question "who am I in this app" before
            // "what mic, where files, etc.".
            Section {
                LabeledContent("Your name") {
                    TextField("", text: $settings.userDisplayName, prompt: Text("e.g. Egor"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                }
                Text("Shown in transcripts and in the summary prompt for your own voice. Without it, your lines are labeled \"Me\" — fine for solo notes, but the summarizer can't address you by name in multi-person meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("You")
            }

            // ── Group 1: Audio & devices ──────────────────────
            // What's coming in and what cues the user hears.
            // Mic picker + system-audio toggle + sound cues fit
            // under one mental model ("audio I/O of the recorder").
            Section {
                micPickerRow
                Toggle(isOn: $settings.captureSystemAudio) {
                    Text("Capture system audio")
                    Text("Records the other side of meetings (Zoom, Meet, Telegram). macOS will ask for Screen & System Audio Recording permission the first time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.recordingSoundsEnabled) {
                    Text("Play sound on start, pause, and stop")
                    Text("Quiet macOS system sounds (Tink / Pop / Glass) on recording transitions. Volume tuned so the cue doesn't get picked up by your own mic.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio & devices")
            }

            // ── Group 2: Storage ──────────────────────────────
            // Two destinations live side-by-side: the on-disk folder
            // (Daisy/Sessions) and an optional Notion push. They're
            // the same logical category ("where finished meetings
            // go") so keeping them in one Section is the right
            // mental model. Notion's deep config (secret + parent ID
            // + test) hides in a DisclosureGroup so the row isn't
            // overwhelming for users who'll never wire Notion up.
            Section {
                storageRow
                Text("Audio, transcripts, summaries and screenshots land in `Daisy/Sessions/` under this folder. Older recordings stay where they were.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                notionDestinationRow
            } header: {
                Text("Storage")
            }

            // ── Group 3a: Shortcuts ───────────────────────────
            // Three independent hotkeys — one per recording mode.
            // Each row offers BOTH the recorder ("Press keys…")
            // and a preset Menu — the preset is the only way to
            // bind Fn / 🌐 globe, F-keys without conflicts, etc.
            // without fighting macOS event delivery quirks.
            Section {
                LabeledContent("Record a meeting") {
                    hotkeyEditor(binding: $settings.recordHotkey)
                }
                LabeledContent("Voice note") {
                    hotkeyEditor(binding: $settings.voiceNoteHotkey)
                }
                LabeledContent("Dictation (hold)") {
                    hotkeyEditor(binding: $settings.dictationHotkey)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Meeting — tap once to start, tap again to pause / resume.\nVoice note — tap once to start, tap again to stop. Saves into Notes (no LLM summary).\nDictation — hold the key, talk, release; Daisy types the text into the focused field (or copies it for you to ⌘V).\nDictation also needs Accessibility to type into other apps. Combos must include ⌘ / ⌃ / ⌥, a bare function key (F1–F20), or the globe Fn key.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // ── Group 3b: Auto-start on meeting app ──────────
            // Standalone — no calendar required for this trigger.
            // Foreground-app detection sees Zoom/Teams/Meet launch
            // and starts recording without any pre-scheduling. The
            // ONLY way to auto-record for ad-hoc meetings that
            // weren't on the calendar.
            Section {
                Toggle(isOn: $settings.autoStartOnMeeting) {
                    Text("Start when a meeting app opens")
                    Text("Begins recording when Zoom, Teams, Webex, Telegram or Discord launches. Apps already open when Daisy starts are left alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Auto-start")
            }

            Section {
                Toggle(isOn: $settings.showSessionAfterStop) {
                    Text("Open the session window when recording stops")
                    Text("Switches to History and shows the just-recorded session the moment you stop. The transcript is visible immediately; the summary fades in as soon as the LLM finishes (usually 15–30 seconds).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("After Stop")
            }

            // ── Group 3c: Calendar ────────────────────────────
            // Behaviour toggles that gate on having an EventKit grant
            // (or a future Google OAuth connection). The permission
            // status itself lives in Settings → Permissions — there
            // the user grants / revokes access and sees the live
            // state badge. Here we just expose what Daisy does once
            // that access is in place.
            //
            // Note: 1.0.2 had these under Connections → Calendar
            // alongside a permission row; 1.0.4 split them — the
            // Connect / Open Settings… affordance graduated to
            // Permissions, the behaviour toggles came back here next
            // to the auto-start trigger they conceptually neighbour.
            Section {
                Toggle(isOn: $settings.autoStartFromCalendar) {
                    Text("Start at the scheduled meeting time")
                    Text("Reads your calendar, finds events with a Zoom/Meet/Teams/Webex link, starts recording when they begin. Up to 2 min late is fine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!hasAnyCalendarSource)

                Toggle(isOn: $settings.autoStopFromCalendar) {
                    Text("Stop when the event ends")
                    Text("Daisy hits Stop & save at the event's end time plus a grace period. A toast 30 s before lets you keep going.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!hasAnyCalendarSource)

                if settings.autoStopFromCalendar {
                    Picker("Grace period", selection: $settings.autoStopGraceSec) {
                        Text("On the dot").tag(0)
                        Text("1 min").tag(60)
                        Text("2 min").tag(120)
                        Text("5 min").tag(300)
                        Text("10 min").tag(600)
                        Text("15 min").tag(900)
                        Text("30 min").tag(1800)
                        Text("1 hour").tag(3600)
                    }
                    .pickerStyle(.menu)
                    .disabled(!hasAnyCalendarSource)
                }

                Toggle(isOn: $settings.menuBarShowsNextMeeting) {
                    Text("Show next meeting in the menu bar")
                    Text("Adds the next event's time + title (\"14:30 · Q3 Review\") next to Daisy's menu-bar icon. Hidden during recording so the active session stays the focus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!hasAnyCalendarSource)
            } header: {
                Text("Calendar")
            } footer: {
                if !hasAnyCalendarSource {
                    Text("Grant Calendar access in Settings → Permissions to enable these.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Uses macOS EventKit — picks up iCloud, Exchange, and any Google accounts you've added to Calendar.app.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // ── Group 4: While recording ──────────────────────
            // What Daisy does and surfaces during a session beyond
            // notifications. Floating widget visibility, screenshots.
            // (Notifications were pulled out into their own Section
            // in 1.0.5 so the user can per-toggle the three banner
            // classes from one place.)
            Section {
                Toggle(isOn: $settings.floatingWidgetEnabled) {
                    Text("Show floating recorder on top of other windows")
                    Text("Small mark above your apps while recording. Tap to pause; right-click for Stop & save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.screenshotsEnabled) {
                    Text("Capture screenshots periodically")
                    Text("Useful for tracking shared screens or slides. Saved alongside the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.screenshotsEnabled {
                    Stepper(value: $settings.screenshotIntervalSec, in: 15...600, step: 15) {
                        HStack {
                            Text("Every")
                            Text("\(settings.screenshotIntervalSec) s")
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("While recording")
            }

            // ── Group 5: Notifications ────────────────────────
            // Per-class toggles for every macOS banner Daisy posts.
            // Surface the user can flip individual notifications off
            // without affecting the rest — common case is "I want
            // auto-start confirmation but the silence prompt feels
            // nannying", or vice versa.
            Section {
                Toggle(isOn: $settings.notifyOnAutoStart) {
                    Text("Recording started")
                    Text("Banner when a calendar event auto-starts Daisy. Includes a Stop & save action if you didn't want that meeting tracked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.notifyOnAutoStop) {
                    Text("Meeting ended — saved")
                    Text("Confirmation banner when the calendar event ends and Daisy auto-stops + saves the recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.silencePromptsEnabled) {
                    Text("Long silence")
                    Text("After 3 min of silence (or 5 min on pause) Daisy asks whether to keep going. Includes Stop & save / Keep recording actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("macOS-level banners. You can also tune Daisy's notification style in System Settings → Notifications → Daisy.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Auto-summary lives in the Summary tab — it sits next
            // to the provider config it depends on.
        }
        .formStyle(.grouped)
    }

    // Microphone selector row in the General tab. Empty UID == follow
    // the macOS system default (the v1.0 behaviour). For the default
    // option we suffix the name of the device currently in that slot
    // so the user knows what "system default" actually resolves to
    // right now ("System default (AirPods Pro)") — far more useful
    // than a bare "System default" label.
    @ViewBuilder
    private var micPickerRow: some View {
        LabeledContent("Microphone") {
            HStack(spacing: 8) {
                Picker("", selection: $settings.selectedMicDeviceUID) {
                    Text(systemDefaultLabel).tag("")
                    if !micDevices.isEmpty {
                        Divider()
                        ForEach(micDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    // If the saved UID isn't in the live list (device
                    // unplugged since selection), include a disabled
                    // placeholder so the Picker can still display the
                    // current value rather than silently snapping to
                    // System default. The user sees that something is
                    // missing and can act on it.
                    if !settings.selectedMicDeviceUID.isEmpty,
                       !micDevices.contains(where: { $0.uid == settings.selectedMicDeviceUID }) {
                        Divider()
                        Text("Saved device (not connected)")
                            .tag(settings.selectedMicDeviceUID)
                    }
                }
                .labelsHidden()
                .fixedSize()

                // Re-scan affordance — mirrors the calendar refresh
                // button in HomeView: same icon, same secondary tint,
                // same 360° spin on tap. Same metaphor everywhere we
                // re-pull external state.
                Button {
                    refreshMicDevices()
                    withAnimation(.easeInOut(duration: 0.7)) {
                        micRefreshRotation += 360
                    }
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(micRefreshRotation))
                }
                .buttonStyle(.plain)
                .help("Re-scan input devices")
            }
        }
        Text("Daisy uses this device for the microphone track. Pick \"System default\" to follow your macOS Sound settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var systemDefaultLabel: String {
        if let current = micDevices.first(where: { $0.isSystemDefault }) {
            return "System default (\(current.name))"
        }
        return "System default"
    }

    private func refreshMicDevices() {
        micDevices = AudioInputDevices.list()
    }

    /// At least one calendar source is connected — Apple EventKit
    /// (`.fullAccess` granted) OR Google via direct OAuth. Gates the
    /// behaviour toggles in the Calendar section of generalTab; the
    /// underlying grant/connect affordances live elsewhere
    /// (EventKit in Settings → Permissions, Google in Connections
    /// once verification clears).
    ///
    /// Reads the LIVE `CalendarService.authorizationStatus`, not the
    /// persisted `settings.calendarAccessGranted` cache. Pre-1.0.4 the
    /// gate used the cached bool, which could lag behind the real
    /// EventKit state — a tester with Apple Calendar granted in
    /// System Settings → Privacy & Security but a stale UserDefaults
    /// bool saw every toggle in this section disabled even though
    /// Permissions tab correctly said "Granted". Same observable
    /// (`@Bindable var calendarService = CalendarService.shared`) the
    /// Permissions tab reads, so the two surfaces can't diverge.
    private var hasAnyCalendarSource: Bool {
        systemPermissions.calendar == .granted || googleAccount.isConnected
    }

    // MARK: - Transcription (Whisper)

    private var transcriptionTab: some View {
        Form {
            Section {
                Picker("Model", selection: $whisper.modelID) {
                    ForEach(WhisperEngine.availableModels, id: \.id) { model in
                        Text("\(model.label) · \(model.sizeMB) MB")
                            .tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                Text("Whisper runs on-device. Bigger models handle accents and multilingual meetings better, at the cost of disk and a bit of speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Model")
            }

            Section {
                Picker("Meetings (default)", selection: $settings.defaultTranscriptionLocale) {
                    ForEach(Transcriber.availableLocales, id: \.id) { locale in
                        Text(locale.label).tag(locale.id)
                    }
                }
                .pickerStyle(.menu)
                Picker("Voice notes", selection: $settings.voiceNoteLocale) {
                    Text("Same as meetings").tag("")
                    ForEach(Transcriber.availableLocales, id: \.id) { locale in
                        Text(locale.label).tag(locale.id)
                    }
                }
                .pickerStyle(.menu)
                Picker("Dictation", selection: $settings.dictationLocale) {
                    Text("Same as meetings").tag("")
                    ForEach(Transcriber.availableLocales, id: \.id) { locale in
                        Text(locale.label).tag(locale.id)
                    }
                }
                .pickerStyle(.menu)
                Text("Pick a specific language to kill the kind of language drift that produces hallucinated phrases in another tongue. Voice notes and dictation inherit the Meetings default unless you set them explicitly — useful if you record meetings in English but dictate personal notes in Russian. Per-session override is still available in the recorder header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Language")
            }

            Section {
                HStack(spacing: 8) {
                    StatusBadge(state: whisperBadgeState, message: whisperStatusText)
                    Spacer()
                    Button("Reload") { Task { await whisper.reload() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Color.daisyTextPrimary)
                        .disabled(isWhisperLoading)
                }
                whisperStatusBody
            } header: {
                Text("Model status")
            } footer: {
                Text("First time you pick a model, Daisy downloads it from Hugging Face. Files live inside the app's container and get reused for every meeting after.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Toggle(isOn: $settings.diarizeMicrophone) {
                    Text("Diarize microphone too")
                    Text("Run speaker separation on your mic audio. Useful when remote participants are heard through your speakers (in-room playback) instead of via system-audio capture — each voice gets its own \"Speaker A / B\" label instead of all collapsing into \"Me\". Adds Pyannote CoreML inference over the mic stream, ~15-25% of Whisper runtime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Diarization")
            } footer: {
                Text("System audio is always diarized (one cluster per remote participant). This toggle adds the same pass for your microphone track — leave off unless you record in-room meetings where everyone shares one mic.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                modelsCacheRow
            } header: {
                Text("Cache")
            } footer: {
                Text("Switching to a different model downloads it alongside the previous one — old files aren't deleted automatically so a downgrade is instant. Use Remove unused to free disk space.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Known speakers — persistent voice profiles store. Lets
            // the user inspect what biometric derivatives Daisy has
            // saved, forget individual profiles, or wipe the whole
            // store. This is a privacy-required surface — without it
            // there's no way to delete enrollment data short of
            // resetting the app container.
            Section {
                speakerProfilesRow
            } header: {
                Text("Known speakers")
            } footer: {
                Text("After you name a speaker in a transcript (e.g. \"Alex\"), Daisy stores a short voice fingerprint locally and auto-labels them in future recordings. Fingerprints never leave your Mac. Forget anytime.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .task(id: cacheRefreshTick) {
            // Refresh on tab open + after any cleanup. Detached so
            // a slow FileManager scan never blocks the form's
            // first paint.
            cachedModelsCount = await Task.detached { WhisperEngine.cachedModels().count }.value
            cachedModelsBytes = await Task.detached { WhisperEngine.totalCacheSizeBytes() }.value
        }
    }

    /// Models-on-disk summary row + Remove-unused action. Disabled
    /// when there's only one cached variant (current one), so the
    /// button never appears actionable when there's nothing it
    /// could do.
    @ViewBuilder
    private var modelsCacheRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models on disk")
                Text("\(cachedModelsCount) \(cachedModelsCount == 1 ? "model" : "models") · \(formattedCacheSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Remove unused") {
                Task {
                    let freed = await whisper.removeUnusedModels()
                    cacheRefreshTick &+= 1
                    if freed > 0 {
                        ToastCenter.shared.show(
                            "Freed \(byteFormatter.string(fromByteCount: freed)) of model cache.",
                            style: .success
                        )
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.daisyTextPrimary)
            .disabled(cachedModelsCount <= 1 || isWhisperLoading)
        }
    }

    private var formattedCacheSize: String {
        byteFormatter.string(fromByteCount: cachedModelsBytes)
    }

    /// Bind directly to the singleton so the row re-renders when the
    /// store mutates (forget, upsert, etc.). Lifecycle-attached to
    /// the view; no need to retain elsewhere.
    @Bindable private var speakerStore = SpeakerProfileStore.shared

    /// Lists every known speaker profile in most-recently-seen order
    /// with per-row "Forget" + a global "Forget all" button. Hides
    /// gracefully when no profiles exist so first-time users don't
    /// see an empty placeholder card.
    @ViewBuilder
    private var speakerProfilesRow: some View {
        let profiles = speakerStore.profilesByRecent
        if profiles.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "person.2")
                    .foregroundStyle(.secondary)
                Text("No voice profiles yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
            .onAppear { speakerStore.ensureLoaded() }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(profiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: "person.fill")
                            .foregroundStyle(Color.daisyAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.callout.weight(.medium))
                            Text(speakerProfileSummary(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("Forget") {
                            speakerStore.forget(profile.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Color.daisyTextPrimary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Forget all") {
                        speakerStore.forgetAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyError)
                }
            }
        }
    }

    private func speakerProfileSummary(_ profile: SpeakerProfile) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let seen = formatter.localizedString(for: profile.lastSeenAt, relativeTo: Date())
        let count = profile.sessionCount
        let meetings = count == 1 ? "1 meeting" : "\(count) meetings"
        return "\(meetings) · last \(seen)"
    }

    private var whisperBadgeState: StatusBadge.State {
        switch whisper.state {
        case .ready:                 return .ok
        case .downloading, .loading: return .busy
        case .failed:                return .err
        case .notLoaded:             return .idle
        }
    }

    private var whisperStatusText: String {
        switch whisper.state {
        case .ready: return "Ready"
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .loading: return "Loading model…"
        case .failed: return "Failed"
        case .notLoaded: return "Not loaded"
        }
    }

    @ViewBuilder
    private var whisperStatusBody: some View {
        switch whisper.state {
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                Text("\(Int(p * 100))% of model downloaded — keep the app open until it finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loading(let status):
            Text(status).font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.secondary)
        case .ready:
            Text("Model: \(whisper.modelID)").font(.caption).foregroundStyle(.secondary)
        case .notLoaded:
            EmptyView()
        }
    }

    private var isWhisperLoading: Bool {
        switch whisper.state {
        case .loading, .downloading: return true
        default: return false
        }
    }

    // MARK: - Summary Provider

    private var summaryTab: some View {
        Form {
            // ONE-block summary section: Provider → credentials →
            // Model → Status → Test. Eliminates the stack of 4–5
            // small sections with redundant headers ("Summary
            // provider", "Anthropic API key", "Model", "Provider
            // status") that fragmented what is conceptually a
            // single setup flow. Caption rolls into one footer
            // explaining where transcripts go for the selected
            // provider.
            Section {
                Picker("Provider", selection: $summarizer.providerKind) {
                    ForEach(availableSummaryProviders, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .onAppear {
                    // If a user upgraded TO macOS 26 with an old
                    // setting OR is downgrading from 26 with
                    // .appleIntelligence stuck in UserDefaults,
                    // bounce them onto a valid provider so the
                    // picker doesn't render an unreachable selection.
                    if !availableSummaryProviders.contains(summarizer.providerKind),
                       let firstAvailable = availableSummaryProviders.first {
                        summarizer.providerKind = firstAvailable
                    }
                }

                providerInlineRows

                // Status row — inline so the user sees
                // "this provider, with these creds, is reachable"
                // without scrolling.
                HStack(spacing: 8) {
                    StatusBadge(state: summarizerBadgeState, message: summarizerStatusText)
                    Spacer()
                    Button("Refresh") {
                        Task { await summarizer.refreshAvailability() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                }

                // Test row — final action in the block. Apple
                // Intelligence has nothing to validate remotely so
                // we skip it for that provider.
                if summarizer.providerKind != .appleIntelligence {
                    HStack {
                        Button("Test summary") {
                            Task { await testSummaryProvider() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.daisyAccent)
                        .disabled(testSummaryButtonDisabled)
                        Spacer()
                        summaryTestStatusView
                    }
                }
            } header: {
                Text("Summary")
            } footer: {
                Text(summarySectionFooter)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // MCP-only extras stay separate — preset menu + raw
            // JSON template are an engineering escape hatch most
            // users never open.
            if summarizer.providerKind == .mcp {
                mcpPresetSection
                mcpAdvancedJSONSection
            }

            // Preview MD-document after a successful Test summary.
            summaryTestPreviewSection

            Section {
                Picker("Summary language", selection: $settings.summaryLanguage) {
                    ForEach(SummaryLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.id)
                    }
                }
                .pickerStyle(.menu)
                Text("The summary will always be written in this language, even if the meeting itself was in another. Handy when you record in one language and send the follow-up in another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Summary language")
            }

            Section {
                Toggle(isOn: $settings.autoSummarize) {
                    Text("Summarize when recording stops")
                    Text("Runs the selected provider on the transcript the moment you stop — meeting overview, next actions, and a follow-up draft for clients or partners.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!summarizerAvailable)
                if !summarizerAvailable {
                    Text("Provider isn’t ready yet — set it up in the section above first.")
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                }
            } header: {
                Text("Auto-summary")
            }
        }
        .formStyle(.grouped)
    }

    /// Inline credential / model rows for the selected provider.
    /// Lives inside the unified Summary section so picker → keys →
    /// model render as one visual block. Apple Intelligence has no
    /// inline rows (nothing to configure).
    @ViewBuilder
    private var providerInlineRows: some View {
        switch summarizer.providerKind {
        case .appleIntelligence:
            EmptyView()

        case .anthropic:
            LabeledContent("API key") {
                SecureField("", text: $settings.anthropicAPIKey, prompt: Text("sk-ant-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.anthropicModel) {
                ForEach(AnthropicAPISummarizer.availableModels, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .pickerStyle(.menu)

        case .openai:
            LabeledContent("API key") {
                SecureField("", text: $settings.openaiAPIKey, prompt: Text("sk-proj-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.openaiModel) {
                ForEach(OpenAIAPISummarizer.availableModels, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .pickerStyle(.menu)

        case .mcp:
            // `prompt:` (placeholder) + `labelsHidden()` so Form
            // doesn't promote the title to a trailing accessory and
            // draw it twice. Same fix we apply in the Notion section.
            LabeledContent("Server URL") {
                TextField("", text: $settings.mcpSummarizerURL, prompt: Text("http://127.0.0.1:11435"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
            LabeledContent("Tool name") {
                TextField("", text: $settings.mcpSummarizerToolName, prompt: Text("chat"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// SummaryProviderKind cases visible to the user on the current
    /// macOS version. Apple Intelligence is hidden on macOS 14/15
    /// because its underlying framework (FoundationModels) only
    /// exists from Tahoe onward — surfacing it on Sonoma would
    /// show a control that has no working code path behind it.
    private var availableSummaryProviders: [SummaryProviderKind] {
        if #available(macOS 26.0, *) {
            return SummaryProviderKind.allCases
        }
        return SummaryProviderKind.allCases.filter { $0 != .appleIntelligence }
    }

    /// Single Test-button enable rule across all providers — saves
    /// duplicating the same `||`-chain in each switch case.
    private var testSummaryButtonDisabled: Bool {
        if summaryTestResult == .testing { return true }
        switch summarizer.providerKind {
        case .appleIntelligence: return true
        case .anthropic: return settings.anthropicAPIKey.isEmpty
        case .openai: return settings.openaiAPIKey.isEmpty
        case .mcp:
            return settings.mcpSummarizerURL.isEmpty
                || settings.mcpSummarizerToolName.isEmpty
        }
    }

    /// Per-provider footer copy for the unified Summary section.
    /// Rolls "where transcripts go" + "where to get keys" + "cost"
    /// into one paragraph so the user doesn't read four scattered
    /// captions.
    private var summarySectionFooter: String {
        switch summarizer.providerKind {
        case .appleIntelligence:
            return "Runs entirely on-device. Nothing about the transcript leaves your Mac. Apple's local model doesn't support every language (e.g. Russian) — for those, switch to a cloud provider."
        case .anthropic:
            return "Transcripts are sent to Anthropic over HTTPS using your own API key. Create one at console.anthropic.com/settings/keys — it's stored in your macOS Keychain. Each summary costs roughly $0.01–0.05."
        case .openai:
            return "Transcripts are sent to OpenAI over HTTPS using your own API key. Create one at platform.openai.com/api-keys — it's stored in your macOS Keychain. Each summary costs roughly $0.01–0.05."
        case .mcp:
            return "Daisy connects to your local MCP server over HTTP+SSE and calls one tool per summary. Most wrappers (Ollama, LM Studio, llama.cpp) expose `chat` or `complete` — use Quick setup below or check your wrapper's docs."
        }
    }

    /// Quick-setup preset menu — MCP only, kept as its own section
    /// because it's an escape hatch most users skip.
    private var mcpPresetSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("Use template for")
                Spacer()
                Menu("Pick wrapper") {
                    Button("Ollama (chat tool)") {
                        applyMCPSummarizerPreset(.ollama)
                    }
                    Button("LM Studio (chat tool)") {
                        applyMCPSummarizerPreset(.lmStudio)
                    }
                    Button("llama.cpp (complete tool)") {
                        applyMCPSummarizerPreset(.llamaCpp)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text("Fills the URL, tool name, and arguments template with sensible defaults for that wrapper. You can still edit anything by hand below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Quick setup")
        }
    }

    /// Raw JSON template editor — engineering escape hatch.
    private var mcpAdvancedJSONSection: some View {
        Section {
            DisclosureGroup("Advanced — raw JSON template") {
                TextEditor(text: $settings.mcpSummarizerArgumentsTemplate)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(6)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                    )
                HStack {
                    Button("Reset to default") {
                        settings.mcpSummarizerArgumentsTemplate = MCPSummarizer.defaultArgumentsTemplate
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                    Spacer()
                }
                Text("JSON template for the tool's `arguments`. Three placeholders get substituted before sending: `{{system}}` (Daisy's system prompt), `{{transcript}}` (meeting title + body), `{{title}}` (meeting title alone). Edit the `model` field to match a model your wrapper has pulled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summarizerBadgeState: StatusBadge.State {
        switch summarizer.availability {
        case .available: return .ok
        case .unavailable: return .warn
        case .unknown: return .busy
        }
    }

    private var summarizerStatusText: String {
        switch summarizer.availability {
        case .available: return "Available"
        case .unavailable: return "Unavailable"
        case .unknown: return "Checking…"
        }
    }

    private var summarizerStatusBody: String {
        switch summarizer.availability {
        case .available: return "\(summarizer.providerKind.shortName) is ready for summaries."
        case .unavailable(let reason): return reason
        case .unknown: return ""
        }
    }

    private var summarizerAvailable: Bool {
        if case .available = summarizer.availability { return true }
        return false
    }

    private var summaryTestStatusView: some View {
        switch summaryTestResult {
        case .idle:        StatusBadge(state: .idle)
        case .testing:     StatusBadge(state: .busy)
        case .success(let msg): StatusBadge(state: .ok, message: msg)
        case .failure(let msg): StatusBadge(state: .err, message: msg)
        }
    }

    /// Inline preview that shows what the rendered summary looks
    /// like after a successful Test summary. Mirrors the typography
    /// SessionDetailView uses for real sessions — same MD-document
    /// grammar (H3 heading + hairline + body) so the test result
    /// reads as a faithful demo of "this is what you'll see after
    /// a real meeting".
    @ViewBuilder
    private var summaryTestPreviewSection: some View {
        if let preview = summaryTestPreview {
            // Headers in the user's chosen summary language — so a
            // Russian summary preview shows "Встреча / Следующие
            // шаги / Ответ клиенту" instead of English structural
            // labels stamped on top of Russian content. The picker
            // value goes through SummaryLanguage.id which matches
            // SummaryLabels.for's expected codes; "auto" → English.
            let labels = SummaryLabels.for(language: settings.summaryLanguage)
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    DisclosureGroup {
                        Text(Self.fixtureTranscript)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    } label: {
                        Text("Test transcript (\(Self.fixtureTitle))")
                            .font(.caption.weight(.medium))
                    }

                    Divider()

                    previewMDSection(title: labels.meeting) {
                        Text(preview.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Granola-style topical outline — 3-5 sections,
                    // each with a flat (or shallow-nested) bullet
                    // list. Mirrors the real session detail layout
                    // so the preview faithfully demos what a session
                    // looks like after a real meeting. Pre-1.0.2 the
                    // preview only rendered Meeting + Next actions +
                    // Follow-up, so a Granola-style summary looked
                    // like a single paragraph here even when the
                    // model returned sections.
                    ForEach(Array(preview.sections.enumerated()), id: \.offset) { _, section in
                        previewMDSection(title: section.title) {
                            previewBulletTree(section.bullets, level: 0)
                        }
                    }

                    if !preview.actionItems.isEmpty {
                        previewMDSection(title: labels.nextActions) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(preview.actionItems.enumerated()), id: \.offset) { _, item in
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

                    if !preview.clientFollowUp.isEmpty {
                        previewMDSection(title: labels.followUp) {
                            Text(preview.clientFollowUp)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Preview · what a real session looks like")
            }
        }
    }

    /// Recursive bullet renderer for the Settings → Test summary
    /// preview. Mirrors `SessionDetailView.bulletTree` typography so
    /// the preview reads as a faithful demo of a real session. Uses
    /// `AnyView` rather than `some View` to break the same recursive-
    /// opaque-return-type compiler error that bit us in
    /// ContentView/SessionDetailView during the Xcode 16 / Swift 6
    /// upgrade — see [[fix-recursive-viewbuilder-bulletTree]].
    private func previewBulletTree(_ bullets: [SummaryBullet], level: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(width: 8, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bullet.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !bullet.children.isEmpty {
                                previewBulletTree(bullet.children, level: level + 1)
                            }
                        }
                    }
                    .padding(.leading, CGFloat(level) * 14)
                }
            }
        )
    }

    @ViewBuilder
    private func previewMDSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.daisyTextPrimary)
            Rectangle()
                .fill(Color.daisyDivider)
                .frame(height: 0.5)
            content()
        }
    }

    private func testSummaryProvider() async {
        summaryTestResult = .testing
        summaryTestPreview = nil
        // Use the isolated `runProbe` path — calling the regular
        // `summarize` would write into the shared singleton's
        // `lastSummary` / `lastError`, which the active recording
        // session reads back as if it were the real summary for
        // that meeting. Bug reproduced when the user pressed Test
        // summary mid-recording and the fixture transcript ended
        // up attached to the live session.
        //
        // Honour the user's Summary-language picker: if they chose
        // a specific language, force the probe to output in that
        // language so they see what their real summaries will look
        // like. "Auto" passes nil so the model picks based on the
        // (English) fixture content — fine for the smoke test
        // semantics ("can my provider produce a summary at all").
        // Pre-fix this hard-coded `localeHint: "en"` made the test
        // always read English even when the picker said "Русский",
        // which looked like a localization bug to QA.
        let chosenHint: String? = (settings.summaryLanguage == SummaryLanguage.auto.id)
            ? nil
            : settings.summaryLanguage
        do {
            let summary = try await summarizer.runProbe(
                transcript: Self.fixtureTranscript,
                title: Self.fixtureTitle,
                localeHint: chosenHint
            )
            summaryTestResult = .success("Summary came through.")
            summaryTestPreview = summary
        } catch {
            // Wrap the raw error — system messages from URLSession /
            // CoreData / decoder show up here looking like "The
            // request timed out." with no context. Prefixing keeps
            // the diagnostic info but anchors it to a recognisable
            // verb ("Test failed"), so the user knows where to
            // look without parsing system-level English.
            summaryTestResult = .failure("Test failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Test fixture
    //
    // Realistic two-person client call so the model has actual
    // material to summarise — a couple of concrete next actions,
    // one decision, and an obvious follow-up to send to the
    // client. Renders into a populated MeetingSummary the preview
    // can show as a "this is what a finished session looks like"
    // demo right inside Settings.

    private static let fixtureTitle = "Brand site · homepage direction review"

    private static let fixtureTranscript = """
    [you] Thanks for jumping on. I pulled together two directions for the homepage hero based on what you mentioned last week. Want to walk through them?
    [client] Yeah, let's do it. I want to know which one we're locking in before I show the team on Friday.
    [you] OK. Direction one leans into the product photography — big image, very little copy. Direction two is more editorial: copy-first, the product appears lower down the fold.
    [client] I like the editorial one. We get more room for the value prop. But honestly, the product photo on direction one is much stronger than what we have today.
    [you] Right. What if we keep the editorial structure but commission a couple of fresh product shots for it? Say two scenes — one lifestyle, one studio.
    [client] That works for me. Can you scope what a new shoot would cost and send a number by Thursday? I'd rather not be guessing on budget when I'm in front of the team.
    [you] Will do — I'll have a quote in your inbox Thursday morning. Quick check: what about the testimonials section? You mentioned wanting to feature the new enterprise quote.
    [client] Yes, please include it. I'll send you the approved version tonight.
    [you] Perfect. So to recap: we go with the editorial direction, you send the testimonial tonight, I send a shoot budget Thursday, and we lock the homepage layout on the call next Tuesday.
    [client] Great. Let's also book 30 minutes Friday to look at the mobile breakpoints — I have a couple of concerns there I want to flag before they freeze.
    [you] Done. I'll send the invite right after this call.
    """

    // MARK: - About

    // About content lives in `AboutView.swift` — promoted out of
    // Settings tabs into a top-level sidebar section.
}

#Preview {
    SettingsView(settings: AppSettings())
}
