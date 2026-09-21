import Foundation
import Network
import Synchronization
import AgentProtocol
import AgentSession

/// One MCP server as an ACP client names it in `session/new`'s `mcpServers` (agentclientprotocol.com,
/// session-setup). The stdio form is the specification's mandatory one, `{"name","command","args","env"}` with
/// `env` an array of `{"name","value"}`; the HTTP form (streamable HTTP, `{"type":"http","name","url","headers"}`)
/// is offered only when the agent's `initialize` advertised `mcpCapabilities.http`. Kyberna's spike of
/// 2026-09-21 found GitHub Copilot CLI refusing the stdio form before spawning anything and taking HTTP on loopback.
public enum MCPServerEndpoint: Sendable, Equatable, Codable {
    public struct Header: Sendable, Equatable, Codable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }
    case http(name: String, url: String, headers: [Header])
    case stdio(name: String, command: String, args: [String], env: [String: String])

    public var name: String {
        switch self {
        case .http(let name, _, _), .stdio(let name, _, _, _): return name
        }
    }

    /// The `McpServer` object for `session/new`.
    public var wire: JSONValue {
        switch self {
        case let .http(name, url, headers):
            return ["type": "http", "name": .string(name), "url": .string(url),
                    "headers": .array(headers.map { ["name": .string($0.name), "value": .string($0.value)] })]
        case let .stdio(name, command, args, env):
            return ["name": .string(name), "command": .string(command), "args": .array(args.map { .string($0) }),
                    "env": .array(env.keys.sorted().map { ["name": .string($0), "value": .string(env[$0] ?? "")] })]
        }
    }
}

/// How the hosted `SwiftTool`s are named to an MCP client and back. On the MCP wire a tool is
/// `<serverName>_<tool>` (`kyberna_notes_search`), a name an agent may prefix again with the server's name and a
/// separator (Copilot: `kyberna-kyberna_notes_search`); to a policy it is `mcp__<serverName>__<tool>`, the row the
/// host already keys on for the CLI's in-process server.
public struct HostedToolNaming: Sendable, Equatable {
    public var serverName: String
    public init(serverName: String) { self.serverName = serverName }

    public func wireName(_ tool: SwiftTool) -> String { "\(serverName)_\(tool.name)" }
    public func policyName(_ tool: SwiftTool) -> String { "mcp__\(serverName)__\(tool.name)" }

    /// The hosted tool an agent's name for a call refers to: the wire name itself, the policy name, the bare
    /// tool name, or the wire name after a prefix the agent added ending in a character that is not part of a
    /// name (`kyberna-kyberna_notes_search`, `kyberna.kyberna_notes_search`, `mcp__kyberna__kyberna_notes_search`).
    public func tool(matching name: String, in tools: [SwiftTool]) -> SwiftTool? {
        if let exact = tools.first(where: { wireName($0) == name || policyName($0) == name }) { return exact }
        for tool in tools {
            let wire = wireName(tool)
            guard name.hasSuffix(wire), name.count > wire.count else { continue }
            let boundary = name[name.index(name.endIndex, offsetBy: -wire.count - 1)]
            if !(boundary.isLetter || boundary.isNumber) { return tool }
        }
        return tools.first { $0.name == name }
    }
}

/// The JSON-RPC side of an MCP server for hosted tools, shared by the loopback HTTP server and by a stdio server
/// another process runs (`HostedToolServing`): `initialize` (the client's `protocolVersion` echoed, `tools`
/// capability), `notifications/initialized` and any other notification (no reply), `ping`, `tools/list`,
/// `tools/call` (a tool's failure is an `isError` result, never an error response), and method-not-found
/// (-32601) for anything else, which is what GitHub Copilot CLI's non-standard `server/discover` probe gets and
/// tolerates (the spike of 2026-09-21).
public enum MCPToolDispatch {
    public static let defaultProtocolVersion = "2025-06-18"

    /// The reply for one message, or nil for a notification.
    public static func reply(to rpc: JSONValue, serverName: String, version: String = "1.0.0",
                             tools: @Sendable () async -> [JSONValue],
                             call: @Sendable (String, [String: JSONValue]) async -> ToolResult) async -> JSONValue? {
        let method = rpc["method"]?.stringValue
        let id = rpc["id"]
        let isNotification = id == nil || id?.isNull == true
        func ok(_ result: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": id ?? .null, "result": result] }
        func fail(_ code: Int, _ message: String) -> JSONValue { ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .number(Double(code)), "message": .string(message)]] }
        guard let method else {
            return isNotification ? nil : fail(-32600, "invalid request: no method")
        }
        if method.hasPrefix("notifications/") { return nil }
        let params = rpc["params"] ?? .object([:])
        switch method {
        case "initialize":
            return ok(["protocolVersion": params["protocolVersion"] ?? .string(defaultProtocolVersion),
                       "capabilities": ["tools": ["listChanged": false]],
                       "serverInfo": ["name": .string(serverName), "version": .string(version)]])
        case "ping":
            return ok(.object([:]))
        case "tools/list":
            return ok(["tools": .array(await tools())])
        case "tools/call":
            guard let name = params["name"]?.stringValue else { return fail(-32602, "tools/call needs a name") }
            let result = await call(name, params["arguments"]?.objectValue ?? [:])
            return ok(result.wire)
        default:
            return isNotification ? nil : fail(-32601, "method not found: \(method)")
        }
    }
}

/// A streamable-HTTP MCP server on loopback for one engine session: `127.0.0.1`, an ephemeral port, one path
/// (`/mcp`), a bearer token minted at start and checked on every request (401 otherwise), JSON responses only.
/// `POST` with a request gets the JSON-RPC reply (`Content-Type: application/json`, an `Mcp-Session-Id` the
/// client echoes), a notification gets `202`; `GET` (the SSE listening stream) answers `405`, since the server
/// initiates nothing; `DELETE` (session termination) answers `200`. Connections are kept alive and requests
/// on one connection are answered in order. Stopped with the session; nothing listens after `stop()`.
/// Network framework, no third-party package.
public final class LoopbackMCPServer: Sendable {
    public struct Configuration: Sendable {
        public var serverName: String
        public var path = "/mcp"
        public var maxBodyBytes = 4 * 1024 * 1024
        public var tools: @Sendable () async -> [JSONValue]
        public var call: @Sendable (String, [String: JSONValue]) async -> ToolResult
        public init(serverName: String, tools: @escaping @Sendable () async -> [JSONValue],
                    call: @escaping @Sendable (String, [String: JSONValue]) async -> ToolResult) {
            self.serverName = serverName; self.tools = tools; self.call = call
        }
    }

    public enum ServerError: Error, Sendable, CustomStringConvertible {
        case listenFailed(String)
        case notStarted
        public var description: String {
            switch self {
            case .listenFailed(let why): return "the loopback MCP server could not listen: \(why)"
            case .notStarted: return "the loopback MCP server has not started"
            }
        }
    }

    struct State: Sendable {
        var listener: NWListener?
        var port: UInt16?
        var connections: [ObjectIdentifier: LoopbackMCPConnection] = [:]
        var stopped = false
        var requestsServed = 0
    }

    public let configuration: Configuration
    /// The bearer token every request must carry; minted at init, 32 random bytes as hex.
    public let token: String
    /// The `Mcp-Session-Id` this server hands out on `initialize` and accepts on later requests.
    public let mcpSessionId: String
    let state = Mutex(State())
    private let queue = DispatchQueue(label: "kyberna-agent-sdk.mcp-loopback")

    public init(configuration: Configuration) {
        self.configuration = configuration
        var generator = SystemRandomNumberGenerator()
        token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        mcpSessionId = UUID().uuidString.lowercased()
    }

    /// The bound port, once started.
    public var port: UInt16? { state.withLock { $0.port } }
    /// `http://127.0.0.1:<port><path>`, once started.
    public var url: String? { port.map { "http://127.0.0.1:\($0)\(configuration.path)" } }
    /// How many requests were answered, for tests and diagnostics.
    public var requestsServed: Int { state.withLock { $0.requestsServed } }
    /// The endpoint for `session/new`: the URL and the `Authorization` header.
    public func endpoint(name: String) -> MCPServerEndpoint? {
        guard let url else { return nil }
        return .http(name: name, url: url, headers: [.init(name: "Authorization", value: "Bearer \(token)")])
    }

    /// Binds an ephemeral port on 127.0.0.1 and returns once the listener is ready.
    public func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw ServerError.listenFailed(String(describing: error)) }
        state.withLock { $0.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = Mutex<CheckedContinuation<UInt16, Error>?>(nil)
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, Error>) in
            ready.withLock { $0 = k }
            listener.stateUpdateHandler = { [weak self] s in
                switch s {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    self?.state.withLock { $0.port = port }
                    ready.withLock { $0 }?.resume(returning: port); ready.withLock { $0 = nil }
                case .failed(let error):
                    ready.withLock { $0 }?.resume(throwing: ServerError.listenFailed(String(describing: error))); ready.withLock { $0 = nil }
                    self?.stop()
                case .cancelled:
                    ready.withLock { $0 }?.resume(throwing: ServerError.listenFailed("cancelled")); ready.withLock { $0 = nil }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Stops listening and closes every connection. Idempotent.
    public func stop() {
        let (listener, connections) = state.withLock { s -> (NWListener?, [LoopbackMCPConnection]) in
            s.stopped = true
            let l = s.listener; s.listener = nil
            let c = Array(s.connections.values); s.connections.removeAll()
            return (l, c)
        }
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        for c in connections { c.close() }
    }

    private func accept(_ nw: NWConnection) {
        let connection = LoopbackMCPConnection(nw, server: self)
        let stopped = state.withLock { s -> Bool in
            if s.stopped { return true }
            s.connections[ObjectIdentifier(connection)] = connection; return false
        }
        if stopped { nw.cancel(); return }
        connection.start(on: queue)
    }

    fileprivate func forget(_ connection: LoopbackMCPConnection) {
        _ = state.withLock { $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    // MARK: One HTTP request

    struct HTTPRequest: Sendable {
        var method: String
        var path: String
        var headers: [String: String]   // lower-cased names
        var body: Data
        var closeAfter: Bool { headers["connection"]?.lowercased() == "close" }
    }
    struct HTTPResponse: Sendable {
        var status: Int
        var headers: [(String, String)] = []
        var body: Data = Data()
        static let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                              405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large"]
        var reason: String { Self.reasons[status] ?? "Error" }
        func serialized() -> Data {
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            head += "Content-Length: \(body.count)\r\n\r\n"
            return Data(head.utf8) + body
        }
    }

    /// Parses one request from the front of `buffer` if it is complete, removing its bytes. Nil when more bytes
    /// are needed; throws when the head is malformed or the body is over the cap.
    static func parse(_ buffer: inout Data, maxBody: Int) throws -> HTTPRequest? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 * 1024 { throw ParseError.malformed("request head over 64 KB") }
            return nil
        }
        guard let headText = String(bytes: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else { throw ParseError.malformed("request head is not UTF-8") }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { throw ParseError.malformed("request line") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headEnd.upperBound
        var body = Data()
        var consumedEnd = bodyStart
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var cursor = bodyStart
            while true {
                guard let lineEnd = buffer[cursor...].range(of: Data("\r\n".utf8)) else { return nil }
                let sizeLine = String(bytes: buffer[cursor..<lineEnd.lowerBound], encoding: .utf8) ?? ""
                let sizeText = sizeLine.split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw ParseError.malformed("chunk size") }
                cursor = lineEnd.upperBound
                if size == 0 {
                    // Trailers end with an empty line.
                    guard let trailerEnd = buffer[cursor...].range(of: Data("\r\n".utf8)) else { return nil }
                    consumedEnd = trailerEnd.upperBound
                    break
                }
                guard buffer.endIndex - cursor >= size + 2 else { return nil }
                body.append(buffer[cursor..<cursor + size])
                if body.count > maxBody { throw ParseError.tooLarge }
                cursor += size + 2
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            if length > maxBody { throw ParseError.tooLarge }
            guard buffer.endIndex - bodyStart >= length else { return nil }
            body = buffer[bodyStart..<bodyStart + length]
            consumedEnd = bodyStart + length
        }
        buffer = Data(buffer[consumedEnd...])
        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: String(requestLine[1]), headers: headers, body: Data(body))
    }

    enum ParseError: Error { case malformed(String), tooLarge }

    /// The response for one parsed request: the token first, then the path, then the method.
    func respond(to request: HTTPRequest) async -> HTTPResponse {
        state.withLock { $0.requestsServed += 1 }
        let json: [(String, String)] = [("Content-Type", "application/json"), ("Mcp-Session-Id", mcpSessionId)]
        guard request.headers["authorization"] == "Bearer \(token)" else {
            let body = JSONValue.object(["jsonrpc": "2.0", "id": .null, "error": ["code": -32001, "message": "unauthorized"]])
            return HTTPResponse(status: 401, headers: json + [("WWW-Authenticate", "Bearer")], body: Data(body.canonicalJSON.utf8))
        }
        guard request.path == configuration.path || request.path.hasPrefix(configuration.path + "?") else {
            return HTTPResponse(status: 404, headers: json, body: Data(#"{"error":"not found"}"#.utf8))
        }
        switch request.method {
        case "GET": return HTTPResponse(status: 405, headers: [("Allow", "POST, DELETE"), ("Mcp-Session-Id", mcpSessionId)])
        case "DELETE": return HTTPResponse(status: 200, headers: [("Mcp-Session-Id", mcpSessionId)])
        case "POST": break
        default: return HTTPResponse(status: 405, headers: [("Allow", "POST, DELETE")])
        }
        let message: JSONValue
        do { message = try JSONValue(data: request.body) } catch {
            let body = JSONValue.object(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "parse error"]])
            return HTTPResponse(status: 400, headers: json, body: Data(body.canonicalJSON.utf8))
        }
        guard case .object = message else {
            let body = JSONValue.object(["jsonrpc": "2.0", "id": .null, "error": ["code": -32600, "message": "one JSON-RPC object per request"]])
            return HTTPResponse(status: 400, headers: json, body: Data(body.canonicalJSON.utf8))
        }
        guard let reply = await MCPToolDispatch.reply(to: message, serverName: configuration.serverName, tools: configuration.tools, call: configuration.call) else {
            return HTTPResponse(status: 202, headers: [("Mcp-Session-Id", mcpSessionId)])
        }
        return HTTPResponse(status: 200, headers: json, body: Data(reply.canonicalJSON.utf8))
    }

}

/// One accepted TCP connection of `LoopbackMCPServer`: bytes in, requests parsed as they complete, answered one
/// after another on the server's queue.
final class LoopbackMCPConnection: Sendable {
    private struct WeakServer: Sendable { weak var server: LoopbackMCPServer? }
    private let nw: NWConnection
    private let serverBox: Mutex<WeakServer>
    private var serverRef: LoopbackMCPServer? { serverBox.withLock { $0.server } }
    private let buffer = Mutex(Data())
    private let chain = Mutex<Task<Void, Never>?>(nil)

    init(_ nw: NWConnection, server: LoopbackMCPServer) { self.nw = nw; self.serverBox = Mutex(WeakServer(server: server)) }

    func start(on queue: DispatchQueue) {
        nw.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        nw.start(queue: queue)
        receive()
    }

    func close() { nw.cancel() }

    private func finish() {
        chain.withLock { $0 }?.cancel()
        serverRef?.forget(self)
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.withLock { $0.append(data) }; self.drain() }
            if complete || error != nil { self.nw.cancel(); return }
            self.receive()
        }
    }

    /// Parses every complete request in the buffer and queues its answer behind the previous one.
    private func drain() {
        guard let server = serverRef else { nw.cancel(); return }
        while true {
            let parsed: Result<LoopbackMCPServer.HTTPRequest?, Error> = buffer.withLock { b in
                do { return .success(try LoopbackMCPServer.parse(&b, maxBody: server.configuration.maxBodyBytes)) } catch { return .failure(error) }
            }
            switch parsed {
            case .success(nil): return
            case .success(let request?):
                enqueue { [weak self] in
                    guard let self, let server = self.serverRef else { return }
                    let response = await server.respond(to: request)
                    self.send(response, closeAfter: request.closeAfter)
                }
            case .failure(let error):
                let status = (error as? LoopbackMCPServer.ParseError).map { if case .tooLarge = $0 { return 413 }; return 400 } ?? 400
                buffer.withLock { $0.removeAll() }
                enqueue { [weak self] in self?.send(LoopbackMCPServer.HTTPResponse(status: status), closeAfter: true) }
                return
            }
        }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        chain.withLock { previous in
            previous = Task { [previous] in
                await previous?.value
                if Task.isCancelled { return }
                await work()
            }
        }
    }

    private func send(_ response: LoopbackMCPServer.HTTPResponse, closeAfter: Bool) {
        nw.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            if closeAfter { self?.nw.cancel() }
        })
    }
}
