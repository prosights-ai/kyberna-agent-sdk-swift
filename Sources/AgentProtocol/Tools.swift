import Foundation

/// One block of an MCP tool result (MCP CallToolResult content).
public enum ToolResultBlock: Sendable, Equatable {
    case text(String)
    case image(base64: String, mimeType: String)
    case resource(uri: String, mimeType: String?, text: String?, blobBase64: String?)
    case resourceLink(uri: String, name: String, description: String?, mimeType: String?)

    public var wire: JSONValue {
        switch self {
        case .text(let t): return ["type": "text", "text": .string(t)]
        case .image(let b64, let mime): return ["type": "image", "data": .string(b64), "mimeType": .string(mime)]
        case .resource(let uri, let mime, let text, let blob):
            var r: [String: JSONValue] = ["uri": .string(uri)]
            if let mime { r["mimeType"] = .string(mime) }
            if let text { r["text"] = .string(text) }
            if let blob { r["blob"] = .string(blob) }
            return ["type": "resource", "resource": .object(r)]
        case .resourceLink(let uri, let name, let desc, let mime):
            var r: [String: JSONValue] = ["type": "resource_link", "uri": .string(uri), "name": .string(name)]
            if let desc { r["description"] = .string(desc) }
            if let mime { r["mimeType"] = .string(mime) }
            return .object(r)
        }
    }
}

/// What a Swift tool returns. `.text("...")` covers the common case.
public struct ToolResult: Sendable, Equatable {
    public var content: [ToolResultBlock]
    public var isError: Bool
    public var structuredContent: JSONValue?
    public init(content: [ToolResultBlock], isError: Bool = false, structuredContent: JSONValue? = nil) {
        self.content = content; self.isError = isError; self.structuredContent = structuredContent
    }
    public static func text(_ t: String) -> ToolResult { ToolResult(content: [.text(t)]) }
    public static func error(_ t: String) -> ToolResult { ToolResult(content: [.text(t)], isError: true) }
    public var wire: JSONValue {
        var d: [String: JSONValue] = ["content": .array(content.map { $0.wire })]
        if isError { d["isError"] = true }
        if let structuredContent { d["structuredContent"] = structuredContent }
        return .object(d)
    }
}

/// MCP tool annotations. All hints are informational except readOnlyHint, which lets Claude Code batch calls.
public struct ToolAnnotations: Sendable, Equatable {
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?
    /// Claude Code-specific: size up to which a result stays inline. Travels in `_meta`.
    public var maxResultSizeChars: Int?
    public init(readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil, openWorldHint: Bool? = nil, maxResultSizeChars: Int? = nil) {
        self.readOnlyHint = readOnlyHint; self.destructiveHint = destructiveHint; self.idempotentHint = idempotentHint; self.openWorldHint = openWorldHint; self.maxResultSizeChars = maxResultSizeChars
    }
    public var wire: JSONValue {
        var d: [String: JSONValue] = [:]
        if let readOnlyHint { d["readOnlyHint"] = .bool(readOnlyHint) }
        if let destructiveHint { d["destructiveHint"] = .bool(destructiveHint) }
        if let idempotentHint { d["idempotentHint"] = .bool(idempotentHint) }
        if let openWorldHint { d["openWorldHint"] = .bool(openWorldHint) }
        return .object(d)
    }
}

/// One clarifying question from Claude's AskUserQuestion tool.
public struct AskQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable { public var label: String; public var description: String; public init(label: String, description: String) { self.label = label; self.description = description } }
    public var question: String
    public var header: String
    public var options: [Option]
    public var multiSelect: Bool
    public init(question: String, header: String, options: [Option], multiSelect: Bool) { self.question = question; self.header = header; self.options = options; self.multiSelect = multiSelect }
}

/// Extra fields the CLI sends with a can_use_tool request (mirrors ToolPermissionContext).
public struct PermissionContext: Sendable, Equatable {
    public var toolUseId: String?
    public var suggestions: [JSONValue]
    public var blockedPath: String?
    public var decisionReason: String?
    public var title: String?
    public var description: String?
    public var payload: ApprovalPayload
    public init(toolUseId: String?, suggestions: [JSONValue], blockedPath: String?, decisionReason: String?, title: String?, description: String?, payload: ApprovalPayload) {
        self.toolUseId = toolUseId; self.suggestions = suggestions; self.blockedPath = blockedPath; self.decisionReason = decisionReason; self.title = title; self.description = description; self.payload = payload
    }
}

public enum PermissionDecision: Sendable, Equatable {
    case allow(updatedInput: JSONValue? = nil, updatedPermissions: [JSONValue]? = nil)
    case deny(String, interrupt: Bool = false)
}

/// Outcome of the synchronous policy check that runs before any human is asked.
public enum PolicyOutcome: Sendable, Equatable {
    case allow
    case deny(String)
    case ask
}

/// One entry of the `models` list in the initialize response (observed 2.1.271): what the CLI's own `/model`
/// picker shows. `value` is what `set_model` and `--model` accept; `resolvedModel` is the API model id.
public struct ModelChoice: Sendable, Equatable, Identifiable, Codable {
    public var value: String
    public var resolvedModel: String
    public var displayName: String
    public var description: String
    public var supportedEffortLevels: [String]
    public var id: String { value }
    public init(value: String, resolvedModel: String, displayName: String, description: String, supportedEffortLevels: [String]) {
        self.value = value; self.resolvedModel = resolvedModel; self.displayName = displayName; self.description = description; self.supportedEffortLevels = supportedEffortLevels
    }
    public init?(_ json: JSONValue) {
        guard let v = json["value"]?.stringValue else { return nil }
        self.init(value: v, resolvedModel: json["resolvedModel"]?.stringValue ?? v, displayName: json["displayName"]?.stringValue ?? v,
                  description: json["description"]?.stringValue ?? "", supportedEffortLevels: (json["supportedEffortLevels"]?.arrayValue ?? []).compactMap(\.stringValue))
    }
}


/// `rate_limit_event`, sent with every model request (observed 2.1.271). `status` is usually `allowed`;
/// `allowed_warning` means a window is nearly spent; other values mean the request was refused.
public struct RateLimitInfo: Sendable, Equatable {
    public struct Window: Sendable, Equatable { public var utilization: Double; public var resetsAt: Date? }
    public var status: String
    public var rateLimitType: String?
    public var resetsAt: Date?
    public var fiveHour: Window?
    public var sevenDay: Window?
    public var isUsingOverage: Bool
    public init(_ json: JSONValue) {
        status = json["status"]?.stringValue ?? "unknown"
        rateLimitType = json["rateLimitType"]?.stringValue
        resetsAt = json["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        isUsingOverage = json["isUsingOverage"]?.boolValue ?? false
        func window(_ v: JSONValue?) -> Window? {
            guard let u = v?["utilization"]?.doubleValue else { return nil }
            return Window(utilization: u, resetsAt: v?["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) })
        }
        fiveHour = window(json["unifiedWindows"]?["five_hour"])
        sevenDay = window(json["unifiedWindows"]?["seven_day"])
    }
    public var isWarning: Bool { status == "allowed_warning" }
    public var isRejected: Bool { !(status == "allowed" || status == "allowed_warning") }
}
