import Testing
import Foundation
import Synchronization
import AgentProtocol
import AgentSession
import AgentEngine
import AgentTestKit
@testable import AgentACP

/// Kyberna release plan v0.2.14 Phase 2 step (e): the host's tools reach an ACP agent through `mcpServers` on
/// `session/new`, over the loopback streamable-HTTP server, and back through the policy names. The fake agent plays
/// the scenario GitHub Copilot CLI showed in the spike of 2026-09-21. Nothing here needs the network beyond loopback.
@Suite(.serialized) struct ACPToolHostingTests {
    static var fakePath: String? { ACPEngineTests.fakePath }

    /// Recorded calls, a class so the tool's handler can capture it.
    final class Calls: Sendable {
        let box = Mutex<[[String: JSONValue]]>([])
        var all: [[String: JSONValue]] { box.withLock { $0 } }
        var isEmpty: Bool { all.isEmpty }
    }

    static func notesSearch(calls: Calls) throws -> SwiftTool {
        try SwiftTool(name: "notes_search", description: "Search the person's notes by words in the title or text",
                      inputSchema: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]) { input in
            calls.box.withLock { $0.append(input) }
            if input["query"]?.stringValue == "explode" { throw NSError(domain: "notes", code: 7, userInfo: [NSLocalizedDescriptionKey: "the notes runner failed"]) }
            return "2 notes match: 'Kyberna' (2026-09-20), 'Groceries' (2026-09-19)"
        }
    }

    /// The `initialized` message once the collector's reader has seen it (the reader runs as its own task, so the
    /// message can land a moment after `start()` returns).
    static func initialized(_ c: ACPEngineTests.Collector) async -> (tools: [String], data: JSONValue)? {
        for _ in 0..<100 {
            if let m = c.all.first(where: { if case .initialized = $0 { return true }; return false }), case .initialized(_, _, let tools, let data) = m { return (tools, data) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    // MARK: Naming and the endpoint wire

    @Test func namesMapBothWaysAndTheEndpointsEncodeAsTheSpecificationWrites() throws {
        let tool = try Self.notesSearch(calls: Calls())
        let naming = HostedToolNaming(serverName: "kyberna")
        #expect(naming.wireName(tool) == "kyberna_notes_search")
        #expect(naming.policyName(tool) == "mcp__kyberna__notes_search")
        for name in ["kyberna_notes_search", "mcp__kyberna__notes_search", "notes_search", "kyberna-kyberna_notes_search", "kyberna.kyberna_notes_search", "mcp__kyberna__kyberna_notes_search"] {
            #expect(naming.tool(matching: name, in: [tool])?.name == "notes_search", Comment(rawValue: name))
        }
        #expect(naming.tool(matching: "xkyberna_notes_search", in: [tool]) == nil)   // a letter before the wire name is another name
        #expect(naming.tool(matching: "kyberna_notes_search_v2", in: [tool]) == nil)
        #expect(naming.tool(matching: "read_file", in: [tool]) == nil)
        let http = MCPServerEndpoint.http(name: "kyberna", url: "http://127.0.0.1:48711/mcp", headers: [.init(name: "Authorization", value: "Bearer abc")])
        #expect(http.wire == ["type": "http", "name": "kyberna", "url": "http://127.0.0.1:48711/mcp", "headers": [["name": "Authorization", "value": "Bearer abc"]]])
        let stdio = MCPServerEndpoint.stdio(name: "kyberna", command: "/usr/local/bin/kyb", args: ["mcp-serve", "--session", "s1"], env: ["PATH": "/usr/bin"])
        #expect(stdio.wire == ["name": "kyberna", "command": "/usr/local/bin/kyb", "args": ["mcp-serve", "--session", "s1"], "env": [["name": "PATH", "value": "/usr/bin"]]])
        #expect(stdio.name == "kyberna")
        let data = try JSONEncoder().encode(http)
        #expect(try JSONDecoder().decode(MCPServerEndpoint.self, from: data) == http)
    }

    // MARK: The loopback server on its own

    @Test func theServerChecksTheTokenAnswersTheProbeAndServesToolsOverKeptAliveConnections() async throws {
        let calls = Calls()
        let tool = try Self.notesSearch(calls: calls)
        let naming = HostedToolNaming(serverName: "kyberna")
        let server = LoopbackMCPServer(configuration: .init(serverName: "kyberna",
                                                            tools: { [{ var d = tool.wire.objectValue!; d["name"] = .string(naming.wireName(tool)); return .object(d) }()] },
                                                            call: { name, args in
                                                                guard naming.tool(matching: name, in: [tool]) != nil else { return .error("Unknown tool \(name)") }
                                                                do { return try await tool.handler(args) } catch { return .error("\(error)") }
                                                            }))
        try await server.start()
        defer { server.stop() }
        let url = try #require(server.url)
        #expect(url.hasPrefix("http://127.0.0.1:"))
        #expect(url.hasSuffix("/mcp"))
        #expect(server.token.count == 64)
        guard case .http(let name, let u, let headers) = try #require(server.endpoint(name: "kyberna")) else { Issue.record("no http endpoint"); return }
        #expect(name == "kyberna" && u == url && headers == [.init(name: "Authorization", value: "Bearer \(server.token)")])

        // One raw HTTP/1.1 connection, requests in sequence, so keep-alive and the probe are exercised as Copilot does.
        let client = RawHTTPClient(port: try #require(server.port))
        try await client.connect()
        func post(_ body: JSONValue, token: String? = nil) async throws -> (Int, [String: String], JSONValue?) {
            try await client.request("POST", "/mcp", headers: ["Content-Type": "application/json"] + (token.map { ["Authorization": "Bearer \($0)"] } ?? [:]),
                                     body: Data(body.canonicalJSON.utf8))
        }
        // No token, wrong token: 401 with a JSON-RPC error and no tool served.
        let noToken = try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        #expect(noToken.0 == 401 && noToken.2?["error"]?["message"]?.stringValue == "unauthorized" && noToken.1["www-authenticate"] == "Bearer")
        let wrong = try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], token: "nope")
        #expect(wrong.0 == 401)
        // The vendor probe: method not found, tolerated by the client.
        let probe = try await post(["jsonrpc": "2.0", "id": 0, "method": "server/discover", "params": .object([:])], token: server.token)
        #expect(probe.0 == 200 && probe.2?["error"]?["code"]?.intValue == -32601)
        // initialize echoes the protocol version and hands out the session id.
        let initialized = try await post(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": .object([:]), "clientInfo": ["name": "t", "version": "0"]]], token: server.token)
        #expect(initialized.0 == 200)
        #expect(initialized.2?["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
        #expect(initialized.2?["result"]?["serverInfo"]?["name"]?.stringValue == "kyberna")
        #expect(initialized.2?["result"]?["capabilities"]?["tools"] != nil)
        #expect(initialized.1["mcp-session-id"] == server.mcpSessionId)
        #expect(initialized.1["content-type"] == "application/json")
        // A notification is 202 with no body; GET is 405; DELETE is 200.
        let note = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], token: server.token)
        #expect(note.0 == 202 && note.2 == nil, Comment(rawValue: "\(note)"))
        let get = try await client.request("GET", "/mcp", headers: ["Authorization": "Bearer \(server.token)", "Accept": "text/event-stream"], body: nil)
        #expect(get.0 == 405)
        // tools/list under the wire name; tools/call by the wire name and by Copilot's prefixed name.
        let listed = try await post(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": ["_meta": ["progressToken": 0]]], token: server.token)
        #expect(listed.2?["result"]?["tools"]?[0]?["name"]?.stringValue == "kyberna_notes_search")
        #expect(listed.2?["result"]?["tools"]?[0]?["inputSchema"]?["required"] == ["query"])
        let called = try await post(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "kyberna_notes_search", "arguments": ["query": "Kyberna"]]], token: server.token)
        #expect(called.2?["result"]?["content"]?[0]?["text"]?.stringValue?.hasPrefix("2 notes match") == true)
        #expect(called.2?["result"]?["isError"] == nil)
        let prefixed = try await post(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "kyberna-kyberna_notes_search", "arguments": ["query": "explode"]]], token: server.token)
        #expect(prefixed.2?["result"]?["isError"]?.boolValue == true)   // the tool's throw is a result, never an error response
        #expect(prefixed.2?["result"]?["content"]?[0]?["text"]?.stringValue?.contains("the notes runner failed") == true)
        let unknown = try await post(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "kyberna_mail_send", "arguments": .object([:])]], token: server.token)
        #expect(unknown.2?["result"]?["isError"]?.boolValue == true)
        // Malformed JSON is 400; a chunked body is read; an unknown path is 404.
        let bad = try await client.request("POST", "/mcp", headers: ["Authorization": "Bearer \(server.token)", "Content-Type": "application/json"], body: Data("{not json".utf8))
        #expect(bad.0 == 400 && bad.2?["error"]?["code"]?.intValue == -32700)
        let chunked = try await client.requestChunked("POST", "/mcp", headers: ["Authorization": "Bearer \(server.token)", "Content-Type": "application/json"],
                                                      body: Data(JSONValue.object(["jsonrpc": "2.0", "id": 6, "method": "ping"]).canonicalJSON.utf8))
        #expect(chunked.0 == 200 && chunked.2?["result"] == .object([:]))
        let missing = try await client.request("POST", "/other", headers: ["Authorization": "Bearer \(server.token)"], body: Data("{}".utf8))
        #expect(missing.0 == 404)
        let deleted = try await client.request("DELETE", "/mcp", headers: ["Authorization": "Bearer \(server.token)", "Mcp-Session-Id": server.mcpSessionId], body: nil)
        #expect(deleted.0 == 200)
        #expect(calls.all == [["query": "Kyberna"], ["query": "explode"]])
        #expect(server.requestsServed == 14)
        client.close()
        // Stopped: nothing answers on the port.
        server.stop()
        let after = RawHTTPClient(port: try #require(server.port))
        var refused = false
        do { try await after.connect(); _ = try await after.request("GET", "/mcp", headers: [:], body: nil) } catch { refused = true }
        #expect(refused)
    }

    // MARK: Through the engine and the fake agent

    /// The full path: `host` before start, the endpoint in `session/new` (only because the fake advertised HTTP),
    /// the agent's `tools/list` and `tool_call` under its prefixed name, the permission request under the bare
    /// name matched by id and put to the policy under the policy name, the call at the server without a second
    /// ask, the result as the tool result and in the agent's answer, and the server gone with the session.
    @Test func aHostedToolRunsEndToEndWithThePolicyAnsweringOnce() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built; run `swift build --product fake-acp` first"); return }
        let calls = Calls()
        let engine = ACPEngine(options: ACPEngineTests.options(fake: fake))
        try engine.host([try Self.notesSearch(calls: calls)], serverName: "kyberna")
        #expect(engine.hostedTools.map(\.name) == ["notes_search"])
        #expect(engine.hostedToolList().map { $0["name"]?.stringValue } == ["kyberna_notes_search"])
        let policyAsked = Mutex<[String]>([])
        try engine.setPolicy { tool, input in
            policyAsked.withLock { $0.append(tool) }
            return tool == "mcp__kyberna__notes_search" && input["query"]?.stringValue == "Kyberna" ? .allow : .ask
        }
        let personAsked = Mutex(0)
        try engine.setPermissionHandler { _, _, _ in personAsked.withLock { $0 += 1 }; return .deny("the person should not have been asked") }
        let c = ACPEngineTests.Collector(engine)
        try await engine.start()
        #expect(engine.hostedToolTransport == "http")
        let port = try #require(engine.toolServerPort)
        guard let (tools, data) = await Self.initialized(c) else { Issue.record("no initialized"); return }
        #expect(tools == ["mcp__kyberna__notes_search"])
        #expect(data["mcpTransport"]?.stringValue == "http")
        #expect(data["mcpHttp"]?.boolValue == true)
        try await engine.send("Search my notes for Kyberna with kyberna_notes_search args={\"query\":\"Kyberna\"}")
        let seen = await c.untilResult()
        // The tool use carries the policy name, as the CLI's in-process server would show it.
        let uses = seen.compactMap { m -> (String, JSONValue)? in
            guard case .assistant(let a) = m else { return nil }
            return a.content.compactMap { if case .toolUse(_, let n, let i) = $0 { return (n, i) }; return nil }.first
        }
        #expect(uses.count == 1 && uses.first?.0 == "mcp__kyberna__notes_search" && uses.first?.1 == ["query": "Kyberna"])
        #expect(policyAsked.withLock { $0 } == ["mcp__kyberna__notes_search", "mcp__kyberna__notes_search"])   // the permission request, then the call at the server
        #expect(personAsked.withLock { $0 } == 0)
        #expect(calls.all == [["query": "Kyberna"]])
        let results = seen.compactMap { if case .user(let u) = $0 { return u }; return nil }
        #expect(results.count == 1)
        if case .toolResult(let id, _, let isError) = results.first?.content.first { #expect(id == "mcp-call-1"); #expect(!isError) } else { Issue.record("no tool result") }
        #expect(results.first?.content.first?.resultText.hasPrefix("2 notes match") == true)
        let texts = seen.compactMap { if case .assistant(let a) = $0 { return a.content.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined() }; return nil }
        #expect(texts.last?.hasPrefix("The tool returned: 2 notes match") == true)
        #expect(!seen.contains { if case .permissionRequest = $0 { return true }; return false })
        #expect(!seen.contains { if case .system("hosted_tools_unavailable", _) = $0 { return true }; return false })
        guard case .result(let r) = seen.last else { Issue.record("no result"); return }
        #expect(r.subtype == "success" && r.stopReason == "end_turn")
        await engine.stop(.session)
        await c.untilExit()
        #expect(engine.toolServerPort == nil)
        let probe = RawHTTPClient(port: port)
        var gone = false
        do { try await probe.connect(); _ = try await probe.request("GET", "/mcp", headers: [:], body: nil) } catch { gone = true }
        #expect(gone)
    }

    /// The person answers the permission request once; the same call at the server runs on that answer.
    @Test func thePersonIsAskedOnceAndTheGrantCoversTheCallAtTheServer() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let calls = Calls()
        let engine = ACPEngine(options: ACPEngineTests.options(fake: fake))
        try engine.host([try Self.notesSearch(calls: calls)], serverName: "kyberna")
        let asked = Mutex<[(String, String?, String?)]>([])
        try engine.setPermissionHandler { tool, input, ctx in
            asked.withLock { $0.append((tool, ctx.toolUseId, ctx.title)) }
            #expect(input == ["query": "Kyberna"])
            #expect(ctx.payload.tool == "mcp__kyberna__notes_search")
            return .allow()
        }
        let c = ACPEngineTests.Collector(engine)
        try await engine.start()
        try await engine.send("search my notes args={\"query\":\"Kyberna\"}")
        let seen = await c.untilResult()
        let requests = seen.compactMap { if case .permissionRequest(let p) = $0 { return p }; return nil }
        #expect(requests.count == 1)
        #expect(requests.first?.tool == "mcp__kyberna__notes_search" && requests.first?.toolUseId == "mcp-call-1")
        let a = asked.withLock { $0 }
        #expect(a.count == 1 && a.first?.0 == "mcp__kyberna__notes_search" && a.first?.1 == "mcp-call-1" && a.first?.2 == "kyberna_notes_search")
        #expect(calls.all == [["query": "Kyberna"]])
        guard case .result(let r) = seen.last else { Issue.record("no result"); return }
        #expect(r.result?.hasPrefix("The tool returned") == true)
        await engine.stop(.session)
    }

    /// A refusal: the agent's `failed` update, whose text is the engine's reason rather than the agent's
    /// "The user rejected this tool call.", and the tool never ran.
    @Test func aRefusedHostedToolIsTheFailedStepWithTheReasonAndNeverRuns() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let calls = Calls()
        let engine = ACPEngine(options: ACPEngineTests.options(fake: fake))
        try engine.host([try Self.notesSearch(calls: calls)], serverName: "kyberna")
        try engine.setPolicy { tool, _ in .deny("\(tool) is not allowed for the console profile") }
        let c = ACPEngineTests.Collector(engine)
        try await engine.start()
        try await engine.send("search my notes args={\"query\":\"Kyberna\"}")
        let seen = await c.untilResult()
        let denied = seen.compactMap { if case .permissionDenied(let t, let id, let rt, let r) = $0 { return (t, id, rt, r) }; return nil }
        #expect(denied.count == 1)
        #expect(denied.first?.0 == "mcp__kyberna__notes_search" && denied.first?.1 == "mcp-call-1" && denied.first?.2 == "policy")
        let results = seen.compactMap { if case .user(let u) = $0 { return u }; return nil }
        #expect(results.count == 1)
        if case .toolResult(let id, _, let isError) = results.first?.content.first { #expect(id == "mcp-call-1"); #expect(isError) } else { Issue.record("no tool result") }
        let text = results.first?.content.first?.resultText ?? ""
        #expect(text.hasPrefix("mcp__kyberna__notes_search is not allowed for the console profile"), Comment(rawValue: text))
        #expect(text.contains("The user rejected this tool call."))
        #expect(calls.isEmpty)
        // The agent wrote nothing for the person; the turn still ends as a success with an empty result.
        guard case .result(let r) = seen.last else { Issue.record("no result"); return }
        #expect(r.subtype == "success" && r.result == "")
        await engine.stop(.session)
    }

    /// A call arriving at the server without a permission request first (an agent that never asks) is gated by
    /// the handler there; a denial is an `isError` result the agent shows as the failed step.
    @Test func aCallAtTheServerWithoutAGrantIsGatedThereAndTheToolsThrowIsAResult() async throws {
        let calls = Calls()
        let engine = ACPEngine(options: ACPEngineTests.options(fake: "/bin/echo"))
        try engine.host([try Self.notesSearch(calls: calls)], serverName: "kyberna")
        let decisions = Mutex<[PermissionDecision]>([.deny("not now"), .allow(), .allow()])
        try engine.setPermissionHandler { tool, _, ctx in
            #expect(tool == "mcp__kyberna__notes_search" && ctx.toolUseId == nil && ctx.title == "notes_search")
            return decisions.withLock { $0.removeFirst() }
        }
        let c = ACPEngineTests.Collector(engine)
        let refused = await engine.callHostedTool("kyberna_notes_search", arguments: ["query": "Kyberna"])
        #expect(refused.isError && refused.content == [.text("notes_search was refused: not now")])
        #expect(calls.isEmpty)
        let ran = await engine.callHostedTool("mcp__kyberna__notes_search", arguments: ["query": "Kyberna"])
        #expect(!ran.isError && ran.content.first == .text("2 notes match: 'Kyberna' (2026-09-20), 'Groceries' (2026-09-19)"))
        let threw = await engine.callHostedTool("notes_search", arguments: ["query": "explode"])
        #expect(threw.isError && threw.content.first?.wire["text"]?.stringValue?.contains("the notes runner failed") == true)
        let unknown = await engine.callHostedTool("kyberna_mail_send", arguments: [:])
        #expect(unknown.isError)
        #expect(c.all.filter { if case .permissionRequest = $0 { return true }; return false }.count == 3)
        #expect(c.all.filter { if case .permissionDenied(_, _, "person", "not now") = $0 { return true }; return false }.count == 1)
    }

    /// An agent without `mcpCapabilities.http` gets the host's stdio line when one is configured, and a note on
    /// the stream when none is; either way `session/new` carries what the client offered.
    @Test func withoutHTTPTheStdioLineIsOfferedOrTheStreamSaysTheToolsAreUnavailable() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        var o = ACPEngineTests.options(fake: fake, env: ["FAKE_ACP_NO_HTTP_MCP": "1"])
        o.recordDirectory = NSTemporaryDirectory() + "acp-stdio-\(UUID().uuidString)"
        o.stdioToolServer = .stdio(name: "ignored", command: "/usr/local/bin/kyb", args: ["mcp-serve", "--session", "s1"], env: [:])
        let engine = ACPEngine(options: o)
        try engine.host([try Self.notesSearch(calls: Calls())], serverName: "kyberna")
        let c = ACPEngineTests.Collector(engine)
        try await engine.start()
        #expect(engine.hostedToolTransport == "stdio")
        #expect(engine.toolServerPort == nil)
        guard let (tools, data) = await Self.initialized(c) else { Issue.record("no initialized"); return }
        #expect(tools == ["mcp__kyberna__notes_search"])
        #expect(data["mcpTransport"]?.stringValue == "stdio" && data["mcpHttp"]?.boolValue == false)
        await engine.stop(.session)
        // The recorded stdin line for session/new carries the stdio entry under the host server name.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: o.recordDirectory!)) ?? []
        let text = files.compactMap { try? String(contentsOfFile: o.recordDirectory! + "/" + $0, encoding: .utf8) }.joined()
        #expect(text.contains(#""mcpServers":[{"args":["mcp-serve","--session","s1"],"command":"/usr/local/bin/kyb","env":[],"name":"kyberna"}]"#), Comment(rawValue: text))
        try? FileManager.default.removeItem(atPath: o.recordDirectory!)

        var none = ACPEngineTests.options(fake: fake, env: ["FAKE_ACP_NO_HTTP_MCP": "1"])
        none.stdioToolServer = nil
        let bare = ACPEngine(options: none)
        try bare.host([try Self.notesSearch(calls: Calls())], serverName: "kyberna")
        let c2 = ACPEngineTests.Collector(bare)
        try await bare.start()
        #expect(bare.hostedToolTransport == "none")
        guard let (noTools, _) = await Self.initialized(c2) else { Issue.record("no initialized"); return }
        #expect(noTools.isEmpty)
        let note = c2.all.compactMap { if case .system("hosted_tools_unavailable", let d) = $0 { return d }; return nil }.first
        #expect(note?["tools"] == ["notes_search"])
        #expect(note?["reason"]?.stringValue?.contains("mcpCapabilities.http") == true)
        await bare.stop(.session)
    }

    @Test func hostAfterStartThrowsAndResumableForwards() async throws {
        let tool = try Self.notesSearch(calls: Calls())
        let wrapped: any AgentEngine = ACPEngine.make(options: ACPEngineTests.options(fake: "/bin/echo", load: true))
        #expect(wrapped is ToolHosting)
        #expect(wrapped is HostedToolServing)
        let hosting = try #require(wrapped as? ToolHosting)
        try hosting.host([tool], serverName: "kyberna")
        #expect(hosting.hostedTools.map(\.name) == ["notes_search"])
        #expect((wrapped as? HostedToolServing)?.hostedToolList().first?["name"]?.stringValue == "kyberna_notes_search")
        guard let fake = Self.fakePath else { return }
        let engine = ACPEngine(options: ACPEngineTests.options(fake: fake))
        try await engine.start()
        #expect(throws: EngineError.self) { try engine.host([tool], serverName: "kyberna") }
        await engine.stop(.session)
    }
}

/// A raw HTTP/1.1 client over one TCP connection, so the tests see keep-alive, the status line and the headers
/// as the server writes them (URLSession would hide the connection reuse and normalise the rest).
final class RawHTTPClient: Sendable {
    private let port: UInt16
    private let connection: Mutex<NWConnectionBox?>
    final class NWConnectionBox: Sendable { let nw: Network.NWConnection; init(_ nw: Network.NWConnection) { self.nw = nw } }
    private let queue = DispatchQueue(label: "raw-http-client")
    private let inbox = Mutex(Data())

    init(port: UInt16) { self.port = port; connection = Mutex(nil) }

    func connect() async throws {
        let nw = Network.NWConnection(host: .ipv4(.loopback), port: .init(rawValue: port)!, using: .tcp)
        connection.withLock { $0 = NWConnectionBox(nw) }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let done = Mutex(false)
            nw.stateUpdateHandler = { s in
                switch s {
                case .ready: if !done.withLock({ let d = $0; $0 = true; return d }) { k.resume() }
                case .failed(let e): if !done.withLock({ let d = $0; $0 = true; return d }) { k.resume(throwing: e) }
                case .waiting(let e): if !done.withLock({ let d = $0; $0 = true; return d }) { k.resume(throwing: e) }
                case .cancelled: if !done.withLock({ let d = $0; $0 = true; return d }) { k.resume(throwing: CancellationError()) }
                default: break
                }
            }
            nw.start(queue: queue)
        }
    }

    func close() { connection.withLock { $0 }?.nw.cancel() }

    func request(_ method: String, _ path: String, headers: [String: String], body: Data?) async throws -> (Int, [String: String], JSONValue?) {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        return try await exchange(Data(head.utf8) + (body ?? Data()))
    }

    func requestChunked(_ method: String, _ path: String, headers: [String: String], body: Data) async throws -> (Int, [String: String], JSONValue?) {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        let half = body.count / 2
        var out = Data(head.utf8)
        for part in [body[..<half], body[half...]] {
            out += Data("\(String(part.count, radix: 16))\r\n".utf8) + part + Data("\r\n".utf8)
        }
        out += Data("0\r\n\r\n".utf8)
        return try await exchange(out)
    }

    private func exchange(_ bytes: Data) async throws -> (Int, [String: String], JSONValue?) {
        guard let nw = connection.withLock({ $0 })?.nw else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            nw.send(content: bytes, completion: .contentProcessed { e in if let e { k.resume(throwing: e) } else { k.resume() } })
        }
        // Read until one full response (head plus Content-Length body) is in the inbox.
        while true {
            if let parsed = inbox.withLock({ try? Self.parseResponse(&$0) }) ?? nil { return parsed }
            let chunk: Data = try await withCheckedThrowingContinuation { k in
                nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { k.resume(throwing: error); return }
                    if let data, !data.isEmpty { k.resume(returning: data); return }
                    if complete { k.resume(throwing: URLError(.networkConnectionLost)); return }
                    k.resume(returning: Data())
                }
            }
            inbox.withLock { $0.append(chunk) }
        }
    }

    static func parseResponse(_ buffer: inout Data) throws -> (Int, [String: String], JSONValue?)? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let status = Int(lines.removeFirst().split(separator: " ")[1]) ?? 0
        var headers: [String: String] = [:]
        for line in lines { if let c = line.firstIndex(of: ":") { headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.endIndex - headEnd.upperBound >= length else { return nil }
        let body = buffer[headEnd.upperBound..<headEnd.upperBound + length]
        buffer = Data(buffer[(headEnd.upperBound + length)...])
        let json: JSONValue? = body.isEmpty ? Optional<JSONValue>.none : try JSONValue(data: Data(body))   // a bare nil would be JSONValue.null (ExpressibleByNilLiteral)
        return (status, headers, json)
    }
}

import Network

private func + (lhs: [String: String], rhs: [String: String]) -> [String: String] { lhs.merging(rhs) { _, new in new } }
