//
//  ClaudeDesktopConfig.swift
//  Daisy
//
//  One-click installer that drops Daisy's MCP server entry into
//  Claude Desktop's `claude_desktop_config.json`, so users don't have
//  to copy-paste JSON and hunt down the file path. First call asks
//  for permission via NSOpenPanel (Claude's config lives outside
//  Daisy's sandbox container at `~/Library/Application Support/
//  Claude/`); subsequent calls reuse a stored security-scoped
//  bookmark for silent re-writes when the port changes.
//
//  Merge logic preserves any other `mcpServers` entries the user
//  already has (Cursor, custom local servers, etc.) — we only
//  insert/refresh our own `daisy` key.
//

import Foundation
import AppKit
import os

@MainActor
enum ClaudeDesktopConfig {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "ClaudeDesktopConfig")
    private static let bookmarkKey = "daisy.claudeDesktopConfigBookmark"
    private static let defaultFileName = "claude_desktop_config.json"

    enum InstallResult {
        case installed(URL)
        case cancelled
        case failed(String)
    }

    /// Whether the user has previously granted access to Claude's
    /// config file. UI uses this to flip button copy from "Add to
    /// Claude Desktop" → "Refresh Claude Desktop config" once the
    /// bookmark exists.
    static var isInstalled: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    // MARK: - Install / refresh

    /// Insert or refresh the `daisy` entry in Claude Desktop's
    /// config file. Uses the stored bookmark for silent writes; on
    /// first call (or if the bookmark went stale) prompts the user
    /// via NSOpenPanel.
    static func install(port: Int) -> InstallResult {
        // Silent path — stored bookmark available.
        if let resolved = resolveBookmark() {
            let acquired = resolved.startAccessingSecurityScopedResource()
            defer { if acquired { resolved.stopAccessingSecurityScopedResource() } }
            do {
                try mergeAndWrite(daisyURL: daisySSEURL(port: port), at: resolved)
                log.info("Refreshed Daisy entry in \(resolved.path, privacy: .private)")
                return .installed(resolved)
            } catch {
                // Bookmark resolved but write failed — probably the
                // user moved or deleted the file. Forget the
                // bookmark and fall through to the panel.
                log.warning("Silent write failed (\(error.localizedDescription, privacy: .public)) — re-prompting")
                forgetBookmark()
            }
        }

        // First-run path — ask the user.
        guard let picked = promptForConfigFile() else {
            return .cancelled
        }
        let acquired = picked.startAccessingSecurityScopedResource()
        defer { if acquired { picked.stopAccessingSecurityScopedResource() } }

        do {
            try mergeAndWrite(daisyURL: daisySSEURL(port: port), at: picked)
            storeBookmark(for: picked)
            log.info("Installed Daisy entry into \(picked.path, privacy: .private)")
            return .installed(picked)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Silent refresh — used by Settings when the port changes
    /// without the user pressing the button. No-op if no bookmark
    /// is stored. Doesn't surface errors; if the silent write fails
    /// the user will still see the next manual press behave the
    /// same way it always did.
    static func refreshIfInstalled(port: Int) {
        guard isInstalled else { return }
        _ = install(port: port)
    }

    /// Wipe the stored bookmark — next install will re-prompt.
    /// Exposed for the unit-test seam and for any future
    /// "Disconnect Claude" UI.
    static func forgetBookmark() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    // MARK: - Panel

    private static func promptForConfigFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Add Daisy to Claude Desktop"
        panel.message = "Select Claude Desktop's `claude_desktop_config.json`. If the file doesn't exist yet, pick the Claude folder and Daisy will create it."
        panel.prompt = "Add to Claude Desktop"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        // Default landing spot — sandboxed NSOpenPanel still honours
        // this hint, the user just clicks through the dialog.
        let home = FileManager.default.homeDirectoryForCurrentUser
        panel.directoryURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        // If the user picked a folder (e.g. the Claude support dir
        // because the config file doesn't exist yet), append the
        // canonical filename so we end up with a real file URL to
        // bookmark and write to.
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isDir ? url.appendingPathComponent(defaultFileName, isDirectory: false) : url
    }

    // MARK: - JSON merge

    /// Read existing JSON (if any), merge `mcpServers.daisy = {url}`,
    /// write back atomically. Refuses to overwrite a file whose
    /// contents aren't a JSON object — that almost certainly means
    /// the user has hand-written garbage and we'd silently destroy
    /// it.
    private static func mergeAndWrite(daisyURL: String, at url: URL) throws {
        let fm = FileManager.default

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           !data.isEmpty {
            do {
                let parsed = try JSONSerialization.jsonObject(with: data, options: [])
                guard let dict = parsed as? [String: Any] else {
                    throw configError(
                        "Existing config isn't a JSON object — refusing to overwrite. Open the file and check it manually."
                    )
                }
                root = dict
            } catch let nsError as NSError where nsError.domain == "ClaudeDesktopConfig" {
                throw nsError
            } catch {
                throw configError(
                    "Existing config has invalid JSON — refusing to overwrite. Open the file, fix the syntax, and try again."
                )
            }
        }

        // Preserve every other mcpServers entry — only mutate ours.
        //
        // Claude Desktop's current MCP config schema requires stdio
        // transport (`command` + `args`), not the URL-based SSE
        // shape SDKs accept. Bridge through `mcp-remote` (npm
        // package, auto-fetched by `npx -y`), which wraps a remote
        // SSE/HTTP MCP server into a stdio transport Claude accepts.
        //
        // Two flag tweaks were needed in 1.0.5.3 after a real-world
        // pass-through stalled mid-session:
        //   • `--transport sse-only` — pin the bridge to SSE so it
        //     doesn't waste cycles trying the newer Streamable HTTP
        //     endpoint first and falling back. Daisy speaks SSE.
        //   • `--allow-http` — `mcp-remote` defaults to HTTPS-only;
        //     loopback HTTP (127.0.0.1) needs explicit permission.
        //
        // Requires Node.js on the user's machine — surfaced in the
        // settings footer so non-devs know to install it first.
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["daisy"] = [
            "command": "npx",
            "args": ["-y", "mcp-remote", daisyURL,
                     "--transport", "sse-only", "--allow-http"]
        ]
        root["mcpServers"] = mcpServers

        // .sortedKeys keeps diffs stable when the user has the
        // file under git/Time Machine. .prettyPrinted because the
        // user is going to open this file at some point.
        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try out.write(to: url, options: [.atomic])
    }

    private static func configError(_ message: String) -> NSError {
        NSError(
            domain: "ClaudeDesktopConfig",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func daisySSEURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/sse"
    }

    // MARK: - Bookmark plumbing

    private static func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                storeBookmark(for: url)
            }
            return url
        } catch {
            log.warning("Couldn't resolve Claude config bookmark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func storeBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            log.error("Couldn't store Claude config bookmark: \(error.localizedDescription, privacy: .public)")
        }
    }
}
