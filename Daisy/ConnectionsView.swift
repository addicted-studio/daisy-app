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
//  Layout: TabView with two tabs — MCP server (incoming) and
//  Auto-routing (outgoing MCP integrations). External CTAs can
//  deep-link via `AppNavigation.shared.openInConnections(.mcpServer)`
//  etc. Notion / Calendar destinations live in Settings; this page
//  is reserved for power-user MCP wiring.
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
    /// 1.0.4: Calendar tab left — EventKit grant in Settings →
    /// Permissions, behaviour toggles in Settings → General.
    /// 1.0.5: Notion tab left too — destination of the same logical
    /// class as the local sessions folder, lives in Settings →
    /// General → Storage with an inline disclosure for advanced
    /// fields. Google Calendar OAuth UI stays dormant pre-
    /// verification; when Google approves it comes back here.
    @State private var selectedSection: ConnectionSection = .mcpServer
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
    // The actual section content (mcpServerSection / autoRoutingSection)
    // is unchanged from when it lived in the stacked scroll layout.

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

    // Notion configuration moved to Settings → General → Storage in
    // 1.0.5 — destination of the same logical class as the local
    // sessions folder. The Test connection flow, auto-send toggle,
    // folder filter, and credentials all live there now next to the
    // sessions folder picker, with the advanced fields collapsed in
    // a DisclosureGroup so they don't dominate the General tab.

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

    // Shared helpers (labelWithCaption, folderFilterPicker,
    // folderFilterSummary) left with the Notion section to
    // Settings in 1.0.5 — they were used only by Notion config
    // here. SettingsView owns the canonical copies now.
}
