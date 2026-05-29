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
    @State private var selectedSection: ConnectionSection = .autoRouting
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

    // Google account UI moved to Settings → Permissions → Calendar
    // (build 42, 2026-05-28) — Apple Calendar and Google Calendar are
    // both calendar sources, they belong side-by-side under
    // Permissions. `GoogleAccountStore` is read directly by
    // PermissionsView now.

    // MARK: - Body

    var body: some View {
        // Two tabs since build 42: Auto-routing + MCP server. Calendar
        // tab moved to Settings → Permissions → Calendar (both Apple
        // EventKit and Google OAuth sources live there together so
        // the user has ONE place that shows "where Daisy reads
        // calendar data from"). Connections is now strictly outbound
        // integrations: where Daisy SENDS data, not where it reads
        // from.
        TabView(selection: $selectedSection) {
            autoRoutingTab
                .tag(ConnectionSection.autoRouting)
                .tabItem { Label("Auto-routing", systemImage: "arrow.triangle.swap") }
                .scrollContentBackground(.hidden)

            mcpServerTab
                .tag(ConnectionSection.mcpServer)
                .tabItem { Label("MCP server", systemImage: "antenna.radiowaves.left.and.right") }
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

    // Calendar UI moved out of Connections entirely in build 42
    // (2026-05-28). Both Apple Calendar (EventKit) and Google Calendar
    // (OAuth) now live in Settings → Permissions → Calendar — see
    // PermissionsView for the unified UI. Connections is now strictly
    // about outbound integrations (Auto-routing + MCP server).
    // Backend (`GoogleOAuthClient` / `GoogleAccountStore` /
    // `GoogleCalendarService`) is unchanged; only the UI surface moved.

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
            Text("Default port 54321. Add to Claude Desktop writes the snippet into ~/Library/Application Support/Claude/claude_desktop_config.json. Requires Node.js installed — Claude Desktop runs the snippet through `npx mcp-remote` to bridge SSE into the stdio transport Claude expects. Copy snippet works the same for Cursor / Cline / Continue.")
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
        // Claude Desktop config schema requires stdio transport
        // (`command` + `args`), not raw URL. `npx -y mcp-remote`
        // proxies a remote SSE/HTTP MCP into the stdio shape
        // Claude expects. The two extra flags after the URL pin
        // mcp-remote to the SSE transport Daisy speaks
        // (`--transport sse-only`) and allow plain HTTP on loopback
        // (`--allow-http`, otherwise mcp-remote refuses 127.0.0.1
        // since it isn't TLS). Same args work in Cursor / Cline /
        // Continue — they all accept stdio-style entries.
        return """
        {
          "mcpServers": {
            "daisy": {
              "command": "npx",
              "args": [
                "-y",
                "mcp-remote",
                "http://127.0.0.1:\(port)/sse",
                "--transport",
                "sse-only",
                "--allow-http"
              ]
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
                    // Templates dropped in 1.0.5.4 — until we verify
                    // each one works end-to-end against the real
                    // upstream service, surfacing them was promising
                    // more than the code delivers. Blank integration
                    // is the only safe path; collapsed the menu into
                    // a direct button.
                    Button {
                        editingIntegration = MCPIntegration(
                            name: "New integration",
                            baseURL: "http://127.0.0.1:11436",
                            toolName: "",
                            argumentsTemplate: "{}",
                            enabled: true
                        )
                    } label: {
                        Label("Add integration", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.daisyTextPrimary)
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
