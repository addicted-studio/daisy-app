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
//    • A few concurrent clients (Claude Desktop + Cowork + friends),
//      each on its own SSE stream with its own ?sessionId endpoint;
//      capped at `maxSSEClients` with oldest-stream eviction.
//      (Single-client-with-rollover until 2026-07-25 — two legit
//      clients ping-ponged each other's streams every 15 s.)
//    • Tools (see MCPTools.swift) are READ tools plus a small,
//      deliberately SAFE set of ACTION (write) tools — regenerate a
//      summary, rename a session/speaker, route a session to a
//      configured destination. No DESTRUCTIVE surface: nothing here
//      can delete a session/audio/transcript, change settings or
//      credentials, or alter this server's own transport / network
//      binding. The security posture below (loopback + bounded client
//      table + Host/Origin guards) is unchanged by the addition of
//      write tools — only the tool surface in MCPTools grew.
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
    /// Live SSE clients keyed by session id. MULTI-CLIENT since
    /// 2026-07-25: the old single-slot design made two legitimate
    /// clients (Claude Desktop's mcp-remote + Cowork's Daisy
    /// connector) ping-pong forever — every GET /sse tore down the
    /// other's stream, the loser reconnected after the 15 s retry
    /// floor and tore down the winner, producing one "SSE stream
    /// opened" every 15 s for hours in field logs (2026-07-25).
    /// Each client gets its own keepalive timer and its own endpoint
    /// URL carrying ?sessionId=… so POSTs route to the right stream.
    private struct SSEClient {
        let sessionID: String
        let connection: NWConnection
        let keepalive: DispatchSourceTimer
        let openedAt: Date
    }
    @ObservationIgnored private var sseClients: [String: SSEClient] = [:]

    /// Hard cap on concurrent SSE clients — past it the OLDEST stream
    /// is evicted. Normal setups run 1-2 (Claude Desktop + Cowork);
    /// the cap only bounds a leaky client that opens without closing.
    private static let maxSSEClients = 4

    /// Consecutive bind-retry attempts after EADDRINUSE (a previous
    /// Daisy instance still holding the port during an update
    /// relaunch). Reset when the listener reaches .ready.
    @ObservationIgnored private var bindRetryCount = 0

    /// Periodic SSE comment-frame timer. Without it the loopback
    /// socket goes half-open after macOS power-naps or after long
    /// user idle, mcp-remote silently dies, and the next POST hangs
    /// because the response writes into a TCP send buffer that will
    /// never drain. 15s cadence is well under the 30-45s standard
    /// EventSource staleness window mcp-remote uses internally.
    /// (Keepalive timers now live PER-CLIENT inside `SSEClient` — see
    /// the multi-client note above. The half-open-detection behaviour
    /// is unchanged: a failed keepalive write tears that one client
    /// down so it can reconnect cleanly, instead of the server nursing
    /// a zombie stream.)

    /// SSE `retry:` directive (milliseconds) emitted on every stream
    /// open. The `eventsource` package mcp-remote rides on hardcodes a
    /// 3000 ms reconnect interval and only ever changes it when the
    /// server sends a `retry:` field — it has no exponential backoff
    /// and no jitter of its own. Left unset, ANY churn (a half-open
    /// socket, a Claude restart, an eviction) turns into a fixed
    /// 3-per-9-seconds hammer. Emitting a larger floor here converts
    /// that into a paced reconnect: a genuine reconnect still happens
    /// promptly enough to feel live, but a pathological loop can no
    /// longer pile requests on faster than this. 15000 ms matches the
    /// keepalive cadence — by the time the client would reconnect we've
    /// either proven the socket alive (heartbeat) or torn it down.
    private static let sseReconnectFloorMillis = 15_000

    // (per-session UUIDs live as `SSEClient.sessionID` keys now)

    /// Sliding window of recent SSE-open timestamps for the
    /// connection-storm circuit breaker. Pruned to the last
    /// `stormWindow` on every open. The breaker is now a LAST-RESORT
    /// safety net, not the primary defence — see the root-cause fixes
    /// in `openSSEStream` (half-open detection + SSE `retry:` directive
    /// + network-layer disconnect observation). Real-world trigger it
    /// used to fire on: Claude Desktop's mcp-remote reconnect loop
    /// wedged on macOS 26.2 and hammered our SSE endpoint every 3
    /// seconds (the `eventsource` package's hardcoded 3000 ms reconnect
    /// interval, which we now widen via a `retry:` directive). That
    /// kept Daisy's runloop busy enough that an unrelated SwiftUI
    /// concurrency bug (swift_task_isCurrentExecutor UAF in
    /// DesignLibrary HStack during layout cycles) fired predictably
    /// during the next `start recording` action and crashed the
    /// process. Memory note:
    /// `feedback_tahoe_swiftui_button_assumeisolated_crash`. Removing
    /// the reconnect-loop removes the layout-pressure trigger at the
    /// source; the breaker only catches a pathological client we
    /// haven't anticipated.
    @ObservationIgnored private var recentSSEOpenings: [Date] = []
    @ObservationIgnored private var stormCooldownEndsAt: Date?

    /// Storm thresholds — exceeded = circuit breaker trips. Loosened
    /// now that the root cause (a tight client reconnect loop) is
    /// fixed: a genuine reconnect after a half-open socket is a single
    /// clean re-open, and Claude-Desktop restarts produce at most a
    /// couple of opens. Anything past 20 opens in 60s is therefore a
    /// client we don't understand, and we respond gently (503 +
    /// Retry-After) rather than killing the listener.
    private static let stormWindow: TimeInterval = 60
    private static let stormThreshold = 20
    private static let stormCooldown: TimeInterval = 60

    private init() {}

    // MARK: - Lifecycle

    /// Start the server on `port`. Idempotent — calling again with
    /// the same port is a no-op; with a different port it stops the
    /// current listener and restarts on the new one.
    func start(port: Int) {
        if case .running(let p) = state, p == port { return }
        // Fresh explicit start = fresh retry budget (the counter
        // otherwise only resets on .ready, so an exhausted
        // EADDRINUSE cycle would leave later starts retry-less).
        bindRetryCount = 0
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

    /// Stop the listener and close all in-flight SSE streams.
    func stop() {
        listener?.cancel()
        listener = nil
        tearDownAllSSE()
        state = .stopped
    }

    /// Cancel ONE client's SSE connection + keepalive timer and drop
    /// it from the table. Single chokepoint so we can't leak a timer
    /// firing into a dead connection.
    private func tearDown(clientID: String) {
        guard let client = sseClients.removeValue(forKey: clientID) else { return }
        client.keepalive.cancel()
        client.connection.cancel()
    }

    private func tearDownAllSSE() {
        for id in Array(sseClients.keys) { tearDown(clientID: id) }
    }

    private func handleListenerState(_ s: NWListener.State, port: Int) {
        switch s {
        case .ready:
            state = .running(port: port)
            bindRetryCount = 0
            log.info("MCP server listening on 127.0.0.1:\(port, privacy: .public)")
        case .failed(let err):
            state = .failed(err.localizedDescription)
            log.error("MCP listener failed: \(err.localizedDescription, privacy: .public)")
            // "Address already in use" = a previous Daisy instance
            // still holds the port (relaunch during a Sparkle update,
            // or a duplicate launch). It exits within seconds — retry
            // instead of staying dead until the user relaunches (field
            // log 2026-07-25: two EADDRINUSE entries, no MCP server
            // for hours).
            if case .posix(let code) = err, code == .EADDRINUSE {
                scheduleBindRetry(port: port)
            }
        case .cancelled:
            state = .stopped
        default:
            break
        }
    }

    /// Re-attempt the bind every 10 s, up to 6 tries, while the state
    /// is still `.failed`. A successful `.ready` resets the counter.
    private func scheduleBindRetry(port: Int) {
        guard bindRetryCount < 6 else { return }
        bindRetryCount += 1
        let attempt = bindRetryCount
        log.info("MCP port \(port, privacy: .public) busy — bind retry \(attempt, privacy: .public)/6 in 10s")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, case .failed = self.state else { return }
            self.start(port: port)
        }
    }

    // MARK: - Per-connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        // Observe the network layer so a dropped/failed connection is
        // noticed proactively instead of only when a keepalive write
        // happens to fail. This is what lets us detect a half-open or
        // RST'd SSE socket and tear it down cleanly — the client then
        // reconnects ONCE rather than the server holding a zombie
        // stream and the client's EventSource looping against it. We
        // only act when the connection is the CURRENT sseConnection;
        // short-lived request/response connections (GET /, POST
        // /messages) cancel themselves and we simply ignore their
        // terminal states.
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.handleConnectionTerminated(connection)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulator: Data())
    }

    /// Called when any accepted connection reaches `.failed`/`.cancelled`.
    /// If it was the live SSE stream, tear the stream state down so the
    /// next `GET /sse` is a clean fresh open (not a roll-over against a
    /// stale reference) and the keepalive timer can't fire into a dead
    /// socket.
    private func handleConnectionTerminated(_ connection: NWConnection) {
        guard let client = sseClients.values.first(where: { $0.connection === connection }) else { return }
        log.info("SSE connection terminated (\(client.sessionID, privacy: .public)) — removing stream (remaining: \(self.sseClients.count - 1, privacy: .public)); client may reconnect")
        tearDown(clientID: client.sessionID)
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

            // Bound the header size — a client that never sends the
            // end-of-headers marker must not make us buffer unboundedly.
            let maxHeaderBytes = 64 * 1024
            // Wait until we've seen the end-of-headers marker.
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > maxHeaderBytes {
                    Self.write(status: 431, body: "Request Header Fields Too Large", on: connection, closeAfter: true)
                    return
                }
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

            // Content-Length validation. Without this a malicious header
            // could crash the app (negative / overflowing value → range
            // trap on the subdata below) or exhaust memory (huge body).
            let maxBodyBytes = 8 * 1024 * 1024
            // Duplicate Content-Length is a request-smuggling vector.
            let clOccurrences = headerString.lowercased().components(separatedBy: "content-length:").count - 1
            guard clOccurrences <= 1 else {
                Self.write(status: 400, body: "Bad Request", on: connection, closeAfter: true)
                return
            }
            // `Int.init` on an over-long value returns nil → treated as 0.
            let contentLength = parsed.headers["content-length"].flatMap(Int.init) ?? 0
            guard contentLength >= 0, contentLength <= maxBodyBytes else {
                Self.write(status: 413, body: "Payload Too Large", on: connection, closeAfter: true)
                return
            }

            let bodyStart = headerEnd.upperBound
            let available = buffer.count - bodyStart

            if available < contentLength {
                if isComplete { connection.cancel(); return }
                self.receiveRequest(on: connection, accumulator: buffer)
                return
            }

            // Safe now: contentLength is in 0...maxBodyBytes.
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

        // Bearer-token auth (when enabled): Host/Origin close the
        // browser vector, but any LOCAL process could otherwise read
        // every transcript. The friendly GET / probe stays open so
        // pasting the URL into a browser still explains the server.
        // Split the query string off — the endpoint URL handed to SSE
        // clients carries ?sessionId=… for multi-client POST routing.
        let pathParts = request.path.split(separator: "?", maxSplits: 1)
        let path = pathParts.first.map(String.init) ?? request.path
        let query = pathParts.count > 1 ? String(pathParts[1]) : nil

        let isProbe = request.method.uppercased() == "GET" && path == "/"
        if !isProbe, !MCPAccessToken.authorize(header: request.headers["authorization"]) {
            Self.write(
                status: 401,
                body: "Unauthorized — this Daisy MCP server requires an access token. Copy it from Daisy → Connections → MCP server.",
                on: connection,
                closeAfter: true
            )
            return
        }

        switch (request.method.uppercased(), path) {
        case ("GET", "/sse"):
            await openSSEStream(on: connection)
        case ("POST", "/messages"):
            await handlePostedMessage(
                body: body,
                replyOn: connection,
                sessionID: Self.queryValue(query, key: "sessionId")
            )
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

    /// Value of `key` in a raw query string ("a=1&b=2"). Minimal on
    /// purpose — the only producer of these URLs is our own endpoint
    /// event, so no exotic encodings to handle beyond percent-escapes.
    private static func queryValue(_ query: String?, key: String) -> String? {
        guard let query else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == Substring(key) {
                let raw = String(kv[1])
                return raw.removingPercentEncoding ?? raw
            }
        }
        return nil
    }

    // MARK: - SSE stream (server → client)

    private func openSSEStream(on connection: NWConnection) async {
        // ── Connection-storm circuit breaker (LAST-RESORT) ───────────
        //
        // The primary fix for the reconnect loop lives below (SSE
        // `retry:` floor, half-open detection on the keepalive, and the
        // network-layer disconnect observer in handleNewConnection).
        // This breaker only catches a pathological client those don't
        // tame. Its RESPONSE has changed: it no longer calls stop().
        //
        // Why not stop(): killing the listener makes every subsequent
        // TCP attempt hit ECONNREFUSED. The `eventsource` runtime
        // mcp-remote uses treats a refused/failed connection as
        // `_onFetchError → scheduleReconnect` — i.e. it KEEPS looping at
        // its reconnect interval. So a 5-minute listener blackout
        // produced 5 minutes of refused-connection hammering and then
        // an instant re-storm on re-arm. The cure was feeding the
        // disease.
        //
        // Gentle response instead: answer `GET /sse` with HTTP 503 +
        // Retry-After and close. A non-200 status drives that same
        // EventSource into `failConnection → readyState = CLOSED`, which
        // does NOT schedule a reconnect — the loop stops cleanly. The
        // listener stays up, so a fresh Claude Desktop launch (or the
        // user toggling MCP off/on) reconnects immediately rather than
        // waiting out a cooldown.
        let now = Date()
        if let until = stormCooldownEndsAt, now < until {
            let retryAfter = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            log.warning("MCP connection-storm cooldown active until \(until, privacy: .public) — replying 503 (Retry-After: \(retryAfter, privacy: .public)s)")
            Self.write(
                status: 503,
                contentType: "text/plain; charset=utf-8",
                body: "MCP server cooling down after a connection storm. Retry shortly.",
                on: connection,
                closeAfter: true,
                extraHeaders: ["Retry-After: \(retryAfter)"]
            )
            return
        }
        recentSSEOpenings.append(now)
        recentSSEOpenings.removeAll { now.timeIntervalSince($0) > Self.stormWindow }
        if recentSSEOpenings.count > Self.stormThreshold {
            stormCooldownEndsAt = now.addingTimeInterval(Self.stormCooldown)
            recentSSEOpenings.removeAll()
            let retryAfter = Int(Self.stormCooldown)
            log.error("MCP connection storm: \(Self.stormThreshold, privacy: .public)+ opens in \(Int(Self.stormWindow), privacy: .public)s — replying 503 + Retry-After \(retryAfter, privacy: .public)s for \(Int(Self.stormCooldown), privacy: .public)s. Likely cause: a misbehaving MCP client (e.g. mcp-remote with a broken reconnect). Daisy stays usable and the listener stays up; the client should stop its EventSource on the non-200 and reconnect cleanly later.")
            // Tear down every live stream this storm rolled over so we
            // don't leak them, then 503 the offending open.
            tearDownAllSSE()
            Self.write(
                status: 503,
                contentType: "text/plain; charset=utf-8",
                body: "MCP server saw a connection storm and is backing off. Retry shortly.",
                on: connection,
                closeAfter: true,
                extraHeaders: ["Retry-After: \(retryAfter)"]
            )
            return
        }

        // Multi-client: register ALONGSIDE any existing streams —
        // never tear a peer down for a new arrival (that was the
        // 15-second ping-pong storm; see `sseClients` doc). Bounded by
        // evicting the OLDEST stream past the cap.
        if sseClients.count >= Self.maxSSEClients,
           let oldest = sseClients.values.min(by: { $0.openedAt < $1.openedAt }) {
            log.warning("SSE client cap (\(Self.maxSSEClients, privacy: .public)) reached — evicting oldest session \(oldest.sessionID, privacy: .public)")
            tearDown(clientID: oldest.sessionID)
        }
        let sessionID = UUID().uuidString

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

        // Pace the client's reconnect FIRST. A bare `retry:` line is a
        // valid SSE field and sets the EventSource reconnection time;
        // without it the client is pinned to its hardcoded 3000 ms.
        // Emitting it before the endpoint guarantees it's applied even
        // if the stream is torn down a beat later. This is THE knob that
        // turns a 3-second hammer into a paced reconnect.
        connection.send(
            content: Data("retry: \(Self.sseReconnectFloorMillis)\r\n\r\n".utf8),
            completion: .contentProcessed { _ in }
        )

        // Per MCP spec: first event tells the client where to POST.
        // Idempotent on every (re)connect — a fresh `GET /sse` always
        // gets the endpoint event, so a reconnect never lands without
        // knowing where to POST (which would itself make the client
        // give up and retry).
        // The endpoint carries this stream's sessionId so the client's
        // POSTs route back to ITS stream (multi-client). Legacy clients
        // that cached a plain "/messages" still work — see the
        // most-recent-stream fallback in handlePostedMessage.
        sendSSEEvent(name: "endpoint", data: "/messages?sessionId=\(sessionID)", on: connection)

        // Start a receive pump on the SSE socket. We don't expect the
        // client to send anything on this connection (it POSTs on a
        // separate one), but reading is how Network.framework surfaces
        // the peer's FIN: a graceful client close lands here as
        // `isComplete == true`, and a reset lands as an error. Either
        // way we tear the stream down immediately rather than waiting
        // up to one keepalive interval to (maybe) notice. The
        // stateUpdateHandler set in handleNewConnection then fires and
        // clears `sseConnection`.
        receiveAndDiscardSSE(on: connection)

        // Arm the keepalive — comment-frame heartbeat every 15s for the
        // lifetime of THIS connection. The closure captures the
        // connection weakly so a dropped client can't keep the server
        // alive; we also re-verify it's still THIS session's live
        // connection on each fire (race against eviction/teardown).
        // Crucially the send-completion INSPECTS the error: a
        // half-open loopback socket swallows the first write into the
        // kernel buffer but fails the next one with ECONNRESET/EPIPE.
        // On any such failure we tear the connection down so the client
        // reconnects once cleanly instead of the server nursing a
        // zombie stream forever (the old `{ _ in }` discarded this and
        // was the core of the wedge-then-hang bug).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        let keepaliveBytes = Data(": keepalive\r\n\r\n".utf8)
        timer.setEventHandler { [weak self, weak connection] in
            guard let connection,
                  let strongSelf = self else { return }
            // Avoid the hop entirely if the connection is already
            // cancelled.
            if connection.state == .cancelled { return }
            Task { @MainActor in
                guard strongSelf.sseClients[sessionID]?.connection === connection else { return }
                connection.send(content: keepaliveBytes, completion: .contentProcessed { error in
                    // `strongSelf`/`connection` are immutable strong
                    // `let`s from the timer-handler guard, captured
                    // strongly all the way down — weak captures here
                    // are mutable boxes Swift 6 won't let the nested
                    // Task reference, and the lifetime is bounded
                    // anyway: Network.framework releases this
                    // completion as soon as the send resolves (the
                    // long-lived reference is the timer handler above,
                    // which IS weak).
                    guard error != nil else { return }
                    // The peer is gone (half-open detected). Cancelling
                    // drives the stateUpdateHandler → tearDownSSE on the
                    // MainActor; we don't touch isolated state here.
                    Task { @MainActor in
                        guard strongSelf.sseClients[sessionID]?.connection === connection else { return }
                        strongSelf.log.info("SSE keepalive write failed — peer gone; tearing down session \(sessionID, privacy: .public) so client can reconnect cleanly")
                        connection.cancel()
                    }
                })
            }
        }
        timer.resume()
        sseClients[sessionID] = SSEClient(
            sessionID: sessionID,
            connection: connection,
            keepalive: timer,
            openedAt: Date()
        )
        log.info("SSE stream opened, session=\(sessionID, privacy: .public) (live streams: \(self.sseClients.count, privacy: .public))")
    }

    /// Drain (and discard) anything the client sends on the SSE
    /// connection. The MCP HTTP+SSE transport never sends client→server
    /// bytes on this stream — POSTs go to /messages on their own
    /// connections — so any data here is unexpected and ignored. The
    /// point of reading at all is detection: `isComplete`/error tells us
    /// the peer closed, and we tear the stream down at once. Only acts
    /// on the connection while it is the current SSE stream.
    private nonisolated func receiveAndDiscardSSE(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                // Cancelling fires the stateUpdateHandler, which clears
                // sseConnection on the MainActor if this was the live
                // stream. Safe to call unconditionally — cancel on an
                // already-dead connection is a no-op.
                connection.cancel()
                return
            }
            // Keep draining; we never act on the bytes.
            self.receiveAndDiscardSSE(on: connection)
        }
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

    private func handlePostedMessage(body: Data, replyOn postConnection: NWConnection, sessionID: String?) async {
        // Acknowledge the POST with 202 Accepted immediately — the
        // actual JSON-RPC response goes out on the SSE stream.
        Self.write(status: 202, body: "", on: postConnection, closeAfter: true)

        // Route to the POSTing client's own stream. The sessionId comes
        // from the endpoint URL this client received on connect; a
        // legacy client that cached a plain "/messages" (pre-multi-
        // client state file under ~/.mcp-auth) falls back to the most
        // recently opened stream, loudly.
        let targetID: String
        if let sessionID {
            // A PRESENT sessionId must match a live stream. Routing an
            // unknown id to some other client's stream would inject an
            // unmatched response into the wrong client (review finding
            // 2026-07-25); the poster's own EventSource reconnects and
            // gets a fresh endpoint anyway.
            guard sseClients[sessionID] != nil else {
                log.warning("POST /messages for unknown session \(sessionID, privacy: .public) — dropping (client should reconnect)")
                return
            }
            targetID = sessionID
        } else if let newest = sseClients.values.max(by: { $0.openedAt < $1.openedAt }) {
            // Legacy client with a cached plain "/messages" endpoint.
            log.info("POST /messages without sessionId (legacy client) — routing to most recent stream")
            targetID = newest.sessionID
        } else {
            log.warning("POST /messages with no live SSE stream — dropping")
            return
        }

        // Snapshot the SSE reference BEFORE any await — if the client
        // reconnects during handler work its old connection dies, and
        // we'd otherwise write the response into a corpse. The final
        // identity check (below) confirms the snapshot is still this
        // session's live stream.
        guard let sseAtEntry = sseClients[targetID]?.connection else {
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

        // Verify the stream we snapshotted is still this session's
        // live one. If the client reconnected mid-request (fresh
        // session id, old connection cancelled), writing to the old
        // reference is a no-op at best and a crash-on-cancelled-
        // connection at worst. Log loudly so a lifecycle regression
        // is obvious.
        guard sseClients[targetID]?.connection === sseAtEntry else {
            log.warning("SSE stream rolled over mid-request — dropping stale response for session \(targetID, privacy: .public)")
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
        closeAfter: Bool,
        extraHeaders: [String] = []
    ) {
        let statusLine = "HTTP/1.1 \(status) \(reasonPhrase(for: status))"
        let bodyData = Data(body.utf8)
        let headers = ([
            statusLine,
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
        ] + extraHeaders + ["\r\n"]).joined(separator: "\r\n")
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
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
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
