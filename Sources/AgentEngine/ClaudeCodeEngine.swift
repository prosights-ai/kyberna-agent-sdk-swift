import Foundation
import AgentProtocol
import AgentSession

/// The Claude Code engine: `AgentEngine` and every capability, each forwarded to `ClaudeSession`. This is the
/// one type outside the `AgentSession` target that knows the CLI (ADR 0015); hosts hold `any AgentEngine`.
/// Capability calls before `start()` edit the session's options through `ClaudeSession.configure`; after start
/// they use the CLI's control requests where one exists.
public final class ClaudeCodeEngine: AgentEngine, ModelSwitching, EffortSetting, ReasoningControl, Resumable,
                                     PermissionGating, HookCapable, ToolHosting, ImageAttaching, ContextReporting,
                                     FileRewinding, RateLimitReporting, Sendable {
    /// The session underneath, for the CLI's own diagnostics (`kyb record`, `kyb probe`, `kyb replay`).
    public let session: ClaudeSession
    public init(options: SessionOptions) { session = ClaudeSession(options: options) }

    /// The options as they stand: what the next start uses, or what the running session was started with.
    public var options: SessionOptions { session.options }
    /// The environment a child of these options receives; see `ClaudeSession.childEnvironment`.
    public static func childEnvironment(options: SessionOptions) -> [String: String] { ClaudeSession.childEnvironment(options: options) }

    // MARK: AgentEngine
    public var messages: AsyncStream<Message> { session.messages }
    public var sessionId: String? { session.sessionId }
    public var engineVersion: String? { session.cliVersion.map { $0.map(String.init).joined(separator: ".") } }
    public func start() async throws { try await session.start() }
    public func send(_ prompt: String) async throws { session.send(prompt) }
    public func steer(_ text: String) async throws { session.steer(text) }
    public func steerNow(_ text: String) async throws { _ = try await session.steerNow(text) }
    public func pause() { session.pause() }
    public func resume() { session.resume() }
    public func stop(_ severity: StopSeverity) async { await session.stop(severity) }

    private func configure(_ operation: String, _ change: (inout SessionOptions) -> Void) throws {
        guard session.configure(change) else { throw EngineError.alreadyStarted(operation: operation) }
    }

    // MARK: ModelSwitching
    public var availableModels: [ModelChoice] { session.availableModels }
    public func setModel(_ model: String?) async throws {
        if session.isStarted { try await session.setModel(model) } else { try configure("setModel") { $0.model = model } }
    }

    // MARK: EffortSetting
    /// Running: `/effort <level>` as a user message, its own small exchange, awaited so the host's next message is
    /// not queued into it as steering (wire document 9.x, verified on 2.1.271). `nil` sends the CLI's default,
    /// `medium`, since the command has no reset form.
    public func setEffort(_ level: String?) async throws {
        if session.isStarted { _ = await session.sendAndWait("/effort " + (level ?? "medium")) }
        else { try configure("setEffort") { $0.effort = level } }
    }

    // MARK: ReasoningControl
    /// `--thinking` is a launch flag; on a running session nothing changes and false is returned.
    public func setThinking(_ thinking: ThinkingOption?) async throws -> Bool {
        session.configure { $0.thinking = thinking }
    }
    public func setReasoningDisplay(_ display: ReasoningDisplay) throws {
        try configure("setReasoningDisplay") { $0.thinkingDisplay = display.rawValue }
    }

    // MARK: Resumable
    public func resume(_ reference: String) throws { try configure("resume") { $0.resume = reference } }

    // MARK: PermissionGating
    public func setPolicy(_ policy: PolicyCallback?) throws { try configure("setPolicy") { $0.policy = policy } }
    public func setPermissionHandler(_ handler: PermissionCallback?) throws { try configure("setPermissionHandler") { $0.canUseTool = handler } }
    public func setQuestionHandler(_ handler: QuestionCallback?) throws { try configure("setQuestionHandler") { $0.askUserQuestion = handler } }

    // MARK: HookCapable
    public func addHook(_ event: HookEvent, _ matcher: HookMatcher) throws {
        try configure("addHook") { $0.hooks[event, default: []].append(matcher) }
    }

    // MARK: ToolHosting
    public var hostedTools: [SwiftTool] { session.options.swiftTools }
    public func host(_ tools: [SwiftTool], serverName: String) throws {
        try configure("host") { $0.swiftTools += tools; $0.serverName = serverName }
    }

    // MARK: ImageAttaching
    public func send(_ text: String, images: [ImageAttachment]) async throws {
        var blocks: [JSONValue] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
        blocks += images.map { ClaudeSession.imageBlock(base64: $0.base64, mediaType: $0.mediaType) }
        session.send(blocks: blocks)
    }

    // MARK: ContextReporting, FileRewinding
    public func contextUsage() async throws -> ContextUsage { try await session.contextUsage() }
    public func rewindFiles(toUserMessageId id: String) async throws { try await session.rewindFiles(toUserMessageId: id) }
}
