//
//  MCPIntegration.swift
//  Daisy
//
//  User-configured MCP servers Daisy can push session content into
//  (Notion, Linear, Asana, whatever exposes MCP tools). Each
//  integration is a small Codable record persisted as JSON in
//  UserDefaults under "daisy.mcpIntegrations".
//
//  Distinct from `mcpSummarizer.*` settings — those describe a
//  single MCP server used for LLM summarization. Integrations here
//  are an arbitrary-length list of destinations the user can fan
//  finished sessions out to.
//

import Foundation
import Observation
import os
// `Array.remove(atOffsets:)` (used by MCPIntegrationStore.remove(at:))
// is an extension SwiftUI ships for IndexSet-based deletion from
// ForEach/.onDelete handlers. Linking SwiftUI here keeps the store
// usable from both Form rows and any future drag-reorder UI.
import SwiftUI

// MARK: - Model

/// One user-configured destination. Sendable + Codable so it
/// round-trips through UserDefaults cleanly.
nonisolated struct MCPIntegration: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var baseURL: String
    var toolName: String
    /// JSON template for the tool's `arguments`. Supports the same
    /// placeholders MCPDispatcher knows how to substitute:
    /// {{title}}, {{date}}, {{summary}}, {{actionItems}},
    /// {{actionItemsBullets}}, {{clientFollowUp}}, {{transcript}},
    /// {{folder}}, {{locale}}.
    var argumentsTemplate: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        toolName: String,
        argumentsTemplate: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.toolName = toolName
        self.argumentsTemplate = argumentsTemplate
        self.enabled = enabled
    }

    // MARK: - Starter presets

    /// Notion shape: assumes a `create_page` tool that takes a
    /// parent database id, a title, and a content block array.
    /// Most Notion-MCP wrappers follow this shape (see
    /// modelcontextprotocol/server-notion).
    static func notionDefault() -> MCPIntegration {
        MCPIntegration(
            name: "Notion",
            baseURL: "http://127.0.0.1:11436",
            toolName: "create_page",
            argumentsTemplate: """
            {
              "parent": {"database_id": "<your-database-id>"},
              "properties": {
                "Name": {
                  "title": [{"text": {"content": "{{title}}"}}]
                }
              },
              "children": [
                {"type": "heading_2", "heading_2": {"rich_text": [{"text": {"content": "Meeting"}}]}},
                {"type": "paragraph", "paragraph": {"rich_text": [{"text": {"content": "{{summary}}"}}]}},
                {"type": "heading_2", "heading_2": {"rich_text": [{"text": {"content": "Next actions"}}]}},
                {"type": "paragraph", "paragraph": {"rich_text": [{"text": {"content": "{{actionItemsBullets}}"}}]}},
                {"type": "heading_2", "heading_2": {"rich_text": [{"text": {"content": "Follow-up"}}]}},
                {"type": "paragraph", "paragraph": {"rich_text": [{"text": {"content": "{{clientFollowUp}}"}}]}}
              ]
            }
            """,
            enabled: true
        )
    }

    /// Linear shape: `create_issue` tool taking team id, title,
    /// description. One issue per session — action items go into
    /// the description as a checkbox list.
    static func linearDefault() -> MCPIntegration {
        MCPIntegration(
            name: "Linear",
            baseURL: "http://127.0.0.1:11437",
            toolName: "create_issue",
            argumentsTemplate: """
            {
              "teamId": "<your-team-id>",
              "title": "{{title}}",
              "description": "## Meeting\\n\\n{{summary}}\\n\\n## Next actions\\n\\n{{actionItemsBullets}}\\n\\n## Follow-up\\n\\n{{clientFollowUp}}"
            }
            """,
            enabled: true
        )
    }
}

// MARK: - Store

@Observable
@MainActor
final class MCPIntegrationStore {
    static let shared = MCPIntegrationStore()

    private(set) var integrations: [MCPIntegration] = []

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "MCPIntegrationStore")
    @ObservationIgnored
    private let defaults = UserDefaults.standard
    @ObservationIgnored
    private static let storageKey = "daisy.mcpIntegrations"

    private init() {
        load()
    }

    // MARK: - Public CRUD

    func add(_ integration: MCPIntegration) {
        integrations.append(integration)
        save()
    }

    func update(_ integration: MCPIntegration) {
        guard let idx = integrations.firstIndex(where: { $0.id == integration.id }) else { return }
        integrations[idx] = integration
        save()
    }

    func remove(id: UUID) {
        integrations.removeAll(where: { $0.id == id })
        save()
    }

    func remove(at offsets: IndexSet) {
        integrations.remove(atOffsets: offsets)
        save()
    }

    /// Enabled integrations only — what we surface in per-session
    /// menus and in the dispatcher.
    var enabledIntegrations: [MCPIntegration] {
        integrations.filter { $0.enabled }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            integrations = try JSONDecoder().decode([MCPIntegration].self, from: data)
        } catch {
            log.error("Failed to decode integrations: \(error.localizedDescription, privacy: .public). Resetting to empty.")
            integrations = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(integrations)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            log.error("Failed to encode integrations: \(error.localizedDescription, privacy: .public)")
        }
    }
}
