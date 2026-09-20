import Foundation
import Synchronization
import AgentProtocol
import AgentSession
import AgentEngine

/// What the direct engine starts with. Everything a capability can change later (`model`, `effort`, `thinking`,
/// handlers, hosted tools) is here as the initial value only.
public struct DirectEngineOptions: Sendable {
    /// Model id as the provider names it; the caller decides the default.
    public var model: String
    public var systemPrompt: String?
    /// Output cap per model call; the engine continues a `max_tokens` truncation up to `maxTokensRecoveries` times.
    public var maxTokens = 16_000
    /// Model calls per `send` before the turn ends with `error_max_turns`; nil is unbounded.
    public var maxTurns: Int?
    /// Emit `Message.streamEvent` deltas while the model writes.
    public var includePartialMessages = false
    public var toolTimeout: TimeInterval = 30
    /// The model's context window, for `ContextReporting`.
    public var contextWindowTokens = 200_000
    public var compaction: (any CompactionStrategy)? = SummarizingCompaction()
    /// A JSON Schema the final answer must match; parsed into `ResultMessage.structuredOutput`.
    public var outputSchema: JSONValue?
    /// What `ModelSwitching.availableModels` offers; the engine does not learn this from the provider.
    public var availableModels: [ModelChoice] = []
    public var thinking: ThinkingOption?
    public var effort: String?
    public var reasoningDisplay: ReasoningDisplay = .summarized
    public var sessionId = UUID().uuidString
    public var workingDirectory: String?
    public var maxTokensRecoveries = 3
    /// Ask the provider to validate tool arguments against their schemas.
    public var strictTools = false
    public var cachesPrefix = true
    /// Debug assertion when a tool leaves a process outside the registry.
    public var auditsSpawnedProcesses = false
    public init(model: String) { self.model = model }
}

/// The direct API engine (plan section 1.4, Phase 8): its own loop over a `ModelProvider`, `SwiftTool`s run by
/// `ToolExecutor` behind the host's permission gate, history and compaction owned here (plan 4.y), and the same
/// `Message` stream the Console and gateway consume from the Claude Code engine.
///
/// Adopts `ModelSwitching`, `EffortSetting`, `ReasoningControl`, `PermissionGating`, `ToolHosting`,
/// `ImageAttaching` and `ContextReporting`. Omits `Resumable`, `HookCapable`, `FileRewinding` and
/// `RateLimitReporting`, so the documented fallbacks apply: hosts start a fresh conversation, fold policy into the
/// permission handler, hide the rewind control and show no meters.
///
/// Interrupt contract (plan Phase 8): `stop(.turn)` cancels the model stream (partial output is discarded),
/// cancels and awaits the tool wave, sends SIGTERM then SIGKILL to registered process groups, repairs history with
/// "Interrupted by user" error results for every unanswered `tool_use`, and emits a `ResultMessage` with subtype
/// `error_during_execution` and `wasInterrupted == true`.
public final class DirectAPIEngine: AgentEngine, ModelSwitching, EffortSetting, ReasoningControl, PermissionGating,
                                    ToolHosting, ImageAttaching, ContextReporting, Sendable {
    struct Config: Sendable {
        var options: DirectEngineOptions
        var tools: [SwiftTool] = []
        var toolWireNames: [String] = []
        var policy: PolicyCallback?
        var permission: PermissionCallback?
        var question: QuestionCallback?
        var started = false
        var lastUsage = ModelUsage()
        var totalUsage = ModelUsage()
    }

    public let provider: any ModelProvider
    public let executor: ToolExecutor
    private let config: Mutex<Config>
    private let runner: TurnRunner
    private let continuation: AsyncStream<Message>.Continuation
    public let messages: AsyncStream<Message>

    public init(provider: any ModelProvider, options: DirectEngineOptions) {
        self.provider = provider
        config = Mutex(Config(options: options))
        executor = ToolExecutor(toolTimeout: options.toolTimeout, workingDirectory: options.workingDirectory)
        var continuation: AsyncStream<Message>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        runner = TurnRunner()
    }

    // MARK: AgentEngine

    public var sessionId: String? { config.withLock { $0.started ? $0.options.sessionId : nil } }
    public var engineVersion: String? { "direct/\(provider.id)" }

    public func start() async throws {
        let (options, tools, names, policy, permission, question) = config.withLock { c in
            c.started = true
            return (c.options, c.tools, c.toolWireNames, c.policy, c.permission, c.question)
        }
        await executor.register(tools, names: names)
        await executor.setTimeout(options.toolTimeout)
        await executor.setAuditsSpawnedProcesses(options.auditsSpawnedProcesses)
        if let question { await executor.register([Self.askUserQuestionTool(question)]) }
        await executor.setGate(Self.gate(policy: policy, permission: permission, emit: { [continuation] in continuation.yield($0) }))
        var toolNames = names
        if question != nil { toolNames.append(Self.askUserQuestionName) }
        continuation.yield(.initialized(sessionId: options.sessionId, model: options.model, tools: toolNames,
                                        data: ["engine": "direct", "provider": .string(provider.id), "apiKeySource": "direct",
                                               "cwd": options.workingDirectory.map { .string($0) } ?? .null]))
    }

    public func send(_ prompt: String) async throws { try await send(prompt, images: []) }

    public func steer(_ text: String) async throws {
        if await runner.isRunning {
            await runner.queueSteer(text)
            continuation.yield(.steeringQueued(text: text))
        } else { try await send(text) }
    }

    public func steerNow(_ text: String) async throws {
        await stop(.turn)
        try await send(text)
    }

    public func pause() { Task { await runner.setPaused(true) } }
    public func resume() { Task { await runner.setPaused(false) } }

    /// `.turn`: the interrupt contract. `.session` and `.kill`: the turn is interrupted the same way, then the
    /// stream ends with `.exited(status: 0)`; there is no process to end.
    public func stop(_ severity: StopSeverity) async {
        await runner.interrupt()
        if severity != .turn {
            continuation.yield(.exited(status: 0, signal: nil))
            continuation.finish()
        }
    }

    // MARK: Capabilities

    public var availableModels: [ModelChoice] { config.withLock { $0.options.availableModels } }
    /// Applies to the next model call; a running turn continues on the new model from its next request.
    public func setModel(_ model: String?) async throws {
        config.withLock { c in if let model { c.options.model = model } }
    }
    public func setEffort(_ level: String?) async throws { config.withLock { $0.options.effort = level } }
    public func setThinking(_ thinking: ThinkingOption?) async throws -> Bool { config.withLock { $0.options.thinking = thinking }; return true }
    public func setReasoningDisplay(_ display: ReasoningDisplay) throws { config.withLock { $0.options.reasoningDisplay = display } }

    private func beforeStart(_ operation: String, _ change: @Sendable (inout Config) -> Void) throws {
        try config.withLock { c in
            guard !c.started else { throw EngineError.alreadyStarted(operation: operation) }
            change(&c)
        }
    }
    public func setPolicy(_ policy: PolicyCallback?) throws { try beforeStart("setPolicy") { $0.policy = policy } }
    public func setPermissionHandler(_ handler: PermissionCallback?) throws { try beforeStart("setPermissionHandler") { $0.permission = handler } }
    public func setQuestionHandler(_ handler: QuestionCallback?) throws { try beforeStart("setQuestionHandler") { $0.question = handler } }

    public var hostedTools: [SwiftTool] { config.withLock { $0.tools } }
    /// Tools appear to the model as `mcp__<serverName>__<tool>`, the name the policy rows already key on.
    public func host(_ tools: [SwiftTool], serverName: String) throws {
        try beforeStart("host") { c in
            c.tools += tools
            c.toolWireNames += tools.map { "mcp__\(serverName)__\($0.name)" }
        }
    }

    public func send(_ text: String, images: [ImageAttachment]) async throws {
        var blocks: [ModelContentBlock] = images.map { .image(base64: $0.base64, mediaType: $0.mediaType) }
        if !text.isEmpty { blocks.append(.text(text)) }
        try await runner.startTurn(ModelMessage(role: .user, content: blocks), engine: self)
    }

    /// From the last response's usage: what the model read on its last request against the configured window.
    public func contextUsage() async throws -> ContextUsage {
        let (usage, options) = config.withLock { ($0.lastUsage, $0.options) }
        let total = usage.contextTokens
        let pct = options.contextWindowTokens > 0 ? Double(total) * 100 / Double(options.contextWindowTokens) : 0
        return ContextUsage(["totalTokens": .number(Double(total)), "maxTokens": .number(Double(options.contextWindowTokens)),
                             "percentage": .number(pct), "model": .string(options.model),
                             "categories": [["name": "Messages", "tokens": .number(Double(usage.inputTokens)), "kind": "used", "isDeferred": false],
                                            ["name": "Cached prefix", "tokens": .number(Double(usage.cacheReadInputTokens + usage.cacheCreationInputTokens)), "kind": "used", "isDeferred": false]]])
    }

    // MARK: Gate and built-in question tool

    /// The `PermissionGating` flow as one gate: policy first (allow, deny, ask), then the person, with
    /// `Message.permissionRequest` emitted before the person is asked and `Message.permissionDenied` on a refusal.
    /// With no handler set, `.ask` allows: adopting the capability without handlers means "nothing to ask".
    static func gate(policy: PolicyCallback?, permission: PermissionCallback?, emit: @escaping @Sendable (Message) -> Void) -> ToolGate {
        { call in
            let outcome = policy?(call.name, call.input) ?? .ask
            switch outcome {
            case .allow: return .allow(input: nil)
            case .deny(let reason):
                emit(.permissionDenied(tool: call.name, toolUseId: call.id, reasonType: "policy", reason: reason))
                return .deny(reason: reason, endsTurn: false)
            case .ask:
                guard let permission else { return .allow(input: nil) }
                let payload = ApprovalPayload(tool: call.name, input: call.input, toolUseId: call.id)
                emit(.permissionRequest(payload))
                let context = PermissionContext(toolUseId: call.id, suggestions: [], blockedPath: nil, decisionReason: nil, title: nil, description: nil, payload: payload)
                switch await permission(call.name, call.input, context) {
                case .allow(let updated, _): return .allow(input: updated)
                case .deny(let reason, let interrupt):
                    emit(.permissionDenied(tool: call.name, toolUseId: call.id, reasonType: "user", reason: reason))
                    return .deny(reason: reason, endsTurn: interrupt)
                }
            }
        }
    }

    static let askUserQuestionName = "AskUserQuestion"
    /// The model's questions to the person, the CLI's `AskUserQuestion` shape, answered through the host's
    /// `QuestionCallback` and returned as `{"answers": {...}}`.
    static func askUserQuestionTool(_ handler: @escaping QuestionCallback) -> SwiftTool {
        try! SwiftTool(name: askUserQuestionName,
                       description: "Ask the person one or more clarifying questions with options and wait for their answers. Use only when you cannot proceed without the answer.",
                       inputSchema: ["type": "object", "properties": ["questions": ["type": "array", "items": ["type": "object", "properties": [
                            "question": ["type": "string"], "header": ["type": "string"], "multiSelect": ["type": "boolean"],
                            "options": ["type": "array", "items": ["type": "object", "properties": ["label": ["type": "string"], "description": ["type": "string"]], "required": ["label"]]]],
                            "required": ["question", "options"]]]], "required": ["questions"]],
                       annotations: ToolAnnotations(readOnlyHint: true)) { input in
            let questions = (input["questions"]?.arrayValue ?? []).map { q in
                AskQuestion(question: q["question"]?.stringValue ?? "", header: q["header"]?.stringValue ?? "",
                            options: (q["options"]?.arrayValue ?? []).map { .init(label: $0["label"]?.stringValue ?? "", description: $0["description"]?.stringValue ?? "") },
                            multiSelect: q["multiSelect"]?.boolValue ?? false)
            }
            let answers = await handler(questions)
            return ToolResult(content: [.text(JSONValue.object(["answers": .object(answers)]).canonicalJSON)])
        }
    }

    // MARK: Turn internals (called by TurnRunner)

    /// The history as it stands, for tests and diagnostics.
    func testHistory() async -> ConversationHistory { await runner.currentHistory }

    fileprivate func snapshot() -> Config { config.withLock { $0 } }
    fileprivate func emit(_ m: Message) { continuation.yield(m) }
    fileprivate func recordUsage(_ u: ModelUsage) { config.withLock { $0.lastUsage = u; $0.totalUsage = $0.totalUsage + u } }

    fileprivate func request(history: ConversationHistory, config c: Config) -> ModelRequest {
        let o = c.options
        var tools = zip(c.tools, c.toolWireNames).map { ModelToolDefinition(name: $1, description: $0.description, inputSchema: $0.inputSchema, strict: o.strictTools) }
        if c.question != nil {
            let q = Self.askUserQuestionTool { _ in [:] }
            tools.append(ModelToolDefinition(name: q.name, description: q.description, inputSchema: q.inputSchema))
        }
        let display: ModelThinkingDisplay = o.reasoningDisplay == .hidden ? .omitted : .summarized
        let thinking: ModelThinking? = switch o.thinking {
        case .adaptive: .adaptive(display: display)
        case .budget(let n): .budget(tokens: n, display: display)
        case .disabled: .disabled
        case nil: nil
        }
        return ModelRequest(model: o.model, system: o.systemPrompt.map { [$0] } ?? [], messages: history.messages, tools: tools,
                            maxTokens: o.maxTokens, thinking: thinking, effort: o.effort, outputSchema: o.outputSchema, cachesPrefix: o.cachesPrefix)
    }
}

// MARK: - The turn

/// Runs one turn at a time: the loop of model call, tool wave, repeat. Owns the history and the interrupt path.
actor TurnRunner {
    private var history = ConversationHistory()
    private var turn: Task<Void, Never>?
    private var queuedSteers: [String] = []
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    var isRunning: Bool { turn != nil }

    func queueSteer(_ text: String) { queuedSteers.append(text) }
    func takeSteers() -> [String] { defer { queuedSteers = [] }; return queuedSteers }

    func setPaused(_ on: Bool) {
        paused = on
        if !on { let w = pauseWaiters; pauseWaiters = []; for c in w { c.resume() } }
    }
    func waitIfPaused() async {
        guard paused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    var currentHistory: ConversationHistory { history }

    /// Interrupt: cancel the turn task (model stream and tool wave), then wait for its cleanup to finish, which
    /// includes ending registered processes, repairing history and emitting the result.
    func interrupt() async {
        guard let turn else { return }
        turn.cancel()
        await turn.value
    }

    func startTurn(_ input: ModelMessage, engine: DirectAPIEngine) async throws {
        guard engine.snapshot().started else { throw EngineError.notStarted(operation: "send") }
        if turn != nil {
            // A second send during a turn is steering: queued for the next request (plan 9.2, message injection).
            queuedSteers.append(input.text)
            engine.emit(.steeringQueued(text: input.text))
            return
        }
        history.append(input)
        // Returns as soon as the turn is running, like the CLI's `send`; the outcome arrives on `messages`.
        turn = Task { await self.runTurn(engine: engine) }
    }

    private func runTurn(engine: DirectAPIEngine) async {
        defer { turn = nil }
        let started = ContinuousClock.now
        var apiTime: Duration = .zero
        var modelCalls = 0
        var totalUsage = ModelUsage()
        var finalText = ""
        var lastStop: ModelStopReason?
        var truncations = 0
        var lastFingerprint: String?
        var repeats = 0
        let sessionId = engine.snapshot().options.sessionId

        func result(_ subtype: String, isError: Bool = false, errors: [String]? = nil, stopReason: String? = lastStop?.wireValue) -> ResultMessage {
            let elapsed = ContinuousClock.now - started
            var r = ResultMessage(subtype: subtype, isError: isError, durationMs: Int(elapsed / .milliseconds(1)), durationApiMs: Int(apiTime / .milliseconds(1)),
                                  numTurns: modelCalls, sessionId: sessionId, uuid: UUID().uuidString, stopReason: stopReason,
                                  usage: totalUsage.wire, result: finalText.isEmpty ? nil : finalText, errors: errors)
            if let schema = engine.snapshot().options.outputSchema, schema != .null, !finalText.isEmpty, subtype == "success" {
                r.structuredOutput = try? JSONValue(data: Data(finalText.utf8))
            }
            return r
        }

        do {
            loop: while true {
                try Task.checkCancellation()
                await waitIfPaused()
                try Task.checkCancellation()
                let config = engine.snapshot()
                if let maxTurns = config.options.maxTurns, modelCalls >= maxTurns {
                    engine.emit(.result(result("error_max_turns", isError: true, errors: ["Reached \(maxTurns) model calls in one turn"])))
                    return
                }
                if let strategy = config.options.compaction, strategy.shouldCompact(history),
                   let compacted = try? await strategy.compact(history, model: config.options.model, provider: engine.provider) {
                    let before = history.messages.count
                    history = compacted
                    engine.emit(.system(subtype: "compacted", data: ["messages_before": .number(Double(before)), "messages_after": .number(Double(history.messages.count))]))
                }
                // The model call.
                let request = engine.request(history: history, config: config)
                let callStart = ContinuousClock.now
                var accumulator = ResponseAccumulator(model: config.options.model)
                for try await event in engine.provider.stream(request) {
                    accumulator.apply(event)
                    if config.options.includePartialMessages { for e in ResponseAccumulator.streamEvents(for: event) { engine.emit(.streamEvent(event: e, parentToolUseId: nil)) } }
                }
                try Task.checkCancellation()   // a cancelled iteration ends quietly; the partial response is discarded here
                apiTime += ContinuousClock.now - callStart
                modelCalls += 1
                guard let finished = accumulator.finished else { throw ProviderError.invalidResponse("stream ended without a stop reason") }
                let assistant = ModelMessage(role: .assistant, content: accumulator.blocks)
                history.append(assistant)
                history.lastContextTokens = finished.usage.contextTokens
                engine.recordUsage(finished.usage)
                totalUsage = totalUsage + finished.usage
                lastStop = finished.stopReason
                engine.emit(.assistant(AssistantMessage(uuid: UUID().uuidString, content: accumulator.protocolBlocks, model: accumulator.model,
                                                        stopReason: finished.stopReason.wireValue, usage: finished.usage.wire)))
                let text = assistant.text
                if !text.isEmpty { finalText = text }

                switch finished.stopReason {
                case .toolUse:
                    let calls = assistant.content.compactMap { block -> ToolCall? in
                        if case let .toolUse(id, name, input) = block { return ToolCall(id: id, name: name, input: input) }; return nil
                    }
                    // Loop detection (plan 9.2): identical consecutive calls get feedback on the third and end the turn on the fifth.
                    let fingerprint = calls.map(\.fingerprint).joined(separator: "|")
                    repeats = fingerprint == lastFingerprint ? repeats + 1 : 0
                    lastFingerprint = fingerprint
                    var outcomes = await engine.executor.run(calls)
                    try Task.checkCancellation()
                    if repeats >= 2 {
                        for i in outcomes.indices {
                            outcomes[i].result.content.append(.text("\n[Note: this is the same call as the previous \(repeats) turns. Change approach or answer with what you have.]"))
                        }
                    }
                    var blocks = outcomes.map(\.block)
                    let steers = takeSteers()
                    for s in steers { blocks.append(.text(s)) }
                    let user = ModelMessage(role: .user, content: blocks)
                    history.append(user)
                    engine.emit(.user(UserMessage(uuid: UUID().uuidString, content: outcomes.map { o -> ContentBlock in
                        .toolResult(toolUseId: o.call.id, content: ToolOutcome.wireContent(o.result), isError: o.result.isError) } + steers.map { ContentBlock.text($0) })))
                    if outcomes.contains(where: \.endsTurn) {
                        engine.emit(.result(result("success", stopReason: "tool_use")))
                        return
                    }
                    if repeats >= 4 {
                        engine.emit(.result(result("error_during_execution", isError: true, errors: ["Loop detected: the same tool call repeated \(repeats + 1) times"], stopReason: "loop_detected")))
                        return
                    }
                    continue loop
                case .maxTokens where truncations < config.options.maxTokensRecoveries:
                    truncations += 1
                    history.append(.user("Your previous reply was cut off by the output limit. Continue exactly where you left off without repeating."))
                    continue loop
                case .refusal:
                    engine.emit(.system(subtype: "refusal", data: ["category": finished.stopDetails?.category.map { .string($0) } ?? .null,
                                                                   "explanation": finished.stopDetails?.explanation.map { .string($0) } ?? .null]))
                    if finalText.isEmpty { finalText = finished.stopDetails?.explanation ?? "The model declined this request." }
                    engine.emit(.result(result("success")))
                    return
                default:
                    let steers = takeSteers()
                    if !steers.isEmpty {
                        // Queued steering with no tool wave to ride on: deliver it as the next request (plan 9.2).
                        history.append(ModelMessage(role: .user, content: steers.map { .text($0) }))
                        continue loop
                    }
                    engine.emit(.result(result("success")))
                    return
                }
            }
        } catch is CancellationError {
            await engine.executor.registry.terminateAll(grace: 2)
            let repaired = history.repairInterrupted()
            if !repaired.isEmpty {
                engine.emit(.user(UserMessage(uuid: UUID().uuidString, content: repaired.map {
                    .toolResult(toolUseId: $0, content: .array([["type": "text", "text": "Interrupted by user"]]), isError: true) })))
            }
            engine.emit(.result(result("error_during_execution", errors: ["[ede_diagnostic] interrupted_by_user model_calls=\(modelCalls) repaired=\(repaired.count)"], stopReason: nil)))
        } catch let e as ProviderError {
            engine.emit(.result(result("error_during_execution", isError: true, errors: [e.description], stopReason: nil)))
        } catch {
            engine.emit(.result(result("error_during_execution", isError: true, errors: ["\(error)"], stopReason: nil)))
        }
    }
}

/// Builds the assistant message from `ModelEvent`s and re-synthesises the Messages API stream event shape the
/// Console already renders (`content_block_start`, `content_block_delta`, `content_block_stop`).
struct ResponseAccumulator {
    struct Finished { var stopReason: ModelStopReason; var usage: ModelUsage; var stopDetails: ModelStopDetails? }
    private enum Open { case text(String), thinking(String, signature: String?), toolUse(id: String, name: String, json: String), native(JSONValue) }
    private var open: [Int: Open] = [:]
    private var order: [Int] = []
    private(set) var blocks: [ModelContentBlock] = []
    private(set) var protocolBlocks: [ContentBlock] = []
    var model: String
    private var startUsage = ModelUsage()
    private(set) var finished: Finished?

    init(model: String) { self.model = model }

    mutating func apply(_ event: ModelEvent) {
        switch event {
        case .started(let m, let usage): if !m.isEmpty { model = m }; if let usage { startUsage = usage }
        case .blockStarted(let i, let block):
            order.append(i)
            switch block {
            case .text: open[i] = .text("")
            case .thinking: open[i] = .thinking("", signature: nil)
            case .toolUse(let id, let name, _): open[i] = .toolUse(id: id, name: name, json: "")
            case .providerNative(let raw): open[i] = .native(raw)
            }
        case .textDelta(let i, let t): if case .text(let s) = open[i] { open[i] = .text(s + t) }
        case .thinkingDelta(let i, let t): if case .thinking(let s, let sig) = open[i] { open[i] = .thinking(s + t, signature: sig) }
        case .signatureDelta(let i, let sig): if case .thinking(let s, _) = open[i] { open[i] = .thinking(s, signature: sig) }
        case .toolInputDelta(let i, let part): if case .toolUse(let id, let name, let json) = open[i] { open[i] = .toolUse(id: id, name: name, json: json + part) }
        case .blockStopped: break
        case .finished(let stop, let usage, let details):
            for i in order {
                switch open[i] {
                case .text(let s): blocks.append(.text(s)); protocolBlocks.append(.text(s))
                case .thinking(let s, let sig): blocks.append(.thinking(s, signature: sig)); protocolBlocks.append(.thinking(s))
                case .toolUse(let id, let name, let json):
                    let input = (try? JSONValue(data: Data((json.isEmpty ? "{}" : json).utf8))) ?? .object([:])
                    blocks.append(.toolUse(id: id, name: name, input: input)); protocolBlocks.append(.toolUse(id: id, name: name, input: input))
                case .native(let raw): blocks.append(.providerNative(raw))
                case nil: break
                }
            }
            finished = Finished(stopReason: stop, usage: startUsage.merged(with: usage), stopDetails: details)
        }
    }

    /// The Messages API streaming event for a `ModelEvent`, as the CLI forwards them
    /// (https://platform.claude.com/docs/en/build-with-claude/streaming).
    static func streamEvents(for event: ModelEvent) -> [JSONValue] {
        switch event {
        case .blockStarted(let i, let block):
            let cb: JSONValue
            switch block {
            case .text: cb = ["type": "text", "text": ""]
            case .thinking: cb = ["type": "thinking", "thinking": ""]
            case .toolUse(let id, let name, _): cb = ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]]
            case .providerNative(let raw): cb = raw
            }
            return [["type": "content_block_start", "index": .number(Double(i)), "content_block": cb]]
        case .textDelta(let i, let t): return [["type": "content_block_delta", "index": .number(Double(i)), "delta": ["type": "text_delta", "text": .string(t)]]]
        case .thinkingDelta(let i, let t): return [["type": "content_block_delta", "index": .number(Double(i)), "delta": ["type": "thinking_delta", "thinking": .string(t)]]]
        case .toolInputDelta(let i, let p): return [["type": "content_block_delta", "index": .number(Double(i)), "delta": ["type": "input_json_delta", "partial_json": .string(p)]]]
        case .blockStopped(let i): return [["type": "content_block_stop", "index": .number(Double(i))]]
        case .started, .signatureDelta, .finished: return []
        }
    }
}
