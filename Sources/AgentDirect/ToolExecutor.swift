import Foundation
import AgentProtocol
import AgentSession

/// One `tool_use` block the model produced.
public struct ToolCall: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public init(id: String, name: String, input: JSONValue) { self.id = id; self.name = name; self.input = input }
    /// Stable hash of name and canonical input, for loop detection.
    public var fingerprint: String { ApprovalPayload(tool: name, input: input).hash }
}

/// The host's answer before a tool runs: the policy engine's allow/ask/deny/defer folded into one call (ADR 0015
/// `PermissionGating`). `deny` becomes an `is_error` result the model reads; `endsTurn` ends the turn after the
/// wave, which is how `defer` reaches the model on an engine without hooks.
public enum ToolGateDecision: Sendable, Equatable {
    case allow(input: JSONValue?)
    case deny(reason: String, endsTurn: Bool)
}

public typealias ToolGate = @Sendable (ToolCall) async -> ToolGateDecision

/// What one call produced, in the order the model asked.
public struct ToolOutcome: Sendable, Equatable {
    public var call: ToolCall
    public var result: ToolResult
    public var wasDenied: Bool
    public var wasInterrupted: Bool
    public var timedOut: Bool
    public var endsTurn: Bool
    public var duration: TimeInterval
    /// The executor refused the call because the same call had already been made `repeatedCallLimit` times with
    /// the same outcome (loop detection per call; the engine ends the turn after `repeatedCallRefusals` of these).
    public var wasRepeatRefused: Bool
    public init(call: ToolCall, result: ToolResult, wasDenied: Bool = false, wasInterrupted: Bool = false, timedOut: Bool = false,
                endsTurn: Bool = false, duration: TimeInterval = 0, wasRepeatRefused: Bool = false) {
        self.call = call; self.result = result; self.wasDenied = wasDenied; self.wasInterrupted = wasInterrupted
        self.timedOut = timedOut; self.endsTurn = endsTurn; self.duration = duration; self.wasRepeatRefused = wasRepeatRefused
    }

    /// The `tool_result` block for this outcome, content as Messages API blocks
    /// (https://platform.claude.com/docs/en/api/messages: a string or text and image blocks).
    public var block: ModelContentBlock {
        .toolResult(toolUseId: call.id, content: Self.wireContent(result), isError: result.isError)
    }

    static func wireContent(_ result: ToolResult) -> JSONValue {
        var blocks: [JSONValue] = result.content.map {
            switch $0 {
            case .text(let t): return ["type": "text", "text": .string(t)]
            case .image(let b64, let mime): return ["type": "image", "source": ["type": "base64", "media_type": .string(mime), "data": .string(b64)]]
            case .resource(let uri, _, let text, _): return ["type": "text", "text": .string(text ?? uri)]
            case .resourceLink(let uri, let name, _, _): return ["type": "text", "text": .string("\(name): \(uri)")]
            }
        }
        if let structured = result.structuredContent { blocks.append(["type": "text", "text": .string(structured.canonicalJSON)]) }
        if blocks.isEmpty { blocks = [["type": "text", "text": ""]] }
        return .array(blocks)
    }
}

/// Runs a batch of tool calls: waves, timeouts, the process registry, result caps, and the interrupt path
/// (plan Phase 8 "provider-neutral tool execution layer"). Shared by every provider; providers never see it.
///
/// Waves (plan 9.2, after AgentRunKit): consecutive calls to read-only tools (`annotations.readOnlyHint == true`)
/// form one concurrent wave; every other call is a serial wave of its own, so an approval is never batched with
/// another call. Results come back in the model's order whatever finished first.
///
/// Invariants: a tool handler never throws into the loop; any error is an `is_error` result. `CancellationError`
/// is the exception: it marks the outcome interrupted and the batch stops. Every handler is bounded by
/// `toolTimeout` even if it never checks `Task.isCancelled`.
public actor ToolExecutor {
    public nonisolated let registry: ProcessRegistry
    public var toolTimeout: TimeInterval
    /// Characters of result text kept per call; the rest is replaced by a marker. A tool's own
    /// `annotations.maxResultSizeChars` lowers it for that tool.
    public var maxResultChars: Int
    public var workingDirectory: String?
    public var gate: ToolGate?
    /// Debug builds assert when a tool returns with a child process it did not start through `ToolContext.run`.
    /// Off by default because a test process may have unrelated children; the product turns it on.
    public var auditsSpawnedProcesses = false
    /// Loop detection per call (Kyberna gateway 38): a call (tool name and canonical arguments) that has already
    /// run this many times in the current and the two previous turns, every time with the same result or with an
    /// error result last, is not run again; the model gets an error result naming the count and that nothing
    /// differed. Nil turns the check off. The shape of a wave (one call, then five identical ones) no longer matters.
    public var repeatedCallLimit: Int? = 3
    private var tools: [String: SwiftTool] = [:]
    private var repeats: [String: RepeatRecord] = [:]
    private var turnIndex = 0

    /// What one distinct call has produced so far.
    struct RepeatRecord {
        var runs = 0
        /// Hash of the first run's result; `sameResult` holds while every run matches it.
        var firstResultHash: String
        var sameResult = true
        var lastWasError = false
        var lastTurn = 0
    }

    public init(registry: ProcessRegistry = ProcessRegistry(), toolTimeout: TimeInterval = 30, maxResultChars: Int = 100_000,
                workingDirectory: String? = nil, gate: ToolGate? = nil) {
        self.registry = registry; self.toolTimeout = toolTimeout; self.maxResultChars = maxResultChars
        self.workingDirectory = workingDirectory; self.gate = gate
    }

    /// Registers tools under the names the model sees.
    public func register(_ tools: [SwiftTool], names: [String]? = nil) {
        for (i, t) in tools.enumerated() { self.tools[names?[i] ?? t.name] = t }
    }
    public func setGate(_ gate: ToolGate?) { self.gate = gate }
    public func setTimeout(_ seconds: TimeInterval) { toolTimeout = seconds }
    public func setAuditsSpawnedProcesses(_ on: Bool) { auditsSpawnedProcesses = on }
    public func setRepeatedCallLimit(_ limit: Int?) { repeatedCallLimit = limit }
    public var registeredNames: [String] { tools.keys.sorted() }

    /// Called by the engine when a user turn starts: repeat records older than two turns are forgotten, so a call
    /// the model made three times in an earlier turn is not refused in a later one.
    public func beginTurn() {
        turnIndex += 1
        repeats = repeats.filter { $0.value.lastTurn >= turnIndex - 2 }
    }

    /// The refusal for `call` when it has already run `repeatedCallLimit` times with the same outcome, else nil.
    /// `pending` counts identical calls earlier in the same wave, which have not run yet and are taken as one more
    /// run each with the same outcome (they are the same call at the same moment).
    func repeatRefusal(for call: ToolCall, pending: Int = 0) -> String? {
        guard let limit = repeatedCallLimit else { return nil }
        let record = repeats[call.fingerprint]
        let runs = (record?.runs ?? 0) + pending
        guard runs >= limit, record.map({ $0.sameResult || $0.lastWasError }) ?? true else { return nil }
        let outcome = record?.sameResult ?? true ? "the same result" : "an error"
        return "Tool '\(call.name)' not run: this exact call was already made \(runs) times in this conversation, each time with \(outcome). "
            + "Nothing differed between the calls; the arguments were \(call.input.canonicalJSON) every time. Change the arguments or answer with what you have."
    }

    private func recordRun(_ outcome: ToolOutcome) {
        let hash = ApprovalPayload.fnv1a(ToolOutcome.wireContent(outcome.result).canonicalJSON)
        var record = repeats[outcome.call.fingerprint] ?? RepeatRecord(firstResultHash: hash)
        record.runs += 1
        if hash != record.firstResultHash { record.sameResult = false }
        record.lastWasError = outcome.result.isError
        record.lastTurn = turnIndex
        repeats[outcome.call.fingerprint] = record
    }

    /// The wave partition: indices into `calls`.
    public func waves(_ calls: [ToolCall]) -> [[Int]] {
        var out: [[Int]] = [], current: [Int] = []
        for (i, call) in calls.enumerated() {
            let readOnly = tools[call.name]?.annotations?.readOnlyHint == true
            if readOnly { current.append(i) } else {
                if !current.isEmpty { out.append(current); current = [] }
                out.append([i])
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Runs every call and returns one outcome per call in the original order. On cancellation, the calls not
    /// finished are returned as interrupted error results ("Interrupted by user") so history can be repaired.
    public func run(_ calls: [ToolCall]) async -> [ToolOutcome] {
        var outcomes: [Int: ToolOutcome] = [:]
        // Gate first, serially, so approvals arrive one at a time (plan 9.4).
        var permitted: [Int: JSONValue] = [:]
        var endsTurn = false
        var pendingRuns: [String: Int] = [:]
        for (i, call) in calls.enumerated() {
            if Task.isCancelled { break }
            // Arguments the schema does not declare, or required ones missing, stop the call here, before the gate,
            // so the person is never asked to approve a call that would be refused and the tool never runs on a
            // guess (Kyberna console 100: an invented argument set sent `mail_search` into a 30 s scan).
            if let tool = tools[call.name], let violation = Self.schemaViolation(of: call.input, against: tool.inputSchema) {
                outcomes[i] = ToolOutcome(call: call, result: .error("Tool '\(call.name)' not run: \(violation)"))
                recordRun(outcomes[i]!)
                continue
            }
            // Loop detection per call, also before the gate: the person is never asked about a call about to be refused.
            if let refusal = repeatRefusal(for: call, pending: pendingRuns[call.fingerprint] ?? 0) {
                outcomes[i] = ToolOutcome(call: call, result: .error(refusal), wasRepeatRefused: true)
                continue
            }
            switch await gate?(call) ?? .allow(input: nil) {
            case .allow(let updated):
                permitted[i] = updated ?? call.input
                pendingRuns[call.fingerprint, default: 0] += 1
            case .deny(let reason, let ends):
                outcomes[i] = ToolOutcome(call: call, result: .error("Permission denied: \(reason)"), wasDenied: true, endsTurn: ends)
                recordRun(outcomes[i]!)
                if ends { endsTurn = true }
            }
        }
        let runnable = calls.enumerated().filter { permitted[$0.offset] != nil }.map(\.offset)
        let runnableCalls = runnable.map { i in ToolCall(id: calls[i].id, name: calls[i].name, input: permitted[i]!) }
        for wave in waves(runnableCalls) where !Task.isCancelled {
            let results = await withTaskGroup(of: (Int, ToolOutcome).self, returning: [Int: ToolOutcome].self) { group in
                for j in wave {
                    let call = runnableCalls[j]
                    group.addTask { (j, await self.execute(call)) }
                }
                var collected: [Int: ToolOutcome] = [:]
                for await (j, outcome) in group { collected[j] = outcome }
                return collected
            }
            for (j, outcome) in results {
                outcomes[runnable[j]] = outcome
                if !outcome.wasInterrupted { recordRun(outcome) }
            }
        }
        return calls.enumerated().map { i, call in
            if var o = outcomes[i] { o.endsTurn = o.endsTurn || endsTurn; return o }
            return ToolOutcome(call: call, result: .error("Interrupted by user"), wasInterrupted: true, endsTurn: endsTurn)
        }
    }

    /// One call: unknown tool, timeout, thrown error and cancellation all become outcomes.
    private func execute(_ call: ToolCall) async -> ToolOutcome {
        let start = ContinuousClock.now
        func elapsed() -> TimeInterval { Double((ContinuousClock.now - start).components.seconds) + Double((ContinuousClock.now - start).components.attoseconds) / 1e18 }
        guard let tool = tools[call.name] else {
            return ToolOutcome(call: call, result: .error("Unknown tool '\(call.name)'. Available: \(registeredNames.joined(separator: ", "))"), duration: elapsed())
        }
        guard case .object(let input) = call.input else {
            return ToolOutcome(call: call, result: .error("Tool input must be a JSON object"), duration: elapsed())
        }
        let context = ToolContext(registry: registry, toolUseId: call.id, workingDirectory: workingDirectory)
        let timeout = toolTimeout
        let cap = min(maxResultChars, tool.annotations?.maxResultSizeChars ?? Int.max)
        let handler = tool.handler
        let audits = auditsSpawnedProcesses
        let outcome: ToolOutcome = await ToolContext.$current.withValue(context) {
            do {
                let result = try await Self.withTimeout(timeout) { try await handler(input) }
                return ToolOutcome(call: call, result: Self.capped(result, cap), duration: elapsed())
            } catch is CancellationError {
                return ToolOutcome(call: call, result: .error("Interrupted by user"), wasInterrupted: true, duration: elapsed())
            } catch is ToolTimeout {
                await registry.terminateAll(grace: 1)
                return ToolOutcome(call: call, result: .error("Tool '\(call.name)' timed out after \(Int(timeout)) s"), timedOut: true, duration: elapsed())
            } catch {
                return ToolOutcome(call: call, result: .error("Tool '\(call.name)' failed: \(error)"), duration: elapsed())
            }
        }
        if audits {
            let strays = registry.unregisteredChildren()
            assert(strays.isEmpty, "tool '\(call.name)' left processes outside the registry: \(strays); use ToolContext.run")
        }
        return outcome
    }

    struct ToolTimeout: Error {}

    /// Why `input` does not fit `schema`, or nil when it does. Checked: the input is an object, every key is one of
    /// the schema's `properties` (unless the schema sets `additionalProperties` to anything but `false`, or declares
    /// no `properties` at all), and every `required` name is present. The sentence names the offending keys and
    /// quotes the property list, so the model can correct the call on its next turn. Value types are the handler's
    /// business, as before.
    static func schemaViolation(of input: JSONValue, against schema: JSONValue) -> String? {
        guard case .object(let object) = input else { return "arguments must be a JSON object" }
        let declared = schema["properties"]?.objectValue.map { Array($0.keys).sorted() }
        let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        let missing = required.filter { object[$0] == nil }
        var unknown: [String] = []
        if let declared {
            let extras: Bool
            switch schema["additionalProperties"] {
            case .bool(false)?, nil: extras = false
            default: extras = true
            }
            if !extras { unknown = object.keys.filter { !declared.contains($0) }.sorted() }
        }
        guard !missing.isEmpty || !unknown.isEmpty else { return nil }
        var parts: [String] = []
        if !unknown.isEmpty { parts.append("unknown argument\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", "))") }
        if !missing.isEmpty { parts.append("missing required argument\(missing.count == 1 ? "" : "s") \(missing.joined(separator: ", "))") }
        let list = (declared ?? []).map { name in required.contains(name) ? "\(name) (required)" : name }
        let properties = list.isEmpty ? "The tool takes no arguments." : "The schema's properties are: \(list.joined(separator: ", "))."
        return parts.joined(separator: "; ") + ". " + properties + " Call it again with those names."
    }

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw ToolTimeout() }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Truncates text blocks past `cap` characters in total, appending a marker the model reads.
    static func capped(_ result: ToolResult, _ cap: Int) -> ToolResult {
        var remaining = cap, out = result, cut = false
        out.content = result.content.compactMap { block in
            guard case .text(let t) = block else { return block }
            if remaining <= 0 { cut = true; return nil }
            if t.count <= remaining { remaining -= t.count; return block }
            cut = true
            let kept = String(t.prefix(remaining)); remaining = 0
            return .text(kept)
        }
        if cut { out.content.append(.text("\n[output truncated at \(cap) characters]")) }
        return out
    }
}
