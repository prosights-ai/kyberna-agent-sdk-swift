import Foundation
import AgentProtocol

/// A recorded fixture: the argument list, the lines the client wrote, and the lines the CLI wrote.
public struct Fixture: Sendable {
    public var directory: String
    public var arguments: [String]
    public var stdinLines: [String]
    public var stdoutLines: [String]
    public var meta: JSONValue

    public init(directory: String) throws {
        self.directory = directory
        func lines(_ name: String) throws -> [String] {
            let t = try String(contentsOfFile: directory + "/" + name, encoding: .utf8)
            return t.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/args.json")))
        stdinLines = try lines("stdin.jsonl")
        stdoutLines = try lines("stdout.jsonl")
        meta = (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/meta.json")))) ?? .null
    }

    public static func parse(_ line: String) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { return nil }
        return JSONValue(any: any)
    }
}

/// Replays a fixture as if it were the Claude Code CLI. The recording keeps stdin and stdout in their own
/// order but not their interleaving, so the fake reconstructs causality: a CLI `control_response` waits for
/// the client's matching `control_request`; a CLI line that follows a CLI `control_request` waits for the
/// client's answer to it; a turn's first line (`system`/`init`) waits for a user message. Client lines are
/// validated against the recorded stdin lines structurally, ignoring volatile fields.
public final class FakeCLIScript: Sendable {
    public let fixture: Fixture
    public init(fixture: Fixture) { self.fixture = fixture }

    /// True when `actual` (a client line) matches `expected` from the recording, ignoring volatile fields.
    public static func matches(expected: JSONValue, actual: JSONValue) -> Bool { scrub(expected) == scrub(actual) }
    static let volatileKeys: Set<String> = ["request_id", "session_id", "uuid", "id", "timestamp", "parent_tool_use_id"]
    static func scrub(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            var r: [String: JSONValue] = [:]
            for (k, val) in o where !volatileKeys.contains(k) { r[k] = scrub(val) }
            return .object(r)
        case .array(let a): return .array(a.map(scrub))
        default: return v
        }
    }
}

/// Drives a fixture over arbitrary input/output closures. Used by the `fake-claude` executable (stdin/stdout)
/// and directly by tests.
public final class FakeCLIRunner {
    let script: FakeCLIScript
    public var strict = true
    public private(set) var mismatches: [String] = []

    private var remainingRecorded: [JSONValue]
    private var idMap: [String: String] = [:]          // recorded client request id -> actual client request id
    private var clientRequestsSeen: Set<String> = []    // actual ids
    private var clientResponsesSeen: Set<String> = []   // CLI request ids the client has answered
    private var userMessagesReceived = 0
    private var userMessagesConsumed = 0

    public init(script: FakeCLIScript) {
        self.script = script
        remainingRecorded = script.fixture.stdinLines.compactMap(Fixture.parse)
    }

    /// Runs to completion. `readLine` returns nil at EOF. Returns the exit status the CLI would have used.
    public func run(readLine: () -> String?, writeLine: (String) -> Void) -> Int32 {
        let stdout = script.fixture.stdoutLines.compactMap(Fixture.parse)
        var previousCLIRequestId: String?
        for line in stdout {
            // What must the client have sent before this line can go out?
            let need: () -> Bool
            let t = line["type"]?.stringValue
            if t == "control_response", let rid = line["response"]?["request_id"]?.stringValue {
                if script.fixture.stdinLines.contains(where: { $0.contains(rid) && $0.contains("control_request") }) {
                    // The CLI answering a client request: wait until the client has actually sent it.
                    need = { [self] in idMap[rid].map { clientRequestsSeen.contains($0) } ?? false }
                } else {
                    // An echo of the client's own answer to a CLI request (`--replay-user-messages` replays those too,
                    // observed on 2.1.271): wait until the client has answered that request.
                    need = { [self] in clientResponsesSeen.contains(rid) }
                }
            } else if let cid = previousCLIRequestId {
                need = { [self] in clientResponsesSeen.contains(cid) }
            } else if t == "system", line["subtype"]?.stringValue == "init" {
                need = { [self] in userMessagesReceived > userMessagesConsumed }
            } else { need = { true } }
            while !need() {
                guard let raw = readLine() else { return 0 }          // stdin closed: the CLI exits
                guard let actual = Fixture.parse(raw) else { continue }
                if let status = accept(actual, writeLine: writeLine) { return status }
            }
            if t == "system", line["subtype"]?.stringValue == "init" { userMessagesConsumed += 1 }
            writeLine(rewriteOutgoing(line).canonicalJSON)
            previousCLIRequestId = (t == "control_request") ? line["request_id"]?.stringValue : nil
        }
        while let raw = readLine() {   // drain until EOF, validating what arrives
            if let actual = Fixture.parse(raw), let status = accept(actual, writeLine: writeLine) { return status }
        }
        return 0
    }

    /// Validates one client line against the recording and records what it satisfies. Returns an exit status on a strict mismatch.
    private func accept(_ actual: JSONValue, writeLine: (String) -> Void) -> Int32? {
        let idx = remainingRecorded.firstIndex { FakeCLIScript.matches(expected: $0, actual: actual) }
        if let idx {
            let recorded = remainingRecorded.remove(at: idx)
            if actual["type"]?.stringValue == "control_request", let a = actual["request_id"]?.stringValue, let r = recorded["request_id"]?.stringValue { idMap[r] = a }
        } else {
            mismatches.append("unexpected client line: \(FakeCLIScript.scrub(actual).canonicalJSON.prefix(300))")
            if strict {
                writeLine((["type": "system", "subtype": "fake_cli_mismatch", "detail": .string(mismatches.last!)] as JSONValue).canonicalJSON)
                return 3
            }
            // Lenient: answer a control request the recording does not contain (a host asking get_context_usage,
            // mcp_status, and so on) with an empty success so the client does not wait for its timeout.
            if actual["type"]?.stringValue == "control_request", let rid = actual["request_id"]?.stringValue {
                writeLine((["type": "control_response", "response": ["subtype": "success", "request_id": .string(rid), "response": [:]]] as JSONValue).canonicalJSON)
            }
        }
        switch actual["type"]?.stringValue {
        case "control_request": if let a = actual["request_id"]?.stringValue { clientRequestsSeen.insert(a) }
        case "control_response": if let cid = actual["response"]?["request_id"]?.stringValue { clientResponsesSeen.insert(cid) }
        case "user": userMessagesReceived += 1
        default: break
        }
        return nil
    }

    /// Replace recorded client request ids in CLI control_response lines with the ids the client actually used.
    func rewriteOutgoing(_ v: JSONValue) -> JSONValue {
        guard case .object(var o) = v else { return v }
        if o["type"]?.stringValue == "control_response", case .object(var r)? = o["response"], let rid = r["request_id"]?.stringValue, let real = idMap[rid] {
            r["request_id"] = .string(real); o["response"] = .object(r)
        }
        return .object(o)
    }
}
