//
//  ClaudeExporter.swift
//  Daisy
//
//  Sends the rendered meeting to Claude — copies a structured prompt onto
//  the system pasteboard and opens Claude.app (falling back to claude.ai
//  if the desktop app isn't installed). The user pastes once with ⌘V.
//

import Foundation
import AppKit
import os

enum ClaudeExporter {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "Claude")

    /// Build a Claude-friendly prompt from a meeting + optional summary.
    static func renderPrompt(data: MeetingExportData) -> String {
        var lines: [String] = []
        lines.append("I just finished a meeting and want your help with the follow-up.")
        lines.append("")
        lines.append("**Meeting:** \(data.title)")
        if let started = data.startedAt {
            let stamp = DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .short)
            lines.append("**When:** \(stamp)")
        }
        lines.append("**Duration:** \(data.durationSeconds / 60) min")
        lines.append("")

        if let summary = data.summary {
            lines.append("## Summary")
            lines.append(summary.summary)
            lines.append("")
            if !summary.actionItems.isEmpty {
                lines.append("## Action items")
                for item in summary.actionItems { lines.append("- [ ] \(item)") }
                lines.append("")
            }
            if !summary.decisions.isEmpty {
                lines.append("## Decisions")
                for d in summary.decisions { lines.append("- \(d)") }
                lines.append("")
            }
            if !summary.followUps.isEmpty {
                lines.append("## Follow-ups")
                for f in summary.followUps { lines.append("- \(f)") }
                lines.append("")
            }
        }

        lines.append("## Transcript")
        for chunk in data.transcriptChunks {
            lines.append(chunk)
            lines.append("")
        }

        lines.append("---")
        lines.append("")
        lines.append("Please:")
        lines.append("1. Confirm the action items capture everything important — flag anything I'm missing.")
        lines.append("2. Draft a short follow-up message I can send to the other party.")
        lines.append("3. If you spot any commitments I made that I should track, list them separately.")

        return lines.joined(separator: "\n")
    }

    /// Copy the prompt onto the clipboard, then open Claude. Returns true
    /// if the native Claude.app was launched; false if we fell back to the
    /// web version.
    @MainActor
    @discardableResult
    static func sendToClaude(data: MeetingExportData) -> Bool {
        let prompt = renderPrompt(data: data)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)

        let workspace = NSWorkspace.shared
        let candidateBundleIDs = [
            "com.anthropic.claudefordesktop",
            "com.anthropic.claude",
        ]

        for bundleID in candidateBundleIDs {
            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                workspace.openApplication(at: appURL, configuration: config) { _, error in
                    if let error {
                        Self.log.error("Open Claude.app failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                return true
            }
        }

        // No native app — open the web client.
        if let webURL = URL(string: "https://claude.ai/new") {
            workspace.open(webURL)
        }
        return false
    }
}
