import Foundation

/// One block of assistant or user content (mirrors the Agent SDK's content block types). Encoded with every
/// field named (`{"text":{"text":"…"}}`, `{"thinking":{"thinking":"…"}}`); the `_0` the synthesizer wrote for

extension ContentBlock: Codable {
    private enum Case: String, CodingKey { case text, thinking, toolUse, toolResult, serverToolUse, serverToolResult }
    private enum Field: String, CodingKey { case text, thinking, id, name, input, toolUseId, content, isError, legacy = "_0" }
    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Case.self)
        guard let kind = outer.allKeys.first, outer.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "ContentBlock needs exactly one case key"))
        }
        let c = try outer.nestedContainer(keyedBy: Field.self, forKey: kind)
        switch kind {
        case .text: self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? c.decode(String.self, forKey: .legacy))
        case .thinking: self = .thinking(try c.decodeIfPresent(String.self, forKey: .thinking) ?? c.decode(String.self, forKey: .legacy))
        case .toolUse: self = .toolUse(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name), input: try c.decode(JSONValue.self, forKey: .input))
        case .toolResult: self = .toolResult(toolUseId: try c.decode(String.self, forKey: .toolUseId), content: try c.decode(JSONValue.self, forKey: .content),
                                             isError: try c.decode(Bool.self, forKey: .isError))
        case .serverToolUse: self = .serverToolUse(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name), input: try c.decode(JSONValue.self, forKey: .input))
        case .serverToolResult: self = .serverToolResult(toolUseId: try c.decode(String.self, forKey: .toolUseId), content: try c.decode(JSONValue.self, forKey: .content))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: Case.self)
        switch self {
        case .text(let t): var c = outer.nestedContainer(keyedBy: Field.self, forKey: .text); try c.encode(t, forKey: .text)
        case .thinking(let t): var c = outer.nestedContainer(keyedBy: Field.self, forKey: .thinking); try c.encode(t, forKey: .thinking)
        case let .toolUse(id, name, input):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .toolUse); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(input, forKey: .input)
        case let .toolResult(id, content, isError):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .toolResult); try c.encode(id, forKey: .toolUseId); try c.encode(content, forKey: .content); try c.encode(isError, forKey: .isError)
        case let .serverToolUse(id, name, input):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .serverToolUse); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(input, forKey: .input)
        case let .serverToolResult(id, content):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .serverToolResult); try c.encode(id, forKey: .toolUseId); try c.encode(content, forKey: .content)
        }
    }
}

/// the two single-value cases before 0.2.0 still decodes (gateway backlog 9).
public enum ContentBlock: Sendable, Equatable {
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
    /// The structured `/usage` answer, on the assistant message that answers a headless `/usage` (`usage_report`,
    /// TypeScript SDK 0.3.273). Absent on every other assistant message and in every recorded fixture.
    public var usageReport: UsageReport?
    public init(uuid: String? = nil, content: [ContentBlock], model: String, stopReason: String? = nil, usage: JSONValue? = nil,
                parentToolUseId: String? = nil, wireToolInputs: [String: JSONValue]? = nil) {
        self.uuid = uuid; self.content = content; self.model = model; self.stopReason = stopReason; self.usage = usage
        self.parentToolUseId = parentToolUseId; self.wireToolInputs = wireToolInputs
    }

    /// Existing keys keep the names this type has always encoded (stored rows and gateway frames read them);
    /// fields added from the wire carry the wire's own name.
    enum CodingKeys: String, CodingKey {
        case uuid, content, wireToolInputs, model, stopReason, usage, parentToolUseId
        case usageReport = "usage_report"
    }
}

public struct UserMessage: Sendable, Equatable, Codable {
    public var uuid: String?
    public var content: [ContentBlock]
    public var parentToolUseId: String?
    /// Text the person pasted rather than typed, appended after the typed prompt on an outbound user frame
    /// (`pasted_content`, TypeScript SDK 0.3.277: `MessageParam['content'][]`, so each element is one message's
    /// content, string or block array). Nil on every frame the CLI sends.
    public var pastedContent: [JSONValue]?
    public init(uuid: String? = nil, content: [ContentBlock], parentToolUseId: String? = nil) {
        self.uuid = uuid; self.content = content; self.parentToolUseId = parentToolUseId
    }
    /// The same message with pasted text attached, for an outbound frame.
    public func withPastedContent(_ pasted: [JSONValue]) -> UserMessage {
        var copy = self; copy.pastedContent = pasted; return copy
    }

    /// Existing keys keep the names this type has always encoded; the added field carries the wire's name.
    enum CodingKeys: String, CodingKey {
        case uuid, content, parentToolUseId
        case pastedContent = "pasted_content"
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
    /// Why the CLI could not start (`startup_failure_reason`, TypeScript SDK 0.3.274). Absent on a session that
    /// started; absent in every recorded fixture.
    public var startupFailureReason: StartupFailureReason?
    /// Remote-session latency (TypeScript SDK 0.3.277), absent on a local CLI session and in every recorded
    /// fixture: milliseconds to the first text post, the same measured against wall time, the queue wait before
    /// the first stream post, and how many posts were queued ahead of it.
    public var firstTextPostMs: Int?
    public var firstTextPostWallMs: Int?
    public var firstStreamPostQueueWaitMs: Int?
    public var firstStreamPostQueuedBehind: Int?

    /// Existing keys keep the names this type has always encoded; fields added from the wire carry the wire's name.
    enum CodingKeys: String, CodingKey {
        case subtype, isError, durationMs, durationApiMs, numTurns, sessionId, uuid, stopReason, totalCostUSD, usage
        case result, structuredOutput, modelUsage, permissionDenials, deferredToolUse, errors, apiErrorStatus, terminalReason
        case startupFailureReason = "startup_failure_reason"
        case firstTextPostMs = "first_text_post_ms"
        case firstTextPostWallMs = "first_text_post_wall_ms"
        case firstStreamPostQueueWaitMs = "first_stream_post_queue_wait_ms"
        case firstStreamPostQueuedBehind = "first_stream_post_queued_behind"
    }

    public init(subtype: String, isError: Bool = false, durationMs: Int = 0, durationApiMs: Int = 0, numTurns: Int = 0, sessionId: String,
                uuid: String? = nil, stopReason: String? = nil, totalCostUSD: Double? = nil, usage: JSONValue? = nil, result: String? = nil,
                structuredOutput: JSONValue? = nil, modelUsage: JSONValue? = nil, permissionDenials: [JSONValue]? = nil,
                deferredToolUse: DeferredToolUse? = nil, errors: [String]? = nil, apiErrorStatus: Int? = nil, terminalReason: String? = nil) {
        self.subtype = subtype; self.isError = isError; self.durationMs = durationMs; self.durationApiMs = durationApiMs; self.numTurns = numTurns
        self.sessionId = sessionId; self.uuid = uuid; self.stopReason = stopReason; self.totalCostUSD = totalCostUSD; self.usage = usage; self.result = result
        self.structuredOutput = structuredOutput; self.modelUsage = modelUsage; self.permissionDenials = permissionDenials; self.deferredToolUse = deferredToolUse
        self.errors = errors; self.apiErrorStatus = apiErrorStatus; self.terminalReason = terminalReason
    }

    /// A `result` frame as the CLI wrote it. Every field is optional on the wire; absence leaves the default,
    /// so a fixture recorded before a field existed decodes unchanged.
    public init(wire d: JSONValue) {
        let deferred = d["deferred_tool_use"].flatMap { v -> DeferredToolUse? in
            guard let id = v["id"]?.stringValue, let name = v["name"]?.stringValue else { return nil }
            return DeferredToolUse(id: id, name: name, input: v["input"] ?? .object([:]))
        }
        self.init(subtype: d["subtype"]?.stringValue ?? "", isError: d["is_error"]?.boolValue ?? false,
                  durationMs: d["duration_ms"]?.intValue ?? 0, durationApiMs: d["duration_api_ms"]?.intValue ?? 0,
                  numTurns: d["num_turns"]?.intValue ?? 0, sessionId: d["session_id"]?.stringValue ?? "", uuid: d["uuid"]?.stringValue,
                  stopReason: d["stop_reason"]?.stringValue, totalCostUSD: d["total_cost_usd"]?.doubleValue, usage: d["usage"],
                  result: d["result"]?.stringValue, structuredOutput: d["structured_output"], modelUsage: d["modelUsage"],
                  permissionDenials: d["permission_denials"]?.arrayValue, deferredToolUse: deferred,
                  errors: d["errors"]?.arrayValue?.compactMap { $0.stringValue }, apiErrorStatus: d["api_error_status"]?.intValue,
                  terminalReason: d["terminal_reason"]?.stringValue)
        startupFailureReason = d["startup_failure_reason"]?.stringValue.map { StartupFailureReason(rawValue: $0) }
        firstTextPostMs = d["first_text_post_ms"]?.intValue
        firstTextPostWallMs = d["first_text_post_wall_ms"]?.intValue
        firstStreamPostQueueWaitMs = d["first_stream_post_queue_wait_ms"]?.intValue
        firstStreamPostQueuedBehind = d["first_stream_post_queued_behind"]?.intValue
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

/// Everything a session emits to its consumer. Encoded as one object keyed by the case name, with every field
/// inside named, so a host can forward events to its clients once and the ports can decode them without knowing
/// Swift. `Codable` is written out rather than synthesized (gateway backlog 9, decided 2026-09-19): four cases
/// carry a single unlabelled value, which the synthesizer would name `_0`; they encode as `message`, `payload`
/// and `result` instead, and the decoder still accepts `_0` for rows and parts written by 0.1.x. Drop that
/// acceptance once no store carries schema 1 rows (`EventStore.eventSchema`).
public enum Message: Sendable, Equatable {
    case initialized(sessionId: String, model: String, tools: [String], data: JSONValue)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case streamEvent(event: JSONValue, parentToolUseId: String?)
    case taskStarted(taskId: String, description: String, taskType: String?)
    case taskProgress(taskId: String, description: String, lastToolName: String?)
    case taskNotification(taskId: String, status: String, summary: String, reason: TaskNotificationReason? = nil)
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

extension Message: Codable {
    private enum Case: String, CodingKey {
        case initialized, assistant, user, streamEvent, taskStarted, taskProgress, taskNotification, taskUpdated, hookEvent
        case rateLimit, conversationReset, system, permissionRequest, permissionDenied, steeringQueued, result, exited
    }
    private enum Field: String, CodingKey {
        case sessionId, model, tools, data, message, payload, result, legacy = "_0"
        case event, parentToolUseId, taskId, description, taskType, lastToolName, status, summary, reason
        case subtype, hookEventName, info, newConversationId, tool, toolUseId, reasonType, text, signal
    }

    /// The one field a single-value case carries, under its named key or the `_0` the synthesizer wrote before 0.2.0.
    private static func single<T: Decodable>(_ c: KeyedDecodingContainer<Field>, _ key: Field, as type: T.Type) throws -> T {
        if c.contains(key) { return try c.decode(type, forKey: key) }
        return try c.decode(type, forKey: .legacy)
    }

    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Case.self)
        guard let kind = outer.allKeys.first, outer.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Message needs exactly one case key, got \(outer.allKeys.map(\.stringValue))"))
        }
        let c = try outer.nestedContainer(keyedBy: Field.self, forKey: kind)
        switch kind {
        case .initialized: self = .initialized(sessionId: try c.decode(String.self, forKey: .sessionId), model: try c.decode(String.self, forKey: .model),
                                               tools: try c.decode([String].self, forKey: .tools), data: try c.decode(JSONValue.self, forKey: .data))
        case .assistant: self = .assistant(try Self.single(c, .message, as: AssistantMessage.self))
        case .user: self = .user(try Self.single(c, .message, as: UserMessage.self))
        case .streamEvent: self = .streamEvent(event: try c.decode(JSONValue.self, forKey: .event), parentToolUseId: try c.decodeIfPresent(String.self, forKey: .parentToolUseId))
        case .taskStarted: self = .taskStarted(taskId: try c.decode(String.self, forKey: .taskId), description: try c.decode(String.self, forKey: .description),
                                               taskType: try c.decodeIfPresent(String.self, forKey: .taskType))
        case .taskProgress: self = .taskProgress(taskId: try c.decode(String.self, forKey: .taskId), description: try c.decode(String.self, forKey: .description),
                                                 lastToolName: try c.decodeIfPresent(String.self, forKey: .lastToolName))
        case .taskNotification: self = .taskNotification(taskId: try c.decode(String.self, forKey: .taskId), status: try c.decode(String.self, forKey: .status),
                                                         summary: try c.decode(String.self, forKey: .summary), reason: try c.decodeIfPresent(TaskNotificationReason.self, forKey: .reason))
        case .taskUpdated: self = .taskUpdated(taskId: try c.decode(String.self, forKey: .taskId), status: try c.decodeIfPresent(String.self, forKey: .status))
        case .hookEvent: self = .hookEvent(subtype: try c.decode(String.self, forKey: .subtype), hookEventName: try c.decode(String.self, forKey: .hookEventName),
                                           data: try c.decode(JSONValue.self, forKey: .data))
        case .rateLimit: self = .rateLimit(info: try c.decode(JSONValue.self, forKey: .info))
        case .conversationReset: self = .conversationReset(newConversationId: try c.decode(String.self, forKey: .newConversationId))
        case .system: self = .system(subtype: try c.decode(String.self, forKey: .subtype), data: try c.decode(JSONValue.self, forKey: .data))
        case .permissionRequest: self = .permissionRequest(try Self.single(c, .payload, as: ApprovalPayload.self))
        case .permissionDenied: self = .permissionDenied(tool: try c.decode(String.self, forKey: .tool), toolUseId: try c.decodeIfPresent(String.self, forKey: .toolUseId),
                                                         reasonType: try c.decodeIfPresent(String.self, forKey: .reasonType), reason: try c.decode(String.self, forKey: .reason))
        case .steeringQueued: self = .steeringQueued(text: try c.decode(String.self, forKey: .text))
        case .result: self = .result(try Self.single(c, .result, as: ResultMessage.self))
        case .exited: self = .exited(status: try c.decode(Int32.self, forKey: .status), signal: try c.decodeIfPresent(Int32.self, forKey: .signal))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: Case.self)
        func inner(_ kind: Case) -> KeyedEncodingContainer<Field> { outer.nestedContainer(keyedBy: Field.self, forKey: kind) }
        switch self {
        case let .initialized(sessionId, model, tools, data):
            var c = inner(.initialized); try c.encode(sessionId, forKey: .sessionId); try c.encode(model, forKey: .model); try c.encode(tools, forKey: .tools); try c.encode(data, forKey: .data)
        case let .assistant(m): var c = inner(.assistant); try c.encode(m, forKey: .message)
        case let .user(m): var c = inner(.user); try c.encode(m, forKey: .message)
        case let .streamEvent(event, parent): var c = inner(.streamEvent); try c.encode(event, forKey: .event); try c.encodeIfPresent(parent, forKey: .parentToolUseId)
        case let .taskStarted(id, d, t): var c = inner(.taskStarted); try c.encode(id, forKey: .taskId); try c.encode(d, forKey: .description); try c.encodeIfPresent(t, forKey: .taskType)
        case let .taskProgress(id, d, t): var c = inner(.taskProgress); try c.encode(id, forKey: .taskId); try c.encode(d, forKey: .description); try c.encodeIfPresent(t, forKey: .lastToolName)
        case let .taskNotification(id, st, su, r):
            var c = inner(.taskNotification); try c.encode(id, forKey: .taskId); try c.encode(st, forKey: .status); try c.encode(su, forKey: .summary); try c.encodeIfPresent(r, forKey: .reason)
        case let .taskUpdated(id, st): var c = inner(.taskUpdated); try c.encode(id, forKey: .taskId); try c.encodeIfPresent(st, forKey: .status)
        case let .hookEvent(s, n, d): var c = inner(.hookEvent); try c.encode(s, forKey: .subtype); try c.encode(n, forKey: .hookEventName); try c.encode(d, forKey: .data)
        case let .rateLimit(info): var c = inner(.rateLimit); try c.encode(info, forKey: .info)
        case let .conversationReset(id): var c = inner(.conversationReset); try c.encode(id, forKey: .newConversationId)
        case let .system(s, d): var c = inner(.system); try c.encode(s, forKey: .subtype); try c.encode(d, forKey: .data)
        case let .permissionRequest(p): var c = inner(.permissionRequest); try c.encode(p, forKey: .payload)
        case let .permissionDenied(tool, id, rt, r):
            var c = inner(.permissionDenied); try c.encode(tool, forKey: .tool); try c.encodeIfPresent(id, forKey: .toolUseId); try c.encodeIfPresent(rt, forKey: .reasonType); try c.encode(r, forKey: .reason)
        case let .steeringQueued(t): var c = inner(.steeringQueued); try c.encode(t, forKey: .text)
        case let .result(r): var c = inner(.result); try c.encode(r, forKey: .result)
        case let .exited(st, sig): var c = inner(.exited); try c.encode(st, forKey: .status); try c.encodeIfPresent(sig, forKey: .signal)
        }
    }
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
    /// The 64-bit FNV-1a hash of `s` as lowercase hex; what `hash` is made of, shared with the direct engine's
    /// loop detection for hashing tool results.
    public static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
