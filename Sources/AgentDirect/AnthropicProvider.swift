import Foundation
import AgentProtocol

/// The Anthropic provider: `ModelRequest` to the Messages API request body and its SSE stream back to
/// `ModelEvent`s. A pure mapper (plan 9.3): retry is in `RetryingHTTPClient`, the tool loop in the engine.
///
/// Shapes are from Anthropic's documentation, cited per shape below. The API key is a `Secret` unwrapped in
/// `buildRequest` only.
public struct AnthropicProvider: ModelProvider {
    public let id = "anthropic"
    public var apiKey: Secret
    /// https://platform.claude.com/docs/en/api/messages: `POST /v1/messages`.
    public var baseURL: URL
    /// Required header `anthropic-version: 2023-06-01` (https://platform.claude.com/docs/en/api/messages).
    public var apiVersion: String
    /// Comma-joined into `anthropic-beta` when non-empty.
    public var betas: [String]
    public var client: any StreamingHTTPClient
    /// Seconds with no bytes before the stream is abandoned as stalled.
    public var stallTimeout: TimeInterval
    /// `cache_control.ttl`: nil is the 5-minute default, "1h" the hour-long cache
    /// (https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
    public var cacheTTL: String?
    /// Sent as `metadata.user_id` when set (an opaque id for abuse detection, never a name or email).
    public var userId: String?

    public init(apiKey: Secret, baseURL: URL = URL(string: "https://api.anthropic.com")!, apiVersion: String = "2023-06-01",
                betas: [String] = [], client: (any StreamingHTTPClient)? = nil, stallTimeout: TimeInterval = 60,
                cacheTTL: String? = nil, userId: String? = nil) {
        self.apiKey = apiKey; self.baseURL = baseURL; self.apiVersion = apiVersion; self.betas = betas
        self.client = client ?? RetryingHTTPClient(inner: URLSessionStreamingClient())
        self.stallTimeout = stallTimeout; self.cacheTTL = cacheTTL; self.userId = userId
    }

    // MARK: Request

    /// The request body (https://platform.claude.com/docs/en/api/messages). Public so tests and the recorder can
    /// inspect it without a key; `buildRequest` adds the headers.
    public func body(for request: ModelRequest) throws -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            "messages": .array(try request.messages.map { try Self.wireMessage($0) }),
        ]
        // Prompt caching (https://platform.claude.com/docs/en/build-with-claude/prompt-caching): the prefix is
        // tools, then system, then messages; a `cache_control` breakpoint on the last tool and on the last system
        // block caches the stable prefix. At most four breakpoints per request; two are used here.
        var cacheControl: JSONValue = ["type": "ephemeral"]
        if let cacheTTL { cacheControl = ["type": "ephemeral", "ttl": .string(cacheTTL)] }
        if !request.tools.isEmpty {
            var tools = request.tools.map { Self.wireTool($0) }
            if request.cachesPrefix, case .object(var last) = tools[tools.count - 1] { last["cache_control"] = cacheControl; tools[tools.count - 1] = .object(last) }
            body["tools"] = .array(tools)
        }
        if !request.system.isEmpty {
            var system: [JSONValue] = request.system.map { ["type": "text", "text": .string($0)] }
            if request.cachesPrefix, case .object(var last) = system[system.count - 1] { last["cache_control"] = cacheControl; system[system.count - 1] = .object(last) }
            body["system"] = .array(system)
        }
        // Thinking (https://platform.claude.com/docs/en/api/messages: `thinking` with `type`, `budget_tokens`,
        // `display`). Which type a model accepts is the model's business; the mapping is one to one.
        switch request.thinking {
        case .adaptive(let display): body["thinking"] = ["type": "adaptive", "display": .string(display.rawValue)]
        case .budget(let tokens, let display): body["thinking"] = ["type": "enabled", "budget_tokens": .number(Double(tokens)), "display": .string(display.rawValue)]
        case .disabled: body["thinking"] = ["type": "disabled"]
        case nil: break
        }
        // `output_config.effort` and `output_config.format` for structured output
        // (https://platform.claude.com/docs/en/build-with-claude/structured-outputs: `{"type": "json_schema",
        // "schema": {...}}`; the answer arrives as the text block). No beta header is needed.
        var outputConfig: [String: JSONValue] = [:]
        if let effort = request.effort { outputConfig["effort"] = .string(effort) }
        if let schema = request.outputSchema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        if !outputConfig.isEmpty { body["output_config"] = .object(outputConfig) }
        if let userId { body["metadata"] = ["user_id": .string(userId)] }
        // Provider-specific knobs (plan 9.3): top-level fields merged last, so a caller can add `stop_sequences`,
        // `service_tier`, `tool_choice` or a beta field without a new neutral field.
        if case .object(let extra) = request.providerOptions[id] ?? .null { for (k, v) in extra { body[k] = v } }
        return .object(body)
    }

    /// Headers per https://platform.claude.com/docs/en/api/messages ("Required headers": `x-api-key`,
    /// `anthropic-version`, `content-type`; `anthropic-beta` for beta features). The one place the key is read.
    public func buildRequest(_ request: ModelRequest) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        apiKey.withValue { req.setValue($0, forHTTPHeaderField: "x-api-key") }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]   // stable bytes keep the cache prefix stable
        req.httpBody = try enc.encode(try body(for: request))
        req.timeoutInterval = 600
        return req
    }

    /// A message param (https://platform.claude.com/docs/en/api/messages, `MessageParam` and the content block
    /// params: text, image with base64 source, tool_use, tool_result with `tool_use_id`, `content`, `is_error`).
    static func wireMessage(_ m: ModelMessage) throws -> JSONValue {
        ["role": .string(m.role.rawValue), "content": .array(try m.content.map { try wireBlock($0) })]
    }

    static func wireBlock(_ b: ModelContentBlock) throws -> JSONValue {
        switch b {
        case .text(let t): return ["type": "text", "text": .string(t)]
        case .image(let b64, let mediaType):
            let allowed = ["image/jpeg", "image/png", "image/gif", "image/webp"]
            guard allowed.contains(mediaType) else { throw ProviderError.capabilityMismatch("image media type \(mediaType); Anthropic accepts \(allowed.joined(separator: ", "))") }
            return ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(b64)]]
        case let .toolUse(id, name, input): return ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
        case let .toolResult(id, content, isError):
            var d: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id), "content": content]
            if isError { d["is_error"] = true }
            return .object(d)
        case .thinking(let text, let signature):
            var d: [String: JSONValue] = ["type": "thinking", "thinking": .string(text)]
            if let signature { d["signature"] = .string(signature) }
            return .object(d)
        case .providerNative(let raw): return raw
        }
    }

    /// A tool definition (https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools: `name`
    /// matching `^[a-zA-Z0-9_-]{1,128}$`, `description`, `input_schema`; `strict` per
    /// https://platform.claude.com/docs/en/agents-and-tools/tool-use/strict-tool-use).
    static func wireTool(_ t: ModelToolDefinition) -> JSONValue {
        var d: [String: JSONValue] = ["name": .string(t.name), "description": .string(t.description), "input_schema": t.inputSchema]
        if t.strict { d["strict"] = true }
        return .object(d)
    }

    // MARK: Stream

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildRequest(request)
                    let response = try await client.stream(urlRequest)
                    guard (200..<300).contains(response.status) else {
                        let body = try await response.collectBody()
                        throw Self.error(status: response.status, body: body, requestId: response.header("request-id"))
                    }
                    var parser = SSEParser()
                    var mapper = EventMapper()
                    for try await chunk in StallWatchdog.guarded(response.body, timeout: stallTimeout) {
                        for sse in try parser.feed(chunk) { for event in try mapper.map(sse) { continuation.yield(event) } }
                    }
                    if let last = parser.flush() { for event in try mapper.map(last) { continuation.yield(event) } }
                    guard mapper.finished else { throw ProviderError.invalidResponse("stream ended before message_stop") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The error body (https://platform.claude.com/docs/en/api/errors: `{"type": "error", "error": {"type",
    /// "message"}, "request_id"}`), or the status alone when the body is not that shape.
    static func error(status: Int, body: Data, requestId: String?) -> ProviderError {
        let json = try? JSONValue(data: body)
        return .http(status: status, type: json?["error"]?["type"]?.stringValue, message: json?["error"]?["message"]?.stringValue,
                     requestId: requestId ?? json?["request_id"]?.stringValue)
    }

    /// SSE events to `ModelEvent`s (https://platform.claude.com/docs/en/build-with-claude/streaming): `message_start`
    /// with the opening `message` and its `usage`; `content_block_start` with `index` and `content_block` (`text`,
    /// `thinking`, `tool_use` with `id`, `name`, empty `input`); `content_block_delta` with `delta.type` of
    /// `text_delta`, `thinking_delta`, `signature_delta` or `input_json_delta` (`partial_json`);
    /// `content_block_stop`; `message_delta` with `delta.stop_reason`, `delta.stop_details` and cumulative `usage`;
    /// `message_stop`; `ping`; and `error` with an error object.
    struct EventMapper {
        var model = ""
        var usage = ModelUsage()
        var stopReason: ModelStopReason?
        var stopDetails: ModelStopDetails?
        var finished = false

        mutating func map(_ sse: SSEEvent) throws -> [ModelEvent] {
            guard !sse.data.isEmpty else { return [] }
            let d = try JSONValue(data: Data(sse.data.utf8))
            let type = d["type"]?.stringValue ?? sse.event ?? ""
            switch type {
            case "ping": return []
            case "error":
                throw ProviderError.stream(type: d["error"]?["type"]?.stringValue ?? "error", message: d["error"]?["message"]?.stringValue ?? "")
            case "message_start":
                let m = d["message"]
                model = m?["model"]?.stringValue ?? ""
                if let u = m?["usage"] { usage = usage.merged(with: Self.usage(u)) }
                return [.started(model: model, usage: m?["usage"].map(Self.usage))]
            case "content_block_start":
                let index = d["index"]?.intValue ?? 0
                let block = d["content_block"] ?? .null
                switch block["type"]?.stringValue {
                case "text": return [.blockStarted(index: index, block: .text)]
                case "thinking", "redacted_thinking": return [.blockStarted(index: index, block: .thinking)]
                case "tool_use":
                    let id = block["id"]?.stringValue ?? "toolu_" + UUID().uuidString.lowercased()
                    return [.blockStarted(index: index, block: .toolUse(id: id, name: block["name"]?.stringValue ?? "", synthetic: block["id"]?.stringValue == nil))]
                default: return [.blockStarted(index: index, block: .providerNative(block))]
                }
            case "content_block_delta":
                let index = d["index"]?.intValue ?? 0
                let delta = d["delta"] ?? .null
                switch delta["type"]?.stringValue {
                case "text_delta": return [.textDelta(index: index, text: delta["text"]?.stringValue ?? "")]
                case "thinking_delta": return [.thinkingDelta(index: index, text: delta["thinking"]?.stringValue ?? "")]
                case "signature_delta": return [.signatureDelta(index: index, signature: delta["signature"]?.stringValue ?? "")]
                case "input_json_delta": return [.toolInputDelta(index: index, partialJSON: delta["partial_json"]?.stringValue ?? "")]
                default: return []
                }
            case "content_block_stop": return [.blockStopped(index: d["index"]?.intValue ?? 0)]
            case "message_delta":
                if let s = d["delta"]?["stop_reason"]?.stringValue { stopReason = ModelStopReason(wireValue: s) }
                if let sd = d["delta"]?["stop_details"], !sd.isNull {
                    stopDetails = ModelStopDetails(category: sd["category"]?.stringValue, explanation: sd["explanation"]?.stringValue)
                }
                if let u = d["usage"] { usage = usage.merged(with: Self.usage(u)) }
                return []
            case "message_stop":
                finished = true
                return [.finished(stopReason: stopReason ?? .endTurn, usage: usage, stopDetails: stopDetails)]
            default: return []
            }
        }

        /// `usage` fields (https://platform.claude.com/docs/en/api/messages): `input_tokens`, `output_tokens`,
        /// `cache_creation_input_tokens`, `cache_read_input_tokens`.
        static func usage(_ u: JSONValue) -> ModelUsage {
            ModelUsage(inputTokens: u["input_tokens"]?.intValue ?? 0, outputTokens: u["output_tokens"]?.intValue ?? 0,
                       cacheReadInputTokens: u["cache_read_input_tokens"]?.intValue ?? 0, cacheCreationInputTokens: u["cache_creation_input_tokens"]?.intValue ?? 0)
        }
    }
}
