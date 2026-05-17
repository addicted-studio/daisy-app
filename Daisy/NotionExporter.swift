//
//  NotionExporter.swift
//  Daisy
//
//  Pushes a finished meeting (summary + transcript) into Notion as a new
//  child page under the user's configured parent page. Uses the official
//  REST API directly — no third-party SDK.
//

import Foundation
import os

struct MeetingExportData: Sendable {
    let title: String
    let summary: MeetingSummary?
    let transcriptChunks: [String]
    let durationSeconds: Int
    let locale: String
    let startedAt: Date?
}

actor NotionExporter {
    static let shared = NotionExporter()

    enum NotionError: LocalizedError {
        case missingCredentials
        case invalidParentID
        case httpError(Int, String)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Notion token or parent page ID is missing. Open Settings to configure."
            case .invalidParentID:
                return "Notion parent ID looks malformed (expecting 32 hex chars)."
            case .httpError(let code, let body):
                return "Notion API error \(code): \(body)"
            case .decodingFailed(let msg):
                return "Could not decode Notion response: \(msg)"
            }
        }
    }

    private let urlSession = URLSession.shared
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Notion")

    /// Create a new page under the configured parent containing the
    /// rendered meeting summary + transcript. Returns the canonical URL
    /// to the new page.
    func createMeetingPage(_ data: MeetingExportData) async throws -> URL {
        guard let token = await readCredential(SecretKey.notionToken),
              let rawParent = await readCredential(SecretKey.notionParentID),
              !token.isEmpty, !rawParent.isEmpty else {
            throw NotionError.missingCredentials
        }

        let normalized = rawParent
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard normalized.count == 32 else {
            throw NotionError.invalidParentID
        }
        let parentID = formatPageID(normalized)

        let body = buildPageJSON(parentID: parentID, data: data)
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionError.httpError(0, "No HTTP response.")
        }
        if !(200..<300).contains(http.statusCode) {
            let payload = String(data: responseData, encoding: .utf8) ?? "<empty>"
            log.error("Notion HTTP \(http.statusCode): \(payload, privacy: .public)")
            throw NotionError.httpError(http.statusCode, payload)
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            throw NotionError.decodingFailed("Missing 'url' field.")
        }
        log.info("Created Notion page at \(url.absoluteString, privacy: .public)")
        return url
    }

    // MARK: - Helpers

    /// Keychain access is synchronous; wrap to keep this code async-friendly.
    private func readCredential(_ key: String) async -> String? {
        KeychainStore.get(account: key)
    }

    private func formatPageID(_ raw: String) -> String {
        let s = Array(raw)
        let parts = [
            String(s[0..<8]),
            String(s[8..<12]),
            String(s[12..<16]),
            String(s[16..<20]),
            String(s[20..<32])
        ]
        return parts.joined(separator: "-")
    }

    private func buildPageJSON(parentID: String, data: MeetingExportData) -> [String: Any] {
        var children: [[String: Any]] = []

        // Metadata callout-style paragraph.
        if let started = data.startedAt {
            let stamp = DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .short)
            let dur = "\(data.durationSeconds / 60):\(String(format: "%02d", data.durationSeconds % 60))"
            children.append(paragraph("📌  \(stamp)  ·  \(dur)  ·  \(data.locale)"))
        }

        if let summary = data.summary {
            children.append(heading2("Summary"))
            children.append(paragraph(summary.summary))

            if !summary.actionItems.isEmpty {
                children.append(heading2("Action items"))
                for item in summary.actionItems {
                    children.append(todo(item))
                }
            }

            if !summary.decisions.isEmpty {
                children.append(heading2("Decisions"))
                for item in summary.decisions {
                    children.append(bullet(item))
                }
            }

            if !summary.followUps.isEmpty {
                children.append(heading2("Follow-ups"))
                for item in summary.followUps {
                    children.append(bullet(item))
                }
            }

            children.append(divider())
        }

        children.append(heading2("Transcript"))
        for chunk in data.transcriptChunks {
            children.append(paragraph(chunk))
        }

        return [
            "parent": ["page_id": parentID],
            "properties": [
                "title": [
                    "title": [
                        ["type": "text", "text": ["content": data.title.notionTrimmed]]
                    ]
                ]
            ],
            "children": children
        ]
    }

    // MARK: - Block factories

    private func paragraph(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "paragraph",
            "paragraph": ["rich_text": richText(text)]
        ]
    }

    private func heading2(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "heading_2",
            "heading_2": ["rich_text": richText(text)]
        ]
    }

    private func todo(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "to_do",
            "to_do": [
                "rich_text": richText(text),
                "checked": false
            ]
        ]
    }

    private func bullet(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "bulleted_list_item",
            "bulleted_list_item": ["rich_text": richText(text)]
        ]
    }

    private func divider() -> [String: Any] {
        ["object": "block", "type": "divider", "divider": [String: Any]()]
    }

    private func richText(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": ["content": text.notionTrimmed]]]
    }
}

nonisolated private extension String {
    /// Notion caps `rich_text.content` at 2000 characters per element.
    var notionTrimmed: String {
        if count <= 2000 { return self }
        return String(prefix(1997)) + "…"
    }
}
