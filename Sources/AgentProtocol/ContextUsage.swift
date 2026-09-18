import Foundation

/// The CLI's answer to `get_context_usage`: what occupies the context window before and during a session.
/// Same numbers the `/context` command shows. Available right after the initialize handshake, with no API call
/// (`apiUsage` is null then). Observed on 2.1.271; unknown fields stay in `raw`.
public struct ContextUsage: Sendable, Equatable {
    public struct Category: Sendable, Equatable { public var name: String; public var tokens: Int; public var kind: String; public var isDeferred: Bool }
    public struct MemoryFile: Sendable, Equatable { public var path: String; public var type: String; public var tokens: Int }
    public struct NamedTokens: Sendable, Equatable { public var name: String; public var source: String?; public var tokens: Int }

    public var totalTokens: Int
    public var maxTokens: Int
    public var percentage: Double
    public var model: String
    public var categories: [Category]
    public var memoryFiles: [MemoryFile]
    public var mcpTools: [NamedTokens]
    public var skills: [NamedTokens]
    public var skillTokens: Int
    public var slashCommandTokens: Int
    public var autoCompactThreshold: Int?
    public var raw: JSONValue

    public init(_ json: JSONValue) {
        raw = json
        totalTokens = json["totalTokens"]?.intValue ?? 0
        maxTokens = json["maxTokens"]?.intValue ?? 0
        percentage = json["percentage"]?.doubleValue ?? 0
        model = json["model"]?.stringValue ?? ""
        categories = (json["categories"]?.arrayValue ?? []).map {
            Category(name: $0["name"]?.stringValue ?? "", tokens: $0["tokens"]?.intValue ?? 0, kind: $0["kind"]?.stringValue ?? "", isDeferred: $0["isDeferred"]?.boolValue ?? false)
        }
        memoryFiles = (json["memoryFiles"]?.arrayValue ?? []).map {
            MemoryFile(path: $0["path"]?.stringValue ?? "", type: $0["type"]?.stringValue ?? "", tokens: $0["tokens"]?.intValue ?? 0)
        }
        mcpTools = (json["mcpTools"]?.arrayValue ?? []).map {
            NamedTokens(name: $0["name"]?.stringValue ?? "", source: $0["server"]?.stringValue ?? $0["serverName"]?.stringValue, tokens: $0["tokens"]?.intValue ?? 0)
        }
        skills = (json["skills"]?["skillFrontmatter"]?.arrayValue ?? []).map {
            NamedTokens(name: $0["name"]?.stringValue ?? "", source: $0["source"]?.stringValue, tokens: $0["tokens"]?.intValue ?? 0)
        }
        skillTokens = json["skills"]?["tokens"]?.intValue ?? 0
        slashCommandTokens = json["slashCommands"]?["tokens"]?.intValue ?? 0
        autoCompactThreshold = json["autoCompactThreshold"]?.intValue
    }

    /// Tokens the model sees on every request: everything except the autocompact buffer, free space, and deferred tools.
    public var loadedTokens: Int { categories.filter { $0.kind == "used" }.reduce(0) { $0 + $1.tokens } }
    public func tokens(for categoryName: String) -> Int { categories.first { $0.name == categoryName }?.tokens ?? 0 }
}
