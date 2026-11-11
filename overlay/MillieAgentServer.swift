import AppKit
import Combine
import Foundation
import Network

/// "Bring your own agent" (Ardia parity): a tiny loopback HTTP server that
/// speaks the Model Context Protocol so an external terminal agent — your own
/// Claude Code or Codex session — can drive Millie, logins and all, using the
/// exact same tool surface the in-app assistant uses (`BrowserAutomation`).
///
/// Safety model, defense in depth:
///   • Off by default. Nothing listens until the user flips it on in Settings.
///   • Binds 127.0.0.1 only, and drops any connection whose remote endpoint is
///     not loopback — nothing on the network can reach it.
///   • Every request must carry `Authorization: Bearer <token>`; the token is a
///     per-machine secret generated on first enable and never synced.
///   • Every state-changing / page-reading tool call still routes through the
///     same macOS approval alert the in-app Codex path uses, so the agent can't
///     touch the browser without the user clicking Allow (with an opt-in
///     "allow for this session" so a long agent run isn't death-by-dialog).
///
/// The transport is MCP's Streamable HTTP: the client POSTs a JSON-RPC message
/// and we answer with a single `application/json` body (no server-initiated
/// stream needed for a request/response tool server). That means there is no
/// separate binary to ship, sign or put on PATH — the "CLI" is one
/// `claude mcp add` line, shown in Settings.
/// Carries the listener's bind outcome out of the (concurrently-executing)
/// state handler. Guarded by the start-time semaphore handshake.
private final class BindProbe: @unchecked Sendable {
    var failed = false
}

final class MillieAgentServer: ObservableObject {
    static let shared = MillieAgentServer()

    /// Whether the listener is currently accepting connections.
    @Published private(set) var isRunning = false
    /// Human-readable status for the Settings panel (bound port, or an error).
    @Published private(set) var statusMessage = "Off"
    /// The port we actually bound (may differ from the preferred one if it was
    /// taken); surfaced so the copy-paste command stays accurate.
    @Published private(set) var boundPort: UInt16 = 0

    private weak var store: BrowserStore?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.millie.agent-server")

    /// Set when the user ticks "allow for this session" on an approval alert, so
    /// the rest of this run proceeds unattended. Reset whenever the server stops.
    private var sessionAutoApprove = false

    /// The bearer token the current listener requires. Captured per-start into
    /// the connection handler, but also kept here for the loopback auth check.
    private var activeToken = ""

    private let protocolVersion = "2024-11-05"

    private init() {}

    // MARK: Lifecycle

    /// Called once from `BrowserStore` at launch to hand us the live store and
    /// bring the listener up if the user has the feature enabled.
    @MainActor
    func attach(store: BrowserStore) {
        self.store = store
        applySettings()
    }

    /// Reconcile the running listener with the current Settings toggle. Safe to
    /// call repeatedly (e.g. from the toggle's didSet).
    @MainActor
    func applySettings() {
        if BrowserSettings.shared.agentServerEnabled {
            if !isRunning { startListener() }
        } else {
            if isRunning { stopListener(status: "Off") }
        }
    }

    /// The exact command a user pastes into a terminal to register Millie with
    /// Claude Code. Codex/other MCP clients use the same URL + header.
    var claudeMCPCommand: String {
        let port = boundPort == 0 ? preferredPort() : boundPort
        return "claude mcp add --transport http millie http://127.0.0.1:\(port)/mcp "
            + "--header \"Authorization: Bearer \(activeTokenOrStored())\""
    }

    var endpointURL: String {
        let port = boundPort == 0 ? preferredPort() : boundPort
        return "http://127.0.0.1:\(port)/mcp"
    }

    var bearerToken: String { activeTokenOrStored() }

    // MARK: Start / stop

    @MainActor
    private func startListener() {
        let token = ensureToken()
        activeToken = token
        sessionAutoApprove = false

        let preferred = preferredPort()
        // Try the preferred port, then a small sweep if it's taken, so a second
        // launch or a lingering socket doesn't leave the feature dead.
        for offset in 0..<12 {
            let candidate = UInt16((Int(preferred) + offset))
            if bind(port: candidate, token: token) {
                boundPort = candidate
                BrowserSettings.shared.agentServerPort = Int(candidate)
                isRunning = true
                statusMessage = "Listening on 127.0.0.1:\(candidate)"
                return
            }
        }
        isRunning = false
        statusMessage = "Couldn't bind a local port (8777–8788 all in use)."
    }

    @MainActor
    private func bind(port: UInt16, token: String) -> Bool {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to loopback explicitly so we never expose a port on the LAN.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)

        guard let listener = try? NWListener(using: params) else { return false }
        self.listener = listener

        // Capture only Sendable values (queue, token) into the handler so we
        // never close over non-Sendable `self`.
        let q = queue
        listener.newConnectionHandler = { connection in
            MillieAgentServer.handle(connection: connection, token: token, queue: q)
        }

        // Mutating a property of a captured reference avoids "mutation of
        // captured var" in the @Sendable state handler; the semaphore handshake
        // (write-before-signal, read-after-wait) makes the access safe.
        let probe = BindProbe()
        let sema = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sema.signal()
            case .failed, .cancelled:
                probe.failed = true
                sema.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        // Wait briefly for the bind result so we can fall through to the next
        // port on failure. Ready/failed both fire fast for a local bind.
        _ = sema.wait(timeout: .now() + 1.0)
        if probe.failed {
            listener.cancel()
            self.listener = nil
            return false
        }
        return true
    }

    @MainActor
    private func stopListener(status: String) {
        listener?.cancel()
        listener = nil
        isRunning = false
        boundPort = 0
        sessionAutoApprove = false
        statusMessage = status
    }

    // MARK: Token / port helpers

    @MainActor
    private func ensureToken() -> String {
        let existing = BrowserSettings.shared.agentServerToken
        if !existing.isEmpty { return existing }
        let fresh = Self.randomToken()
        BrowserSettings.shared.agentServerToken = fresh
        return fresh
    }

    /// Mint a brand-new token (invalidates any configured agent). Used by the
    /// "Regenerate" button in Settings.
    @MainActor
    func regenerateToken() {
        let fresh = Self.randomToken()
        BrowserSettings.shared.agentServerToken = fresh
        activeToken = fresh
        objectWillChange.send()
        // Restart so the live listener enforces the new token immediately.
        if isRunning {
            stopListener(status: "Restarting…")
            startListener()
        }
    }

    private func activeTokenOrStored() -> String {
        if !activeToken.isEmpty { return activeToken }
        return BrowserSettings.shared.agentServerToken
    }

    private func preferredPort() -> UInt16 {
        let stored = BrowserSettings.shared.agentServerPort
        if stored >= 1024 && stored <= 65535 { return UInt16(stored) }
        return 8777
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Connection handling (stateless HTTP plumbing)

    private static func handle(connection: NWConnection, token: String, queue: DispatchQueue) {
        // Reject anything that isn't loopback, belt-and-braces with the bind.
        if !isLoopback(connection.endpoint) {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data()) { request in
            guard let request else { connection.cancel(); return }
            Task {
                let response = await MillieAgentServer.shared.makeResponse(request: request, token: token)
                send(response, on: connection)
            }
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return true }
        switch host {
        case .ipv4(let ip): return ip.isLoopback
        case .ipv6(let ip): return ip.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    /// Recursively receive until a full HTTP request (headers + Content-Length
    /// body) is in hand, or the peer closes. No `self` capture.
    private static func readRequest(_ conn: NWConnection,
                                    buffer: Data,
                                    completion: @escaping @Sendable (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }
            if error != nil {
                completion(buf.isEmpty ? nil : buf)
                return
            }
            if let boundary = headerBodyBoundary(buf) {
                let need = contentLength(in: buf, headerEnd: boundary)
                let have = buf.count - boundary
                if have >= need {
                    completion(buf)
                    return
                }
            }
            if isComplete {
                completion(buf.isEmpty ? nil : buf)
                return
            }
            // Guard against an unbounded request.
            if buf.count > (4 << 20) {
                completion(buf)
                return
            }
            readRequest(conn, buffer: buf, completion: completion)
        }
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private static func headerBodyBoundary(_ data: Data) -> Int? {
        guard let range = data.range(of: headerTerminator) else { return nil }
        return range.upperBound
    }

    private static func contentLength(in data: Data, headerEnd: Int) -> Int {
        let headerData = data.subdata(in: 0..<headerEnd)
        guard let header = String(data: headerData, encoding: .utf8) else { return 0 }
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1]) ?? 0
            }
        }
        return 0
    }

    private static func send(_ body: Data, on conn: NWConnection) {
        conn.send(content: body, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: Request → response

    /// Parse a complete HTTP request, enforce auth, dispatch the JSON-RPC body,
    /// and return the full HTTP response bytes.
    private func makeResponse(request: Data, token: String) async -> Data {
        guard let boundary = Self.headerBodyBoundary(request),
              let headerString = String(data: request.subdata(in: 0..<boundary), encoding: .utf8) else {
            return Self.httpResponse(status: "400 Bad Request", json: nil)
        }
        let lines = headerString.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""

        // A GET (the client probing for an SSE stream) gets a clean 405 so it
        // falls back to POST-only JSON-RPC.
        if method == "GET" {
            return Self.httpResponse(status: "405 Method Not Allowed", json: nil)
        }
        guard method == "POST" else {
            return Self.httpResponse(status: "405 Method Not Allowed", json: nil)
        }

        // Bearer auth.
        let auth = Self.headerValue("authorization", in: lines) ?? ""
        let expected = "Bearer \(token)"
        guard Self.constantTimeEquals(auth, expected) else {
            return Self.httpResponse(status: "401 Unauthorized", json: nil)
        }

        let bodyData = request.subdata(in: boundary..<request.count)
        guard let message = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
            return Self.httpResponse(
                status: "200 OK",
                json: Self.rpcError(id: nil, code: -32700, message: "Parse error"))
        }

        let rpcMethod = message["method"] as? String ?? ""
        let id = message["id"]

        // Notifications carry no id and expect no body.
        if id == nil && rpcMethod.hasPrefix("notifications/") {
            return Self.httpResponse(status: "202 Accepted", json: nil)
        }

        let result = await dispatch(method: rpcMethod, params: message["params"] as? [String: Any] ?? [:])
        switch result {
        case .success(let value):
            return Self.httpResponse(status: "200 OK", json: Self.rpcResult(id: id, result: value))
        case .failure(let rpcErr):
            return Self.httpResponse(status: "200 OK",
                                     json: Self.rpcError(id: id, code: rpcErr.code, message: rpcErr.message))
        }
    }

    private struct RPCError: Error { let code: Int; let message: String }

    private func dispatch(method: String, params: [String: Any]) async -> Result<[String: Any], RPCError> {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? protocolVersion
            return .success([
                "protocolVersion": requested,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": "millie",
                    "version": Self.appVersion
                ]
            ])
        case "ping":
            return .success([:])
        case "tools/list":
            return .success(["tools": BrowserAutomation.dynamicTools])
        case "tools/call":
            return await callTool(params: params)
        default:
            return .failure(RPCError(code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func callTool(params: [String: Any]) async -> Result<[String: Any], RPCError> {
        guard let name = params["name"] as? String, !name.isEmpty else {
            return .failure(RPCError(code: -32602, message: "Missing tool name"))
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        let store = await MainActor.run { MillieAgentServer.shared.store }
        guard let store else {
            return .success(Self.toolContent(text: "Millie's browser isn't ready yet.", isError: true))
        }

        // Reuse the in-app approval gate, routed through a session-scoped
        // auto-allow so a long agent run isn't a wall of dialogs.
        let approved = await MainActor.run { () -> Bool in
            MillieAgentServer.shared.approve(tool: name, arguments: arguments, store: store)
        }
        guard approved else {
            return .success(Self.toolContent(
                text: "The user denied permission to run \(name). Do not retry unless the user explicitly asks.",
                isError: true))
        }

        let result = await BrowserAutomation.handle(tool: name, arguments: arguments, store: store)
        return .success(Self.toolContent(text: result.text, isError: !result.success))
    }

    /// Present the shared approval alert (unless this session is auto-approving),
    /// rewording the in-app "Codex" copy for an external agent and offering a
    /// one-tick "allow for this session".
    @MainActor
    private func approve(tool: String, arguments: [String: Any], store: BrowserStore) -> Bool {
        if sessionAutoApprove { return true }
        guard let request = BrowserAutomation.approvalRequest(tool: tool, arguments: arguments, store: store) else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = request.isDestructive ? .warning : .informational
        alert.messageText = Self.rewordForAgent(request.title)
        alert.informativeText = Self.rewordForAgent(request.message)
        alert.addButton(withTitle: request.confirmButtonTitle)
        alert.addButton(withTitle: "Deny")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Allow agent actions for this session"
        let allowed = alert.runModal() == .alertFirstButtonReturn
        if allowed, alert.suppressionButton?.state == .on {
            sessionAutoApprove = true
        }
        return allowed
    }

    private static func rewordForAgent(_ text: String) -> String {
        text
            .replacingOccurrences(of: "Millie Assistant", with: "the connected agent")
            .replacingOccurrences(of: "Codex", with: "The connected agent")
    }

    // MARK: JSON-RPC / HTTP builders

    private static func toolContent(text: String, isError: Bool) -> [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": isError
        ]
    }

    private static func rpcResult(id: Any?, result: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["jsonrpc": "2.0", "result": result]
        out["id"] = id ?? NSNull()
        return out
    }

    private static func rpcError(id: Any?, code: Int, message: String) -> [String: Any] {
        var out: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        out["id"] = id ?? NSNull()
        return out
    }

    private static func httpResponse(status: String, json: [String: Any]?) -> Data {
        var body = Data()
        if let json,
           let data = try? JSONSerialization.data(withJSONObject: json, options: []) {
            body = data
        }
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func headerValue(_ name: String, in lines: [String]) -> String? {
        let target = name.lowercased()
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0].lowercased() == target {
                return parts[1]
            }
        }
        return nil
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
