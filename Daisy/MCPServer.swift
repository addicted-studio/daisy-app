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
//    • Read-only tools (see MCPTools.swift) — no mutation surface
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
        sseConnection?.cancel()
        sseConnection = nil
        state = .stopped
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
        // Drop any previous stream — single-client transport.
        sseConnection?.cancel()
        sseConnection = connection

        // No `Access-Control-Allow-Origin: *` — see the long note in
        // `route(...)`. Native MCP clients (Claude Desktop, Cursor)
        // don't honour CORS anyway, and emitting the wildcard would
        // re-enable the very browser-cross-origin attack the Host /
        // Origin guards exist to block.
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache, no-store, no-transform",
            "Connection: keep-alive",
            "\r\n",
        ].joined(separator: "\r\n")

        connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })

        // Per MCP spec: first event tells the client where to POST.
        sendSSEEvent(name: "endpoint", data: "/messages", on: connection)
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

        guard let sse = sseConnection else {
            log.warning("POST /messages with no live SSE stream — dropping")
            return
        }

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

        do {
            let data = try JSONEncoder().encode(response)
            let json = String(decoding: data, as: UTF8.self)
            sendSSEEvent(name: "message", data: json, on: sse)
        } catch {
            log.error("Failed to encode JSON-RPC response: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - JSON-RPC dispatch

    private func handleJSONRPC(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return await handleInitialize(id: request.id)
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

    private func handleInitialize(id: JSONRPCID?) async -> JSONRPCResponse {
        let result = MCPInitializeResult(
            protocolVersion: "2024-11-05",
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
