import Foundation
import Synchronization
import AgentProtocol
import AgentSession
import AgentTransport
import AgentEngine

/// What an ACP engine starts with. The host builds `environment` from its own allowlist (Kyberna: ADR 0007 point
/// 4); `PATH` in it is where `descriptor.executable` is found unless `executablePath` says otherwise.
public struct ACPEngineOptions: Sendable {
    public var descriptor: ACPAgentDescriptor
    public var workingDirectory: String
    /// The model the agent is launched on, through `descriptor.modelArgument`; nil is the agent's default.
    public var model: String?
    public var environment: [String: String]
    /// The resolved executable; nil looks `descriptor.executable` up on `environment["PATH"]` at start.
    public var executablePath: String?
    /// Text sent as its own block ahead of the first prompt (a carried transcript). ACP's `session/new` takes no
    /// system prompt, so this is the one place a host can put context the agent did not see itself.
    public var preamble: String?
    /// Emit `Message.streamEvent` deltas (the Messages API shape the Console renders) as chunks arrive.
    public var includePartialMessages = false
    public var initializeTimeout: TimeInterval = 60
    /// How long `stop(.turn)` waits for the agent to end the cancelled prompt before the engine ends the turn itself.
    public var cancelGrace: TimeInterval = 5
    /// How long `stop(.session)` waits after closing stdin before SIGTERM, and after SIGTERM before SIGKILL.
    public var exitGrace: TimeInterval = 5
    public var maxLineBytes = 1024 * 1024
    public var recordDirectory: String?
    public var stderr: (@Sendable (String) -> Void)?
    /// What the client tells the agent it offers. Nothing: the engine serves no `fs/*` or `terminal/*` methods
    /// in this release, so the agent uses its own file access and shell.
    public var clientCapabilities: JSONValue = ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]
    /// The stdio form of the hosted-tool server for an agent whose `initialize` does not advertise
    /// `mcpCapabilities.http` (Kyberna: `kyb mcp-serve --session ID`, a stdio MCP server that forwards to the daemon,
    /// which answers through `HostedToolServing`). Nil leaves such an agent without the hosted tools, and the
    /// stream says so (`system/hosted_tools_unavailable`). The endpoint's name is replaced by the `host` server name.
    public var stdioToolServer: MCPServerEndpoint?
    public init(descriptor: ACPAgentDescriptor, workingDirectory: String, environment: [String: String]) {
        self.descriptor = descriptor; self.workingDirectory = workingDirectory; self.environment = environment
    }
}

/// Thrown by `ACPEngine.start()`; everything after start becomes an error result on the stream.
public enum ACPEngineError: Error, Sendable, Equatable, CustomStringConvertible {
    case executableNotFound(name: String, path: String)
    /// `initialize` or `session/new` failed; `authNote` is the descriptor's, since a failed session start on a
    /// fresh install is most often a sign-in the agent still needs.
    case sessionStartFailed(String, authNote: String)
    public var description: String {
        switch self {
        case let .executableNotFound(name, path): return "\(name) was not found on PATH (\(path))"
        case let .sessionStartFailed(why, note): return "the agent could not open a session: \(why). Sign-in: \(note)"
        }
    }
}

/// One `AgentEngine` over the Agent Client Protocol (agentclientprotocol.com, protocol version 1): an ACP agent
/// as a child on stdio, `initialize` then `session/new` (or `session/load`) at start, each `send` a
/// `session/prompt`, `session/update` notifications mapped to `Message`, `session/request_permission` answered
/// through `PermissionGating`, `session/cancel` for `stop(.turn)`.
///
/// Capabilities: `PermissionGating` (the agent's `allow_once`/`allow_always`/`reject_once`/`reject_always`
/// options mapped from the policy's and the person's allow and deny; the question handler is kept but ACP has no
/// `AskUserQuestion` round trip, so it is never called), `ModelSwitching` as a restart on the new model argument
/// (the engine ends its child; the host, which carries the conversation, starts it again), and `Resumable` only
/// through the `ResumableACPEngine` wrapper `make(options:)` returns for a descriptor that advertises `session/load`.
/// `ToolHosting` and `HostedToolServing` (Kyberna release plan v0.2.14 Phase 2 step (e)): the host's `SwiftTool`s
/// reach the agent through `mcpServers` on `session/new` as one MCP server named `serverName`, on the wire as
/// `<serverName>_<tool>` and to the policy as `mcp__<serverName>__<tool>` (`HostedToolNaming`). The transport is
/// a loopback streamable-HTTP server per session (`LoopbackMCPServer`: 127.0.0.1, an ephemeral port, a bearer
/// token checked on every request, closed with the session) when the agent's `initialize` advertises
/// `mcpCapabilities.http`, else the host's `stdioToolServer` line, else nothing and `system/hosted_tools_unavailable`.
/// An agent's `session/request_permission` for a hosted tool is matched to the tool by `toolCallId` (the request's
/// title is the bare wire name, the `tool_call` update's a prefixed one) and answered under the policy name; a call
/// arriving at the server is gated again (the policy callback, then the person unless the same call was just
/// allowed), and a refusal is an `isError` result. A refused call's `failed` update carries the refusal as its text.
/// Absent, with the documented fallbacks: `ContextReporting`, `FileRewinding`, `HookCapable`, `EffortSetting`,
/// `ReasoningControl`, `ImageAttaching` and `RateLimitReporting`.
///
/// Errors from the child after start are error results on the stream, never throws into the loop;
/// `CancellationError` passes through. Steering has no ACP form apart from another prompt, so `steer` queues the
/// text as the next `session/prompt` and `steerNow` cancels the running one first.
public final class ACPEngine: AgentEngine, PermissionGating, ModelSwitching, ToolHosting, HostedToolServing, Sendable {
    /// The engine for a descriptor: `ResumableACPEngine` (this engine with `Resumable` in front) when the
    /// descriptor advertises `session/load`, else this class alone.
    public static func make(options: ACPEngineOptions) -> any AgentEngine {
        options.descriptor.supportsSessionLoad ? ResumableACPEngine(options: options) : ACPEngine(options: options)
    }

    struct ToolCallRecord: Sendable {
        var name: String
        var title: String
        var kind: String?
        var input: JSONValue
        var status: String
        var output: [String] = []
        var resultEmitted = false
        /// Set when the call names a hosted tool: the tool's own name (`notes_search`).
        var hostedTool: String?
    }
    struct Turn: Sendable {
        var number: Int
        var text = ""
        var thinking = ""
        var resultText = ""
        var toolCalls: [String: ToolCallRecord] = [:]
        var toolOrder: [String] = []
        /// By tool call id: the reason this engine refused the call (policy or person), the failed step's text.
        var refusals: [String: String] = [:]
        var cancelled = false
        var startedAt = Date()
        var task: Task<Void, Never>?
        var blockIndex = 0
    }
    struct PendingPermission: Sendable { var requestId: JSONValue; var task: Task<Void, Never>? }
    struct State: Sendable {
        var options: ACPEngineOptions
        var started = false
        var policy: PolicyCallback?
        var permission: PermissionCallback?
        var question: QuestionCallback?
        var resumeReference: String?
        var sessionId: String?
        var agentName: String?
        var agentVersion: String?
        var loadSession = false
        var loading = false
        var availableModels: [ModelChoice] = []
        var currentModel: String?
        var preambleSent = false
        var turn: Turn?
        var turnsRun = 0
        var queued: [String] = []
        var pendingPermissions: [String: PendingPermission] = [:]
        var exited: Int32?
        var exitWaiters: [CheckedContinuation<Void, Never>] = []
        var hostedTools: [SwiftTool] = []
        var serverName: String?
        var toolServer: LoopbackMCPServer?
        /// `http`, `stdio` or `none`: how the hosted tools reached the agent at start.
        var toolTransport = "none"
        /// Calls the permission flow allowed, by `ApprovalPayload.hash` of the policy name and arguments, so the
        /// same call arriving at the server is not put to the person twice. Cleared at the turn's end.
        var grants: [String: Int] = [:]
    }

    let state: Mutex<State>
    private let clientBox = Mutex<ACPClient?>(nil)
    private let continuation: AsyncStream<Message>.Continuation
    public let messages: AsyncStream<Message>

    public init(options: ACPEngineOptions) {
        state = Mutex(State(options: options))
        var c: AsyncStream<Message>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public var descriptor: ACPAgentDescriptor { state.withLock { $0.options.descriptor } }
    /// The options as they stand: what the next start uses, or what the running child was started with.
    public var options: ACPEngineOptions { state.withLock { $0.options } }

    // MARK: AgentEngine

    public var sessionId: String? { state.withLock { $0.sessionId } }
    /// "<agent name> <version>" from `initialize`'s `agentInfo`, or the descriptor's id before start.
    public var engineVersion: String? {
        state.withLock { s in
            guard let name = s.agentName else { return nil }
            return s.agentVersion.map { "\(name) \($0)" } ?? name
        }
    }

    /// Finds `name` on `path` (a colon list); a name with a slash is taken as given.
    public static func locate(_ name: String, path: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = String(dir) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func start() async throws {
        let (options, resumeReference) = try state.withLock { s -> (ACPEngineOptions, String?) in
            guard !s.started else { throw SessionError.alreadyStarted }
            s.started = true
            return (s.options, s.resumeReference)
        }
        let path = options.environment["PATH"] ?? ""
        guard let executable = options.executablePath ?? Self.locate(options.descriptor.executable, path: path) else {
            state.withLock { $0.started = false }
            throw ACPEngineError.executableNotFound(name: options.descriptor.executable, path: path)
        }
        let launch = options.descriptor.launch(model: options.model, environment: options.environment)
        var config = ACPClient.Configuration(executable: executable, arguments: launch.arguments, workingDirectory: options.workingDirectory, environment: launch.environment)
        config.maxLineBytes = options.maxLineBytes
        config.recordDirectory = options.recordDirectory
        config.stderr = options.stderr
        let client = ACPClient(configuration: config, handlers: ACPClient.Handlers(
            notification: { [weak self] method, params in self?.notification(method, params) },
            request: { [weak self] request in self?.incoming(request) },
            exited: { [weak self] status, signal in self?.childExited(status: status, signal: signal) }))
        clientBox.withLock { $0 = client }
        do {
            try client.start()
            let initialize = try await Self.withTimeout(options.initializeTimeout, what: "initialize") {
                try await client.request("initialize", params: ["protocolVersion": .number(Double(ACPClient.protocolVersion)),
                                                                "clientCapabilities": options.clientCapabilities,
                                                                "clientInfo": ["name": "kyberna-agent-sdk-swift", "version": "0.8.0"]])
            }
            if let v = initialize["protocolVersion"]?.intValue, v != ACPClient.protocolVersion { throw ACPError.unsupportedProtocolVersion(v) }
            let loadSession = initialize["agentCapabilities"]?["loadSession"]?.boolValue ?? false
            state.withLock { s in
                s.loadSession = loadSession
                s.agentName = initialize["agentInfo"]?["name"]?.stringValue ?? options.descriptor.displayName
                s.agentVersion = initialize["agentInfo"]?["version"]?.stringValue
            }
            let httpMCP = initialize["agentCapabilities"]?["mcpCapabilities"]?["http"]?.boolValue ?? false
            let mcpServers = await hostedToolEndpoint(httpCapable: httpMCP)
            var resumed = false
            var opened: JSONValue
            let sessionParams: [String: JSONValue] = ["cwd": .string(options.workingDirectory), "mcpServers": .array(mcpServers.map(\.wire))]
            if let previous = resumeReference, loadSession {
                state.withLock { $0.loading = true }
                defer { state.withLock { $0.loading = false } }
                var p = sessionParams; p["sessionId"] = .string(previous)
                do {
                    opened = try await client.request("session/load", params: .object(p))
                    // `session/load` answers with an empty result; the id is the one asked for.
                    if opened["sessionId"] == nil { var o = opened.objectValue ?? [:]; o["sessionId"] = .string(previous); opened = .object(o) }
                    resumed = true
                } catch let error as ACPError {
                    // The agent no longer has that session (or refuses the load): a fresh one, said on the stream.
                    continuation.yield(.system(subtype: "resume_unavailable", data: ["previous": .string(previous), "reason": .string("session/load failed: \(error)")]))
                    opened = try await client.request("session/new", params: .object(sessionParams))
                }
            } else {
                if let previous = resumeReference {
                    continuation.yield(.system(subtype: "resume_unavailable", data: ["previous": .string(previous), "reason": "the agent does not advertise session/load; this start is a fresh one"]))
                }
                opened = try await client.request("session/new", params: .object(sessionParams))
            }
            guard let sessionId = opened["sessionId"]?.stringValue else { throw ACPError.protocolViolation("session/new returned no sessionId") }
            let models = (opened["models"]?["availableModels"]?.arrayValue ?? []).compactMap { m -> ModelChoice? in
                guard let id = m["modelId"]?.stringValue else { return nil }
                return ModelChoice(value: id, resolvedModel: id, displayName: m["name"]?.stringValue ?? id, description: m["description"]?.stringValue ?? "", supportedEffortLevels: [])
            }
            let current = options.model ?? opened["models"]?["currentModelId"]?.stringValue
            let (name, version, toolNames, transport) = state.withLock { s -> (String?, String?, [String], String) in
                s.sessionId = sessionId; s.availableModels = models; s.currentModel = current
                let naming = HostedToolNaming(serverName: s.serverName ?? "")
                return (s.agentName, s.agentVersion, s.toolTransport == "none" ? [] : s.hostedTools.map { naming.policyName($0) }, s.toolTransport)
            }
            continuation.yield(.initialized(sessionId: sessionId, model: current ?? "default", tools: toolNames,
                                            data: ["engine": "acp", "agent": .string(options.descriptor.id), "agentName": .string(name ?? ""),
                                                   "agentVersion": version.map { .string($0) } ?? .null, "protocolVersion": .number(Double(ACPClient.protocolVersion)),
                                                   "loadSession": .bool(loadSession), "resumed": .bool(resumed), "apiKeySource": "none",
                                                   "cwd": .string(options.workingDirectory), "mcpTransport": .string(transport), "mcpHttp": .bool(httpMCP)]))
        } catch {
            // A start that failed leaves no child behind; the host sees the throw and nothing on the stream.
            stopToolServer()
            client.kill()
            var gone = false
            if let acp = error as? ACPError, case .exited = acp { gone = true }
            if !gone { _ = await awaitExit(timeout: 1) }
            throw ACPEngineError.sessionStartFailed(String(describing: error), authNote: options.descriptor.authNote)
        }
    }

    public func send(_ prompt: String) async throws {
        guard state.withLock({ $0.started }) else { throw EngineError.notStarted(operation: "send") }
        let queued = state.withLock { s -> Bool in
            if s.turn != nil { s.queued.append(prompt); return true }
            s.turnsRun += 1
            s.turn = Turn(number: s.turnsRun)
            return false
        }
        if queued { continuation.yield(.steeringQueued(text: prompt)); return }
        runTurn(prompt)
    }

    /// ACP has no mid-turn message: the text is the next `session/prompt`, sent when the running one ends.
    public func steer(_ text: String) async throws { try await send(text) }

    /// `session/cancel`, the running prompt's end awaited, then `text` as the next prompt.
    public func steerNow(_ text: String) async throws {
        await cancelTurn()
        try await send(text)
    }

    public func pause() { clientBox.withLock { $0 }?.suspend() }
    public func resume() { clientBox.withLock { $0 }?.continue() }

    /// `.turn`: `session/cancel`; every open permission request is answered `cancelled` first, as the protocol
    /// requires. `.session`: the turn cancelled, stdin closed, then SIGTERM and SIGKILL after `exitGrace` each.
    /// `.kill`: SIGKILL at once. The stream ends with `.exited` when the child is gone.
    public func stop(_ severity: StopSeverity) async {
        guard let client = clientBox.withLock({ $0 }) else {
            // Never started: nothing to end, but the stream must still close for a host that awaits it.
            if state.withLock({ s in let was = s.exited; s.exited = s.exited ?? 0; return was }) == nil {
                continuation.yield(.exited(status: 0, signal: nil)); continuation.finish()
            }
            return
        }
        switch severity {
        case .turn:
            await cancelTurn()
        case .session:
            await cancelTurn()
            defer { stopToolServer() }
            let grace = state.withLock { $0.options.exitGrace }
            client.closeInput()
            if await awaitExit(timeout: grace) { return }
            client.terminate()
            if await awaitExit(timeout: grace) { return }
            client.kill()
            _ = await awaitExit(timeout: grace)
        case .kill:
            client.kill()
            _ = await awaitExit(timeout: state.withLock { $0.options.exitGrace })
            stopToolServer()
        }
    }

    // MARK: PermissionGating

    private func beforeStart(_ operation: String, _ change: @Sendable (inout State) -> Void) throws {
        try state.withLock { s in
            guard !s.started else { throw EngineError.alreadyStarted(operation: operation) }
            change(&s)
        }
    }
    public func setPolicy(_ policy: PolicyCallback?) throws { try beforeStart("setPolicy") { $0.policy = policy } }
    public func setPermissionHandler(_ handler: PermissionCallback?) throws { try beforeStart("setPermissionHandler") { $0.permission = handler } }
    /// Kept for the protocol's shape; ACP has no question round trip in the methods this engine speaks, so it is never called.
    public func setQuestionHandler(_ handler: QuestionCallback?) throws { try beforeStart("setQuestionHandler") { $0.question = handler } }

    /// The ACP session id to `session/load` at start; `ResumableACPEngine.resume` sets it.
    func setResumeReference(_ reference: String) throws { try beforeStart("resume") { $0.resumeReference = reference } }

    // MARK: ToolHosting, HostedToolServing

    public var hostedTools: [SwiftTool] { state.withLock { $0.hostedTools } }
    /// Before start only. The tools reach the agent as one MCP server named `serverName` (see the class comment).
    public func host(_ tools: [SwiftTool], serverName: String) throws {
        try beforeStart("host") { s in s.hostedTools += tools; s.serverName = serverName }
    }
    /// `http`, `stdio` or `none` after start: how the hosted tools were offered to the agent.
    public var hostedToolTransport: String { state.withLock { $0.toolTransport } }
    /// The loopback server's bound port while it runs, for tests.
    public var toolServerPort: UInt16? { state.withLock { $0.toolServer?.port } }

    /// The hosted tools as MCP `tools/list` entries, under their wire names.
    public func hostedToolList() -> [JSONValue] {
        let (tools, naming) = state.withLock { ($0.hostedTools, HostedToolNaming(serverName: $0.serverName ?? "")) }
        return tools.map { tool in
            var d = tool.wire.objectValue ?? [:]
            d["name"] = .string(naming.wireName(tool))
            return .object(d)
        }
    }

    /// One `tools/call` as the server receives it, by any name `HostedToolNaming.tool(matching:)` reads. The policy
    /// callback first (a deny is the `isError` result and `permissionDenied` on the stream); then a grant left by the
    /// permission flow for this exact call, else the permission handler with a `permissionRequest` on the stream;
    /// then the tool. The tool's own throw is an `isError` result; `CancellationError` is reported as `cancelled`.
    public func callHostedTool(_ name: String, arguments: [String: JSONValue]) async -> ToolResult {
        let (tools, naming, policy, handler) = state.withLock { ($0.hostedTools, HostedToolNaming(serverName: $0.serverName ?? ""), $0.policy, $0.permission) }
        guard let tool = naming.tool(matching: name, in: tools) else { return .error("Unknown tool \(name)") }
        let policyName = naming.policyName(tool)
        let input = JSONValue.object(arguments)
        switch policy?(policyName, input) ?? .ask {
        case .deny(let why):
            continuation.yield(.permissionDenied(tool: policyName, toolUseId: nil, reasonType: "policy", reason: why))
            return .error("\(tool.name) was refused by policy: \(why)")
        case .allow:
            break
        case .ask:
            let payload = ApprovalPayload(tool: policyName, input: input)
            let granted = state.withLock { s -> Bool in
                guard let n = s.grants[payload.hash], n > 0 else { return false }
                s.grants[payload.hash] = n - 1; return true
            }
            if !granted {
                guard let handler else { return .error("\(tool.name) was refused: no permission handler") }
                continuation.yield(.permissionRequest(payload))
                let context = PermissionContext(toolUseId: nil, suggestions: [], blockedPath: nil, decisionReason: nil,
                                                title: tool.name, description: "mcp", payload: payload)
                switch await handler(policyName, input, context) {
                case .allow: break
                case .deny(let why, _):
                    continuation.yield(.permissionDenied(tool: policyName, toolUseId: nil, reasonType: "person", reason: why))
                    return .error("\(tool.name) was refused: \(why)")
                }
            }
        }
        do { return try await tool.handler(arguments) }
        catch is CancellationError { return .error("cancelled") }
        catch { return .error("\(error)") }
    }

    /// The `mcpServers` entries for `session/new`: the loopback HTTP server, started here, when the agent takes
    /// HTTP; the host's stdio line otherwise; nothing (and a note on the stream) when neither applies or no tool
    /// is hosted.
    private func hostedToolEndpoint(httpCapable: Bool) async -> [MCPServerEndpoint] {
        let (tools, serverName, stdio) = state.withLock { ($0.hostedTools, $0.serverName ?? "", $0.options.stdioToolServer) }
        guard !tools.isEmpty else { return [] }
        let names = JSONValue.array(tools.map { .string($0.name) })
        if httpCapable {
            let server = LoopbackMCPServer(configuration: .init(serverName: serverName,
                                                                tools: { [weak self] in self?.hostedToolList() ?? [] },
                                                                call: { [weak self] name, args in await self?.callHostedTool(name, arguments: args) ?? .error("the engine is gone") }))
            do {
                try await server.start()
                guard let endpoint = server.endpoint(name: serverName) else { throw LoopbackMCPServer.ServerError.notStarted }
                state.withLock { s in s.toolServer = server; s.toolTransport = "http" }
                return [endpoint]
            } catch {
                // A loopback port that cannot be bound is no reason to refuse the agent: the session runs without
                // the hosted tools and the transcript says why.
                server.stop()
                continuation.yield(.system(subtype: "hosted_tools_unavailable", data: ["tools": names, "reason": .string("the loopback MCP server could not start: \(error)")]))
                return []
            }
        }
        if let stdio, case let .stdio(_, command, args, env) = stdio {
            state.withLock { $0.toolTransport = "stdio" }
            return [.stdio(name: serverName, command: command, args: args, env: env)]
        }
        continuation.yield(.system(subtype: "hosted_tools_unavailable",
                                   data: ["tools": names, "reason": .string(stdio == nil
                                        ? "the agent does not advertise mcpCapabilities.http and no stdio server line is configured; the hosted tools do not reach it"
                                        : "the agent does not advertise mcpCapabilities.http and the configured server line is not a stdio one")]))
        return []
    }

    private func stopToolServer() {
        let server = state.withLock { s -> LoopbackMCPServer? in let t = s.toolServer; s.toolServer = nil; return t }
        server?.stop()
    }

    /// Marks a record that names a hosted tool (by its title or name) with the policy name and the tool.
    private func resolveHosted(_ record: inout ToolCallRecord) {
        guard record.hostedTool == nil else { return }
        let (tools, naming) = state.withLock { ($0.hostedTools, HostedToolNaming(serverName: $0.serverName ?? "")) }
        guard !tools.isEmpty else { return }
        for candidate in [record.title, record.name] where !candidate.isEmpty {
            if let tool = naming.tool(matching: candidate, in: tools) {
                record.hostedTool = tool.name
                record.name = naming.policyName(tool)
                return
            }
        }
    }

    // MARK: ModelSwitching

    /// What `session/new` listed under `models.availableModels`; empty for an agent that lists none.
    public var availableModels: [ModelChoice] { state.withLock { $0.availableModels } }

    /// Before start: the model the agent is launched on. After start: the model is a launch argument, so the
    /// engine records `system/model_restart`, ends its child (the running turn is cancelled first) and leaves the
    /// host to start it again on the new model with the conversation it carries.
    public func setModel(_ model: String?) async throws {
        let started = state.withLock { s in s.options.model = model; return s.started }
        guard started else { return }
        continuation.yield(.system(subtype: "model_restart", data: ["model": model.map { .string($0) } ?? .null,
                                                                    "reason": "the agent takes its model at launch; the engine restarts on it and the host carries the conversation"]))
        await stop(.session)
    }

    // MARK: The turn

    private func runTurn(_ prompt: String) {
        guard let client = clientBox.withLock({ $0 }) else { return }
        let (sessionId, preamble, number) = state.withLock { s -> (String, String?, Int) in
            let p = s.preambleSent ? nil : s.options.preamble
            s.preambleSent = true
            return (s.sessionId ?? "", p, s.turn?.number ?? 0)
        }
        var blocks: [JSONValue] = []
        if let preamble, !preamble.isEmpty { blocks.append(["type": "text", "text": .string(preamble)]) }
        blocks.append(["type": "text", "text": .string(prompt)])
        // The prompt goes on the wire here, before `send` returns, so a `session/cancel` that follows cannot
        // overtake it; the task only awaits the answer.
        let requestId: Int
        do { requestId = try client.send("session/prompt", params: ["sessionId": .string(sessionId), "prompt": .array(blocks)]) }
        catch { finishTurn(number, stopReason: "error", error: String(describing: error)); return }
        let task = Task { [weak self] in
            do {
                let result = try await client.response(for: requestId)
                self?.finishTurn(number, stopReason: result["stopReason"]?.stringValue ?? "end_turn", error: nil)
            } catch is CancellationError {
                self?.finishTurn(number, stopReason: "cancelled", error: nil)
            } catch {
                self?.finishTurn(number, stopReason: "error", error: String(describing: error))
            }
        }
        state.withLock { s in if s.turn?.number == number { s.turn?.task = task } }
    }

    /// Ends turn `number` with a result; a later call for the same turn (the agent answering a prompt the
    /// engine already gave up on) is ignored.
    private func finishTurn(_ number: Int, stopReason: String, error: String?) {
        guard var turn = state.withLock({ s -> Turn? in
            guard let t = s.turn, t.number == number else { return nil }
            s.turn = nil; s.grants.removeAll(); return t
        }) else { return }
        let (sessionId, model) = state.withLock { ($0.sessionId ?? "", $0.currentModel ?? "default") }
        flushAssistant(&turn, extra: [], stopReason: stopReason, model: model)
        // A tool call the agent never reported the end of gets a result saying so, so a transcript pairs every use.
        for id in turn.toolOrder {
            guard var rec = turn.toolCalls[id], !rec.resultEmitted else { continue }
            rec.resultEmitted = true; turn.toolCalls[id] = rec
            let why = turn.cancelled || stopReason == "cancelled" ? "cancelled before the tool finished" : "the agent reported no result for this tool call"
            continuation.yield(.user(UserMessage(content: [.toolResult(toolUseId: id, content: .string(why), isError: true)])))
        }
        let ms = Int(Date().timeIntervalSince(turn.startedAt) * 1000)
        var result: ResultMessage
        if let error {
            result = ResultMessage(subtype: "error_during_execution", isError: true, durationMs: ms, numTurns: 1, sessionId: sessionId,
                                   stopReason: nil, result: error, errors: [error])
        } else {
            switch stopReason {
            case "end_turn", "max_tokens", "refusal":
                result = ResultMessage(subtype: "success", isError: false, durationMs: ms, numTurns: 1, sessionId: sessionId, stopReason: stopReason,
                                       result: turn.resultText.isEmpty && stopReason == "refusal" ? "The agent declined the request." : turn.resultText)
            case "max_turn_requests":
                result = ResultMessage(subtype: "error_max_turns", isError: true, durationMs: ms, numTurns: 1, sessionId: sessionId, stopReason: stopReason, result: turn.resultText)
            case "cancelled":
                // The CLI's shape for an interrupt, so `ResultMessage.wasInterrupted` reads the same on every engine.
                result = ResultMessage(subtype: "error_during_execution", isError: false, durationMs: ms, numTurns: 1, sessionId: sessionId, stopReason: stopReason,
                                       result: turn.resultText, errors: ["[ede_diagnostic] cancelled: session/cancel"])
            default:
                result = ResultMessage(subtype: "success", isError: false, durationMs: ms, numTurns: 1, sessionId: sessionId, stopReason: stopReason, result: turn.resultText)
            }
        }
        continuation.yield(.result(result))
        // The next queued prompt, if any, is its own turn.
        let next = state.withLock { s -> String? in
            guard s.exited == nil, !s.queued.isEmpty else { return nil }
            let n = s.queued.removeFirst()
            s.turnsRun += 1; s.turn = Turn(number: s.turnsRun)
            return n
        }
        if let next { runTurn(next) }
    }

    /// The buffered text and thinking, plus `extra` blocks, as one assistant message.
    private func flushAssistant(_ turn: inout Turn, extra: [ContentBlock], stopReason: String?, model: String) {
        var content: [ContentBlock] = []
        if !turn.thinking.isEmpty { content.append(.thinking(turn.thinking)) }
        if !turn.text.isEmpty { content.append(.text(turn.text)) }
        content += extra
        guard !content.isEmpty else { return }
        turn.resultText += (turn.resultText.isEmpty || turn.text.isEmpty ? "" : "\n") + turn.text
        turn.text = ""; turn.thinking = ""
        continuation.yield(.assistant(AssistantMessage(content: content, model: model, stopReason: stopReason)))
    }

    /// `session/cancel`, the open permission requests answered `cancelled`, and the turn's end awaited up to
    /// `cancelGrace`; past that the engine ends the turn itself and ignores the agent's late answer.
    private func cancelTurn() async {
        guard let client = clientBox.withLock({ $0 }) else { return }
        struct Cancel: Sendable { var sessionId: String; var number: Int; var task: Task<Void, Never>?; var grace: TimeInterval; var pending: [PendingPermission] }
        guard let c = state.withLock({ s -> Cancel? in
            guard var t = s.turn else { return nil }
            t.cancelled = true; s.turn = t
            let p = Array(s.pendingPermissions.values); s.pendingPermissions.removeAll()
            return Cancel(sessionId: s.sessionId ?? "", number: t.number, task: t.task, grace: s.options.cancelGrace, pending: p)
        }) else { return }
        let (sessionId, number, task, grace, pending) = (c.sessionId, c.number, c.task, c.grace, c.pending)
        for p in pending { p.task?.cancel(); client.respond(p.requestId, result: ["outcome": ["outcome": "cancelled"]]) }
        client.notify("session/cancel", params: ["sessionId": .string(sessionId)])
        guard let task else { finishTurn(number, stopReason: "cancelled", error: nil); return }
        let ended = await Self.race(task, timeout: grace)
        if !ended { finishTurn(number, stopReason: "cancelled", error: nil) }
    }

    // MARK: Incoming

    private func notification(_ method: String, _ params: JSONValue) {
        guard method == "session/update", let update = params["update"], let kind = update["sessionUpdate"]?.stringValue else {
            continuation.yield(.system(subtype: "acp_notification", data: ["method": .string(method), "params": params]))
            return
        }
        if state.withLock({ $0.loading }) { return }   // `session/load` replays the history the host already holds
        let (partial, model) = state.withLock { ($0.options.includePartialMessages, $0.currentModel ?? "default") }
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk":
            guard let text = Self.text(of: update["content"]) else { return }
            let thought = kind == "agent_thought_chunk"
            let index = state.withLock { s -> Int? in
                guard var t = s.turn else { return nil }
                if thought { t.thinking += text } else { t.text += text }
                s.turn = t; return t.blockIndex
            }
            if partial, let index {
                let delta: JSONValue = thought ? ["type": "thinking_delta", "thinking": .string(text)] : ["type": "text_delta", "text": .string(text)]
                continuation.yield(.streamEvent(event: ["type": "content_block_delta", "index": .number(Double(index)), "delta": delta], parentToolUseId: nil))
            }
        case "user_message_chunk":
            break
        case "tool_call":
            guard let id = update["toolCallId"]?.stringValue else { return }
            let known = state.withLock { $0.turn?.toolCalls[id] }
            var record = Self.record(from: update, merging: known)
            resolveHosted(&record)
            let (use, done) = state.withLock { s -> (Bool, Bool) in
                guard var t = s.turn else { return (false, false) }
                let isNew = t.toolCalls[id] == nil
                if isNew { t.toolOrder.append(id) }
                t.toolCalls[id] = record
                if isNew { t.blockIndex += 1 }
                s.turn = t
                return (isNew, record.status == "completed" || record.status == "failed")
            }
            if use {
                state.withLock { s in
                    guard var t = s.turn else { return }
                    flushAssistant(&t, extra: [.toolUse(id: id, name: record.name, input: record.input)], stopReason: nil, model: model)
                    s.turn = t
                }
            }
            if done { emitToolResult(id, model: model) }
        case "tool_call_update":
            guard let id = update["toolCallId"]?.stringValue else { return }
            let known = state.withLock { $0.turn?.toolCalls[id] }
            var merged = Self.record(from: update, merging: known)
            resolveHosted(&merged)
            let done = state.withLock { s -> Bool in
                guard var t = s.turn else { return false }
                if t.toolCalls[id] == nil { t.toolOrder.append(id); t.blockIndex += 1 }
                t.toolCalls[id] = merged
                s.turn = t
                return merged.status == "completed" || merged.status == "failed"
            }
            if done { emitToolResult(id, model: model) }
        case "plan":
            continuation.yield(.system(subtype: "plan", data: ["entries": update["entries"] ?? .array([])]))
        default:
            continuation.yield(.system(subtype: "acp_" + kind, data: update))
        }
    }

    /// The tool's result as one `user` message, its content blocks joined with a newline (Kyberna console 93). Text
    /// the agent wrote while the call ran ("Info: …/hello.txt", which GitHub Copilot CLI sends as a message chunk
    /// before the `completed` update) goes out first as its own assistant message, so what the agent says after
    /// the result ("Done.") starts a new block instead of running on from the earlier text without a separator.
    private func emitToolResult(_ id: String, model: String) {
        guard let (rec, refusal) = state.withLock({ s -> (ToolCallRecord, String?)? in
            guard var t = s.turn, var r = t.toolCalls[id], !r.resultEmitted else { return nil }
            r.resultEmitted = true; t.toolCalls[id] = r; s.turn = t
            if !t.text.isEmpty || !t.thinking.isEmpty {
                flushAssistant(&t, extra: [], stopReason: nil, model: model)
                t.blockIndex += 1
                s.turn = t
            }
            return (r, t.refusals[id])
        }) else { return }
        var text = rec.output.joined(separator: "\n")
        if rec.status == "failed", let refusal {
            // The agent's own text for a rejection ("The user rejected this tool call.") says nothing about why;
            // the engine's reason does, and is what the transcript shows for the failed step.
            text = text.isEmpty || text == refusal ? refusal : "\(refusal) (agent: \(text))"
        }
        continuation.yield(.user(UserMessage(content: [.toolResult(toolUseId: id, content: .string(text.isEmpty ? rec.status : text), isError: rec.status == "failed")])))
    }

    /// A tool call record from a `tool_call` or `tool_call_update` payload, over what was known before.
    static func record(from update: JSONValue, merging previous: ToolCallRecord?) -> ToolCallRecord {
        var r = previous ?? ToolCallRecord(name: "", title: "", input: .object([:]), status: "pending")
        if let title = update["title"]?.stringValue { r.title = title }
        if let kind = update["kind"]?.stringValue { r.kind = kind }
        if let name = update["name"]?.stringValue, !name.isEmpty { r.name = name }
        if r.name.isEmpty { r.name = r.kind ?? (r.title.isEmpty ? "tool" : r.title) }
        if let input = update["rawInput"], !input.isNull { r.input = input }
        else if case .object(let o) = r.input, o.isEmpty, !r.title.isEmpty { r.input = ["title": .string(r.title)] }
        if let status = update["status"]?.stringValue { r.status = status }
        if let content = update["content"]?.arrayValue {
            for block in content {
                switch block["type"]?.stringValue {
                case "content": if let t = text(of: block["content"]) { r.output.append(t) }
                case "diff":
                    let path = block["path"]?.stringValue ?? ""
                    r.output.append("diff \(path):\n--- old\n\(block["oldText"]?.stringValue ?? "")\n+++ new\n\(block["newText"]?.stringValue ?? "")")
                case "terminal": r.output.append("terminal \(block["terminalId"]?.stringValue ?? "")")
                default: r.output.append(block.canonicalJSON)
                }
            }
        }
        if let raw = update["rawOutput"], !raw.isNull, r.output.isEmpty {
            // Copilot's failed update is `{"message": "...", "code": "rejected"}`; its text is the message.
            r.output.append(raw.stringValue ?? raw["message"]?.stringValue ?? raw.canonicalJSON)
        }
        return r
    }

    /// The text of an ACP content block (`text` blocks; a resource link or image is named, not embedded).
    static func text(of block: JSONValue?) -> String? {
        guard let block else { return nil }
        switch block["type"]?.stringValue {
        case "text": return block["text"]?.stringValue
        case "resource_link": return "[\(block["name"]?.stringValue ?? "resource")](\(block["uri"]?.stringValue ?? ""))"
        case "resource": return block["resource"]?["text"]?.stringValue
        case "image": return "[image \(block["mimeType"]?.stringValue ?? "")]"
        case "audio": return "[audio \(block["mimeType"]?.stringValue ?? "")]"
        default: return nil
        }
    }

    private func incoming(_ request: ACPClient.IncomingRequest) {
        guard let client = clientBox.withLock({ $0 }) else { return }
        switch request.method {
        case "session/request_permission": permissionRequest(request, client: client)
        default:
            // `fs/*`, `terminal/*` and the rest: the client advertised none of them in `initialize`.
            client.respond(request.id, errorCode: -32601, message: "\(request.method) is not served by this client")
        }
    }

    /// `session/request_permission`: the policy first, the person second, the chosen option back. `allow_once`
    /// for a plain allow, `allow_always` when the handler asks to remember (`updatedPermissions`) and the agent
    /// offers it, `reject_once` (else `reject_always`) for a denial; no matching option means `cancelled`.
    private func permissionRequest(_ request: ACPClient.IncomingRequest, client: ACPClient) {
        let call = request.params["toolCall"] ?? .object([:])
        let id = call["toolCallId"]?.stringValue ?? ""
        let known = state.withLock { $0.turn?.toolCalls[id] }
        var resolved = Self.record(from: call, merging: known)
        // A hosted tool is recognised here by the request's title (the bare wire name) when the `tool_call` update
        // has not named it yet; a record the turn already holds takes the name, so the transcript's tool use
        // and result read the same. An id not seen yet is left to its `tool_call`, which names the tool itself.
        resolveHosted(&resolved)
        let record = resolved
        if known != nil { state.withLock { s in s.turn?.toolCalls[id] = record } }
        let options = (request.params["options"]?.arrayValue ?? []).compactMap { o -> (id: String, kind: String)? in
            guard let oid = o["optionId"]?.stringValue else { return nil }
            return (oid, o["kind"]?.stringValue ?? "")
        }
        let key = request.id.canonicalJSON
        let payload = ApprovalPayload(tool: record.name, input: record.input, toolUseId: id.isEmpty ? nil : id)
        let (policy, handler) = state.withLock { ($0.policy, $0.permission) }
        let pick: @Sendable ([String]) -> String? = { kinds in
            for k in kinds { if let o = options.first(where: { $0.kind == k }) { return o.id } }
            return nil
        }
        let answer: @Sendable (PermissionDecision, String) -> Void = { [weak self] decision, reasonType in
            guard let self else { return }
            // Answered once: a cancel that already replied `cancelled` removed the entry.
            guard self.state.withLock({ $0.pendingPermissions.removeValue(forKey: key) }) != nil else { return }
            switch decision {
            case .allow(_, let perms):
                let remember = (perms?.isEmpty == false)
                // A hosted tool the agent may now call: the same call at the server runs without a second ask.
                if record.hostedTool != nil { self.state.withLock { $0.grants[payload.hash, default: 0] += 1 } }
                if let chosen = pick(remember ? ["allow_always", "allow_once"] : ["allow_once", "allow_always"]) {
                    client.respond(request.id, result: ["outcome": ["outcome": "selected", "optionId": .string(chosen)]])
                } else { client.respond(request.id, result: ["outcome": ["outcome": "cancelled"]]) }
            case .deny(let why, _):
                if !id.isEmpty { self.state.withLock { s in s.turn?.refusals[id] = why } }
                self.continuation.yield(.permissionDenied(tool: record.name, toolUseId: id.isEmpty ? nil : id, reasonType: reasonType, reason: why))
                if let chosen = pick(["reject_once", "reject_always"]) {
                    client.respond(request.id, result: ["outcome": ["outcome": "selected", "optionId": .string(chosen)]])
                } else { client.respond(request.id, result: ["outcome": ["outcome": "cancelled"]]) }
            }
        }
        state.withLock { $0.pendingPermissions[key] = PendingPermission(requestId: request.id, task: nil) }
        switch policy?(record.name, record.input) ?? .ask {
        case .allow: answer(.allow(), "policy"); return
        case .deny(let why): answer(.deny(why), "policy"); return
        case .ask: break
        }
        guard let handler else { answer(.deny("no permission handler"), "engine"); return }
        continuation.yield(.permissionRequest(payload))
        let context = PermissionContext(toolUseId: id.isEmpty ? nil : id, suggestions: [], blockedPath: nil, decisionReason: nil,
                                        title: record.title.isEmpty ? nil : record.title, description: record.kind, payload: payload)
        let task = Task {
            let decision = await handler(record.name, record.input, context)
            if Task.isCancelled { return }
            answer(decision, "person")
        }
        state.withLock { s in if s.pendingPermissions[key] != nil { s.pendingPermissions[key]?.task = task } }
    }

    private func childExited(status: Int32, signal: Int32?) {
        stopToolServer()
        let (turn, waiters) = state.withLock { s -> (Turn?, [CheckedContinuation<Void, Never>]) in
            s.exited = status
            let t = s.turn
            let w = s.exitWaiters; s.exitWaiters.removeAll()
            s.pendingPermissions.removeAll()
            return (t, w)
        }
        if let turn {
            turn.task?.cancel()
            finishTurn(turn.number, stopReason: turn.cancelled ? "cancelled" : "error", error: turn.cancelled ? nil : "the agent exited with status \(status) during the turn")
        }
        continuation.yield(.exited(status: status, signal: signal))
        continuation.finish()
        for w in waiters { w.resume() }
    }

    /// True when the child ended within `timeout`.
    private func awaitExit(timeout: TimeInterval) async -> Bool {
        let already = state.withLock { $0.exited != nil }
        if already { return true }
        let waiter = Task { [self] in
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let done = state.withLock { s -> Bool in
                    if s.exited != nil { return true }
                    s.exitWaiters.append(k); return false
                }
                if done { k.resume() }
            }
        }
        return await Self.race(waiter, timeout: timeout)
    }

    /// True when `task` ends within `timeout`; the task is left running otherwise.
    static func race(_ task: Task<Void, Never>, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(max(0, timeout))); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, what: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: .seconds(max(0, seconds))); throw ACPError.timeout(what) }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

/// `ACPEngine` with `Resumable` in front, for an agent that advertises `session/load`: `resume(_:)` names the
/// ACP session id to load at start. Should the live `initialize` answer say otherwise, the start is a fresh
/// session and the stream says so (`system/resume_unavailable`). A wrapper rather than a subclass because a
/// `Sendable` class is final; every other member forwards to `engine`.
public final class ResumableACPEngine: AgentEngine, PermissionGating, ModelSwitching, Resumable, ToolHosting, HostedToolServing, Sendable {
    public let engine: ACPEngine
    public init(options: ACPEngineOptions) { engine = ACPEngine(options: options) }

    public var messages: AsyncStream<Message> { engine.messages }
    public var sessionId: String? { engine.sessionId }
    public var engineVersion: String? { engine.engineVersion }
    public func start() async throws { try await engine.start() }
    public func send(_ prompt: String) async throws { try await engine.send(prompt) }
    public func steer(_ text: String) async throws { try await engine.steer(text) }
    public func steerNow(_ text: String) async throws { try await engine.steerNow(text) }
    public func pause() { engine.pause() }
    public func resume() { engine.resume() }
    public func stop(_ severity: StopSeverity) async { await engine.stop(severity) }
    public func setPolicy(_ policy: PolicyCallback?) throws { try engine.setPolicy(policy) }
    public func setPermissionHandler(_ handler: PermissionCallback?) throws { try engine.setPermissionHandler(handler) }
    public func setQuestionHandler(_ handler: QuestionCallback?) throws { try engine.setQuestionHandler(handler) }
    public var availableModels: [ModelChoice] { engine.availableModels }
    public func setModel(_ model: String?) async throws { try await engine.setModel(model) }
    public func resume(_ reference: String) throws { try engine.setResumeReference(reference) }
    public var hostedTools: [SwiftTool] { engine.hostedTools }
    public func host(_ tools: [SwiftTool], serverName: String) throws { try engine.host(tools, serverName: serverName) }
    public func hostedToolList() -> [JSONValue] { engine.hostedToolList() }
    public func callHostedTool(_ name: String, arguments: [String: JSONValue]) async -> ToolResult { await engine.callHostedTool(name, arguments: arguments) }
}
