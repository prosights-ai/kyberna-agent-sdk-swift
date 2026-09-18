import Foundation

/// One block of assistant or user content (mirrors the Agent SDK's content block types).
public enum ContentBlock: Sendable, Equatable, Codable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: JSONValue, isError: Bool)
    case serverToolUse(id: String, name: String, input: JSONValue)
    case serverToolResult(toolUseId: String, content: JSONValue)

    /// Flattened text of a tool_result's content, for display.
    public var resultText: String {
        guard case .toolResult(_, let c, _) = self else { return "" }
        if let s = c.stringValue { return s }
        return c.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(separator: "\n") ?? ""
    }
}

public struct AssistantMessage: Sendable, Equatable, Codable {
    public var uuid: String?
    public var content: [ContentBlock]
    /// Raw tool inputs keyed by tool_use id, as the CLI sent them to the model (`wire_tool_inputs`, 2.1.271+).
    /// Prefer this over the `input` in a `toolUse` block when exact bytes matter (approval hashes).
    public var wireToolInputs: [String: JSONValue]?
    public var model: String
    public var stopReason: String?
    public var usage: JSONValue?
    public var parentToolUseId: String?
    public init(uuid: String? = nil, content: [ContentBlock], model: String, stopReason: String? = nil, usage: JSONValue? = nil,
                parentToolUseId: String? = nil, wireToolInputs: [String: JSONValue]? = nil) {
        self.uuid = uuid; self.content = content; self.model = model; self.stopReason = stopReason; self.usage = usage
        self.parentToolUseId = parentToolUseId; self.wireToolInputs = wireToolInputs
    }
}

public struct UserMessage: Sendable, Equatable, Codable {
    public var uuid: String?
    public var content: [ContentBlock]
    public var parentToolUseId: String?
    public init(uuid: String? = nil, content: [ContentBlock], parentToolUseId: String? = nil) {
        self.uuid = uuid; self.content = content; self.parentToolUseId = parentToolUseId
    }
}

/// A tool call the run stopped on because a PreToolUse hook returned `defer`.
public struct DeferredToolUse: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public init(id: String, name: String, input: JSONValue) { self.id = id; self.name = name; self.input = input }
}

public struct ResultMessage: Sendable, Equatable, Codable {
    public var subtype: String
    public var isError: Bool
    public var durationMs: Int
    public var durationApiMs: Int
    public var numTurns: Int
    public var sessionId: String
    public var uuid: String?
    public var stopReason: String?
    public var totalCostUSD: Double?
    public var usage: JSONValue?
    public var result: String?
    public var structuredOutput: JSONValue?
    public var modelUsage: JSONValue?
    public var permissionDenials: [JSONValue]?
    public var deferredToolUse: DeferredToolUse?
    public var errors: [String]?
    public var apiErrorStatus: Int?
    public var terminalReason: String?

    public init(subtype: String, isError: Bool = false, durationMs: Int = 0, durationApiMs: Int = 0, numTurns: Int = 0, sessionId: String,
                uuid: String? = nil, stopReason: String? = nil, totalCostUSD: Double? = nil, usage: JSONValue? = nil, result: String? = nil,
                structuredOutput: JSONValue? = nil, modelUsage: JSONValue? = nil, permissionDenials: [JSONValue]? = nil,
                deferredToolUse: DeferredToolUse? = nil, errors: [String]? = nil, apiErrorStatus: Int? = nil, terminalReason: String? = nil) {
        self.subtype = subtype; self.isError = isError; self.durationMs = durationMs; self.durationApiMs = durationApiMs; self.numTurns = numTurns
        self.sessionId = sessionId; self.uuid = uuid; self.stopReason = stopReason; self.totalCostUSD = totalCostUSD; self.usage = usage; self.result = result
        self.structuredOutput = structuredOutput; self.modelUsage = modelUsage; self.permissionDenials = permissionDenials; self.deferredToolUse = deferredToolUse
        self.errors = errors; self.apiErrorStatus = apiErrorStatus; self.terminalReason = terminalReason
    }

    public var inputTokens: Int { usage?["input_tokens"]?.intValue ?? 0 }
    public var outputTokens: Int { usage?["output_tokens"]?.intValue ?? 0 }
    /// True when the run was cut short by an interrupt: the CLI reports it as `error_during_execution`
    /// with an `[ede_diagnostic]` error string (observed on 2.1.270, fixture `interrupt`).
    public var wasInterrupted: Bool { subtype == "error_during_execution" && (errors ?? []).contains { $0.hasPrefix("[ede_diagnostic]") } }
    /// True when the CLI could not authenticate: the result carries `is_error` with the CLI's login message
    /// (`Not logged in · Please run /login` or `Login expired · Please run /login`, fixture `auth-failed`;
    /// `Failed to authenticate: OAuth session expired and could not be refreshed`, observed live on 2.1.271, T9).
    /// Note the subtype is still `success` in that case.
    public var isAuthenticationFailure: Bool {
        guard isError, let result else { return false }
        return result.contains("run /login") || result.hasPrefix("Not logged in") || result.hasPrefix("Login expired")
            || result.hasPrefix("Failed to authenticate")
    }
    /// The message the SDK would raise for a failed run, or nil on success or interrupt.
    public var errorText: String? {
        if wasInterrupted { return nil }
        if let errors, !errors.isEmpty { return errors.joined(separator: "; ") }
        if isError, let result { return result }
        if subtype != "success" { return subtype }
        return nil
    }
}

/// Everything a session emits to its consumer. `Codable` is synthesized (case name as key, labels as field
/// names) so a host can forward events to its clients once and the ports can decode them.
public enum Message: Sendable, Equatable, Codable {
    case initialized(sessionId: String, model: String, tools: [String], data: JSONValue)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case streamEvent(event: JSONValue, parentToolUseId: String?)
    case taskStarted(taskId: String, description: String, taskType: String?)
    case taskProgress(taskId: String, description: String, lastToolName: String?)
    case taskNotification(taskId: String, status: String, summary: String)
    case taskUpdated(taskId: String, status: String?)
    case hookEvent(subtype: String, hookEventName: String, data: JSONValue)
    case rateLimit(info: JSONValue)
    case conversationReset(newConversationId: String)
    case system(subtype: String, data: JSONValue)
    /// Emitted before the permission callback runs; carries the escaped, hashed payload the host should show.
    case permissionRequest(ApprovalPayload)
    /// The CLI refused a tool call on its own (a permission rule, a classifier, or a mode). Observed on 2.1.271 as
    /// `system/permission_denied` with `decision_reason_type` and `decision_reason`.
    case permissionDenied(tool: String, toolUseId: String?, reasonType: String?, reason: String)
    case steeringQueued(text: String)
    case result(ResultMessage)
    /// The CLI process ended. `status` is the exit code; `signal` when killed by one.
    case exited(status: Int32, signal: Int32?)
}

/// What a host shows a person when approval is needed. `display` is the tool input as canonical JSON with
/// non-ASCII and zero-width characters escaped so a hostile input cannot disguise itself; `hash` is echoed
/// back by the approver so a decision cannot be applied to a different request.
public struct ApprovalPayload: Sendable, Equatable, Codable {
    public var tool: String
    public var input: JSONValue
    public var display: String
    public var hash: String
    public var toolUseId: String?
    public init(tool: String, input: JSONValue, toolUseId: String? = nil) {
        self.tool = tool; self.input = input; self.toolUseId = toolUseId
        let canonical = input.canonicalJSON
        var escaped = ""
        for scalar in canonical.unicodeScalars {
            if scalar.value < 0x20 || scalar.value > 0x7E || (0x200B...0x200F).contains(scalar.value) || (0x2060...0x206F).contains(scalar.value) || scalar.value == 0xFEFF {
                escaped += String(format: "\\u{%X}", scalar.value)
            } else { escaped.unicodeScalars.append(scalar) }
        }
        display = "\(tool) \(escaped)"
        hash = ApprovalPayload.fnv1a("\(tool)\n\(canonical)")
    }
    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
