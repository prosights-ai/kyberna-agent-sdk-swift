import Foundation
import AgentProtocol
import AgentTransport

public enum StopSeverity: Sendable { case turn, session, kill }

/// Bidirectional session with `claude --input-format stream-json --output-format stream-json`.
/// Replicates the Agent SDK's loop: initialize handshake, user messages over stdin,
/// control_request/control_response for permissions, hooks, and in-process MCP tools.
///
/// `@unchecked Sendable` (one of the SDK's two, see plan 1.5): the session is a single-consumer bridge whose
/// mutable state (waiters, pause flag, ids) is guarded by `lock` via `withLock`; callers on any executor may
/// send, steer, pause, or stop. A host that needs one long-lived owner per session wraps this in an actor.
public final class ClaudeSession: @unchecked Sendable {
    public let options: SessionOptions
    public let messages: AsyncStream<Message>
    public private(set) var sessionId: String?
    public private(set) var initializeResponse: JSONValue = .null
    public private(set) var versionWarning: String?
    public private(set) var cliVersion: [Int]?
    /// The most recent mirror batch, so batches reach the store in order.
    private var mirrorTail: Task<Void, Never>?

    private var transport: CLITransport?
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var inflightRequests: [String: Task<Void, Never>] = [:]
    private var inflightTasks: Set<String> = []
    private var requestCounter = 0
    private var hookCallbacks: [String: HookCallback] = [:]
    private var closeAfterResult = false
    private var started = false
    private var exited = false
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiters: [CheckedContinuation<ResultMessage, Never>] = []
    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var lastActivity = Date()
    private var watchdog: Task<Void, Never>?

    private static let deferringTaskTypes: Set<String> = ["local_agent", "local_workflow"]
    private static let terminalTaskStatuses: Set<String> = ["completed", "failed", "stopped", "killed"]

    public init(options: SessionOptions) {
        self.options = options
        var cont: AsyncStream<Message>.Continuation!
        messages = AsyncStream { cont = $0 }
        messageContinuation = cont
    }

    // MARK: Lifecycle

    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    static func dotted(_ v: [Int]) -> String { v.map(String.init).joined(separator: ".") }

    /// The environment the CLI child receives. Allowlisted inherited keys, the SDK's own markers, the update
    /// blockers, then `options.env` on top. Exposed so hosts and tests can see exactly what the child gets.
    public static func childEnvironment(options: SessionOptions, parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        for k in options.inheritedEnvironmentKeys { if let v = parent[k] { env[k] = v } }
        env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-swift"
        if options.disableUpdates { env["DISABLE_AUTOUPDATER"] = "1"; env["DISABLE_UPDATES"] = "1" }
        if options.enableFileCheckpointing { env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "true" }
        options.env.forEach { env[$0.key] = $0.value }
        return env
    }

    public func start() async throws {
        let was = withLock { let w = started; started = true; return w }
        guard !was else { throw SessionError.alreadyStarted }
        // The CLI refuses both at once, and the SDK says so before a process is spawned.
        if options.sessionStore != nil, options.enableFileCheckpointing {
            withLock { started = false }
            throw SessionError.invalidOptions("a session store and file checkpointing cannot be used together")
        }
        let env = Self.childEnvironment(options: options)
        if !options.skipVersionCheck {
            cliVersion = CLITransport.probeVersion(executable: options.claudePath, environment: env)
            if let v = cliVersion {
                if let allowed = options.allowedClaudeCodeVersions, !allowed.contains(v) {
                    withLock { started = false }
                    throw SessionError.versionMismatch(found: Self.dotted(v), allowed: allowed.map(Self.dotted).joined(separator: ", "))
                }
                if v.lexicographicallyPrecedes(options.minimumClaudeCodeVersion) {
                    versionWarning = "Claude Code \(Self.dotted(v)) is below the minimum \(Self.dotted(options.minimumClaudeCodeVersion))"
                }
            } else {
                if options.allowedClaudeCodeVersions != nil { withLock { started = false }; throw SessionError.versionMismatch(found: "unknown", allowed: "a pinned version") }
                versionWarning = "could not determine Claude Code version at \(options.claudePath)"
            }
        }
        var cfg = CLITransport.Configuration(executable: options.claudePath, arguments: buildArguments(), workingDirectory: options.workingDirectory, environment: env)
        cfg.maxLineBytes = options.maxBufferSize
        cfg.recordDirectory = options.recordDirectory
        cfg.stderr = options.stderr
        let t = CLITransport(configuration: cfg) { [weak self] event in self?.handleTransport(event) }
        transport = t
        try t.start()
        initializeResponse = try await sendControl(buildInitializeRequest(), timeout: options.initializeTimeout)
        // Workspace trust, as the CLI does it: an untrusted directory still runs, but the CLI ignores its
        // .claude/settings.json rules. Tell the host so it can show the trust dialog (see WorkspaceTrust).
        let loadsProject = options.settingSources.map { $0.contains("project") || $0.contains("local") } ?? true
        if loadsProject, WorkspaceTrust().status(of: options.workingDirectory) == .untrusted {
            emit(.system(subtype: "workspace_untrusted", data: ["directory": .string(options.workingDirectory)]))
        }
    }

    /// Sends one user turn and keeps stdin open for more.
    public func send(_ prompt: String) {
        write(["type": "user", "session_id": .string(sessionId ?? ""), "message": ["role": "user", "content": .string(prompt)], "parent_tool_use_id": .null])
        armWatchdog()
    }

    /// A user turn made of content blocks: text plus images (`{"type":"image","source":{"type":"base64",…}}`),
    /// the Agent SDK's user-message shape. Verified on 2.1.271: the model sees the image (fixture `image-paste`).
    public func send(blocks: [JSONValue]) {
        write(["type": "user", "session_id": .string(sessionId ?? ""), "message": ["role": "user", "content": .array(blocks)], "parent_tool_use_id": .null])
        armWatchdog()
    }
    public static func imageBlock(base64: String, mediaType: String) -> JSONValue {
        ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(base64)]]
    }

    /// Emits `.system(subtype: "watchdog")` when a turn produces no output for `turnIdleTimeout` seconds.
    /// The host decides what to do (interrupt, kill, wait); the SDK never acts on its own.
    private func armWatchdog() {
        guard let limit = options.turnIdleTimeout else { return }
        withLock { lastActivity = Date(); watchdog?.cancel() }
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(limit, 5)))
                guard let self else { return }
                let idle = self.withLock { Date().timeIntervalSince(self.lastActivity) }
                if idle >= limit {
                    self.emit(.system(subtype: "watchdog", data: ["idle_seconds": .number(idle.rounded()), "limit_seconds": .number(limit)]))
                    self.withLock { self.lastActivity = Date() }   // report once per idle period
                }
            }
        }
        withLock { watchdog = task }
    }

    /// Adds input while a turn is running. The CLI queues it and delivers it at its next model call,
    /// after the tool that is currently running completes (verified on 2.1.270, probe `probe-steer-mid-turn`).
    public func steer(_ text: String) {
        send(text)
        emit(.steeringQueued(text: text))
    }

    /// Stops the running tool and the current turn, then delivers `text` as the next turn. Use when the
    /// operator's message must take effect now rather than after the current step. Sequence, per the CLI's
    /// `interrupt_cancel_queued_v1` capability: the interrupt discards anything already queued, so the text
    /// is sent only after the interrupted turn's result arrives (which carries `wasInterrupted`).
    /// Returns the result of the new turn.
    @discardableResult
    public func steerNow(_ text: String) async throws -> ResultMessage {
        let interrupted: ResultMessage = await withCheckedContinuation { cont in
            withLock { resultWaiters.append(cont) }
            Task { _ = try? await self.sendControl(["subtype": "interrupt"], timeout: 10) }
        }
        emit(.system(subtype: "steer_interrupted", data: ["was_interrupted": .bool(interrupted.wasInterrupted), "previous_subtype": .string(interrupted.subtype)]))
        return await sendAndWait(text)
    }

    /// Chooses between `steer` and `steerNow` with the session's `steerIntent` classifier (default: queue).
    @discardableResult
    public func steer(_ text: String, mode: SteerMode) async throws -> ResultMessage? {
        let resolved: SteerMode
        if case .auto = mode { resolved = options.steerIntent?(text) ?? .queue } else { resolved = mode }
        switch resolved {
        case .queue, .auto: steer(text); return nil
        case .interrupt: return try await steerNow(text)
        }
    }

    /// One-shot, like the SDK's `query(prompt=str)`: sends the prompt and ends input the way the SDK does.
    @discardableResult
    public func query(_ prompt: String) async throws -> ResultMessage {
        let s = withLock { started }
        if !s { try await start() }
        let result: ResultMessage = await withCheckedContinuation { cont in
            withLock { resultWaiters.append(cont) }
            send(prompt)
            if options.hasBidirectionalNeeds { withLock { closeAfterResult = true } } else { close() }
        }
        if result.isAuthenticationFailure { throw SessionError.authenticationFailed(result.result ?? "") }
        if let _ = result.errorText { throw SessionError.runFailed(result) }
        return result
    }

    /// Sends a prompt and waits for the result of that turn (the waiter is registered before the send, so a fast
    /// result cannot be missed). Use this in place of `send` + `nextResult` when you need the result.
    public func sendAndWait(_ prompt: String) async -> ResultMessage {
        await withCheckedContinuation { cont in
            withLock { resultWaiters.append(cont) }
            send(prompt)
        }
    }

    /// Waits for the next result message without consuming `messages`. Register before triggering the turn.
    public func nextResult() async -> ResultMessage {
        await withCheckedContinuation { cont in withLock { resultWaiters.append(cont) } }
    }

    // MARK: Pause, stop

    /// Soft pause: the next permission, hook, or tool request from the CLI is held unanswered until `resume()`.
    /// The CLI blocks on it; nothing is lost and the process stays alive.
    public func pause() { lock.lock(); paused = true; lock.unlock() }
    public func resume() {
        lock.lock(); paused = false; let w = pauseWaiters; pauseWaiters.removeAll(); lock.unlock()
        w.forEach { $0.resume() }
    }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    private func waitIfPaused() async {
        guard withLock({ paused }) else { return }
        await withCheckedContinuation { cont in
            let stillPaused = withLock { () -> Bool in if paused { pauseWaiters.append(cont); return true }; return false }
            if !stillPaused { cont.resume() }
        }
    }

    /// `.turn`: interrupt control request, the turn ends cleanly. `.session`: close stdin, SIGTERM after `grace`
    /// (CLI exits 143, unfinished turn resumes later). `.kill`: SIGKILL the process and its descendants.
    public func stop(_ severity: StopSeverity, grace: TimeInterval = 5) async {
        switch severity {
        case .turn: _ = try? await sendControl(["subtype": "interrupt"], timeout: 10)
        case .session:
            close()
            let deadline = Date().addingTimeInterval(grace)
            while transport?.isRunning == true && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if transport?.isRunning == true { transport?.terminate() }
        case .kill: transport?.kill()
        }
    }

    public func interrupt() async throws { _ = try await sendControl(["subtype": "interrupt"]) }
    public func setPermissionMode(_ mode: String) async throws { _ = try await sendControl(["subtype": "set_permission_mode", "mode": .string(mode)]) }
    public func setModel(_ model: String?) async throws { _ = try await sendControl(["subtype": "set_model", "model": model.map { .string($0) } ?? .null]) }
    public func mcpStatus() async throws -> JSONValue { try await sendControl(["subtype": "mcp_status"]) }
    /// What occupies the context window now (same numbers as `/context`). Works right after `start()`, before
    /// any turn, without an API call, so hosts can measure what a profile loads.
    public func contextUsage() async throws -> ContextUsage { ContextUsage(try await sendControl(["subtype": "get_context_usage"])) }
    public func rewindFiles(toUserMessageId id: String) async throws { _ = try await sendControl(["subtype": "rewind_files", "user_message_id": .string(id)]) }
    public func stopTask(_ taskId: String) async throws { _ = try await sendControl(["subtype": "stop_task", "task_id": .string(taskId)]) }
    public func reconnectMcpServer(_ name: String) async throws {
        guard name != options.serverName else { throw SessionError.control("'\(name)' is the in-process server; the CLI cannot reconnect it") }
        _ = try await sendControl(["subtype": "mcp_reconnect", "serverName": .string(name)])
    }
    public func toggleMcpServer(_ name: String, enabled: Bool) async throws {
        guard name != options.serverName else { throw SessionError.control("'\(name)' is the in-process server; the CLI cannot toggle it") }
        _ = try await sendControl(["subtype": "mcp_toggle", "serverName": .string(name), "enabled": .bool(enabled)])
    }

    public var availableCommands: [JSONValue] { initializeResponse["commands"]?.arrayValue ?? [] }
    /// The models the CLI offers this account, from the initialize response; empty before `start()`.
    public var availableModels: [ModelChoice] { (initializeResponse["models"]?.arrayValue ?? []).compactMap(ModelChoice.init) }
    public var outputStyle: String? { initializeResponse["output_style"]?.stringValue }

    /// Closes stdin; the CLI finishes in-flight work and exits.
    public func close() { transport?.closeInput() }

}

// MARK: Argument and initialize construction (mirrors _build_command / initialize)
extension ClaudeSession {

    /// The exact argument list this session passes to the CLI (public so hosts and tests can compare it to fixtures).
    public func buildArguments() -> [String] {
        var a = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]
        a += promptAndToolArguments() + modelArguments() + sessionArguments() + configArguments()
        a += options.extraArgs
        return a
    }

    private func promptAndToolArguments() -> [String] {
        let o = options; var a: [String] = []
        switch o.systemPrompt {
        case .claudeCodeDefault: break
        case .replace(let s): a += ["--system-prompt", s]
        case .append(let s): a += ["--append-system-prompt", s]
        }
        if let tools = o.tools { a += ["--tools", tools.joined(separator: ",")] }
        if !o.allowedTools.isEmpty { a += ["--allowedTools", o.allowedTools.joined(separator: ",")] }
        if !o.disallowedTools.isEmpty { a += ["--disallowedTools", o.disallowedTools.joined(separator: ",")] }
        if let n = o.maxTurns { a += ["--max-turns", String(n)] }
        if let b = o.maxBudgetUSD { a += ["--max-budget-usd", String(b)] }
        return a
    }

    private func modelArguments() -> [String] {
        let o = options; var a: [String] = []
        if let m = o.model { a += ["--model", m] }
        if let m = o.fallbackModel { a += ["--fallback-model", m] }
        if let e = o.effort { a += ["--effort", e] }
        switch o.thinking {
        case .adaptive?: a += ["--thinking", "adaptive"]
        case .budget(let n)?: a += ["--max-thinking-tokens", String(n)]
        case .disabled?: a += ["--thinking", "disabled"]
        case nil: break
        }
        if let schema = o.jsonSchema { a += ["--json-schema", schema.canonicalJSON] }
        if o.includePartialMessages { a.append("--include-partial-messages") }
        if let t = o.thinkingDisplay { a += ["--thinking-display", t] }
        return a
    }

    private func sessionArguments() -> [String] {
        let o = options; var a: [String] = []
        if o.canUseTool != nil || o.askUserQuestion != nil { a += ["--permission-prompt-tool", "stdio"] }
        if let mode = o.permissionMode { a += ["--permission-mode", mode] }
        if o.continueConversation { a.append("--continue") }
        if let r = o.resume { a.append("--resume=\(r)") }
        if let s = o.sessionId { a.append("--session-id=\(s)") }
        if o.forkSession { a.append("--fork-session") }
        if let at = o.resumeSessionAt { a.append("--resume-session-at=\(at)") }
        if let drop = o.resumeDropsTurn { a.append("--resume-drops-turn=\(drop)") }
        if o.replayUserMessages { a.append("--replay-user-messages") }
        if !o.persistSession { a.append("--no-session-persistence") }
        return a
    }

    private func configArguments() -> [String] {
        let o = options; var a: [String] = []
        if let s = o.settingsJSON { a += ["--settings", s] } else if let s = o.settings, !s.isEmpty { a += ["--settings", s.encoded] }
        if o.sessionStore != nil { a += ["--session-mirror"] }
        for d in o.addDirs { a += ["--add-dir", d] }
        if !o.swiftTools.isEmpty {
            let mcp: JSONValue = ["mcpServers": .object([o.serverName: ["type": "sdk", "name": .string(o.serverName)]])]
            a += ["--mcp-config", mcp.canonicalJSON]
        }
        if o.strictMcpConfig { a.append("--strict-mcp-config") }
        if let s = o.settingSources { a.append("--setting-sources=\(s.joined(separator: ","))") }
        for p in o.pluginDirs { a += ["--plugin-dir", p] }
        return a
    }

    private func buildInitializeRequest() -> JSONValue {
        var hooksConfig: [String: JSONValue] = [:]
        var counter = 0
        for event in HookEvent.allCases {
            guard let matchers = options.hooks[event] else { continue }
            var list: [JSONValue] = []
            for m in matchers {
                var ids: [JSONValue] = []
                for cb in m.hooks { let id = "hook_\(counter)"; counter += 1; hookCallbacks[id] = cb; ids.append(.string(id)) }
                var entry: [String: JSONValue] = ["matcher": m.matcher.map { .string($0) } ?? .null, "hookCallbackIds": .array(ids)]
                if let t = m.timeout { entry["timeout"] = .number(Double(t)) }
                list.append(.object(entry))
            }
            hooksConfig[event.rawValue] = .array(list)
        }
        var req: [String: JSONValue] = ["subtype": "initialize", "hooks": hooksConfig.isEmpty ? .null : .object(hooksConfig)]
        if let agents = options.agents { req["agents"] = agents }
        if let skills = options.skills { req["skills"] = .array(skills.map { .string($0) }) }
        return .object(req)
    }

}

// MARK: Transport events
extension ClaudeSession {

    private func write(_ obj: JSONValue) {
        transport?.write(Data(obj.canonicalJSON.utf8))
    }

    private func handleTransport(_ event: CLITransport.Event) {
        switch event {
        case .line(let data):
            guard let any = try? JSONSerialization.jsonObject(with: data) else { return }
            route(JSONValue(any: any))
        case .overflow(let bytes, let limit):
            emit(.system(subtype: "buffer_overflow", data: ["bytes": .number(Double(bytes)), "limit": .number(Double(limit))]))
        case .exited(let status, let signal):
            lock.lock(); exited = true; lock.unlock()
            failAllPending("claude exited with status \(status)")
            // A mirror batch handed over just before the process ended still has to reach the store, and a
            // `mirror_error` has to reach the consumer, so the stream ends after that work settles.
            let pending = withLock { mirrorTail }
            if let pending {
                Task { [weak self] in
                    await pending.value
                    self?.emit(.exited(status: status, signal: signal))
                    self?.messageContinuation?.finish()
                }
            } else {
                emit(.exited(status: status, signal: signal))
                messageContinuation?.finish()
            }
        }
    }

    private func route(_ msg: JSONValue) {
        let type = msg["type"]?.stringValue
        if routeControl(type, msg) { return }
        // A mirrored transcript batch belongs to the store, not to the consumer (engine enhancement 14).
        if type == "transcript_mirror" { mirror(msg); return }
        switch type {
        case "system":
            if let m = parseSystem(msg) { emit(m) }
        case "assistant": emit(.assistant(parseAssistant(msg)))
        case "user": emit(.user(parseUser(msg)))
        case "stream_event": emit(.streamEvent(event: msg["event"] ?? .null, parentToolUseId: msg["parent_tool_use_id"]?.stringValue))
        case "rate_limit_event": emit(.rateLimit(info: msg["rate_limit_info"] ?? .null))
        case "conversation_reset": emit(.conversationReset(newConversationId: msg["new_conversation_id"]?.stringValue ?? ""))
        case "result": routeResult(parseResult(msg))
        default: break
        }
    }

    /// Hands a `transcript_mirror` batch to the store, in order, retrying a failure a few times before saying
    /// so with a `mirror_error` system message. Mirroring never blocks the session or fails a turn.
    private func mirror(_ msg: JSONValue) {
        guard let store = options.sessionStore,
              let path = msg["filePath"]?.stringValue,
              let key = SessionStoreKey(mirrorPath: path) else { return }
        let entries = msg["entries"]?.arrayValue ?? []
        guard !entries.isEmpty else { return }
        let attempts = max(1, options.sessionMirrorAttempts)
        let previous = withLock { let t = mirrorTail; mirrorTail = nil; return t }
        let task = Task { [weak self] in
            await previous?.value                       // keep batches in the order the CLI wrote them
            var lastError: Error?
            for attempt in 1...attempts {
                do { try await store.append(entries, for: key); return } catch {
                    lastError = error
                    if attempt < attempts { try? await Task.sleep(for: .milliseconds(200 * attempt)) }
                }
            }
            guard let self, let lastError else { return }
            self.emit(.system(subtype: "mirror_error", data: ["path": .string(path),
                                                              "entries": .number(Double(entries.count)),
                                                              "error": .string(String(describing: lastError))]))
        }
        withLock { mirrorTail = task }
    }

    /// Waits for every mirror batch handed over so far, so a caller can be sure the store has them.
    public func flushMirror() async { await withLock { mirrorTail }?.value }

    private func routeResult(_ r: ResultMessage) {
        sessionId = r.sessionId
        emit(.result(r))
        lock.lock()
        let shouldClose = closeAfterResult && inflightTasks.isEmpty
        let waiters = resultWaiters; resultWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: r) }
        if shouldClose { close() }
    }

    /// Control-channel lines; returns false for everything else.
    private func routeControl(_ type: String?, _ msg: JSONValue) -> Bool {
        switch type {
        case "control_response":
            let r = msg["response"] ?? .null
            guard let id = r["request_id"]?.stringValue, let cont = takePending(id) else { return true }
            if r["subtype"]?.stringValue == "error" { cont.resume(throwing: SessionError.control(r["error"]?.stringValue ?? "unknown")) } else { cont.resume(returning: r["response"] ?? .object([:])) }
        case "control_request":
            let id = msg["request_id"]?.stringValue ?? ""
            let task = Task { await self.handleControlRequest(msg) }
            lock.lock(); inflightRequests[id] = task; lock.unlock()
        case "control_cancel_request":
            if let id = msg["request_id"]?.stringValue { lock.lock(); let t = inflightRequests.removeValue(forKey: id); lock.unlock(); t?.cancel() }
        default: return false
        }
        return true
    }

    private func emit(_ m: Message) {
        withLock { lastActivity = Date() }
        if case .result = m { withLock { watchdog?.cancel(); watchdog = nil } }
        messageContinuation?.yield(m)
    }

}

// MARK: Parsers
extension ClaudeSession {

    private func parseBlocks(_ raw: JSONValue?) -> [ContentBlock] {
        (raw?.arrayValue ?? []).compactMap { b in
            switch b["type"]?.stringValue {
            case "text": return .text(b["text"]?.stringValue ?? "")
            case "thinking": return .thinking(b["thinking"]?.stringValue ?? "")
            case "tool_use": return .toolUse(id: b["id"]?.stringValue ?? "", name: b["name"]?.stringValue ?? "", input: b["input"] ?? .object([:]))
            case "tool_result": return .toolResult(toolUseId: b["tool_use_id"]?.stringValue ?? "", content: b["content"] ?? .null, isError: b["is_error"]?.boolValue ?? false)
            case "server_tool_use": return .serverToolUse(id: b["id"]?.stringValue ?? "", name: b["name"]?.stringValue ?? "", input: b["input"] ?? .object([:]))
            case "advisor_tool_result": return .serverToolResult(toolUseId: b["tool_use_id"]?.stringValue ?? "", content: b["content"] ?? .null)
            default: return nil
            }
        }
    }
    private func parseAssistant(_ d: JSONValue) -> AssistantMessage {
        let m = d["message"] ?? .null
        return AssistantMessage(uuid: d["uuid"]?.stringValue, content: parseBlocks(m["content"]), model: m["model"]?.stringValue ?? "",
                                stopReason: m["stop_reason"]?.stringValue, usage: m["usage"], parentToolUseId: d["parent_tool_use_id"]?.stringValue,
                                wireToolInputs: d["wire_tool_inputs"]?.objectValue)
    }
    private func parseUser(_ d: JSONValue) -> UserMessage {
        let m = d["message"] ?? .null
        let blocks: [ContentBlock] = m["content"]?.stringValue.map { [.text($0)] } ?? parseBlocks(m["content"])
        return UserMessage(uuid: d["uuid"]?.stringValue, content: blocks, parentToolUseId: d["parent_tool_use_id"]?.stringValue)
    }
    private func parseSystem(_ d: JSONValue) -> Message? {
        let subtype = d["subtype"]?.stringValue ?? ""
        let taskId = d["task_id"]?.stringValue
        if let taskId {
            lock.lock()
            switch subtype {
            case "task_started" where Self.deferringTaskTypes.contains(d["task_type"]?.stringValue ?? ""): inflightTasks.insert(taskId)
            case "task_notification": inflightTasks.remove(taskId)
            case "task_updated": if let st = d["patch"]?["status"]?.stringValue, Self.terminalTaskStatuses.contains(st) { inflightTasks.remove(taskId) }
            default: break
            }
            lock.unlock()
        }
        switch subtype {
        case "init":
            sessionId = d["session_id"]?.stringValue
            return .initialized(sessionId: sessionId ?? "", model: d["model"]?.stringValue ?? "", tools: d["tools"]?.arrayValue?.compactMap { $0.stringValue } ?? [], data: d)
        case "task_started": return .taskStarted(taskId: taskId ?? "", description: d["description"]?.stringValue ?? "", taskType: d["task_type"]?.stringValue)
        case "task_progress": return .taskProgress(taskId: taskId ?? "", description: d["description"]?.stringValue ?? "", lastToolName: d["last_tool_name"]?.stringValue)
        case "task_notification": return .taskNotification(taskId: taskId ?? "", status: d["status"]?.stringValue ?? "", summary: d["summary"]?.stringValue ?? "")
        case "task_updated": return .taskUpdated(taskId: taskId ?? "", status: d["patch"]?["status"]?.stringValue)
        case "permission_denied":
            return .permissionDenied(tool: d["tool_name"]?.stringValue ?? "", toolUseId: d["tool_use_id"]?.stringValue,
                                     reasonType: d["decision_reason_type"]?.stringValue, reason: d["decision_reason"]?.stringValue ?? d["message"]?.stringValue ?? "")
        case "hook_started", "hook_response":
            let name = (d["hook_event"] ?? d["hook_name"] ?? d["hook_event_name"])?.stringValue ?? ""
            return .hookEvent(subtype: subtype, hookEventName: name, data: d)
        default: return .system(subtype: subtype, data: d)
        }
    }
    private func parseResult(_ d: JSONValue) -> ResultMessage {
        let deferred = d["deferred_tool_use"].flatMap { v -> DeferredToolUse? in
            guard let id = v["id"]?.stringValue, let name = v["name"]?.stringValue else { return nil }
            return DeferredToolUse(id: id, name: name, input: v["input"] ?? .object([:]))
        }
        return ResultMessage(subtype: d["subtype"]?.stringValue ?? "", isError: d["is_error"]?.boolValue ?? false,
                             durationMs: d["duration_ms"]?.intValue ?? 0, durationApiMs: d["duration_api_ms"]?.intValue ?? 0,
                             numTurns: d["num_turns"]?.intValue ?? 0, sessionId: d["session_id"]?.stringValue ?? "", uuid: d["uuid"]?.stringValue,
                             stopReason: d["stop_reason"]?.stringValue, totalCostUSD: d["total_cost_usd"]?.doubleValue, usage: d["usage"],
                             result: d["result"]?.stringValue, structuredOutput: d["structured_output"], modelUsage: d["modelUsage"],
                             permissionDenials: d["permission_denials"]?.arrayValue, deferredToolUse: deferred,
                             errors: d["errors"]?.arrayValue?.compactMap { $0.stringValue }, apiErrorStatus: d["api_error_status"]?.intValue,
                             terminalReason: d["terminal_reason"]?.stringValue)
    }

}

// MARK: Outgoing control requests (app -> CLI)
extension ClaudeSession {

    private func sendControl(_ request: JSONValue, timeout: TimeInterval = 60) async throws -> JSONValue {
        let (id, gone) = withLock { () -> (String, Bool) in requestCounter += 1; return ("req_\(requestCounter)_\(UUID().uuidString.prefix(8))", exited) }
        if gone { throw SessionError.processExited(status: -1) }
        return try await withCheckedThrowingContinuation { cont in
            withLock { pending[id] = cont }
            write(["type": "control_request", "request_id": .string(id), "request": request])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.takePending(id)?.resume(throwing: SessionError.control("timeout: \(request["subtype"]?.stringValue ?? "")"))
            }
        }
    }
    private func takePending(_ id: String) -> CheckedContinuation<JSONValue, Error>? { lock.lock(); defer { lock.unlock() }; return pending.removeValue(forKey: id) }
    private func failAllPending(_ reason: String) {
        lock.lock(); let all = pending; pending.removeAll(); let rw = resultWaiters; resultWaiters.removeAll(); lock.unlock()
        all.values.forEach { $0.resume(throwing: SessionError.control(reason)) }
        rw.forEach { $0.resume(returning: ResultMessage(subtype: "error_process_exited", isError: true, sessionId: sessionId ?? "", errors: [reason])) }
    }

}

// MARK: Incoming control requests (CLI -> app)
extension ClaudeSession {

    private func handleControlRequest(_ msg: JSONValue) async {
        let id = msg["request_id"]?.stringValue ?? ""
        defer { withLock { _ = inflightRequests.removeValue(forKey: id) } }
        let req = msg["request"] ?? .null
        await waitIfPaused()
        var response: JSONValue = .object([:])
        var errorText: String?
        switch req["subtype"]?.stringValue {
        case "can_use_tool":
            let tool = req["tool_name"]?.stringValue ?? ""
            let input = req["input"] ?? .object([:])
            let payload = ApprovalPayload(tool: tool, input: input, toolUseId: req["tool_use_id"]?.stringValue)
            if tool == "AskUserQuestion", let ask = options.askUserQuestion {
                let questions = (input["questions"]?.arrayValue ?? []).map { q in
                    AskQuestion(question: q["question"]?.stringValue ?? "", header: q["header"]?.stringValue ?? "",
                                options: (q["options"]?.arrayValue ?? []).map { .init(label: $0["label"]?.stringValue ?? "", description: $0["description"]?.stringValue ?? "") },
                                multiSelect: q["multiSelect"]?.boolValue ?? false)
                }
                let answers = await ask(questions)
                response = ["behavior": "allow", "updatedInput": ["questions": input["questions"] ?? .array([]), "answers": .object(answers)]]
            } else {
                // Policy first; only `.ask` reaches a person.
                var decision: PermissionDecision?
                switch options.policy?(tool, input) ?? .ask {
                case .allow: decision = .allow()
                case .deny(let why): decision = .deny(why)
                case .ask: break
                }
                if decision == nil {
                    emit(.permissionRequest(payload))
                    let ctx = PermissionContext(toolUseId: req["tool_use_id"]?.stringValue, suggestions: req["permission_suggestions"]?.arrayValue ?? [],
                                                blockedPath: req["blocked_path"]?.stringValue, decisionReason: req["decision_reason"]?.stringValue,
                                                title: req["title"]?.stringValue, description: req["description"]?.stringValue, payload: payload)
                    decision = await options.canUseTool?(tool, input, ctx) ?? .deny("no permission handler")
                }
                switch decision! {
                case .allow(let updated, let perms):
                    var r: [String: JSONValue] = ["behavior": "allow", "updatedInput": updated ?? input]
                    if let perms { r["updatedPermissions"] = .array(perms) }
                    response = .object(r)
                case .deny(let why, let interrupt):
                    var r: [String: JSONValue] = ["behavior": "deny", "message": .string(why)]
                    if interrupt { r["interrupt"] = true }
                    response = .object(r)
                }
            }
        case "hook_callback":
            let cbId = req["callback_id"]?.stringValue ?? ""
            if let cb = hookCallbacks[cbId] { response = await cb(req["input"] ?? .null, req["tool_use_id"]?.stringValue).wire } else { errorText = "No hook callback found for ID: \(cbId)" }
        case "mcp_message":
            response = ["mcp_response": await handleMCP(req["message"] ?? .null)]
        default:
            errorText = "unsupported control request: \(req["subtype"]?.stringValue ?? "")"
        }
        if Task.isCancelled { return }
        if let errorText {
            write(["type": "control_response", "response": ["subtype": "error", "request_id": .string(id), "error": .string(errorText)]])
        } else {
            write(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": response]])
        }
    }

    // MARK: In-process MCP server (JSON-RPC over the control channel)

    private func handleMCP(_ rpc: JSONValue) async -> JSONValue {
        let method = rpc["method"]?.stringValue ?? ""
        let rpcId = rpc["id"] ?? .null
        func ok(_ result: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": rpcId, "result": result] }
        let params = rpc["params"] ?? .object([:])
        switch method {
        case "initialize":
            return ok(["protocolVersion": params["protocolVersion"] ?? "2025-06-18", "capabilities": ["tools": .object([:])],
                       "serverInfo": ["name": .string(options.serverName), "version": "1.0.0"]])
        case "notifications/initialized", "ping": return ok(.object([:]))
        case "tools/list": return ok(["tools": .array(options.swiftTools.map { $0.wire })])
        case "tools/call":
            let name = params["name"]?.stringValue ?? ""
            guard let tool = options.swiftTools.first(where: { $0.name == name }) else { return ok(ToolResult.error("Unknown tool \(name)").wire) }
            do { return ok(try await tool.handler(params["arguments"]?.objectValue ?? [:]).wire) }
            catch is CancellationError { return ok(ToolResult.error("cancelled").wire) }
            catch { return ok(ToolResult.error("\(error)").wire) }
        default:
            return ["jsonrpc": "2.0", "id": rpcId, "error": ["code": -32601, "message": .string("\(method) not supported")]]
        }
    }
}
