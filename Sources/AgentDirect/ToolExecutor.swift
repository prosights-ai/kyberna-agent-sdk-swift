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
    public init(call: ToolCall, result: ToolResult, wasDenied: Bool = false, wasInterrupted: Bool = false, timedOut: Bool = false,
                endsTurn: Bool = false, duration: TimeInterval = 0) {
        self.call = call; self.result = result; self.wasDenied = wasDenied; self.wasInterrupted = wasInterrupted
        self.timedOut = timedOut; self.endsTurn = endsTurn; self.duration = duration
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
    private var tools: [String: SwiftTool] = [:]

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
    public var registeredNames: [String] { tools.keys.sorted() }

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
        for (i, call) in calls.enumerated() {
            if Task.isCancelled { break }
            switch await gate?(call) ?? .allow(input: nil) {
            case .allow(let updated): permitted[i] = updated ?? call.input
            case .deny(let reason, let ends):
                outcomes[i] = ToolOutcome(call: call, result: .error("Permission denied: \(reason)"), wasDenied: true, endsTurn: ends)
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
            for (j, outcome) in results { outcomes[runnable[j]] = outcome }
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
