//
//  CursorMCPConfig.swift
//  Daisy
//
//  One-click, non-destructive registration of Daisy in Cursor's global
//  MCP configuration. Cursor accepts stdio MCP servers, so the pinned
//  mcp-remote bridge keeps Daisy's local SSE endpoint private.
//

import Foundation

@MainActor
enum CursorMCPConfig {
    enum EntryState: Equatable {
        case notInstalled
        case installed
        case installedDifferentPort
        case malformed
    }

    enum InstallResult {
        case installed
        case failed(String)
    }

    enum RemoveResult {
        case removed
        case notPresent
        case failed(String)
    }

    private static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
    }

    private static var configURL: URL {
        configDirectory.appendingPathComponent("mcp.json", isDirectory: false)
    }

    static func entryState(port: Int) -> EntryState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              !data.isEmpty else {
            return .notInstalled
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        guard let servers = root["mcpServers"] as? [String: Any],
              let daisy = servers["daisy"] as? [String: Any] else {
            return .notInstalled
        }
        let args = daisy["args"] as? [String] ?? []
        return args.contains(daisySSEURL(port: port)) ? .installed : .installedDifferentPort
    }

    @discardableResult
    static func install(port: Int) -> InstallResult {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: configDirectory.path) {
                try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            }

            var root: [String: Any] = [:]
            if fm.fileExists(atPath: configURL.path),
               let data = try? Data(contentsOf: configURL),
               !data.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failed("Cursor's MCP config isn't a JSON object, so Daisy won't overwrite it.")
                }
                root = parsed
            }

            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            var arguments = ["-y", "mcp-remote@0.1.38", daisySSEURL(port: port),
                             "--transport", "sse-only", "--allow-http"]
            if MCPAccessToken.isRequired {
                arguments += ["--header", "Authorization: Bearer \(MCPAccessToken.ensure())"]
            }
            servers["daisy"] = ["command": "npx", "args": arguments]
            root["mcpServers"] = servers

            let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL, options: .atomic)
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    static func remove() -> RemoveResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              !data.isEmpty else {
            return .notPresent
        }
        do {
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("Cursor's MCP config isn't a JSON object, so Daisy won't edit it.")
            }
            guard var servers = root["mcpServers"] as? [String: Any], servers["daisy"] != nil else {
                return .notPresent
            }
            servers.removeValue(forKey: "daisy")
            if servers.isEmpty {
                root.removeValue(forKey: "mcpServers")
            } else {
                root["mcpServers"] = servers
            }
            let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL, options: .atomic)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func refreshIfInstalled(port: Int) {
        switch entryState(port: port) {
        case .installed, .installedDifferentPort:
            _ = install(port: port)
        case .notInstalled, .malformed:
            break
        }
    }

    private static func daisySSEURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/sse"
    }
}
