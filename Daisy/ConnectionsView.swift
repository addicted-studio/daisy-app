//
//  ConnectionsView.swift
//  Daisy
//
//  First-class sidebar destination for everything that touches the
//  outside world: calendar sources, Notion, MCP server, auto-routing
//  to other integrations. Previously these lived inside Settings as
//  separate tabs (Integrations / MCP server), with calendar
//  connection rows scattered into the General (formerly Capture) tab.
//
//  Why a top-level destination instead of a Settings tab:
//   • The Settings TabView was at 5 tabs and growing (Apple HIG: ≤5).
//   • Calendar connections live in the same mental category as Notion
//     and the MCP socket — "where Daisy talks to other systems" —
//     not "how the recorder works". Splitting them by tab obscured
//     that.
//   • Users come back here regularly: to check whether Notion's still
//     authed, what port the MCP server is on, whether Google Calendar
//     re-needs consent. Settings-tab depth was wrong for that flow.
//
//  Layout: a single Form with three anchored Sections so external
//  CTAs (FirstRun, Home destination prompts) can deep-link via
//  `AppNavigation.shared.openInConnections(.notion)` etc., and we
//  scroll to the right section.
//

import SwiftUI

struct ConnectionsView: View {
    @Bindable var settings: AppSettings
    @Bindable var mcpServer = MCPServer.shared
    @Bindable var integrationStore = MCPIntegrationStore.shared
    @Bindable var nav = AppNavigation.shared

    // MARK: - View state

    /// Currently-selected Connections tab. Persisted across navigations
    /// to / from the Connections sidebar entry within the same launch;
    /// deep-links (AppNavigation.openInConnections(_:)) write through
    /// to this value on .onChange.
    ///
    /// 1.0.4: Calendar tab left this page entirely — EventKit grant is
    /// in Settings → Permissions, behaviour toggles are in Settings →
    /// General. Google Calendar OAuth UI is dormant pre-verification;
    /// it'll come back here as its own tab once Google approves.
    @State private var selectedSection: ConnectionSection = .notion
    @State private var notionTestResult: TestResult = .idle
    @State private var editingIntegration: MCPIntegration?
    @State private var mcpPortText: String = ""
    /// Disables the "Add to Claude Desktop" button while the open
    /// panel + JSON merge are running. Without this a user could
    /// double-click and end up with two overlapping NSOpenPanels.
    @State private var claudeInstallInProgress: Bool = false
    /// Mirrors `ClaudeDesktopConfig.isInstalled` so the button can
    /// switch between "Add to Claude Desktop" (first run) and
    /// "Refresh Claude Desktop config" (after the bookmark is
    /// stored). Set on appear and after each install run.
    @State private var claudeBookmarkExists: Bool = false

    enum TestResult: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    // MARK: - Body

    var body: some View {
        // Four tabs, one per connection category. Previously a single
        // anchored ScrollView Form with all sections stacked — switched
        // to tabs because (a) only one section is ever the active focus
        // of attention; the rest were visual clutter that pushed the
        // important content below the fold, and (b) deep-links now
        // simply flip the selected tab instead of animating a scroll,
        // which is the macOS-native idiom for "go to that subsection".
        // Section headers inside each tab still carry the status pill
        // (Connected / Running / Needs test) so a glance at any tab
        // gives you the live state without leaving the page.
        TabView(selection: $selectedSection) {
            notionTab
                .tag(ConnectionSection.notion)
                .tabItem { Label("Notion", systemImage: "paperplane") }
                .scrollContentBackground(.hidden)

            mcpServerTab
                .tag(ConnectionSection.mcpServer)
                .tabItem { Label("MCP server", systemImage: "antenna.radiowaves.left.and.right") }
                .scrollContentBackground(.hidden)

            autoRoutingTab
                .tag(ConnectionSection.autoRouting)
                .tabItem { Label("Auto-routing", systemImage: "arrow.triangle.swap") }
                .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color.daisyBgPrimary)
        .onAppear {
            mcpPortText = String(settings.mcpServerPort)
            claudeBookmarkExists = ClaudeDesktopConfig.isInstalled
            consumePendingSection()
        }
        .onChange(of: nav.pendingConnectionsSection) { _, _ in
            consumePendingSection()
        }
        .onChange(of: settings.mcpServerPort) { _, new in
            mcpPortText = String(new)
            // If the user has already wired Daisy into Claude Desktop,
            // silently rewrite the config so the URL keeps pointing at
            // the right port.
            ClaudeDesktopConfig.refreshIfInstalled(port: new)
        }
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

    /// One-shot deep-link consumer. AppNavigation writes a pending
    /// section before flipping `section = .connections`; we read it
    /// here on appear / on change and flip the selected tab.
    private func consumePendingSection() {
        guard let pending = nav.pendingConnectionsSection else { return }
        selectedSection = pending
        nav.pendingConnectionsSection = nil
    }

    // MARK: - Tab wrappers
    //
    // Each tab is a single-Section Form so it inherits the same
    // grouped-card chrome the rest of Daisy's preference surfaces use.
    // The actual section content (notionSection / mcpServerSection / …)
    // is unchanged from when it lived in the stacked scroll layout.

    private var notionTab: some View {
        Form { notionSection }
            .formStyle(.grouped)
    }

    private var mcpServerTab: some View {
        Form { mcpServerSection }
            .formStyle(.grouped)
    }

    private var autoRoutingTab: some View {
        Form { autoRoutingSection }
            .formStyle(.grouped)
    }

    // Calendar UI moved out of Connections in 1.0.4:
    //   • EventKit grant + status badge — Settings → Permissions
    //   • Behaviour toggles (autoStart/autoStop/menuBar/grace) —
    //     Settings → General → Calendar
    //   • Google Calendar OAuth row is dormant pre-verification; the
    //     `GoogleOAuthClient` / `GoogleAccountStore` / `GoogleCalendarService`
    //     backend stays alive (existing connections keep refreshing
    //     tokens and feeding events into the merged Home view), but
    //     there's no Connect affordance until Google approves the
    //     verification questionnaire. When it does, a dedicated tab
    //     comes back here next to Notion / MCP server.

    // MARK: - Notion section

    @ViewBuilder
    private var notionSection: some View {
        Section {
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
                    testStatusView
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

            Toggle(isOn: $settings.autoSendNotion) {
                Text("Auto-send when session finishes")
                Text(autoSendNotionCaption)
                    .font(.caption)
                    .foregroundStyle(autoSendNotionCaptionStyle)
            }
            .disabled(!settings.hasNotionCredentials || settings.lastNotionTestPassedAt == nil)
            if settings.autoSendNotion {
                folderFilterPicker(
                    title: "Only from folders",
                    selection: Binding(
                        get: { settings.autoSendNotionFolders },
                        set: { settings.autoSendNotionFolders = $0 }
                    )
                )
            }
            Text("Make an internal integration at notion.so/profile/integrations, then share the parent page or database with it. Test creates a probe page you can delete.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack(spacing: 6) {
                Text("Notion")
                Spacer()
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
        }
    }

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
            // Mark this configuration as proven-working — the UI gate
            // on auto-send lifts only after this timestamp exists,
            // so a user can't silently break every future session by
            // flipping auto-send with bad credentials / a mistyped
            // parent ID / a database missing a "Name" title column.
            settings.lastNotionTestPassedAt = Date()
            NSWorkspace.shared.open(url)
        } catch {
            notionTestResult = .failure("Couldn't reach Notion — \(error.localizedDescription)")
        }
    }

    private var autoSendNotionCaption: String {
        if settings.hasNotionCredentials && settings.lastNotionTestPassedAt == nil {
            return "Pass Test connection first — auto-send needs a confirmed working setup."
        }
        return "Pushes the session to Notion the moment you stop recording."
    }

    private var autoSendNotionCaptionStyle: Color {
        if settings.hasNotionCredentials && settings.lastNotionTestPassedAt == nil {
            return Color.daisyWarning
        }
        return .secondary
    }

    // MARK: - MCP server section

    @ViewBuilder
    private var mcpServerSection: some View {
        Section {
            Toggle(isOn: $settings.mcpServerEnabled) {
                Text("Let AI clients read your sessions")
                Text("So Claude Desktop, Cursor and other MCP-compatible tools on this Mac can read your transcripts and summaries. Bound to 127.0.0.1 only — nothing leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            mcpStatusRow
            HStack {
                Text("Port")
                Spacer()
                TextField("", text: $mcpPortText, prompt: Text("54321"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { commitMCPPort() }
            }

            // Snippet + install affordance live in the same Section
            // so the Form draws no inner divider between the local-
            // server config and the client-side instructions.
            VStack(alignment: .leading, spacing: 10) {
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

                HStack(spacing: 8) {
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

                    Button {
                        Task { await installToClaudeDesktop() }
                    } label: {
                        Label(
                            claudeBookmarkExists
                                ? "Refresh Claude Desktop config"
                                : "Add to Claude Desktop",
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color.daisyAccent)
                    .disabled(claudeInstallInProgress)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("MCP server")
                Spacer()
                switch mcpServer.state {
                case .running:
                    Text("Running")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.daisySuccess)
                case .starting:
                    Text("Starting…")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                case .failed:
                    Text("Error")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.daisyWarning)
                case .stopped:
                    EmptyView()
                }
            }
        } footer: {
            Text("Default port 54321. Add to Claude Desktop writes the snippet into ~/Library/Application Support/Claude/claude_desktop_config.json. Copy snippet is for Cursor, Cline, Continue or anything else that speaks MCP over SSE.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    private func installToClaudeDesktop() async {
        claudeInstallInProgress = true
        let result = ClaudeDesktopConfig.install(port: settings.mcpServerPort)
        claudeInstallInProgress = false
        claudeBookmarkExists = ClaudeDesktopConfig.isInstalled
        switch result {
        case .installed:
            ToastCenter.shared.show(
                "Added to Claude Desktop — restart Claude to load Daisy.",
                style: .success
            )
        case .cancelled:
            break
        case .failed(let message):
            ToastCenter.shared.show(
                "Couldn't update Claude config: \(message)",
                style: .warning
            )
        }
    }

    // MARK: - Auto-routing section (MCP integrations + default destination)

    @ViewBuilder
    private var autoRoutingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if integrationStore.integrations.isEmpty {
                    Text("No MCP integrations yet. Add one to push finished sessions into Linear, a custom Notion database, or any other MCP-compatible service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(integrationStore.integrations) { integration in
                        integrationRow(integration)
                    }
                }

                HStack {
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
                        Button("Attio (note)") {
                            editingIntegration = MCPIntegration.attioDefault()
                        }
                        Button("Webhook (Slack-style)") {
                            editingIntegration = MCPIntegration.webhookDefault()
                        }
                        Button("Linear (create_issue)") {
                            editingIntegration = MCPIntegration.linearDefault()
                        }
                    } label: {
                        Label("Add integration", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .tint(Color.daisyTextPrimary)
                    .menuIndicator(.hidden)
                    Spacer()
                }
            }

            // Default destination — what Send-to fires when the user
            // clicks the toolbar button without expanding the dropdown.
            LabeledContent {
                HStack {
                    Spacer()
                    Picker("", selection: $settings.defaultDestinationID) {
                        Text("None (always show menu)").tag("")
                        if settings.hasNotionCredentials {
                            Text("Notion").tag("notion")
                        }
                        if !integrationStore.enabledIntegrations.isEmpty {
                            Divider()
                            ForEach(integrationStore.enabledIntegrations) { integration in
                                Text(integration.name).tag(integration.id.uuidString)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            } label: {
                Text("Default Send-to destination")
            }
        } header: {
            HStack(spacing: 6) {
                Text("Auto-routing")
                Spacer()
                if !integrationStore.enabledIntegrations.isEmpty {
                    Text("\(integrationStore.enabledIntegrations.count) active")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Each integration is a destination Daisy can push a finished session to over MCP — Linear ticket, custom Notion DB, webhook, anything that speaks the protocol. Clicking Send-to in a session's toolbar fires the default destination immediately; the chevron next to it still opens the full list.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .accessibilityLabel("Delete \(integration.name)")
        }
    }

    // MARK: - Shared helpers

    /// Label + caption stacked vertically in the LEADING column of
    /// a `LabeledContent` row. Mirrors the helper in SettingsView —
    /// duplicated rather than shared to keep ConnectionsView a
    /// self-contained refactor target.
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

    /// Folder-filter picker used by Notion auto-send "Only from
    /// folders" row. Same helper SettingsView used to own; moved
    /// here together with the auto-send toggle.
    @ViewBuilder
    private func folderFilterPicker(
        title: String,
        selection: Binding<Set<String>>
    ) -> some View {
        let folders = FolderStore.shared.allFolders
        VStack(alignment: .leading, spacing: 6) {
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
    }

    private func folderFilterSummary(_ slugs: Set<String>, allFolders: [SessionFolder]) -> String {
        if slugs.isEmpty { return "All folders" }
        let names = allFolders
            .filter { slugs.contains($0.slug) }
            .map(\.name)
        if names.count == 1 { return names[0] }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names.count) folders"
    }
}
