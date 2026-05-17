//
//  MCPTools.swift
//  Daisy
//
//  Daisy-specific tools the MCP server exposes. Reading-only by
//  design — external clients see what Daisy has captured but can't
//  mutate state. Mutation would need a separate consent flow.
//
//  Four tools live here:
//
//   • list_sessions    — paginated session metadata, optional filters
//   • get_session      — full session: transcript + summary + attendees
//   • search_sessions  — substring search over title / transcript /
//                        summary; returns hits with snippets
//   • list_folders     — available folder names
//
//  Each tool returns a single text block of JSON — clients can parse
//  it directly. (MCP allows multiple block types but text + JSON is
//  the most portable.)
//

import Foundation

@MainActor
enum MCPTools {

    // MARK: - Catalog

    /// Advertise the full toolset to the MCP client via `tools/list`.
    /// JSON Schemas are hand-rolled as AnyJSON literals.
    static func catalog() -> [MCPTool] {
        [
            MCPTool(
                name: "list_sessions",
                description: "List Daisy meeting sessions. Returns metadata only (no transcripts). Use this to discover what's available, then call get_session for the body.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("Filter by folder slug (e.g. 'inbox', 'work', 'personal'). Omit to include all folders.")
                        ]),
                        "since": .object([
                            "type": .string("string"),
                            "format": .string("date-time"),
                            "description": .string("Only return sessions started at or after this ISO-8601 timestamp.")
                        ]),
                        "until": .object([
                            "type": .string("string"),
                            "format": .string("date-time"),
                            "description": .string("Only return sessions started before this ISO-8601 timestamp.")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of sessions to return. Default 50, max 500."),
                            "minimum": .int(1),
                            "maximum": .int(500)
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            MCPTool(
                name: "get_session",
                description: "Get the full content of one session: title, timestamps, duration, attendees, transcript, summary (if present), screenshot URLs.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Session id as returned by list_sessions.")
                        ])
                    ]),
                    "required": .array([.string("id")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            MCPTool(
                name: "search_sessions",
                description: "Substring search across session titles, transcripts, and summary fields. Returns hits with a short snippet so the model can decide which to fetch in full.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Free-text query. Case-insensitive substring match.")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of hits. Default 20, max 200."),
                            "minimum": .int(1),
                            "maximum": .int(200)
                        ])
                    ]),
                    "required": .array([.string("query")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            MCPTool(
                name: "list_folders",
                description: "List the folder slugs and display names the user has set up. Use these as the `folder` argument to list_sessions.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false)
                ])
            ),
        ]
    }

    // MARK: - Dispatch

    /// Route a `tools/call` to the right handler. Errors are returned
    /// as `MCPToolCallResult.error(_:)` rather than thrown — that
    /// surface lets the LLM-side see structured error text, which is
    /// usually more useful than a hard protocol failure.
    static func call(name: String, arguments: AnyJSON?) async -> MCPToolCallResult {
        do {
            switch name {
            case "list_sessions":
                let args = try arguments?.decoded(as: ListSessionsArgs.self) ?? .init()
                return try await listSessions(args: args)
            case "get_session":
                let args = try arguments?.decoded(as: GetSessionArgs.self)
                    ?? { throw MCPToolError.missingArgument("id") }()
                return try await getSession(args: args)
            case "search_sessions":
                let args = try arguments?.decoded(as: SearchSessionsArgs.self)
                    ?? { throw MCPToolError.missingArgument("query") }()
                return try await searchSessions(args: args)
            case "list_folders":
                return await listFolders()
            default:
                return .error("Unknown tool: \(name)")
            }
        } catch let MCPToolError.missingArgument(name) {
            return .error("Missing required argument: \(name)")
        } catch {
            return .error("Tool execution failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Argument shapes

    private struct ListSessionsArgs: Decodable {
        var folder: String?
        var since: String?
        var until: String?
        var limit: Int?
    }

    private struct GetSessionArgs: Decodable {
        let id: String
    }

    private struct SearchSessionsArgs: Decodable {
        let query: String
        var limit: Int?
    }

    private enum MCPToolError: Error {
        case missingArgument(String)
    }

    // MARK: - Handlers

    private static func listSessions(args: ListSessionsArgs) async throws -> MCPToolCallResult {
        await SessionStore.shared.refresh()
        var pool = SessionStore.shared.sessions

        if let folder = args.folder, !folder.isEmpty {
            pool = pool.filter { $0.folderSlug == folder }
        }
        if let sinceStr = args.since, let since = parseISO8601(sinceStr) {
            pool = pool.filter { $0.startedAt >= since }
        }
        if let untilStr = args.until, let until = parseISO8601(untilStr) {
            pool = pool.filter { $0.startedAt < until }
        }
        let limit = max(1, min(args.limit ?? 50, 500))
        pool = Array(pool.prefix(limit))

        let payload: [SessionListItem] = pool.map(SessionListItem.init)
        return try .text(encodeJSON(payload))
    }

    private static func getSession(args: GetSessionArgs) async throws -> MCPToolCallResult {
        await SessionStore.shared.refresh()
        guard let session = SessionStore.shared.sessions.first(where: { $0.id == args.id }) else {
            return .error("No session with id: \(args.id)")
        }
        let payload = SessionFull(session)
        return try .text(encodeJSON(payload))
    }

    private static func searchSessions(args: SearchSessionsArgs) async throws -> MCPToolCallResult {
        await SessionStore.shared.refresh()
        let q = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .error("Query is empty.") }
        let limit = max(1, min(args.limit ?? 20, 200))

        let hits = SessionStore.shared.sessions
            .filter { $0.matches(query: q) }
            .prefix(limit)
            .map { SessionHit($0, query: q) }

        return try .text(encodeJSON(Array(hits)))
    }

    private static func listFolders() async -> MCPToolCallResult {
        let folders = FolderStore.shared.allFolders.map { f in
            FolderItem(slug: f.slug, name: f.name)
        }
        return (try? .text(encodeJSON(folders)))
            ?? .error("Couldn't encode folder list.")
    }

    // MARK: - DTOs (Encodable)
    //
    // We deliberately re-shape StoredSession into MCP-friendly DTOs
    // rather than Encodable-conforming the existing types. Lets us
    // pick stable field names independent of internal refactors and
    // strip out heavy fields (raw audio URLs, etc.) from listings.

    private struct SessionListItem: Encodable {
        let id: String
        let title: String
        let started_at: String
        let duration_seconds: Int
        let folder: String
        let locale: String
        let has_summary: Bool
        let has_system_audio: Bool
        let attendees: [String]
        let preview: String

        init(_ s: StoredSession) {
            self.id = s.id
            self.title = s.title
            self.started_at = ISO8601DateFormatter().string(from: s.startedAt)
            self.duration_seconds = s.durationSec
            self.folder = s.folderSlug
            self.locale = s.locale
            self.has_summary = s.hasSummary
            self.has_system_audio = s.hasSystemAudio
            self.attendees = s.meetingAttendees
            self.preview = s.transcriptPreview
        }
    }

    private struct SessionFull: Encodable {
        let id: String
        let title: String
        let started_at: String
        let duration_seconds: Int
        let folder: String
        let locale: String
        let attendees: [String]
        let speaker_map: [String: String]
        let transcript: String
        let summary: SummaryDTO?
        let screenshot_urls: [String]
        let has_system_audio: Bool

        init(_ s: StoredSession) {
            self.id = s.id
            self.title = s.title
            self.started_at = ISO8601DateFormatter().string(from: s.startedAt)
            self.duration_seconds = s.durationSec
            self.folder = s.folderSlug
            self.locale = s.locale
            self.attendees = s.meetingAttendees
            self.speaker_map = s.speakerMap
            self.transcript = s.transcriptText
            self.summary = s.summary.map(SummaryDTO.init)
            self.screenshot_urls = s.screenshotURLs.map(\.absoluteString)
            self.has_system_audio = s.hasSystemAudio
        }
    }

    private struct SummaryDTO: Encodable {
        let meeting: String
        let next_actions: [String]
        let client_follow_up: String

        init(_ m: MeetingSummary) {
            self.meeting = m.summary
            self.next_actions = m.actionItems
            self.client_follow_up = m.clientFollowUp
        }
    }

    private struct SessionHit: Encodable {
        let id: String
        let title: String
        let started_at: String
        let snippet: String

        init(_ s: StoredSession, query: String) {
            self.id = s.id
            self.title = s.title
            self.started_at = ISO8601DateFormatter().string(from: s.startedAt)
            self.snippet = Self.makeSnippet(from: s.transcriptText, query: query)
        }

        private static func makeSnippet(from text: String, query: String, radius: Int = 80) -> String {
            let lower = text.lowercased()
            let q = query.lowercased()
            guard let range = lower.range(of: q) else {
                return String(text.prefix(160))
            }
            let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
            var snippet = String(text[start..<end])
            if start != text.startIndex { snippet = "…" + snippet }
            if end != text.endIndex { snippet = snippet + "…" }
            return snippet
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private struct FolderItem: Encodable {
        let slug: String
        let name: String
    }

    // MARK: - Helpers

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: s)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
