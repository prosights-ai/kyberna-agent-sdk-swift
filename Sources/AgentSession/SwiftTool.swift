import Foundation
import AgentProtocol

/// A tool implemented in Swift and served to Claude Code as an in-process MCP server.
public struct SwiftTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public var annotations: ToolAnnotations?
    public let handler: @Sendable ([String: JSONValue]) async throws -> ToolResult

    public init(name: String, description: String, inputSchema: JSONValue, annotations: ToolAnnotations? = nil,
                handler: @escaping @Sendable ([String: JSONValue]) async throws -> ToolResult) throws {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { throw ToolDefinitionError.invalidName(name) }
        guard inputSchema["type"]?.stringValue == "object" else { throw ToolDefinitionError.schemaNotObject(name) }
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.annotations = annotations; self.handler = handler
    }
    /// Convenience for tools that only ever return a string.
    public init(name: String, description: String, inputSchema: JSONValue, annotations: ToolAnnotations? = nil,
                text handler: @escaping @Sendable ([String: JSONValue]) async throws -> String) throws {
        try self.init(name: name, description: description, inputSchema: inputSchema, annotations: annotations) { .text(try await handler($0)) }
    }

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
