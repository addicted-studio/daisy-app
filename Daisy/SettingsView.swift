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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color.daisyBgPrimary)
        .task { await summarizer.refreshAvailability() }
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
                Picker("Global shortcut", selection: $settings.recordHotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                Text("Pressed from any app, starts a new recording or stops the current one. Choose “Disabled” to opt out.")
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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
                Toggle(isOn: $settings.autoSummarize) {
                    Text("Summarize when recording stops")
                    Text("Generates a summary, action items, decisions, and follow-ups via the selected provider when you stop recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!summarizerAvailable)
            } header: {
                Text("Behavior")
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
        }
    }

    private var summarizerStatusIcon: some View {
        Group {
            switch summarizer.availability {
            case .available:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
                    .foregroundStyle(.green)
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
                    .foregroundStyle(.green)
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
