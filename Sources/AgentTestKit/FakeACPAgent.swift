import Foundation
import AgentProtocol

/// A scripted ACP agent (agentclientprotocol.com, protocol version 1) for tests of `ACPEngine`, the way
/// fake-claude stands in for the CLI. `initialize`, `session/new`, `session/load` (when `loadSession` is set),
/// and one prompt scenario: a thought, a message, a `tool_call`, a `session/request_permission` the client
/// answers, the tool's end, a closing message and `end_turn`; a prompt naming `hello.txt` ends the call the way
/// GitHub Copilot CLI does (a message chunk while the call runs, a `completed` update with two content blocks, a
/// closing chunk). A prompt containing `fail` is answered with a
/// JSON-RPC error; one containing `sleep` runs until `session/cancel` and ends `cancelled`; `--model NAME` on
/// the command line becomes the session's `currentModelId`, so a test sees the model argument arrive.
///
/// MCP pass-through (Kyberna release plan v0.2.14 Phase 2 step (e)): `initialize` advertises
/// `mcpCapabilities {http: true}` unless `noHTTPMCP`; `session/new` keeps the first `{"type":"http"}` entry of
/// `mcpServers`; a prompt that does not name `utils.py` then runs the streamable-HTTP scenario GitHub Copilot CLI
/// showed in the spike of 2026-09-21: a `server/discover` probe (an error is tolerated), `initialize` at
/// `2025-11-25`, `notifications/initialized`, a `GET` (405 tolerated), `tools/list`, then a `tool_call` titled
/// `<server>-<tool>` and a `session/request_permission` titled with the bare tool name and kind `other`; on an
/// allow, `tools/call` (the tool named in the prompt, else the first; arguments from `args={...}` in the prompt)
/// whose result is the `completed` update's content (or a `failed` one for `isError`) and a closing message
/// "The tool returned: …"; on a rejection, a `failed` update with Copilot's `rawOutput` and no text; `DELETE` at
/// the end. Every request carries the entry's headers (the bearer token).
public final class FakeACPAgent {
    public var model: String?
    public var loadSession = false
    /// Leave `mcpCapabilities` out of `initialize` (`FAKE_ACP_NO_HTTP_MCP`), so the client falls back to stdio.
    public var noHTTPMCP = false
    /// One HTTP MCP server as `session/new` named it.
    public struct MCPServerRef: Sendable, Equatable { public var name: String; public var url: String; public var headers: [String: String] }
    /// The HTTP MCP server `session/new` named, if any.
    public private(set) var mcpServer: MCPServerRef?
    /// Exit with status 3 when the first prompt arrives (`FAKE_ACP_EXIT_ON_PROMPT`).
    public var exitOnPrompt = false
    private var nextRequestId = 100
    private let readLine: () -> String?
    private let writeLine: (String) -> Void
    /// Every line the client wrote, for a test that drives the agent in process.
    public private(set) var received: [JSONValue] = []

    public init(readLine: @escaping () -> String?, writeLine: @escaping (String) -> Void) {
        self.readLine = readLine; self.writeLine = writeLine
    }

    public static let sessionId = "fake-acp-session-1"
    public static let agentName = "fake-acp"
    public static let agentVersion = "0.1.0"

    /// Runs until stdin ends. Returns the exit status.
    public func run() -> Int32 {
        while let line = readLine() {
            guard let v = Fixture.parse(line) else { continue }
            received.append(v)
            let method = v["method"]?.stringValue
            let id = v["id"]
            switch method {
            case "initialize":
                var capabilities: [String: JSONValue] = ["loadSession": .bool(loadSession),
                                                         "promptCapabilities": ["image": false, "audio": false, "embeddedContext": true]]
                if !noHTTPMCP { capabilities["mcpCapabilities"] = ["http": true, "sse": false] }
                respond(id, ["protocolVersion": 1,
                             "agentCapabilities": .object(capabilities),
                             "authMethods": [],
                             "agentInfo": ["name": .string(Self.agentName), "version": .string(Self.agentVersion)]])
            case "session/new":
                for entry in v["params"]?["mcpServers"]?.arrayValue ?? [] where entry["type"]?.stringValue == "http" {
                    guard let url = entry["url"]?.stringValue else { continue }
                    var headers: [String: String] = [:]
                    for h in entry["headers"]?.arrayValue ?? [] { if let n = h["name"]?.stringValue, let val = h["value"]?.stringValue { headers[n] = val } }
                    mcpServer = MCPServerRef(name: entry["name"]?.stringValue ?? "server", url: url, headers: headers)
                    break
                }
                respond(id, ["sessionId": .string(Self.sessionId), "models": models])
            case "session/load":
                guard loadSession else { error(id, code: -32601, message: "session/load is not supported"); continue }
                notify("session/update", ["sessionId": v["params"]?["sessionId"] ?? .null,
                                          "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "replayed earlier answer"]]])
                respond(id, [:])
            case "session/prompt":
                if exitOnPrompt { return 3 }
                prompt(id, v["params"] ?? .object([:]))
            case "session/cancel", nil:
                break
            default:
                if let id, !id.isNull { error(id, code: -32601, message: "method not found: \(method ?? "")") }
            }
        }
        return 0
    }

    private var models: JSONValue {
        ["currentModelId": .string(model ?? "fake-default"),
         "availableModels": [["modelId": "fake-default", "name": "Fake default", "description": "the fake's own model"],
                             ["modelId": "fake-large", "name": "Fake large", "description": "a second row"]]]
    }

    private func prompt(_ id: JSONValue?, _ params: JSONValue) {
        let sid = params["sessionId"] ?? .string(Self.sessionId)
        let text = (params["prompt"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        func update(_ u: JSONValue) { notify("session/update", ["sessionId": sid, "update": u]) }
        if text.contains("fail") { error(id, code: -32000, message: "the fake agent failed on purpose"); return }
        if let mcpServer, !text.contains("utils.py") { mcpPrompt(id, sid: sid, text: text, server: mcpServer); return }
        if text.contains("sleep") {
            update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "working until cancelled"]])
            while let line = readLine() {
                guard let v = Fixture.parse(line) else { continue }
                received.append(v)
                if v["method"]?.stringValue == "session/cancel" { respond(id, ["stopReason": "cancelled"]); return }
            }
            return
        }
        update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Thinking about the file."]])
        update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "I will read utils.py."]])
        let call: JSONValue = ["toolCallId": "call-1", "title": "Read utils.py", "kind": "read", "status": "pending", "name": "read_file", "rawInput": ["path": "utils.py"]]
        update(["sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "Read utils.py", "kind": "read", "status": "pending", "name": "read_file", "rawInput": ["path": "utils.py"]])
        let requestId = nextRequestId; nextRequestId += 1
        writeLine(Self.encode(["jsonrpc": "2.0", "id": .number(Double(requestId)), "method": "session/request_permission",
                               "params": ["sessionId": sid, "toolCall": call,
                                          "options": [["optionId": "allow-once", "name": "Allow", "kind": "allow_once"],
                                                      ["optionId": "allow-always", "name": "Always allow", "kind": "allow_always"],
                                                      ["optionId": "reject-once", "name": "Reject", "kind": "reject_once"]]]]))
        var chosen: String?
        var cancelled = false
        while let line = readLine() {
            guard let v = Fixture.parse(line) else { continue }
            received.append(v)
            if v["method"]?.stringValue == "session/cancel" { cancelled = true; continue }
            guard v["id"]?.intValue == requestId else { continue }
            let outcome = v["result"]?["outcome"]
            if outcome?["outcome"]?.stringValue == "selected" { chosen = outcome?["optionId"]?.stringValue } else { cancelled = true }
            break
        }
        guard let chosen, !cancelled else {
            update(["sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "failed"])
            respond(id, ["stopReason": "cancelled"]); return
        }
        if chosen.hasPrefix("allow"), text.contains("hello.txt") {
            // GitHub Copilot CLI's shape after an edit (Kyberna console 93): a message chunk while the call runs, a
            // `completed` update with several content blocks, and a closing chunk after it.
            update(["sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "in_progress"])
            update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Info: /tmp/hello.txt"]])
            update(["sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed",
                    "content": [["type": "content", "content": ["type": "text", "text": "wrote 6 bytes"]],
                                ["type": "content", "content": ["type": "text", "text": "ok"]]]])
            update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Done."]])
        } else if chosen.hasPrefix("allow") {
            update(["sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "in_progress"])
            update(["sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed",
                    "content": [["type": "content", "content": ["type": "text", "text": "def calculate_average(values):\n    return sum(values) / len(values)"]]],
                    "rawOutput": ["bytes": 61]])
            update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("utils.py defines calculate_average. (permission: \(chosen))")]])
        } else {
            update(["sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "failed",
                    "content": [["type": "content", "content": ["type": "text", "text": "permission denied"]]]])
            update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("I could not read the file. (permission: \(chosen))")]])
        }
        respond(id, ["stopReason": "end_turn"])
    }

    // MARK: The MCP scenario

    private struct HTTPReply { var status: Int; var headers: [String: String]; var body: JSONValue? }

    /// One HTTP request to the MCP server, synchronous; nil when the transport failed.
    private func http(_ method: String, _ server: MCPServerRef, body: JSONValue?, extra: [String: String] = [:]) -> HTTPReply? {
        guard let url = URL(string: server.url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in server.headers { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extra { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.canonicalJSON.utf8)
        }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var result: HTTPReply? }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let r = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in r.allHeaderFields { if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v } }
                let json: JSONValue? = data.flatMap { $0.isEmpty ? Optional<JSONValue>.none : try? JSONValue(data: $0) }
                box.result = HTTPReply(status: r.statusCode, headers: headers, body: json)
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return box.result
    }

    private func mcpPrompt(_ id: JSONValue?, sid: JSONValue, text: String, server: MCPServerRef) {
        func update(_ u: JSONValue) { notify("session/update", ["sessionId": sid, "update": u]) }
        func giveUp(_ why: String) {
            update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("MCP server error: \(why)")]])
            respond(id, ["stopReason": "end_turn"])
        }
        // The probe Copilot sends first; its error is tolerated.
        _ = http("POST", server, body: ["jsonrpc": "2.0", "id": 0, "method": "server/discover", "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]])
        guard let initialized = http("POST", server, body: ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                             "params": ["protocolVersion": "2025-11-25", "capabilities": ["sampling": .object([:])],
                                                                        "clientInfo": ["name": "fake-acp", "version": .string(Self.agentVersion)]]]),
              initialized.status == 200, initialized.body?["result"]?["protocolVersion"] != nil else {
            giveUp("initialize failed"); return
        }
        let session = initialized.headers["mcp-session-id"].map { ["Mcp-Session-Id": $0, "MCP-Protocol-Version": "2025-11-25"] } ?? [:]
        guard http("POST", server, body: ["jsonrpc": "2.0", "method": "notifications/initialized"], extra: session)?.status == 202 else { giveUp("initialized notification was not accepted"); return }
        _ = http("GET", server, body: nil, extra: session)   // the SSE stream; 405 is fine
        guard let listed = http("POST", server, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": .object([:])], extra: session),
              let tools = listed.body?["result"]?["tools"]?.arrayValue, !tools.isEmpty else { giveUp("tools/list returned nothing"); return }
        let names = tools.compactMap { $0["name"]?.stringValue }
        let chosen = names.first { text.contains($0) } ?? names.first { n in text.contains(n.split(separator: "_", maxSplits: 1).last.map(String.init) ?? n) } ?? names[0]
        var arguments: JSONValue = .object([:])
        if let range = text.range(of: "args="), let parsed = try? JSONValue(data: Data(text[range.upperBound...].utf8)) { arguments = parsed }
        let callId = "mcp-call-1"
        update(["sessionUpdate": "tool_call", "toolCallId": .string(callId), "title": .string("\(server.name)-\(chosen)"), "kind": "search", "status": "pending", "rawInput": arguments])
        let requestId = nextRequestId; nextRequestId += 1
        writeLine(Self.encode(["jsonrpc": "2.0", "id": .number(Double(requestId)), "method": "session/request_permission",
                               "params": ["sessionId": sid,
                                          "toolCall": ["toolCallId": .string(callId), "title": .string(chosen), "kind": "other", "status": "pending", "rawInput": arguments],
                                          "options": [["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"],
                                                      ["optionId": "allow_always", "name": "Always allow", "kind": "allow_always"],
                                                      ["optionId": "reject_once", "name": "Deny", "kind": "reject_once"]]]]))
        var answer: String?
        var cancelled = false
        while let line = readLine() {
            guard let v = Fixture.parse(line) else { continue }
            received.append(v)
            if v["method"]?.stringValue == "session/cancel" { cancelled = true; continue }
            guard v["id"]?.intValue == requestId else { continue }
            let outcome = v["result"]?["outcome"]
            if outcome?["outcome"]?.stringValue == "selected" { answer = outcome?["optionId"]?.stringValue } else { cancelled = true }
            break
        }
        guard let answer, !cancelled else {
            update(["sessionUpdate": "tool_call_update", "toolCallId": .string(callId), "status": "failed"])
            respond(id, ["stopReason": "cancelled"]); return
        }
        if answer.hasPrefix("allow") {
            guard let called = http("POST", server, body: ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": .string(chosen), "arguments": arguments]], extra: session),
                  let result = called.body?["result"] else { giveUp("tools/call failed"); return }
            let blocks = (result["content"]?.arrayValue ?? []).map { block -> JSONValue in ["type": "content", "content": block] }
            let joined = (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            if result["isError"]?.boolValue == true {
                update(["sessionUpdate": "tool_call_update", "toolCallId": .string(callId), "status": "failed", "content": .array(blocks)])
            } else {
                update(["sessionUpdate": "tool_call_update", "toolCallId": .string(callId), "status": "completed", "content": .array(blocks),
                        "rawOutput": ["content": .string(joined)]])
                update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("The tool returned: \(joined)")]])
            }
        } else {
            // Copilot's shape for a rejection: a failed update with its own message, and no text for the person.
            update(["sessionUpdate": "tool_call_update", "toolCallId": .string(callId), "status": "failed",
                    "rawOutput": ["message": "The user rejected this tool call.", "code": "rejected"]])
        }
        _ = http("DELETE", server, body: nil, extra: session)
        respond(id, ["stopReason": "end_turn"])
    }

    private func respond(_ id: JSONValue?, _ result: JSONValue) {
        writeLine(Self.encode(["jsonrpc": "2.0", "id": id ?? .null, "result": result]))
    }
    private func error(_ id: JSONValue?, code: Int, message: String) {
        writeLine(Self.encode(["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .number(Double(code)), "message": .string(message)]]))
    }
    private func notify(_ method: String, _ params: JSONValue) {
        writeLine(Self.encode(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }
    static func encode(_ v: JSONValue) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(data: (try? enc.encode(v)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}

/// The fake ACP agent as a function, so an executable in any package is one line: `FakeACPMain.run()`.
/// Usage: `fake-acp [--model NAME] [any other args]`; `FAKE_ACP_LOAD_SESSION=1` advertises `session/load`,
/// `FAKE_ACP_EXIT_ON_PROMPT=1` makes the agent exit with status 3 when the first prompt arrives,
/// `FAKE_ACP_NO_HTTP_MCP=1` leaves `mcpCapabilities` out of `initialize`.
public enum FakeACPMain {
    public static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = ProcessInfo.processInfo.environment
        let agent = FakeACPAgent(readLine: { Swift.readLine(strippingNewline: true) }, writeLine: { print($0) })
        let args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count { agent.model = args[i + 1] }
        agent.loadSession = env["FAKE_ACP_LOAD_SESSION"] != nil
        agent.exitOnPrompt = env["FAKE_ACP_EXIT_ON_PROMPT"] != nil
        agent.noHTTPMCP = env["FAKE_ACP_NO_HTTP_MCP"] != nil
        exit(agent.run())
    }
}
