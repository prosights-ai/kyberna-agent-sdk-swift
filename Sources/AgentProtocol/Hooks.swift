import Foundation

public enum HookEvent: String, CaseIterable, Sendable, Codable {
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse", postToolUseFailure = "PostToolUseFailure"
    case userPromptSubmit = "UserPromptSubmit", stop = "Stop", subagentStop = "SubagentStop", subagentStart = "SubagentStart"
    case preCompact = "PreCompact", notification = "Notification", permissionRequest = "PermissionRequest"
    case elicitation = "Elicitation"
}

/// What a hook returns. Field names follow the CLI's hook JSON output.
public struct HookOutput: Sendable, Equatable {
    public var continueRun: Bool?
    public var stopReason: String?
    public var suppressOutput: Bool?
    public var systemMessage: String?
    public var decision: String?
    public var reason: String?
    public var hookSpecificOutput: JSONValue?

    public init() {}
    public static let proceed = HookOutput()
    /// PreToolUse: `"allow"`, `"deny"`, `"ask"`, or `"defer"`; optionally rewrite the input.
    public static func preToolUse(_ permission: String, reason: String? = nil, updatedInput: JSONValue? = nil) -> HookOutput {
        var specific: [String: JSONValue] = ["hookEventName": "PreToolUse", "permissionDecision": .string(permission)]
        if let reason { specific["permissionDecisionReason"] = .string(reason) }
        if let updatedInput { specific["updatedInput"] = updatedInput }
        var o = HookOutput(); o.hookSpecificOutput = .object(specific); return o
    }
    public static func addContext(_ event: HookEvent, _ text: String) -> HookOutput {
        var o = HookOutput(); o.hookSpecificOutput = .object(["hookEventName": .string(event.rawValue), "additionalContext": .string(text)]); return o
    }
    public static func block(_ reason: String) -> HookOutput { var o = HookOutput(); o.decision = "block"; o.reason = reason; return o }

    public var wire: JSONValue {
        var d: [String: JSONValue] = [:]
        if let continueRun { d["continue"] = .bool(continueRun) }
        if let stopReason { d["stopReason"] = .string(stopReason) }
        if let suppressOutput { d["suppressOutput"] = .bool(suppressOutput) }
        if let systemMessage { d["systemMessage"] = .string(systemMessage) }
        if let decision { d["decision"] = .string(decision) }
        if let reason { d["reason"] = .string(reason) }
        if let hookSpecificOutput { d["hookSpecificOutput"] = hookSpecificOutput }
        return .object(d)
    }
}

public typealias HookCallback = @Sendable (_ input: JSONValue, _ toolUseId: String?) async -> HookOutput

public struct HookMatcher: Sendable {
    public var matcher: String?
    public var hooks: [HookCallback]
    public var timeout: Int?
    public init(matcher: String? = nil, hooks: [HookCallback], timeout: Int? = nil) { self.matcher = matcher; self.hooks = hooks; self.timeout = timeout }
}
