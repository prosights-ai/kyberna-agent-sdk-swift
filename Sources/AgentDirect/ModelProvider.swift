import Foundation
import AgentProtocol

// MARK: - The provider contract
//
// A `ModelProvider` is a pure mapper between the engine's neutral request shape and one vendor's wire format
// (plan section 1.4, 9.3 "layered provider clients"). Everything else — the tool loop, waves, timeouts, the
// process registry, interrupt and history repair, compaction, policy — lives in `DirectAPIEngine` and
// `ToolExecutor` and is shared by every provider. A provider therefore contains no policy code, never retries a
// model call itself (retry lives in the HTTP transport it uses), and never executes a tool.
//
// The contract, which the Anthropic provider, the OpenAI-compatible adapter (Phase 2 step 3c) and a local runtime
// all implement:
//
// 1. `stream(_:)` takes one `ModelRequest` and returns one `AsyncThrowingStream<ModelEvent, Error>`. The stream
//    is always a real byte stream from the wire, never a buffered response replayed as deltas (9.3).
// 2. Event order is fixed: exactly one `.started`, then for each content block `.blockStarted(index:)`, zero or
//    more deltas for that index, `.blockStopped(index:)`; then exactly one `.finished`, after which the stream
//    ends. Indices are the block's position in the final content array. Deltas for a block arrive after its
//    start and before its stop; blocks may not interleave.
// 3. A `.toolUse` block's input arrives as `toolInputDelta` fragments of JSON text; the consumer concatenates and
//    parses them at `.blockStopped`. A provider whose wire delivers the whole input at once emits one fragment.
//    A provider whose wire returns no tool-call ids mints one and sets `ModelBlockStart.toolUse(synthetic: true)`.
// 4. `.finished` carries the provider's stop reason mapped to `ModelStopReason`, preserving the distinction between
//    a clean end, `maxTokens` truncation, a tool call, and a refusal (9.2 "preserve the provider stop reason"), plus
//    the final cumulative `ModelUsage`.
// 5. Failures are thrown as `ProviderError`, which has two renderings: `description` for a person and
//    `feedbackMessage` for the model (9.2). HTTP status, error type and request id are kept as fields, never only
//    as text. A `CancellationError` from the consumer cancelling the iteration passes through untouched.
// 6. A neutral request field the provider cannot honour is a thrown `ProviderError.capabilityMismatch` at request
//    build time, never a silent drop (9.3). Provider-specific knobs go in `ModelRequest.providerOptions[id]`.
// 7. Blocks the provider must see again unchanged on the next request (thinking blocks with signatures, other
//    provider-native blocks) round-trip through `ModelContentBlock.thinking(_:signature:)` and
//    `.providerNative(_:)`; the engine appends them to history as received and switching provider mid-session
//    drops them (9.3 "continuity").
// 8. Credentials are `Secret`s unwrapped only inside the provider's request builder.

/// One vendor's mapping of the neutral request to its wire format and of its stream back to `ModelEvent`s.
/// The contract is stated at the top of this file.
public protocol ModelProvider: Sendable {
    /// "anthropic", "openai-compatible", "local": keys `ModelRequest.providerOptions` and names the engine in
    /// transcripts (ADR 0015 point 5).
    var id: String { get }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
    /// Tokens this request would occupy, when the provider offers a count endpoint; nil otherwise. The engine
    /// falls back to the usage fields of the previous response.
    func countTokens(_ request: ModelRequest) async throws -> Int?
}

public extension ModelProvider {
    func countTokens(_ request: ModelRequest) async throws -> Int? { nil }
}

// MARK: - Request

/// The engine's neutral request: what every provider maps from.
public struct ModelRequest: Sendable, Equatable {
    public var model: String
    /// System text blocks, in order. Stable across a session, so providers that cache a prefix cache these.
    public var system: [String]
    public var messages: [ModelMessage]
    /// Tool definitions with JSON Schema inputs; stable across a session and part of the cached prefix.
    public var tools: [ModelToolDefinition]
    public var maxTokens: Int
    public var thinking: ModelThinking?
    /// Provider effort level as the provider names it ("low", "medium", "high", ...); nil is the provider default.
    public var effort: String?
    /// JSON Schema the final answer must match (structured output). nil is free text.
    public var outputSchema: JSONValue?
    /// Marks the stable prefix (tools, then system) for the provider's prompt cache when it has one.
    public var cachesPrefix: Bool
    /// Provider-specific knobs keyed by `ModelProvider.id`; a provider reads only its own entry (9.3).
    public var providerOptions: [String: JSONValue]

    public init(model: String, system: [String] = [], messages: [ModelMessage], tools: [ModelToolDefinition] = [],
                maxTokens: Int = 16_000, thinking: ModelThinking? = nil, effort: String? = nil, outputSchema: JSONValue? = nil,
                cachesPrefix: Bool = true, providerOptions: [String: JSONValue] = [:]) {
        self.model = model; self.system = system; self.messages = messages; self.tools = tools; self.maxTokens = maxTokens
        self.thinking = thinking; self.effort = effort; self.outputSchema = outputSchema; self.cachesPrefix = cachesPrefix
        self.providerOptions = providerOptions
    }
}

public enum ModelRole: String, Sendable, Codable { case user, assistant }

/// One turn of the conversation as the provider sees it.
public struct ModelMessage: Sendable, Equatable, Codable {
    public var role: ModelRole
    public var content: [ModelContentBlock]
    public init(role: ModelRole, content: [ModelContentBlock]) { self.role = role; self.content = content }
    public static func user(_ text: String) -> ModelMessage { ModelMessage(role: .user, content: [.text(text)]) }
    public static func assistant(_ text: String) -> ModelMessage { ModelMessage(role: .assistant, content: [.text(text)]) }

    /// Ids of `tool_use` blocks in this message (assistant turns).
    public var toolUseIds: [String] { content.compactMap { if case .toolUse(let id, _, _) = $0 { return id }; return nil } }
    /// Ids of `tool_result` blocks in this message (user turns).
    public var toolResultIds: [String] { content.compactMap { if case .toolResult(let id, _, _) = $0 { return id }; return nil } }
    public var hasToolResults: Bool { !toolResultIds.isEmpty }
    /// The concatenated text blocks.
    public var text: String { content.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined() }
}

/// A content block in the neutral shape. `thinking` and `providerNative` are the continuity blocks of contract
/// point 7: appended to history as received and sent back unchanged.
public enum ModelContentBlock: Sendable, Equatable, Codable {
    case text(String)
    case image(base64: String, mediaType: String)
    case toolUse(id: String, name: String, input: JSONValue)
    /// `content` is a string or an array of text/image blocks in the provider's own block shape.
    case toolResult(toolUseId: String, content: JSONValue, isError: Bool)
    case thinking(String, signature: String?)
    /// A block the provider returned that the neutral shape does not name; sent back as is.
    case providerNative(JSONValue)
}

/// A tool as offered to the model.
public struct ModelToolDefinition: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// Ask the provider to validate arguments against the schema where it can (Anthropic `strict`).
    public var strict: Bool
    public init(name: String, description: String, inputSchema: JSONValue, strict: Bool = false) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.strict = strict
    }
}

/// The reasoning setting in neutral terms. `display` is how much of it the provider streams back.
public enum ModelThinking: Sendable, Equatable, Codable {
    case adaptive(display: ModelThinkingDisplay)
    case budget(tokens: Int, display: ModelThinkingDisplay)
    case disabled
}

public enum ModelThinkingDisplay: String, Sendable, Codable { case summarized, omitted }

// MARK: - Events

/// What a provider streams back; the order is fixed by contract point 2.
public enum ModelEvent: Sendable, Equatable {
    /// The response opened; `usage` carries the prompt-side counts when the provider reports them up front.
    case started(model: String, usage: ModelUsage?)
    case blockStarted(index: Int, block: ModelBlockStart)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, text: String)
    /// The signature that binds a thinking block; arrives before the block stops.
    case signatureDelta(index: Int, signature: String)
    /// A fragment of the tool input JSON text.
    case toolInputDelta(index: Int, partialJSON: String)
    case blockStopped(index: Int)
    case finished(stopReason: ModelStopReason, usage: ModelUsage, stopDetails: ModelStopDetails?)
}

public enum ModelBlockStart: Sendable, Equatable {
    case text
    case thinking
    /// `synthetic` is true when the provider returned no id and this one was minted (contract point 3).
    case toolUse(id: String, name: String, synthetic: Bool)
    /// A block the neutral shape does not name, carried whole; there are no deltas for it.
    case providerNative(JSONValue)
}

/// The provider's stop reason, mapped. `other` keeps a value the mapping does not know.
public enum ModelStopReason: Sendable, Equatable, Codable {
    case endTurn, maxTokens, stopSequence, toolUse, refusal, pauseTurn
    case other(String)
    /// The Messages API spelling, which `AssistantMessage.stopReason` and `ResultMessage.stopReason` carry.
    public var wireValue: String {
        switch self {
        case .endTurn: return "end_turn"; case .maxTokens: return "max_tokens"; case .stopSequence: return "stop_sequence"
        case .toolUse: return "tool_use"; case .refusal: return "refusal"; case .pauseTurn: return "pause_turn"
        case .other(let s): return s
        }
    }
    public init(wireValue: String) {
        switch wireValue {
        case "end_turn": self = .endTurn; case "max_tokens": self = .maxTokens; case "stop_sequence": self = .stopSequence
        case "tool_use": self = .toolUse; case "refusal": self = .refusal; case "pause_turn": self = .pauseTurn
        default: self = .other(wireValue)
        }
    }
}

/// Why the model declined, when `stopReason` is `.refusal`.
public struct ModelStopDetails: Sendable, Equatable, Codable {
    public var category: String?
    public var explanation: String?
    public init(category: String?, explanation: String?) { self.category = category; self.explanation = explanation }
}

/// Token counts for one response. Cumulative: a later event's counts replace an earlier one's for the same field.
public struct ModelUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreationInputTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadInputTokens: Int = 0, cacheCreationInputTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens; self.cacheCreationInputTokens = cacheCreationInputTokens
    }
    /// Everything the model read this request: the uncached input plus what the cache served or stored.
    public var contextTokens: Int { inputTokens + cacheReadInputTokens + cacheCreationInputTokens }
    /// Field-wise maximum, for merging a `started` usage with the `finished` usage.
    public func merged(with other: ModelUsage) -> ModelUsage {
        ModelUsage(inputTokens: max(inputTokens, other.inputTokens), outputTokens: max(outputTokens, other.outputTokens),
                   cacheReadInputTokens: max(cacheReadInputTokens, other.cacheReadInputTokens),
                   cacheCreationInputTokens: max(cacheCreationInputTokens, other.cacheCreationInputTokens))
    }
    /// Field-wise sum, for a turn's total across model calls.
    public static func + (a: ModelUsage, b: ModelUsage) -> ModelUsage {
        ModelUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
                   cacheReadInputTokens: a.cacheReadInputTokens + b.cacheReadInputTokens,
                   cacheCreationInputTokens: a.cacheCreationInputTokens + b.cacheCreationInputTokens)
    }
    /// The Messages API `usage` object shape, which the Console and gateway already read.
    public var wire: JSONValue {
        ["input_tokens": .number(Double(inputTokens)), "output_tokens": .number(Double(outputTokens)),
         "cache_read_input_tokens": .number(Double(cacheReadInputTokens)), "cache_creation_input_tokens": .number(Double(cacheCreationInputTokens))]
    }
}

// MARK: - Errors

/// A provider failure with two renderings: `description` for a person, `feedbackMessage` for the model (9.2).
public enum ProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The endpoint answered with a non-success status. `type` and `message` are the body's error object when it
    /// had one; `requestId` is the `request-id` header.
    case http(status: Int, type: String?, message: String?, requestId: String?)
    /// An error event inside an otherwise successful stream.
    case stream(type: String, message: String)
    /// No bytes arrived for `seconds`; the connection was closed.
    case stalled(seconds: TimeInterval)
    /// The connection failed before a status arrived.
    case transport(String)
    /// The stream ended without `.finished`, or a block could not be parsed.
    case invalidResponse(String)
    /// A neutral request field this provider cannot honour (contract point 6).
    case capabilityMismatch(String)

    /// Statuses the transport retries: 408, 429, 500, 502, 503, 504 (plan 9.3).
    public static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504]
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _, _, _): return Self.retryableStatuses.contains(status)
        case .transport, .stalled: return true
        default: return false
        }
    }

    /// The request did not fit the model's context window: the local runtimes' "a prompt of N tokens in a context
    /// of M" (`capabilityMismatch`), or a 400 or 413 whose error names the context length (the Messages API's
    /// "prompt is too long", OpenAI-compatible servers' `context_length_exceeded` and "maximum context length",
    /// llama.cpp's server's "exceeds the available context size"). The engine compacts and retries on this.
    public var isContextOverflow: Bool {
        switch self {
        case .capabilityMismatch(let s): return s.contains("in a context of")
        case .http(let status, let type, let message, _):
            guard status == 400 || status == 413 else { return false }
            let text = "\(type ?? "") \(message ?? "")".lowercased()
            return ["context_length", "context length", "context size", "context window", "prompt is too long", "too many tokens", "maximum context"]
                .contains { text.contains($0) }
        default: return false
        }
    }

    public var description: String {
        switch self {
        case let .http(status, type, message, requestId):
            var s = "HTTP \(status)"
            if let type { s += " \(type)" }
            if let message { s += ": \(message)" }
            if let requestId { s += " (request-id \(requestId))" }
            return s
        case let .stream(type, message): return "stream error \(type): \(message)"
        case .stalled(let s): return "no data for \(Int(s)) s; connection closed"
        case .transport(let s): return "transport: \(s)"
        case .invalidResponse(let s): return "invalid response: \(s)"
        case .capabilityMismatch(let s): return "this provider cannot honour: \(s)"
        }
    }
    /// What the model is told when a call on its behalf fails.
    public var feedbackMessage: String {
        switch self {
        case .http(let status, _, _, _): return "The model request failed with HTTP \(status)."
        case .stream, .invalidResponse: return "The model response was cut short."
        case .stalled: return "The model response stalled."
        case .transport: return "The model endpoint could not be reached."
        case .capabilityMismatch(let s): return "The request asked for something this model cannot do: \(s)."
        }
    }
}
