//
//  MCPServer.swift
//  Daisy
//
//  Localhost MCP server. Listens on 127.0.0.1:<port> and speaks the
//  MCP "HTTP+SSE" transport that Claude Desktop and other current
//  MCP clients understand:
//
//    GET  /sse       → open server-sent events stream, server emits
//                      an `endpoint` event pointing to /messages
//    POST /messages  → client sends a JSON-RPC request, server runs
//                      it and writes the response back to the SSE
//                      stream as `data: <json>`
//
//  Scope intentionally narrow:
//    • Loopback only — never bound to anything but 127.0.0.1
//    • Single client at a time — if a second SSE client connects,
//      we drop the previous stream (matches Claude Desktop's
//      restart-on-config-change behaviour)
//    • Tools (see MCPTools.swift) are READ tools plus a small,
//      deliberately SAFE set of ACTION (write) tools — regenerate a
//      summary, rename a session/speaker, route a session to a
//      configured destination. No DESTRUCTIVE surface: nothing here
//      can delete a session/audio/transcript, change settings or
//      credentials, or alter this server's own transport / network
//      binding. The security posture below (loopback + single-client
//      + Host/Origin guards) is unchanged by the addition of write
//      tools — only the tool surface in MCPTools grew.
//
//  We hand-roll the HTTP/1.1 parser and SSE framing on top of
//  Network.framework's NWListener so the build stays free of
//  third-party server dependencies.
//

import Foundation
import Network
import os

@MainActor
@Observable
final class MCPServer {
    /// Singleton — there's only ever one local MCP listener.
    static let shared = MCPServer()

    /// Public, UI-readable state.
    enum State: Equatable {
        case stopped
        case starting(port: Int)
        case running(port: Int)
        case failed(String)
    }

    private(set) var state: State = .stopped

    // MARK: - Private

    @ObservationIgnored private let log = Logger(subsystem: "app.essazanov.Daisy", category: "MCPServer")
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "app.essazanov.Daisy.mcp", qos: .utility)
    /// Currently active SSE client connection, if any. The server is
    /// single-client by design — see header comment.
    @ObservationIgnored private var sseConnection: NWConnection?

    /// Periodic SSE comment-frame timer. Without it the loopback
    /// socket goes half-open after macOS power-naps or after long
    /// user idle, mcp-remote silently dies, and the next POST hangs
    /// because the response writes into a TCP send buffer that will
    /// never drain. 15s cadence is well under the 30-45s standard
    /// EventSource staleness window mcp-remote uses internally.
    /// Bound to the current sseConnection — re-created when a new
    /// SSE stream replaces an old one, torn down on stop().
    @ObservationIgnored private var sseKeepaliveTimer: DispatchSourceTimer?

    /// Per-session UUID issued at `initialize` time. Used to detect
    /// stale reconnects from mcp-remote after a Claude restart — if
    /// the bridge somehow attached to a previous Daisy session
    /// (cached state file under ~/.mcp-auth) but Daisy has rolled
    /// to a new id, we log loudly so support knows what happened
    /// rather than the request just dying mid-flight.
    @ObservationIgnored private var currentSessionID: String?

    /// Sliding window of recent SSE-open timestamps for the
    /// connection-storm circuit breaker. Pruned to the last 30s on
    /// every open. If we see > 5 opens in 30s, we shut the listener
    /// down for 5 minutes. Real-world trigger: Claude Desktop's
    /// mcp-remote reconnect loop wedges on macOS 26.2 and hammers
    /// our SSE endpoint every 3 seconds, which kept Daisy's runloop
    /// busy enough that an unrelated SwiftUI concurrency bug
    /// (swift_task_isCurrentExecutor UAF in DesignLibrary HStack
    /// during layout cycles) fired predictably during the next
    /// `start recording` action and crashed the process. Memory
    /// note: `feedback_tahoe_swiftui_button_assumeisolated_crash`.
    /// Killing the storm removes the layout-pressure trigger.
    @ObservationIgnored private var recentSSEOpenings: [Date] = []
    @ObservationIgnored private var stormCooldownEndsAt: Date?

    /// Storm thresholds — exceeded = circuit breaker trips.
    private static let stormWindow: TimeInterval = 30
    private static let stormThreshold = 5
    private static let stormCooldown: TimeInterval = 5 * 60

    private init() {}

    // MARK: - Lifecycle

    /// Start the server on `port`. Idempotent — calling again with
    /// the same port is a no-op; with a different port it stops the
    /// current listener and restarts on the new one.
    func start(port: Int) {
        if case .running(let p) = state, p == port { return }
        stop()

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            state = .failed("Invalid port: \(port)")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Loopback-only: refuse anything that isn't 127.0.0.1.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: nwPort
            )

            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(newState, port: port)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleNewConnection(connection)
                }
            }
            self.listener = listener
            state = .starting(port: port)
            listener.start(queue: queue)
        } catch {
            log.error("Failed to create NWListener: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Stop the listener and close any in-flight SSE stream.
    func stop() {
        listener?.cancel()
        listener = nil
        tearDownSSE()
        state = .stopped
    }

    /// Cancel the active SSE connection + its keepalive timer + drop
    /// the session id. Single chokepoint so we can't leak a timer
    /// firing into a dead connection (the closure would log, but
    /// it's still wasted work and a small heap-retain leak).
    private func tearDownSSE() {
        sseKeepaliveTimer?.cancel()
        sseKeepaliveTimer = nil
        sseConnection?.cancel()
        sseConnection = nil
        currentSessionID = nil
    }

    private func handleListenerState(_ s: NWListener.State, port: Int) {
        switch s {
        case .ready:
            state = .running(port: port)
            log.info("MCP server listening on 127.0.0.1:\(port, privacy: .public)")
        case .failed(let err):
            state = .failed(err.localizedDescription)
            log.error("MCP listener failed: \(err.localizedDescription, privacy: .public)")
        case .cancelled:
            state = .stopped
        default:
            break
        }
    }

    // MARK: - Per-connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulator: Data())
    }

    /// Pull bytes off `connection` until we have a complete HTTP/1.1
    /// request, then dispatch by method + path. Body must be POSTed
    /// in full before we respond — no chunked transfer, no pipelining.
    private nonisolated func receiveRequest(on connection: NWConnection, accumulator: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulator
            if let chunk { buffer.append(chunk) }
            if let error {
                connection.cancel()
                Task { @MainActor in
                    self.log.error("Connection receive error: \(error.localizedDescription, privacy: .public)")
                }
                return
            }

            // Wait until we've seen the end-of-headers marker.
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel(); return }
                self.receiveRequest(on: connection, accumulator: buffer)
                return
            }

            let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8),
                  let parsed = HTTPRequest.parseHead(headerString) else {
                Self.write(status: 400, body: "Bad Request", on: connection, closeAfter: true)
                return
            }

            let bodyStart = headerEnd.upperBound
            let contentLength = parsed.headers["content-length"].flatMap(Int.init) ?? 0
            let available = buffer.count - bodyStart

            if available < contentLength {
                if isComplete { connection.cancel(); return }
                self.receiveRequest(on: connection, accumulator: buffer)
                return
            }

            let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            Task { @MainActor in
                await self.route(request: parsed, body: body, connection: connection)
            }
        }
    }

    private func route(request: HTTPRequest, body: Data, connection: NWConnection) async {
        // Defence against CORS + DNS rebinding. The MCP server binds
        // to 127.0.0.1 but TCP "binds to loopback only" doesn't stop
        // a browser from issuing requests to 127.0.0.1 — the kernel
        // routes those locally. So a webpage the user visits can
        // `fetch("http://127.0.0.1:<port>/sse")` and (without these
        // checks) walk away with every transcript.
        //
        // Two guards:
        //   1. Host header MUST be loopback (127.0.0.1 / localhost,
        //      with optional :port). Defeats DNS rebinding — the
        //      attacker's DNS may resolve their domain to 127.0.0.1,
        //      but their `fetch` sends `Host: attacker.example.com`
        //      and we reject.
        //   2. Origin header, if present, MUST be a loopback URL.
        //      Native MCP clients (Claude Desktop, Cursor) don't
        //      send Origin — only browsers do. So presence of any
        //      non-loopback Origin = browser cross-origin attempt.
        //
        // SSE response no longer carries `Access-Control-Allow-Origin:
        // *`. Native clients don't need it; the wildcard was the
        // exact opening that made CORS-via-fetch viable.
        if !Self.isLoopbackHost(request.headers["host"]) {
            Self.write(status: 403, body: "Forbidden", on: connection, closeAfter: true)
            return
        }
        if let origin = request.headers["origin"], !Self.isLoopbackOrigin(origin) {
            Self.write(status: 403, body: "Forbidden", on: connection, closeAfter: true)
            return
        }

        switch (request.method.uppercased(), request.path) {
        case ("GET", "/sse"):
            await openSSEStream(on: connection)
        case ("POST", "/messages"):
            await handlePostedMessage(body: body, replyOn: connection)
        case ("GET", "/"):
            // Friendly probe — useful when the user pastes the URL
            // into a browser to check the server's up.
            Self.write(
                status: 200,
                contentType: "text/plain; charset=utf-8",
                body: "Daisy MCP server. Point an MCP client at GET /sse.",
                on: connection,
                closeAfter: true
            )
        default:
            Self.write(status: 404, body: "Not Found", on: connection, closeAfter: true)
        }
    }

    /// Allow exactly `127.0.0.1[:port]` or `localhost[:port]` — case-
    /// insensitive, port optional. A missing/nil/empty Host header
    /// is also rejected; HTTP/1.1 requires Host on every request, and
    /// the absence is itself a red flag.
    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let hostname = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        return hostname == "127.0.0.1" || hostname == "localhost" || hostname == "[::1]"
    }

    /// Same loopback rule for Origin, but parses a full URL form
    /// like `http://127.0.0.1:54321` (or the special `null` token
    /// that browsers send for sandboxed pages — that one we reject
    /// since we have no reason to accept sandboxed iframe origins).
    private static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    // MARK: - SSE stream (server → client)

    private func openSSEStream(on connection: NWConnection) async {
        // ── Connection-storm circuit breaker ─────────────────────────
        //
        // Reject the connection at the application layer if we've seen
        // > stormThreshold opens in stormWindow. NWConnection.cancel()
        // closes the TCP socket; a well-behaved client interprets that
        // as "server unavailable", backs off, and stops pile-on.
        // mcp-remote will keep retrying but at our rate, not its
        // bugged 3-second cadence. After stormCooldown elapses, the
        // breaker auto-resets on the next non-storm open.
        let now = Date()
        if let until = stormCooldownEndsAt, now < until {
            log.warning("MCP connection-storm cooldown active until \(until, privacy: .public) — rejecting")
            connection.cancel()
            return
        }
        recentSSEOpenings.append(now)
        recentSSEOpenings.removeAll { now.timeIntervalSince($0) > Self.stormWindow }
        if recentSSEOpenings.count > Self.stormThreshold {
            stormCooldownEndsAt = now.addingTimeInterval(Self.stormCooldown)
            recentSSEOpenings.removeAll()
            log.error("MCP connection storm: \(Self.stormThreshold, privacy: .public)+ opens in \(Int(Self.stormWindow), privacy: .public)s — tearing down listener for \(Int(Self.stormCooldown), privacy: .public)s. Likely cause: a misbehaving MCP client (e.g. mcp-remote with broken reconnect). Daisy stays usable; restart the app or wait \(Int(Self.stormCooldown / 60), privacy: .public) min to re-enable MCP.")
            connection.cancel()
            // Stop the listener entirely so subsequent TCP attempts
            // hit ECONNREFUSED at the kernel and the client's retry
            // logic shifts to a real backoff. Schedule re-arm in
            // stormCooldown.
            stop()
            // Re-arm with the same port the user has configured
            // (defaults.integer returns 0 for missing; fall back to
            // the same 54321 default AppSettings uses).
            let storedPort = UserDefaults.standard.integer(forKey: "daisy.mcpServerPort")
            let restartPort = storedPort > 0 ? storedPort : 54321
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.stormCooldown * 1_000_000_000))
                self?.start(port: restartPort)
            }
            return
        }

        // Drop any previous stream — single-client transport.
        // Cancel the OLD timer first so it can't race onto the new
        // connection. tearDownSSE handles both.
        tearDownSSE()
        sseConnection = connection
        let sessionID = UUID().uuidString
        currentSessionID = sessionID

        // No `Access-Control-Allow-Origin: *` — see the long note in
        // `route(...)`. Native MCP clients (Claude Desktop, Cursor)
        // don't honour CORS anyway, and emitting the wildcard would
        // re-enable the very browser-cross-origin attack the Host /
        // Origin guards exist to block.
        //
        // Mcp-Session-Id header: defined by the 2025-06-18 Streamable
        // HTTP spec but harmless under the older HTTP+SSE flow we
        // implement — mcp-remote ignores unknown headers gracefully.
        // Surfacing it gives us a per-session correlation token in
        // server logs so we can match a hung POST to the SSE stream
        // that should have answered it.
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache, no-store, no-transform",
            "Connection: keep-alive",
            "Mcp-Session-Id: \(sessionID)",
            "\r\n",
        ].joined(separator: "\r\n")

        connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })

        // Per MCP spec: first event tells the client where to POST.
        sendSSEEvent(name: "endpoint", data: "/messages", on: connection)

        // Arm the keepalive — comment-frame heartbeat every 15s for
        // the lifetime of THIS connection. The closure captures the
        // connection weakly so a dropped client can't keep the
        // server alive; we also re-verify it's still the current
        // sseConnection on each fire (race against a fresh
        // openSSEStream replacing us).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        let keepaliveBytes = Data(": keepalive\r\n\r\n".utf8)
        timer.setEventHandler { [weak self, weak connection] in
            guard let connection,
                  let strongSelf = self else { return }
            // Hop to MainActor briefly to compare against
            // sseConnection. Avoid the hop entirely if the connection
            // is already cancelled.
            if connection.state == .cancelled { return }
            Task { @MainActor in
                guard strongSelf.sseConnection === connection else { return }
                connection.send(content: keepaliveBytes, completion: .contentProcessed { _ in })
            }
        }
        timer.resume()
        sseKeepaliveTimer = timer
        log.info("SSE stream opened, session=\(sessionID, privacy: .public)")
    }

    private func sendSSEEvent(name: String? = nil, data: String, on connection: NWConnection) {
        var frame = ""
        if let name { frame += "event: \(name)\r\n" }
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            frame += "data: \(line)\r\n"
        }
        frame += "\r\n"
        connection.send(content: Data(frame.utf8), completion: .contentProcessed { _ in })
    }

    // MARK: - POST /messages (client → server → SSE)

    private func handlePostedMessage(body: Data, replyOn postConnection: NWConnection) async {
        // Acknowledge the POST with 202 Accepted immediately — the
        // actual JSON-RPC response goes out on the SSE stream.
        Self.write(status: 202, body: "", on: postConnection, closeAfter: true)

        // Snapshot the SSE reference BEFORE any await — if a fresh
        // openSSEStream lands during handler work it'll cancel this
        // one, and we'd otherwise write the response into a dead
        // connection. The final `sseConnection === sseAtEntry` check
        // (below) confirms our snapshot is still the current stream.
        guard let sseAtEntry = sseConnection else {
            log.warning("POST /messages with no live SSE stream — dropping")
            return
        }
        let sessionAtEntry = currentSessionID

        let response: JSONRPCResponse
        do {
            let request = try JSONDecoder().decode(JSONRPCRequest.self, from: body)
            response = await handleJSONRPC(request)
        } catch {
            log.error("Failed to decode JSON-RPC request: \(error.localizedDescription, privacy: .public)")
            response = JSONRPCResponse(
                id: nil,
                error: JSONRPCError(code: JSONRPCError.parseError, message: "Parse error", data: nil)
            )
        }

        // Verify the SSE stream we snapshotted is still the live one.
        // If a fresh client reconnect rolled us over (new
        // openSSEStream → tearDownSSE → fresh sseConnection +
        // sessionID), writing to the old reference is a no-op at
        // best and a crash-on-cancelled-connection at worst. Log
        // loudly so a regression in lifecycle handling is obvious.
        guard sseConnection === sseAtEntry,
              currentSessionID == sessionAtEntry else {
            log.warning("SSE stream rolled over mid-request — dropping stale response for session \(sessionAtEntry ?? "nil", privacy: .public)")
            return
        }
        let sse = sseAtEntry

        do {
            var data = try JSONEncoder().encode(response)
            // Defence-in-depth: cap response bodies at 10 MB. The
            // listener is loopback-only so the attack surface is
            // small, but a misbehaving local client (or our own
            // `get_transcript` on a 4-hour session that returned
            // 80 MB of raw segments) could still ship hundreds of
            // megabytes through SSE. Cap, replace with a JSON-RPC
            // error referencing the request id, log loudly.
            if data.count > Self.maxResponsePayloadBytes {
                log.warning("MCP response too large (\(data.count, privacy: .public) bytes > \(Self.maxResponsePayloadBytes, privacy: .public)) — replacing with error")
                let oversized = JSONRPCResponse(
                    id: response.id,
                    error: JSONRPCError(
                        code: -32000,
                        message: "Result too large — \(data.count) bytes exceeds 10 MB cap. Narrow the query (e.g. fewer sessions, shorter time range) and retry.",
                        data: nil
                    )
                )
                data = try JSONEncoder().encode(oversized)
            }
            let json = String(decoding: data, as: UTF8.self)
            sendSSEEvent(name: "message", data: json, on: sse)
        } catch {
            log.error("Failed to encode JSON-RPC response: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Per-response size ceiling. 10 MB chosen as the threshold
    /// where "normal Daisy response" (a long session's tool result)
    /// already feels like a misuse — fix the query, not the server.
    nonisolated private static let maxResponsePayloadBytes: Int = 10 * 1024 * 1024

    // MARK: - JSON-RPC dispatch

    private func handleJSONRPC(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return await handleInitialize(id: request.id, params: request.params)
        case "notifications/initialized",
             "notifications/cancelled":
            // Notifications carry no id and expect no response —
            // but we always have to write *something* to the SSE
            // stream so we return a 2.0-shaped success with null id.
            return JSONRPCResponse(id: request.id, result: .null)
        case "tools/list":
            return await handleToolsList(id: request.id)
        case "tools/call":
            return await handleToolsCall(id: request.id, params: request.params)
        case "ping":
            return JSONRPCResponse(id: request.id, result: .object([:]))
        default:
            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError(
                    code: JSONRPCError.methodNotFound,
                    message: "Method not found: \(request.method)",
                    data: nil
                )
            )
        }
    }

    /// MCP-version range we can speak. If the client sends a
    /// `protocolVersion` we know — echo it back so the negotiated
    /// version is what the client expects. If the client sends
    /// something newer or unknown, fall through to the latest version
    /// we implement (the highest entry below). Pre-1.0.3 we
    /// hardcoded "2024-11-05" and any client requiring a newer
    /// minimum would break silently.
    private static let supportedProtocolVersions: Set<String> = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18",
    ]
    private static let latestProtocolVersion = "2025-06-18"

    private func handleInitialize(id: JSONRPCID?, params: AnyJSON?) async -> JSONRPCResponse {
        // Extract client's requested protocolVersion if present.
        // params is JSON-RPC-shaped: `{ "protocolVersion": "2025-03-26",
        // "capabilities": {...}, "clientInfo": {...} }`. Tolerate
        // missing / non-string values — we'll fall through to our
        // latest supported version.
        var negotiated = Self.latestProtocolVersion
        if case let .object(dict) = params,
           case let .string(clientVersion) = dict["protocolVersion"] {
            if Self.supportedProtocolVersions.contains(clientVersion) {
                negotiated = clientVersion
            } else {
                log.info("MCP client requested unknown protocolVersion '\(clientVersion, privacy: .public)' — using \(Self.latestProtocolVersion, privacy: .public) instead")
            }
        }

        let result = MCPInitializeResult(
            protocolVersion: negotiated,
            capabilities: MCPServerCapabilities(
                tools: .init(listChanged: false)
            ),
            serverInfo: MCPServerInfo(
                name: "Daisy",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            )
        )
        do {
            return JSONRPCResponse(id: id, result: try .wrap(result))
        } catch {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription, data: nil)
            )
        }
    }

    private func handleToolsList(id: JSONRPCID?) async -> JSONRPCResponse {
        let result = MCPToolsListResult(tools: MCPTools.catalog())
        do {
            return JSONRPCResponse(id: id, result: try .wrap(result))
        } catch {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription, data: nil)
            )
        }
    }

    private func handleToolsCall(id: JSONRPCID?, params: AnyJSON?) async -> JSONRPCResponse {
        guard let params else {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: JSONRPCError.invalidParams, message: "Missing params", data: nil)
            )
        }
        do {
            let callParams = try params.decoded(as: MCPToolCallParams.self)
            let result = await MCPTools.call(name: callParams.name, arguments: callParams.arguments)
            return JSONRPCResponse(id: id, result: try .wrap(result))
        } catch {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(
                    code: JSONRPCError.invalidParams,
                    message: "Invalid tools/call params: \(error.localizedDescription)",
                    data: nil
                )
            )
        }
    }

    // MARK: - HTTP response helper

    /// Stateless HTTP write helper — touches no actor-isolated
    /// state, just writes bytes to an `NWConnection`. Marked
    /// `nonisolated` so the `receiveRequest` parser (which runs in
    /// the NWListener's nonisolated callback context) can call it
    /// without an actor hop.
    nonisolated private static func write(
        status: Int,
        contentType: String = "text/plain; charset=utf-8",
        body: String,
        on connection: NWConnection,
        closeAfter: Bool
    ) {
        let statusLine = "HTTP/1.1 \(status) \(reasonPhrase(for: status))"
        let bodyData = Data(body.utf8)
        let headers = [
            statusLine,
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "\r\n",
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            if closeAfter { connection.cancel() }
        })
    }

    nonisolated private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}

// MARK: - Tiny HTTP request parser
//
// Just enough HTTP/1.1 to handle MCP traffic on loopback. No
// chunked transfer encoding, no pipelining, no caring about
// case-folding header values beyond names. If a client misbehaves
// we respond 400 and move on.

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    static func parseHead(_ head: String) -> HTTPRequest? {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequest(method: method, path: path, headers: headers)
    }
}
