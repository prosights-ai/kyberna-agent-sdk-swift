import Foundation

/// Why the CLI could not start, carried as `startup_failure_reason` on the result message (TypeScript SDK
/// 0.3.274, `SDKStartupFailureReason`, `sdk.d.ts` line 5561). `unknown` keeps a value the CLI adds later
/// decodable instead of failing the frame.
public enum StartupFailureReason: Sendable, Equatable, Hashable, RawRepresentable, Codable {
    case orgPinAPIKeyConflict
    case orgVerifyFailed
    case orgPinMismatch
    case managedSettingsInvalid
    case remoteSettingsRequiredUnavailable
    case gatewaySigninRequired
    case gatewayAccessDenied
    case proxyInvalid
    case tempDirUnusable
    case cwdUnavailable
    case shellToolMissing
    case sessionHeldByBackground
    case worktreeResumeRefused
    case worktreeUnverified
    case cliVersionTooOld
    case bypassRoot
    case unknown(String)

    private static let known: [String: StartupFailureReason] = [
        "org_pin_api_key_conflict": .orgPinAPIKeyConflict,
        "org_verify_failed": .orgVerifyFailed,
        "org_pin_mismatch": .orgPinMismatch,
        "managed_settings_invalid": .managedSettingsInvalid,
        "remote_settings_required_unavailable": .remoteSettingsRequiredUnavailable,
        "gateway_signin_required": .gatewaySigninRequired,
        "gateway_access_denied": .gatewayAccessDenied,
        "proxy_invalid": .proxyInvalid,
        "temp_dir_unusable": .tempDirUnusable,
        "cwd_unavailable": .cwdUnavailable,
        "shell_tool_missing": .shellToolMissing,
        "session_held_by_background": .sessionHeldByBackground,
        "worktree_resume_refused": .worktreeResumeRefused,
        "worktree_unverified": .worktreeUnverified,
        "cli_version_too_old": .cliVersionTooOld,
        "bypass_root": .bypassRoot,
    ]

    public init(rawValue: String) { self = Self.known[rawValue] ?? .unknown(rawValue) }

    // Written as a switch, not a reverse lookup: `RawRepresentable`'s own `==` compares raw values, so a
    // comparison here would recurse.
    public var rawValue: String {
        switch self {
        case .orgPinAPIKeyConflict: return "org_pin_api_key_conflict"
        case .orgVerifyFailed: return "org_verify_failed"
        case .orgPinMismatch: return "org_pin_mismatch"
        case .managedSettingsInvalid: return "managed_settings_invalid"
        case .remoteSettingsRequiredUnavailable: return "remote_settings_required_unavailable"
        case .gatewaySigninRequired: return "gateway_signin_required"
        case .gatewayAccessDenied: return "gateway_access_denied"
        case .proxyInvalid: return "proxy_invalid"
        case .tempDirUnusable: return "temp_dir_unusable"
        case .cwdUnavailable: return "cwd_unavailable"
        case .shellToolMissing: return "shell_tool_missing"
        case .sessionHeldByBackground: return "session_held_by_background"
        case .worktreeResumeRefused: return "worktree_resume_refused"
        case .worktreeUnverified: return "worktree_unverified"
        case .cliVersionTooOld: return "cli_version_too_old"
        case .bypassRoot: return "bypass_root"
        case .unknown(let s): return s
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

/// Why a background task stopped, carried as `reason` on `system`/`task_notification` (TypeScript SDK 0.3.273
/// added `worker_restart`: the task was stopped by a worker-process restart, not by the task or the person).
/// `unknown` keeps a later value decodable.
public enum TaskNotificationReason: Sendable, Equatable, Hashable, RawRepresentable, Codable {
    case workerRestart
    case unknown(String)

    public init(rawValue: String) { self = rawValue == "worker_restart" ? .workerRestart : .unknown(rawValue) }
    public var rawValue: String { if case .unknown(let s) = self { return s }; return "worker_restart" }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

/// One entry of the `commands` array in the `initialize` control response (§3.4). `builtin` arrived in
/// TypeScript SDK 0.3.277 (`SlashCommand.builtin`, `sdk.d.ts` line 8941): true only for Claude Code's own
/// command, so a same-named user, project, plugin, or MCP command is told apart from it.
public struct SlashCommand: Sendable, Equatable, Codable {
    public var name: String
    public var description: String?
    public var argumentHint: String?
    public var builtin: Bool?

    public init(name: String, description: String? = nil, argumentHint: String? = nil, builtin: Bool? = nil) {
        self.name = name; self.description = description; self.argumentHint = argumentHint; self.builtin = builtin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        argumentHint = try c.decodeIfPresent(String.self, forKey: .argumentHint)
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin)
    }

    public init?(wire json: JSONValue?) {
        guard let name = json?["name"]?.stringValue else { return nil }
        self.init(name: name, description: json?["description"]?.stringValue,
                  argumentHint: json?["argumentHint"]?.stringValue, builtin: json?["builtin"]?.boolValue)
    }
}

/// `system`/`init`, decoded with the wire's own key names. Every field is optional or defaulted so a fixture
/// recorded before a field existed still decodes; unknown keys are ignored.
public struct SystemInit: Sendable, Equatable, Codable {
    public var sessionId: String
    public var cwd: String?
    public var model: String?
    public var permissionMode: String?
    public var tools: [String]
    public var mcpServers: [MCPServerStatus]
    public var slashCommands: [String]
    public var claudeCodeVersion: String?
    public var outputStyle: String?
    public var apiKeySource: String?
    /// Per-session scratchpad directory, `/private/tmp/claude-<uid>/<cwd-key>/<session-id>/scratchpad`
    /// (2.1.278; absent in 2.1.270 through 2.1.273). Same path the hook input calls `scratchpad_dir`.
    public var scratchpadPath: String?
    /// Per-phase startup breakdown, emitted only when `CLAUDE_CODE_EMIT_STARTUP_TIMING=1` is in the child's
    /// environment (TypeScript SDK 0.3.274). No recorded fixture carries it and no first-party source states
    /// its phase names, so it stays open JSON.
    public var startupTiming: JSONValue?

    public init(sessionId: String, cwd: String? = nil, model: String? = nil, permissionMode: String? = nil,
                tools: [String] = [], mcpServers: [MCPServerStatus] = [], slashCommands: [String] = [],
                claudeCodeVersion: String? = nil, outputStyle: String? = nil, apiKeySource: String? = nil,
                scratchpadPath: String? = nil, startupTiming: JSONValue? = nil) {
        self.sessionId = sessionId; self.cwd = cwd; self.model = model; self.permissionMode = permissionMode
        self.tools = tools; self.mcpServers = mcpServers; self.slashCommands = slashCommands
        self.claudeCodeVersion = claudeCodeVersion; self.outputStyle = outputStyle; self.apiKeySource = apiKeySource
        self.scratchpadPath = scratchpadPath; self.startupTiming = startupTiming
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, model
        case permissionMode
        case tools
        case mcpServers = "mcp_servers"
        case slashCommands = "slash_commands"
        case claudeCodeVersion = "claude_code_version"
        case outputStyle = "output_style"
        case apiKeySource
        case scratchpadPath = "scratchpad_path"
        case startupTiming = "startup_timing"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        mcpServers = try c.decodeIfPresent([MCPServerStatus].self, forKey: .mcpServers) ?? []
        slashCommands = try c.decodeIfPresent([String].self, forKey: .slashCommands) ?? []
        claudeCodeVersion = try c.decodeIfPresent(String.self, forKey: .claudeCodeVersion)
        outputStyle = try c.decodeIfPresent(String.self, forKey: .outputStyle)
        apiKeySource = try c.decodeIfPresent(String.self, forKey: .apiKeySource)
        scratchpadPath = try c.decodeIfPresent(String.self, forKey: .scratchpadPath)
        startupTiming = try c.decodeIfPresent(JSONValue.self, forKey: .startupTiming)
    }
}
