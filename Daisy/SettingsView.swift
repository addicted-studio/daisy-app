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
    @Bindable var calendar = CalendarService.shared
    @Bindable var mcpServer = MCPServer.shared

    @State private var notionTestResult: TestResult = .idle
    @State private var summaryTestResult: TestResult = .idle

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
    /// Re-read on captureTab .task and on the Refresh button so the
    /// picker reflects current plugged-in hardware without us having
    /// to subscribe to CoreAudio hot-plug notifications (added in
    /// post-launch hardening).
    @State private var micDevices: [AudioInputDevice] = []
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

    var body: some View {
        TabView {
            captureTab
                .tabItem { Label("Capture", systemImage: "mic") }
                .scrollContentBackground(.hidden)

            transcriptionTab
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .scrollContentBackground(.hidden)

            summaryTab
                .tabItem { Label("Summary", systemImage: "text.bubble") }
                .scrollContentBackground(.hidden)

            integrationsTab
                .tabItem { Label("Destinations", systemImage: "paperplane") }
                .scrollContentBackground(.hidden)

            mcpTab
                .tabItem { Label("Sharing", systemImage: "antenna.radiowaves.left.and.right") }
                .scrollContentBackground(.hidden)

            // About tab promoted to a top-level sidebar destination
            // — see `MainSection.about` + `AboutView`. Buried inside
            // Settings → About it wasn't discoverable.
        }
        // macOS Settings convention: ~700pt fixed-width per tab. Without
        // a minimum the form collapses and Hotkey rows cramp horizontally.
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, maxHeight: .infinity)
        .padding()
        .background(Color.daisyBgPrimary)
        .task { await summarizer.refreshAvailability() }
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

    /// Row-style field used by the Notion section: label sits on
    /// the left, input on the right, both vertically centered;
    /// caption tucks underneath, indented to start at the input's
    /// leading edge.
    ///
    /// Why a hand-rolled HStack instead of Form's auto-labelling:
    /// macOS Form aggressively right-aligns text inside the input
    /// when it's in the trailing column, which makes placeholder
    /// values like `secret_…` and `a1b2c3d4…` render flush-right.
    /// A custom row lets us keep the visual rhythm of label/field
    /// while pinning the text inside the field to leading.
    @ViewBuilder
    private func notionField<Field: View>(
        label: String,
        caption: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .font(.callout.weight(.medium))
                    // Fixed-width label column gives us consistent
                    // input alignment across rows; 140pt is wide
                    // enough for "Integration secret" without
                    // overflow on either dark or light system fonts.
                    .frame(width: 140, alignment: .leading)
                field()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Indent the caption to start at the input's
                // leading edge — reads as belonging to the field,
                // not as a free-floating note.
                .padding(.leading, 140 + 12)
        }
    }

    private func graceLabel(seconds: Int) -> String {
        if seconds == 0 { return "On the dot" }
        if seconds < 60 { return "\(seconds) s" }
        let mins = seconds / 60
        let rem = seconds % 60
        if rem == 0 { return "\(mins) min" }
        return "\(mins) min \(rem) s"
    }

    // MARK: - Auto-actions (Phase 6c)

    @Bindable private var integrationStore = MCPIntegrationStore.shared
    @State private var editingIntegration: MCPIntegration?
    @State private var showingNewIntegrationSheet: Bool = false

    /// Unified destinations tab — first-party Notion credentials at
    /// the top (REST API, simplest path), then the open-ended list
    /// of MCP integrations below. Both feed the same "Send to …"
    /// kebab in History; keeping them on one page so the user has a
    /// single place to manage everywhere a session can be pushed.
    private var integrationsTab: some View {
        Form {
            // Notion — first-party REST connector, simplest setup.
            //
            // Each row is wrapped in a VStack with a leading-edge
            // `HStack { Text; Spacer }` for the label. Without the
            // HStack+Spacer, Form's auto-labelling sees the leading
            // `Text` as a row label and pulls it out into the left
            // column — breaking the "label above field" layout.
            // The Spacer forces Form to treat the whole VStack as
            // one block of row content.
            Section {
                notionField(
                    label: "Integration secret",
                    caption: "Paste your Notion integration secret."
                ) {
                    SecureField("", text: $settings.notionToken, prompt: Text("secret_…"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                notionField(
                    label: "Parent page ID",
                    caption: "The 32-character ID at the end of the page URL — with or without dashes."
                ) {
                    TextField("", text: $settings.notionParentID, prompt: Text("a1b2c3d4…"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Test connection") {
                        Task { await testNotion() }
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.daisyTextPrimary)
                    .disabled(notionTestResult == .testing || !settings.hasNotionCredentials)
                    Spacer()
                    testStatusView
                }
                Text("Create an internal integration at notion.so/profile/integrations, then share the parent page with it so Daisy can write under it. Test creates a probe page you can delete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Notion")
            }

            // MCP integrations — generic, multiple destinations.
            Section {
                if integrationStore.integrations.isEmpty {
                    Text("No MCP integrations yet. Add one to push finished sessions into Linear, a custom Notion database, or any other MCP-compatible service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(integrationStore.integrations) { integration in
                        integrationRow(integration)
                    }
                }
            } header: {
                Text("MCP integrations")
            } footer: {
                Text("Each integration is a destination Daisy can send a finished session to via MCP. The `Send to {name}` action shows up in the session's kebab menu in History. Disabled integrations don't appear there.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                HStack(spacing: 8) {
                    Menu {
                        Button("Blank integration") {
                            editingIntegration = MCPIntegration(
                                name: "New integration",
                                baseURL: "http://127.0.0.1:11436",
                                toolName: "",
                                argumentsTemplate: "{}",
                                enabled: true
                            )
                        }
                        Divider()
                        // Notion has a first-class section above — no
                        // template here to avoid two-ways-to-add-Notion
                        // mental-model confusion. Linear stays as the
                        // canonical MCP template starter.
                        Text("Templates").font(.caption).foregroundStyle(.secondary)
                        Button("Linear (create_issue)") {
                            editingIntegration = MCPIntegration.linearDefault()
                        }
                    } label: {
                        Label("Add integration", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .menuIndicator(.hidden)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingIntegration) { integration in
            IntegrationEditor(
                initial: integration,
                onSave: { updated in
                    if integrationStore.integrations.contains(where: { $0.id == updated.id }) {
                        integrationStore.update(updated)
                    } else {
                        integrationStore.add(updated)
                    }
                    editingIntegration = nil
                },
                onCancel: { editingIntegration = nil }
            )
            .frame(minWidth: 580, minHeight: 520)
        }
    }

    @ViewBuilder
    private func integrationRow(_ integration: MCPIntegration) -> some View {
        HStack(spacing: 10) {
            Toggle(
                integration.name,
                isOn: Binding(
                    get: { integration.enabled },
                    set: { newValue in
                        var copy = integration
                        copy.enabled = newValue
                        integrationStore.update(copy)
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            // VoiceOver still reads the label even when hidden;
            // sighted users see the name in the VStack alongside.
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name)
                    .font(.callout.weight(.medium))
                Text("\(integration.toolName) · \(integration.baseURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                editingIntegration = integration
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            .accessibilityLabel("Edit \(integration.name)")
            Button(role: .destructive) {
                integrationStore.remove(id: integration.id)
            } label: {
                // `role: .destructive` already styles this red on
                // macOS — no manual `foregroundStyle` so we don't
                // bypass system hover/disabled states.
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .accessibilityLabel("Delete \(integration.name)")
        }
    }

    // MARK: - MCP server (Phase 6a)

    @State private var mcpPortText: String = ""

    private var mcpTab: some View {
        Form {
            Section {
                Toggle(isOn: $settings.mcpServerEnabled) {
                    Text("Let AI clients read your sessions")
                    Text("So Claude Desktop, Cursor and other MCP-compatible tools on this Mac can read your transcripts and summaries. Bound to 127.0.0.1 only — nothing leaves this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                mcpStatusRow
            } header: {
                Text("Local server")
            }

            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    // Empty `""` as first arg avoids the Form-quirk
                    // where the first string becomes a row label
                    // (would render a duplicate "54321" above the
                    // field). Real prompt goes through `prompt:`.
                    TextField("", text: $mcpPortText, prompt: Text("54321"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { commitMCPPort() }
                }
                Text("Default 54321. Change only if another app on this Mac is already bound to that port.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Network")
            }

            Section {
                Text(mcpConfigSnippet)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                    )

                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpConfigSnippet, forType: .string)
                        ToastCenter.shared.show("MCP config copied", style: .success)
                    } label: {
                        Label("Copy snippet", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                }
            } header: {
                Text("Connect a client")
            } footer: {
                Text("Paste into ~/Library/Application Support/Claude/claude_desktop_config.json under \"mcpServers\", then restart Claude Desktop. The same URL works in any client that speaks MCP over SSE.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear { mcpPortText = String(settings.mcpServerPort) }
        .onChange(of: settings.mcpServerPort) { _, new in
            mcpPortText = String(new)
        }
    }

    @ViewBuilder
    private var mcpStatusRow: some View {
        HStack(spacing: 8) {
            switch mcpServer.state {
            case .stopped:
                StatusBadge(state: .idle, message: nil)
                Text("Not running").font(.caption).foregroundStyle(.secondary)
            case .starting(let port):
                StatusBadge(state: .busy, message: "Starting on port \(port)…")
            case .running(let port):
                StatusBadge(state: .ok, message: "Listening on 127.0.0.1:\(port)")
            case .failed(let msg):
                StatusBadge(state: .err, message: msg)
            }
            Spacer()
        }
    }

    private var mcpConfigSnippet: String {
        let port = settings.mcpServerPort
        return """
        {
          "mcpServers": {
            "daisy": {
              "url": "http://127.0.0.1:\(port)/sse"
            }
          }
        }
        """
    }

    private func commitMCPPort() {
        let trimmed = mcpPortText.trimmingCharacters(in: .whitespaces)
        if let p = Int(trimmed), p > 0, p <= 65535 {
            settings.mcpServerPort = p
        } else {
            mcpPortText = String(settings.mcpServerPort)
            ToastCenter.shared.show("Port must be 1–65535", style: .warning)
        }
    }

    // MARK: - Calendar permission row

    @ViewBuilder
    private var calendarPermissionRow: some View {
        HStack(spacing: 10) {
            switch calendar.authorizationStatus {
            case .fullAccess:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.daisySuccess)
                Text("Calendar access granted").fontWeight(.medium)
                Spacer()
                Button("Revoke…") {
                    calendar.openCalendarPrivacy()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
            case .notDetermined:
                Image(systemName: "calendar.badge.plus").foregroundStyle(.secondary)
                Text("Calendar access not requested yet").foregroundStyle(.secondary)
                Spacer()
                Button("Connect Calendar") {
                    Task {
                        let status = await calendar.requestAccess()
                        settings.calendarAccessGranted = (status == .fullAccess)
                        if settings.calendarAccessGranted {
                            CalendarService.shared.start(
                                lookaheadHours: 24,
                                autoStartOnMeeting: settings.autoStartFromCalendar
                            ) { meeting in
                                // The actual start handler is wired in
                                // DaisyApp.init on next launch; for the
                                // mid-session case we just refresh
                                // upcoming so the Home view populates.
                                _ = meeting
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .denied, .restricted:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.daisyWarning)
                Text("Calendar access denied").foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings…") {
                    calendar.openCalendarPrivacy()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .writeOnly:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.daisyWarning)
                Text("Full access needed — current permission is write-only").foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings…") {
                    calendar.openCalendarPrivacy()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            @unknown default:
                EmptyView()
            }
        }
        .font(.callout)
    }

    // MARK: - Capture

    private var captureTab: some View {
        captureTabForm
            .task { refreshMicDevices() }
    }

    private var captureTabForm: some View {
        Form {
            Section {
                micPickerRow
                Toggle(isOn: $settings.captureSystemAudio) {
                    Text("Capture system audio")
                    Text("Records the other side of the meeting (Zoom, Meet, Telegram). macOS will ask for Screen & System Audio Recording permission the first time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio")
            }

            Section {
                storageRow
                Text("Audio, transcripts, summaries and screenshots are written to `Daisy/Sessions/` inside this folder. Existing recordings stay where they were — Daisy reads from both the new and the old location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Storage")
            }

            Section {
                Toggle(isOn: $settings.floatingWidgetEnabled) {
                    Text("Keep it on top of other windows")
                    Text("A small daisy mark sits above your apps while recording. Tap to pause or resume; right-click for Stop & save. The menu bar item and main window stay available either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Floating widget")
            }

            Section {
                LabeledContent("Global shortcut") {
                    HotkeyRecorder(value: $settings.recordHotkey)
                }
                LabeledContent("Preset") {
                    Menu {
                        ForEach(HotkeyChoice.allPresets) { preset in
                            Button {
                                settings.recordHotkey = preset
                            } label: {
                                if preset == settings.recordHotkey {
                                    Label(preset.label, systemImage: "checkmark")
                                } else {
                                    Text(preset.label)
                                }
                            }
                        }
                    } label: {
                        Text(presetMenuLabel)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text("Pressed from any app, toggles pause / resume during a session or starts a new one. Combos must include ⌘, ⌃ or ⌥ — or a bare function key (F1–F20). Bare letters would hijack normal typing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hotkey")
            }

            Section {
                Toggle(isOn: $settings.autoStartOnMeeting) {
                    Text("Start when a meeting app opens")
                    Text("Daisy begins recording the moment Zoom, Microsoft Teams, Webex, Telegram or Discord launches. Apps that were already open when you started Daisy are left alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Auto-start on app launch")
            }

            Section {
                calendarPermissionRow

                Toggle(isOn: $settings.autoStartFromCalendar) {
                    Text("Start at the scheduled time")
                    Text("Daisy reads your calendar, finds events with a Zoom, Google Meet, Teams or Webex link, and starts recording when they begin. Covers browser-based meetings (Google Meet in Chrome). Up to 2 minutes late is still OK.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.calendarAccessGranted)

                Toggle(isOn: $settings.autoStopFromCalendar) {
                    Text("Stop when the event ends")
                    Text("For sessions bound to a calendar event, Daisy runs Stop & save at the event's end time plus a grace period. A warning toast appears 30 seconds before — if the conversation runs over, click Keep going and the timer resets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.calendarAccessGranted)

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
                    .disabled(!settings.calendarAccessGranted)
                }
            } header: {
                Text("Calendar")
            }

            Section {
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
                Text("Screenshots")
            }

            // Auto-summary moved to the Summary tab — it sits next
            // to the provider config it depends on.
        }
        .formStyle(.grouped)
    }

    // Microphone selector row in the Capture tab. Empty UID == follow
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

                Button {
                    refreshMicDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
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
                Text("Whisper runs entirely on-device using CoreML. Larger models give better accuracy and handle accents / Russian / multilingual meetings better, at the cost of disk space and slightly slower transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Model")
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
                modelsCacheRow
            } header: {
                Text("Cache")
            } footer: {
                Text("Switching to a different model downloads it alongside the previous one — old files aren't deleted automatically so a downgrade is instant. Use Remove unused to free disk space.")
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
            Section {
                Picker("Provider", selection: $summarizer.providerKind) {
                    ForEach(SummaryProviderKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                Text(summarizer.providerKind.privacyTag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Summary provider")
            } footer: {
                Text("Choose where summarization runs. Apple Intelligence is fully on-device but doesn't support every language (e.g. Russian). The cloud providers handle any language; transcripts are sent over HTTPS using your own API key.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Provider-specific config
            providerConfigSection

            Section {
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
                Text(summarizerStatusBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Provider status")
            }

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

    @ViewBuilder
    private var providerConfigSection: some View {
        switch summarizer.providerKind {
        case .appleIntelligence:
            EmptyView()

        case .anthropic:
            Section {
                SecureField("sk-ant-...", text: $settings.anthropicAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Create a key at console.anthropic.com/settings/keys. Stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Anthropic API key")
            }

            Section {
                Picker("Model", selection: $summarizer.anthropicModel) {
                    ForEach(AnthropicAPISummarizer.availableModels, id: \.id) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Model")
            }

            Section {
                HStack {
                    Button("Test summary") {
                        Task { await testSummaryProvider() }
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.daisyTextPrimary)
                    .disabled(summaryTestResult == .testing || settings.anthropicAPIKey.isEmpty)
                    Spacer()
                    summaryTestStatusView
                }
                Text("Sends a realistic two-person client call through the provider so you can see exactly what a finished session will look like — and confirm the response parses correctly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            summaryTestPreviewSection

        case .openai:
            Section {
                SecureField("sk-proj-...", text: $settings.openaiAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Create a key at platform.openai.com/api-keys. Stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("OpenAI API key")
            }

            Section {
                Picker("Model", selection: $summarizer.openaiModel) {
                    ForEach(OpenAIAPISummarizer.availableModels, id: \.id) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Model")
            }

            Section {
                HStack {
                    Button("Test summary") {
                        Task { await testSummaryProvider() }
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.daisyTextPrimary)
                    .disabled(summaryTestResult == .testing || settings.openaiAPIKey.isEmpty)
                    Spacer()
                    summaryTestStatusView
                }
                Text("Sends a realistic two-person client call through the provider so you can see exactly what a finished session will look like — and confirm the response parses correctly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            summaryTestPreviewSection

        case .mcp:
            Section {
                LabeledContent("Server URL") {
                    TextField("http://127.0.0.1:11435", text: $settings.mcpSummarizerURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                LabeledContent("Tool name") {
                    TextField("chat", text: $settings.mcpSummarizerToolName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                Text("Daisy connects over HTTP+SSE and calls one tool per summarize. Most local-LLM wrappers expose a `chat` or `complete` tool — check your wrapper's docs for the exact name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Local LLM connection")
            }

            // Presets — let users pick a known wrapper's shape so
            // they never have to hand-write JSON.
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

            // Engineering escape hatch — hand-edit the raw JSON. Most
            // users never open this; preset above covers the
            // common cases.
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

            Section {
                HStack {
                    Button("Test summary") {
                        Task { await testSummaryProvider() }
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.daisyTextPrimary)
                    .disabled(summaryTestResult == .testing
                              || settings.mcpSummarizerURL.isEmpty
                              || settings.mcpSummarizerToolName.isEmpty)
                    Spacer()
                    summaryTestStatusView
                }
                Text("Sends a realistic two-person client call through your MCP server. Confirms the URL is reachable, the tool exists, the response parses into the expected schema — and shows you what a finished session will look like.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            summaryTestPreviewSection
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

                    previewMDSection(title: "Meeting") {
                        Text(preview.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !preview.actionItems.isEmpty {
                        previewMDSection(title: "Next actions") {
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
                        previewMDSection(title: "Follow-up for client / partner") {
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
        do {
            let summary = try await summarizer.runProbe(
                transcript: Self.fixtureTranscript,
                title: Self.fixtureTitle,
                localeHint: "en"
            )
            summaryTestResult = .success("Summary came through.")
            summaryTestPreview = summary
        } catch {
            summaryTestResult = .failure(error.localizedDescription)
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

    // MARK: - Notion (helpers used by integrationsTab)

    private var testStatusView: some View {
        switch notionTestResult {
        case .idle:        StatusBadge(state: .idle)
        case .testing:     StatusBadge(state: .busy)
        case .success(let msg): StatusBadge(state: .ok, message: msg)
        case .failure(let msg): StatusBadge(state: .err, message: msg)
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
            NSWorkspace.shared.open(url)
        } catch {
            notionTestResult = .failure(error.localizedDescription)
        }
    }

    // MARK: - About

    // About content lives in `AboutView.swift` — promoted out of
    // Settings tabs into a top-level sidebar section.
}

#Preview {
    SettingsView(settings: AppSettings())
}
