import Foundation
import AgentProtocol

/// A tool implemented in Swift and served to Claude Code as an in-process MCP server.
public struct SwiftTool: Sendable {
    /// The tool's own reading of one call's arguments before it runs; nil when the tool has no opinion on that
    /// call. A host's grader consults it ahead of any table it keeps by tool name.
    public typealias RiskJudgment = @Sendable ([String: JSONValue]) -> ToolCallRisk?

    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public var annotations: ToolAnnotations?
    /// The baseline risk of a call, kept with the definition (Kyberna release plan v0.2.13 Phase 2 step 2, after
    /// Qwen Code's `getDefaultPermission`). nil: the tool states no baseline and the host's tables decide.
    public var riskOfCall: RiskJudgment?
    public let handler: @Sendable ([String: JSONValue]) async throws -> ToolResult

    public init(name: String, description: String, inputSchema: JSONValue, annotations: ToolAnnotations? = nil,
                riskOfCall: RiskJudgment? = nil,
                handler: @escaping @Sendable ([String: JSONValue]) async throws -> ToolResult) throws {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { throw ToolDefinitionError.invalidName(name) }
        guard inputSchema["type"]?.stringValue == "object" else { throw ToolDefinitionError.schemaNotObject(name) }
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.annotations = annotations
        self.riskOfCall = riskOfCall; self.handler = handler
    }
    /// Convenience for tools that only ever return a string.
    public init(name: String, description: String, inputSchema: JSONValue, annotations: ToolAnnotations? = nil,
                riskOfCall: RiskJudgment? = nil,
                text handler: @escaping @Sendable ([String: JSONValue]) async throws -> String) throws {
        try self.init(name: name, description: description, inputSchema: inputSchema, annotations: annotations, riskOfCall: riskOfCall) { .text(try await handler($0)) }
    }

    /// A judgment that reads every call the same, for a tool whose arguments never change what it could do.
    public static func fixedRisk(_ risk: ToolCallRisk) -> RiskJudgment { { _ in risk } }

    /// The tool's baseline for `input`: its judgment's answer, or nil when it has none or declines.
    public func risk(of input: [String: JSONValue]) -> ToolCallRisk? { riskOfCall?(input) }

    public var wire: JSONValue {
        var d: [String: JSONValue] = ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
        if let a = annotations {
            if case .object(let w) = a.wire, !w.isEmpty { d["annotations"] = .object(w) }
            if let m = a.maxResultSizeChars { d["_meta"] = ["anthropic/maxResultSizeChars": .number(Double(m))] }
        }
        return .object(d)
    }
}

public enum ToolDefinitionError: Error, CustomStringConvertible, Sendable {
    case invalidName(String), schemaNotObject(String)
    public var description: String {
        switch self {
        case .invalidName(let n): return "tool name '\(n)' must be letters, digits, '_' or '-'"
        case .schemaNotObject(let n): return "tool '\(n)' inputSchema must have \"type\": \"object\""
        }
    }
}
