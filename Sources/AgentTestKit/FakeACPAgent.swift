import Foundation
import AgentProtocol

/// A scripted ACP agent (agentclientprotocol.com, protocol version 1) for tests of `ACPEngine`, the way
/// fake-claude stands in for the CLI. `initialize`, `session/new`, `session/load` (when `loadSession` is set),
/// and one prompt scenario: a thought, a message, a `tool_call`, a `session/request_permission` the client
/// answers, the tool's end, a closing message and `end_turn`. A prompt containing `fail` is answered with a
/// JSON-RPC error; one containing `sleep` runs until `session/cancel` and ends `cancelled`; `--model NAME` on
/// the command line becomes the session's `currentModelId`, so a test sees the model argument arrive.
public final class FakeACPAgent {
    public var model: String?
    public var loadSession = false
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
                respond(id, ["protocolVersion": 1,
                             "agentCapabilities": ["loadSession": .bool(loadSession),
                                                   "promptCapabilities": ["image": false, "audio": false, "embeddedContext": true]],
                             "authMethods": [],
                             "agentInfo": ["name": .string(Self.agentName), "version": .string(Self.agentVersion)]])
            case "session/new":
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
        if chosen.hasPrefix("allow") {
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
/// `FAKE_ACP_EXIT_ON_PROMPT=1` makes the agent exit with status 3 when the first prompt arrives.
public enum FakeACPMain {
    public static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = ProcessInfo.processInfo.environment
        let agent = FakeACPAgent(readLine: { Swift.readLine(strippingNewline: true) }, writeLine: { print($0) })
        let args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count { agent.model = args[i + 1] }
        agent.loadSession = env["FAKE_ACP_LOAD_SESSION"] != nil
        agent.exitOnPrompt = env["FAKE_ACP_EXIT_ON_PROMPT"] != nil
        exit(agent.run())
    }
}
