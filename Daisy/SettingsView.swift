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

    @State private var notionTestResult: TestResult = .idle
    @State private var summaryTestResult: TestResult = .idle

    enum TestResult: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

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

            notionTab
                .tabItem { Label("Notion", systemImage: "doc.text") }
                .scrollContentBackground(.hidden)

            mcpTab
                .tabItem { Label("MCP", systemImage: "antenna.radiowaves.left.and.right") }
                .scrollContentBackground(.hidden)

            autoActionsTab
                .tabItem { Label("Auto-actions", systemImage: "paperplane") }
                .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color.daisyBgPrimary)
        .task { await summarizer.refreshAvailability() }
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

    private var autoActionsTab: some View {
        Form {
            Section {
                if integrationStore.integrations.isEmpty {
                    Text("No integrations yet. Add one to push finished sessions into Notion, Linear, or any MCP-compatible service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(integrationStore.integrations) { integration in
                        integrationRow(integration)
                    }
                }
            } header: {
                Text("Integrations")
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
                        Text("Templates").font(.caption).foregroundStyle(.secondary)
                        Button("Notion (create_page)") {
                            editingIntegration = MCPIntegration.notionDefault()
                        }
                        Button("Linear (create_issue)") {
                            editingIntegration = MCPIntegration.linearDefault()
                        }
                    } label: {
                        Label("Add integration", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
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
                "",
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
            Button(role: .destructive) {
                integrationStore.remove(id: integration.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Color.daisyError)
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
    }

    // MARK: - MCP server (Phase 6a)

    @State private var mcpPortText: String = ""

    private var mcpTab: some View {
        Form {
            Section {
                Toggle(isOn: $settings.mcpServerEnabled) {
                    Text("Run local MCP server")
                    Text("Lets Claude Desktop, Claude Code, Cowork, Cursor and any other MCP-compatible client read your Daisy transcripts and summaries. Bound to 127.0.0.1 only — nothing ever leaves this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                mcpStatusRow
            } header: {
                Text("Server")
            }

            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("54321", text: $mcpPortText, prompt: Text("54321"))
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
                }
            } header: {
                Text("Claude Desktop config")
            } footer: {
                Text("Paste this into ~/Library/Application Support/Claude/claude_desktop_config.json under the top-level \"mcpServers\" key. Restart Claude Desktop to pick it up. Same shape works for any client that speaks MCP over SSE.")
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
            switch MCPServer.shared.state {
            case .stopped:
                Image(systemName: "circle.fill").foregroundStyle(.tertiary)
                Text("Not running").foregroundStyle(.secondary)
            case .starting(let port):
                ProgressView().controlSize(.small)
                Text("Starting on port \(port)…").foregroundStyle(.secondary)
            case .running(let port):
                Image(systemName: "circle.fill").foregroundStyle(Color.daisySuccess)
                Text("Listening on 127.0.0.1:\(port)").fontWeight(.medium)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.daisyError)
                Text(msg).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
        }
        .font(.caption)
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
                    calendar.openSystemSettingsIfDenied()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                    calendar.openSystemSettingsIfDenied()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .writeOnly:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.daisyWarning)
                Text("Full access needed — current permission is write-only").foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings…") {
                    calendar.openSystemSettingsIfDenied()
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
        Form {
            Section {
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
                Toggle(isOn: $settings.floatingWidgetEnabled) {
                    Text("Show floating widget")
                    Text("Pops a small daisy mark above all other windows while a session is active. Tap to pause / resume, right-click for Stop & save. The menu bar item and main window stay available either way — this is just an extra always-visible affordance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Floating widget")
            }

            Section {
                HStack {
                    Text("Global shortcut")
                    Spacer()
                    HotkeyRecorder(value: $settings.recordHotkey)
                }
                Menu("Choose preset…") {
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
                }
                .menuStyle(.borderlessButton)
                Text("Pressed from any app, starts a new recording or stops the current one. Click the shortcut pill to record your own combination, or pick a preset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hotkey")
            }

            Section {
                Toggle(isOn: $settings.autoStartOnMeeting) {
                    Text("Start automatically when a meeting app opens")
                    Text("Daisy will begin recording the moment Zoom, Microsoft Teams, Webex, Telegram or Discord launches. Apps that were already open when you started Daisy are left alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Auto-start · app launch")
            }

            Section {
                calendarPermissionRow

                Toggle(isOn: $settings.autoStartFromCalendar) {
                    Text("Start automatically at the scheduled time")
                    Text("Daisy reads your calendar, finds events with a Zoom / Google Meet / Teams / Webex link in them, and starts recording at the moment they begin. This is how browser-based meetings (Google Meet in Chrome) get covered. Up to 2 minutes late is still OK — Daisy will start if you’re running behind.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.calendarAccessGranted)
            } header: {
                Text("Auto-start · calendar")
            }

            Section {
                Toggle(isOn: $settings.autoStopFromCalendar) {
                    Text("Stop automatically when the event ends")
                    Text("For sessions bound to a calendar event, Daisy schedules a Stop & save at the event's end time plus a grace period. You get a cancellable warning toast 30 seconds before — if the conversation runs over, click Keep going and the timer resets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.calendarAccessGranted)

                if settings.autoStopFromCalendar {
                    Stepper(value: $settings.autoStopGraceSec, in: 0...1800, step: 30) {
                        HStack {
                            Text("Grace period")
                            Spacer()
                            Text(graceLabel(seconds: settings.autoStopGraceSec))
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Auto-stop · calendar")
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

            Section {
                Toggle(isOn: $settings.autoSummarize) {
                    Text("Summarize automatically when recording stops")
                    Text("Runs the selected AI provider on the transcript the moment you stop recording — meeting summary, next actions, and a follow-up draft for clients or partners. Configure the provider in Settings → AI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!summarizerAvailable)
                if !summarizerAvailable {
                    Text("AI provider isn’t ready — open Settings → AI to configure it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Auto-summary")
            }
        }
        .formStyle(.grouped)
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
                    whisperStatusIcon
                    Text(whisperStatusText).fontWeight(.medium)
                    Spacer()
                    Button("Reload") { Task { await whisper.reload() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isWhisperLoading)
                }
                whisperStatusBody
            } header: {
                Text("Status")
            } footer: {
                Text("First time a model is selected it downloads from Hugging Face (argmaxinc/whisperkit-coreml). The model is stored inside the app's container and reused for subsequent meetings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private var whisperStatusIcon: some View {
        Group {
            switch whisper.state {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.daisySuccess)
            case .downloading, .loading:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.daisyError)
            case .notLoaded:
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            }
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
                    summarizerStatusIcon
                    Text(summarizerStatusText).fontWeight(.medium)
                    Spacer()
                    Button("Refresh") {
                        Task { await summarizer.refreshAvailability() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text(summarizerStatusBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Status")
            }

            Section {
                Picker("Summary language", selection: $settings.summaryLanguage) {
                    ForEach(SummaryLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.id)
                    }
                }
                .pickerStyle(.menu)
                Text("Pin the language the AI writes the summary in. Decoupled from the transcript — you can record in one language and read the summary in another (handy for sending follow-ups to clients in a different language).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Summary language")
            }

            // The "auto-summarize on stop" toggle used to live here, but
            // logically it's a capture-time behaviour, not a provider
            // configuration — moved to the Capture tab where the user
            // already configures what happens during/after a recording.
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
                    .disabled(summaryTestResult == .testing || settings.anthropicAPIKey.isEmpty)
                    Spacer()
                    summaryTestStatusView
                }
            }

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
                    .disabled(summaryTestResult == .testing || settings.openaiAPIKey.isEmpty)
                    Spacer()
                    summaryTestStatusView
                }
            }

        case .mcp:
            Section {
                HStack {
                    Text("Server URL")
                    Spacer()
                    TextField("http://127.0.0.1:11435", text: $settings.mcpSummarizerURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                HStack {
                    Text("Tool name")
                    Spacer()
                    TextField("chat", text: $settings.mcpSummarizerToolName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                Text("Daisy connects to your MCP server over HTTP+SSE and calls one tool per summarize. Most local-LLM wrappers expose either a `chat` or `complete` tool — check your wrapper's `tools/list` for the exact name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("MCP server")
            }

            Section {
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
                    Spacer()
                }
                Text("JSON template for the tool's `arguments`. Three placeholders get substituted before sending: `{{system}}` (Daisy's system prompt), `{{transcript}}` (meeting title + body), `{{title}}` (meeting title alone). Edit the `model` field to match a model your wrapper has pulled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Arguments template")
            }

            Section {
                HStack {
                    Button("Test summary") {
                        Task { await testSummaryProvider() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(summaryTestResult == .testing
                              || settings.mcpSummarizerURL.isEmpty
                              || settings.mcpSummarizerToolName.isEmpty)
                    Spacer()
                    summaryTestStatusView
                }
                Text("Sends a short fixture transcript through your MCP server. Confirms the URL is reachable, the tool exists, and the response parses into the expected schema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summarizerStatusIcon: some View {
        Group {
            switch summarizer.availability {
            case .available:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.daisySuccess)
            case .unavailable:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.daisyError)
            case .unknown:
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
            }
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
        Group {
            switch summaryTestResult {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .success(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.daisySuccess)
                    .font(.caption)
                    .lineLimit(2)
            case .failure(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.daisyError)
                    .font(.caption)
                    .lineLimit(3)
            }
        }
    }

    private func testSummaryProvider() async {
        summaryTestResult = .testing
        // Tiny test transcript so we don't burn many tokens.
        let probeTranscript = """
        [you] Hi, this is a quick connection test from Daisy.
        We discussed two items: confirming the API works, and noting the model name.
        Decision: ship after this test passes.
        """
        await summarizer.summarize(
            transcript: probeTranscript,
            title: "Daisy — connection test",
            localeHint: "en"
        )
        if let err = summarizer.lastError {
            summaryTestResult = .failure(err)
        } else if summarizer.lastSummary != nil {
            summaryTestResult = .success("Got a summary back — provider works.")
        } else {
            summaryTestResult = .failure("No response.")
        }
    }

    // MARK: - Notion

    private var notionTab: some View {
        Form {
            Section {
                SecureField("secret_xxxxxxxxxxxxxxxxxxxxxxx", text: $settings.notionToken)
                    .textFieldStyle(.roundedBorder)
                Text("Create a Notion internal integration at notion.so/profile/integrations, copy the token, and share the parent page with that integration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Integration token")
            }

            Section {
                TextField("a1b2c3d4e5f6...", text: $settings.notionParentID)
                    .textFieldStyle(.roundedBorder)
                Text("32-character page ID — the long string at the end of the page URL, with or without dashes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Parent page ID")
            }

            Section {
                HStack {
                    Button("Test connection") {
                        Task { await testNotion() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(notionTestResult == .testing || !settings.hasNotionCredentials)
                    Spacer()
                    testStatusView
                }
            }
        }
        .formStyle(.grouped)
    }

    private var testStatusView: some View {
        Group {
            switch notionTestResult {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .success(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.daisySuccess)
                    .font(.caption)
                    .lineLimit(2)
            case .failure(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.daisyError)
                    .font(.caption)
                    .lineLimit(3)
            }
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
            notionTestResult = .success("Test page created.")
            NSWorkspace.shared.open(url)
        } catch {
            notionTestResult = .failure(error.localizedDescription)
        }
    }
}

#Preview {
    SettingsView(settings: AppSettings())
}
