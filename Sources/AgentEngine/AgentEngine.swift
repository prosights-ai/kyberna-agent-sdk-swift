import Foundation
import AgentProtocol
import AgentSession

/// What every engine provides to a host: a message stream, a session id once it has one, and the turn controls.
/// `ClaudeCodeEngine` wraps `ClaudeSession`; a direct-API engine and a local-model engine follow (ADR 0015).
///
/// ## Capabilities
///
/// Everything a host may want beyond this core is an optional capability: a small protocol that refines
/// `AgentEngine` and that an engine adopts when it can honour it. A host discovers one with a cast,
/// `engine as? ModelSwitching`, and takes the capability's documented fallback when the cast fails. The
/// capabilities are `ModelSwitching`, `EffortSetting`, `ReasoningControl`, `Resumable`, `PermissionGating`,
/// `HookCapable`, `ToolHosting`, `ImageAttaching`, `ContextReporting`, `FileRewinding` and `RateLimitReporting`;
/// each states its fallback in its own doc comment.
///
/// Why protocols rather than an `EngineCapabilities` option set with optional methods: the compiler checks a
/// conformance, so an engine cannot claim a capability it does not implement and a flag cannot drift from the
/// method behind it; each protocol carries its own typed signatures (`ModelChoice`, `ContextUsage`,
/// `ImageAttachment` are `Codable` wire-shaped values, not `JSONValue` bags); adding a capability later is
/// additive for both engines and hosts; and the cast is the idiomatic Swift discovery step, needing no registry.
///
/// Timing rule: a capability method that shapes the start (`resume`, the permission handlers, hooks, hosted
/// tools, reasoning display) is called before `start()` and throws `EngineError.alreadyStarted` afterwards. The
/// methods that also switch a running engine (`setModel`, `setEffort`, `setThinking`) work before and after
/// start: before, they set what the session opens with; after, they apply to the turns that follow.
public protocol AgentEngine: AnyObject, Sendable {
    var messages: AsyncStream<Message> { get }
    var sessionId: String? { get }
    /// The engine's own version, for logs and transcripts (the CLI's `claude --version`); nil when it has none.
    var engineVersion: String? { get }
    func start() async throws
    func send(_ prompt: String) async throws
    func steer(_ text: String) async throws
    /// Stop the running tool and turn, then deliver `text` as the next turn.
    func steerNow(_ text: String) async throws
    func pause()
    func resume()
    func stop(_ severity: StopSeverity) async
}

public extension AgentEngine {
    var engineVersion: String? { nil }
}

/// Thrown by capability methods that are called at the wrong time.
public enum EngineError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The operation shapes the start and the engine has already started.
    case alreadyStarted(operation: String)
    /// The operation needs a running engine and the engine has not started.
    case notStarted(operation: String)
    public var description: String {
        switch self {
        case .alreadyStarted(let op): return "\(op) must be called before the engine starts"
        case .notStarted(let op): return "\(op) needs a started engine"
        }
    }
}

// MARK: - Capabilities

/// The engine can change models. Before start, `setModel` chooses the model the session opens on; after start it
/// applies to the turns that follow (the CLI's `set_model` control request). `nil` is the engine's own default.
/// Fallback when absent: the host keeps one model for the engine's lifetime. The Console disables its model
/// picker with a tooltip saying the engine does not switch models; the gateway remembers the choice for the next
/// start and records `system/model_fixed` so the transcript says why the running engine kept its model.
public protocol ModelSwitching: AgentEngine {
    /// What the engine offers this account; empty before start on an engine that learns the list at start.
    var availableModels: [ModelChoice] { get }
    func setModel(_ model: String?) async throws
}

/// The engine has an effort level. Before start it is what the session opens with; after start it applies to
/// the turns that follow and may run as an exchange of its own on the engine (the CLI has no control request for
/// effort and takes `/effort <level>` as a user message; this call returns when that exchange ends). `nil` asks
/// for the engine's default level.
/// Fallback when absent: the effort control is hidden, and a level a profile or channel carries is ignored with
/// `system/effort_fixed` in the transcript.
public protocol EffortSetting: AgentEngine {
    func setEffort(_ level: String?) async throws
}

/// How much the engine shows of the model's reasoning.
public enum ReasoningDisplay: String, Sendable, Codable, CaseIterable {
    case hidden = "none", summarized, full
}

/// The engine has a reasoning budget and a reasoning display. `setThinking` returns false when the running
/// engine can apply the budget only at its next start (the CLI: `--thinking` is a launch flag), so a host knows
/// to say "applies when the engine next starts". `setReasoningDisplay` is a start-time choice.
/// Fallback when absent: the reasoning controls are hidden; whatever the engine shows is rendered as it arrives.
public protocol ReasoningControl: AgentEngine {
    @discardableResult func setThinking(_ thinking: ThinkingOption?) async throws -> Bool
    func setReasoningDisplay(_ display: ReasoningDisplay) throws
}

/// The engine can continue an earlier conversation it kept itself. `reference` is what the engine handed out as
/// `sessionId` before (the CLI also accepts a transcript path). Before start only.
/// Fallback when absent: the host starts a fresh conversation and says so where the person can see it (the
/// Console's transcript note, the gateway's `system/resume_unavailable` event); the earlier log stays readable.
public protocol Resumable: AgentEngine {
    func resume(_ reference: String) throws
}

/// The engine asks the host before it runs a tool: a synchronous policy first, a person second, and it routes the
/// model's own questions to the person. Handlers are set before start.
/// Fallback when absent: the engine runs its tools without asking. The host records `system/permission_gate_absent`
/// once at start; tools the host itself serves through `ToolHosting` are still checked by the host before they run.
public protocol PermissionGating: AgentEngine {
    /// Answered before anyone is asked; `.allow` and `.ask` are its only outcomes.
    func setPolicy(_ policy: PolicyCallback?) throws
    /// Asked when the policy says `.ask` or is absent.
    func setPermissionHandler(_ handler: PermissionCallback?) throws
    /// The model's questions to the person (the `AskUserQuestion` round trip).
    func setQuestionHandler(_ handler: QuestionCallback?) throws
}

/// The engine runs host callbacks at lifecycle points (the CLI's hook protocol: `PreToolUse`, `PostToolUse`,
/// `Stop`, and the rest of `HookEvent`). Before start only.
/// Fallback when absent: a host that gates tools through a `PreToolUse` hook (the gateway's policy engine) folds
/// the same decision into the `PermissionGating` handler when that exists, and otherwise records
/// `system/policy_unenforced` so the transcript says the engine's built-in tools ran unchecked.
public protocol HookCapable: AgentEngine {
    func addHook(_ event: HookEvent, _ matcher: HookMatcher) throws
}

/// The engine serves the host's own `SwiftTool`s to the model, namespaced by `serverName` (the CLI: an in-process
/// MCP server, so the tools appear as `mcp__<serverName>__<tool>`). Before start only.
/// Fallback when absent: the tools are unavailable to that session; the host records `system/tools_unavailable`
/// naming them, and its prompts must not promise them.
public protocol ToolHosting: AgentEngine {
    var hostedTools: [SwiftTool] { get }
    func host(_ tools: [SwiftTool], serverName: String) throws
}

/// An image in a user turn.
public struct ImageAttachment: Sendable, Equatable, Codable {
    /// Base64 of the encoded image bytes.
    public var base64: String
    /// The IANA media type, `image/png` or `image/jpeg`.
    public var mediaType: String
    public init(base64: String, mediaType: String) { self.base64 = base64; self.mediaType = mediaType }
    public init(data: Data, mediaType: String) { self.init(base64: data.base64EncodedString(), mediaType: mediaType) }
}

/// The engine takes images in a user turn.
/// Fallback when absent: the host sends the text alone and tells the person the images were not sent.
public protocol ImageAttaching: AgentEngine {
    func send(_ text: String, images: [ImageAttachment]) async throws
}

/// The engine reports what occupies its context window (the CLI's `get_context_usage`).
/// Fallback when absent: the context gauge is hidden.
public protocol ContextReporting: AgentEngine {
    func contextUsage() async throws -> ContextUsage
}

/// The engine restores files to how they were before a user message (the CLI's `rewind_files`).
/// Fallback when absent: the rewind control is hidden and asking for it produces a transcript note.
public protocol FileRewinding: AgentEngine {
    func rewindFiles(toUserMessageId id: String) async throws
}

/// The engine emits `Message.rateLimit` events carrying its usage meters (the CLI's 5-hour and 7-day windows).
/// A marker: the events arrive on `messages` like any other. Fallback when absent: no meters are shown.
public protocol RateLimitReporting: AgentEngine {}
