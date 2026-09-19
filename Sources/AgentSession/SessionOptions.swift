import Foundation
import AgentProtocol

public enum SystemPrompt: Sendable, Equatable { case claudeCodeDefault, replace(String), append(String) }
/// Who answers permission prompts (`--permission-prompts`). See `SessionOptions.permissionPrompts`.
public enum PermissionPrompts: String, Sendable, Equatable, Codable { case host, none }
public enum ThinkingOption: Sendable, Equatable { case adaptive, budget(Int), disabled }

public typealias PermissionCallback = @Sendable (_ tool: String, _ input: JSONValue, _ context: PermissionContext) async -> PermissionDecision
public typealias PolicyCallback = @Sendable (_ tool: String, _ input: JSONValue) -> PolicyOutcome
public typealias QuestionCallback = @Sendable ([AskQuestion]) async -> [String: JSONValue]

/// How a mid-turn message is delivered. `.queue`: after the current tool (the CLI's default). `.interrupt`: stop
/// the running tool and turn, then deliver. `.auto`: ask `SessionOptions.steerIntent`, falling back to `.queue`.
public enum SteerMode: Sendable, Equatable { case queue, interrupt, auto }

/// Decides whether a steer text demands immediate effect. Hosts supply their own (a UI toggle, a keyword rule,
/// or a model call); `SteerIntent.keywords` is a conservative default that matches explicit stop language only.
public typealias SteerIntentClassifier = @Sendable (String) -> SteerMode

public enum SteerIntent {
    static let stopWords = ["stop", "cancel", "abort", "halt", "kill", "don't", "do not", "wait", "hold on", "never mind", "nevermind", "instead"]
    /// `.interrupt` when the text starts with, or contains as a whole word, an explicit stop phrase; otherwise `.queue`.
    public static let keywords: SteerIntentClassifier = { text in
        let t = text.lowercased()
        for w in stopWords {
            if t.hasPrefix(w) { return .interrupt }
            if t.range(of: "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b", options: .regularExpression) != nil { return .interrupt }
        }
        return .queue
    }
}

/// Mirrors the ClaudeAgentOptions fields that map to CLI flags or the initialize request.
public struct SessionOptions: Sendable {
    public var claudePath = NSHomeDirectory() + "/.local/bin/claude"
    public var workingDirectory: String
    // Tools and permissions
    public var tools: [String]?
    public var allowedTools: [String] = []
    public var disallowedTools: [String] = []
    public var permissionMode: String?
    /// `--permission-prompts host|none` (CLI 2.1.278): who answers a permission prompt. `.none` means nobody: anything
    /// that would prompt is denied at once with a message to the model and `canUseTool` is never called; the
    /// permission mode still decides everything else. nil sends nothing and keeps the CLI's default (host).
    public var permissionPrompts: PermissionPrompts?
    /// Synchronous policy consulted before any human: `.allow`/`.deny` answer immediately, `.ask` reaches `canUseTool`.
    public var policy: PolicyCallback?
    public var canUseTool: PermissionCallback?
    public var askUserQuestion: QuestionCallback?
    /// Used by `steer(_:mode: .auto)`. nil means every auto steer is queued.
    public var steerIntent: SteerIntentClassifier?
    // Prompting and model
    public var systemPrompt: SystemPrompt = .claudeCodeDefault
    /// `--system-prompt-snapshot on|off` (CLI 2.1.278): `true` records the rendered system prompt on the conversation's
    /// first request and reuses it verbatim on every later request and resume until compaction (stable prompt cache);
    /// `false` renders it fresh each request. nil sends nothing (the CLI's default is on where recording is enabled).
    public var systemPromptSnapshot: Bool?
    public var model: String?
    public var fallbackModel: String?
    public var effort: String?
    public var thinking: ThinkingOption?
    public var maxTurns: Int?
    public var maxBudgetUSD: Double?
    public var jsonSchema: JSONValue?
    public var includePartialMessages = false
    /// `--replay-user-messages`: the CLI echoes each user message back on stdout with its uuid, so a UI renders
    /// from one ordered stream and learns the ids `rewindFiles` needs. The desktop app passes it (plan section 13).
    public var replayUserMessages = false
    /// `--thinking-display`: "none", "summarized", or "full". The desktop app passes "summarized".
    public var thinkingDisplay: String?
    // Sessions
    public var resume: String?
    public var resumeSessionAt: String?
    public var resumeDropsTurn: String?
    public var continueConversation = false
    public var forkSession = false
    public var sessionId: String?
    // Environment
    public var addDirs: [String] = []
    public var env: [String: String] = [:]
    /// Raw `--settings` payload. Prefer `settings` (engine enhancement 9); this stays for callers that already
    /// have a JSON string, and wins over `settings` when both are set.
    public var settingsJSON: String?
    /// Typed `--settings` payload: a profile as a value a host can store and diff.
    public var settings: SessionSettings?
    public var settingSources: [String]?
    public var pluginDirs: [String] = []
    public var strictMcpConfig = false
    public var extraArgs: [String] = []
    public var enableFileCheckpointing = false
    /// Engine enhancement 14: mirror this session's transcript to a store as the CLI writes it. Adds
    /// `--session-mirror`; cannot be combined with file checkpointing, which the CLI refuses.
    public var sessionStore: SessionStore?
    /// How many times a failed mirror batch is retried before the session reports `mirror_error`.
    public var sessionMirrorAttempts = 3
    /// false passes `--no-session-persistence`: no transcript is written, so the session cannot be resumed and does
    /// not appear in any sessions list. For tests and probes (the SDK's `persistSession`).
    public var persistSession = true
    // In-process MCP, hooks, agents, skills
    public var swiftTools: [SwiftTool] = []
    public var serverName = "swift"
    public var hooks: [HookEvent: [HookMatcher]] = [:]
    public var agents: JSONValue?
    public var skills: [String]?
    // Transport
    public var initializeTimeout: TimeInterval = 60
    public var stderr: (@Sendable (String) -> Void)?
    public var maxBufferSize = 1024 * 1024
    public var skipVersionCheck = false
    public var recordDirectory: String?
    /// Seconds of silence during a turn after which a `watchdog` system message is emitted. nil disables.
    public var turnIdleTimeout: TimeInterval?
    /// The CLI version the SDK was validated against; older versions produce `versionWarning`.
    public var minimumClaudeCodeVersion: [Int] = [2, 0, 0]
    /// When set, `start()` throws `SessionError.versionMismatch` unless the probed CLI version is in this list.
    /// This is the engine pin: the host fills it from its `engine.lock`. nil keeps the minimum-version warning only.
    public var allowedClaudeCodeVersions: [[Int]]?
    /// Sets `DISABLE_AUTOUPDATER=1` and `DISABLE_UPDATES=1` in the child so the pinned binary never replaces itself.
    public var disableUpdates = true
    /// The child environment is built from this allowlist of inherited variables, never from the whole parent
    /// environment: a desktop-spawned shell carries `ANTHROPIC_BASE_URL` and a dozen `CLAUDE_CODE_*` variables that
    /// would change which account or endpoint the CLI talks to. Add keys here; set values explicitly in `env`.
    public var inheritedEnvironmentKeys: Set<String> = SessionOptions.defaultInheritedKeys
    /// `CLAUDE_CODE_MCP_STARTUP_WAIT_MS`: how long the CLI waits for MCP servers at startup before reporting them.
    public var mcpStartupWaitMs: Int?
    /// `CLAUDE_CODE_EMIT_STARTUP_TIMING=1`: the CLI adds a `startup_timing` breakdown to `system/init` (`SystemInit.startupTiming`).
    public var emitStartupTiming = false
    public static let defaultInheritedKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TZ",
        "SSH_AUTH_SOCK", "XPC_FLAGS", "XPC_SERVICE_NAME", "__CF_USER_TEXT_ENCODING",
    ]

    public init(workingDirectory: String) { self.workingDirectory = workingDirectory }

    public var hasBidirectionalNeeds: Bool { !swiftTools.isEmpty || !hooks.isEmpty || canUseTool != nil || askUserQuestion != nil }
}
