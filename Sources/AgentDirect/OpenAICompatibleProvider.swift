import Foundation
import AgentProtocol

/// The OpenAI-compatible provider: `ModelRequest` to a Chat Completions request and its SSE stream back to
/// `ModelEvent`s, for the local servers that speak that API (release plan v0.2.0 Phase 2 step 3c). A pure mapper
/// like `AnthropicProvider`: retry is in `RetryingHTTPClient`, the tool loop in the engine.
///
/// Two servers are documented and handled; where they differ, both shapes are accepted and the difference is
/// noted at the line that handles it:
/// - LM Studio's server (https://lmstudio.ai/docs/developer/openai-compat): `GET /v1/models`,
///   `POST /v1/chat/completions` (also `/v1/responses`, `/v1/completions`, `/v1/embeddings`, not used here) under a
///   base URL such as `http://localhost:1234/v1`; the port is whatever `lms server status` reports. No
///   authentication by default; when the person turns it on in Server Settings, requests carry
///   `Authorization: Bearer <token>` (https://lmstudio.ai/docs/developer/core/authentication).
/// - Ollama's `/v1` endpoint (https://docs.ollama.com/api/openai-compatibility, the published form of the
///   repository's `docs/openai.md`): `/v1/chat/completions`, `/v1/models`, `/v1/models/{model}`, `/v1/completions`,
///   `/v1/embeddings`, on `127.0.0.1:11434` by default. Supported chat fields: `model`, `messages`,
///   `frequency_penalty`, `presence_penalty`, `response_format`, `seed`, `stop`, `stream`, `stream_options`
///   (`include_usage`), `temperature`, `top_p`, `max_tokens`, `tools`, `reasoning_effort`, `reasoning`;
///   unsupported: `tool_choice`, `logit_bias`, `user`, `n`. "The client requires an API key value, but Ollama
///   ignores it", so the server needs none.
///
/// Neither documents the streamed chunk format beyond "same as OpenAI"; the shape handled by `EventMapper` is the
/// Chat Completions chunk (`choices[].delta` with `content`, `tool_calls`, `finish_reason`; a final `usage`
/// object; `data: [DONE]`), which Ollama produced verbatim on this Mac on 2026-09-20 (the last chunk carried
/// `choices: []` and `usage`, then `[DONE]`).
public struct OpenAICompatibleProvider: ModelProvider {
    public let id = "openai-compatible"
    /// The server's origin, without `/v1` (`http://127.0.0.1:1235`, `http://127.0.0.1:11434`); the paths are
    /// appended here. A trailing `/v1` is removed so either spelling works.
    public var baseURL: URL
    /// Sent as `Authorization: Bearer` when set. Nil by default: LM Studio does not require a token unless the
    /// person turns authentication on, and Ollama ignores one.
    public var apiKey: Secret?
    public var client: any StreamingHTTPClient
    /// Seconds with no bytes before the stream is abandoned as stalled. Local servers load a model on the first
    /// request ("just-in-time model loading" in LM Studio; Ollama loads on demand), so this is generous.
    public var stallTimeout: TimeInterval
    /// How `ModelRequest.outputSchema` reaches the server. `.responseFormat` sends
    /// `response_format: {type: "json_schema", json_schema: {name, strict, schema}}`
    /// (https://lmstudio.ai/docs/developer/openai-compat/structured-output; Ollama lists `response_format` as
    /// supported) and, when the server answers 400 to that request, repeats it once as `.instruction`.
    /// `.instruction` never sends `response_format` and appends the schema to the system prompt instead.
    public var structuredOutput: StructuredOutputMode
    /// Called when the `response_format` request was refused with 400 and the instruction fallback is used, so a
    /// host can pin `.instruction` for this server and skip the failed request next time.
    public var onStructuredOutputFallback: (@Sendable (ProviderError) -> Void)?

    public enum StructuredOutputMode: String, Sendable, Codable { case responseFormat, instruction }

    public init(baseURL: URL, apiKey: Secret? = nil, client: (any StreamingHTTPClient)? = nil, stallTimeout: TimeInterval = 120,
                structuredOutput: StructuredOutputMode = .responseFormat, onStructuredOutputFallback: (@Sendable (ProviderError) -> Void)? = nil) {
        var base = baseURL
        if base.lastPathComponent == "v1" { base = base.deletingLastPathComponent() }
        if base.absoluteString.hasSuffix("/") { base = URL(string: String(base.absoluteString.dropLast())) ?? base }
        self.baseURL = base; self.apiKey = apiKey
        self.client = client ?? RetryingHTTPClient(inner: URLSessionStreamingClient())
        self.stallTimeout = stallTimeout; self.structuredOutput = structuredOutput; self.onStructuredOutputFallback = onStructuredOutputFallback
    }

    // MARK: Request

    /// The request body: the Chat Completions fields both servers list (`model`, `messages`, `max_tokens`,
    /// `stream`, `tools`, `response_format`) plus `stream_options.include_usage` (Ollama lists it; LM Studio's
    /// parameter list at https://lmstudio.ai/docs/developer/openai-compat/chat-completions does not, and it is
    /// sent anyway, since a server that ignores it simply omits `usage`). Public so tests inspect it.
    public func body(for request: ModelRequest, structuredOutput mode: StructuredOutputMode) throws -> JSONValue {
        var system = request.system
        if mode == .instruction, let schema = request.outputSchema {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let text = String(decoding: try enc.encode(schema), as: UTF8.self)
            system.append("Answer with a single JSON value that matches this JSON Schema, and nothing else: \(text)")
        }
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": .array(try Self.wireMessages(system: system, request.messages)),
        ]
        if !request.tools.isEmpty { body["tools"] = .array(request.tools.map { Self.wireTool($0) }) }
        // Thinking: neither server documents a budget field, so `.budget` is a capability mismatch (contract
        // point 6). `.adaptive` and `.disabled` are the server's own default (the model decides) and send nothing.
        if case .budget(let tokens, _) = request.thinking { throw ProviderError.capabilityMismatch("a thinking budget of \(tokens) tokens; the Chat Completions API has no budget field") }
        // `reasoning_effort` is in Ollama's supported list; LM Studio's list omits it. Sent only when asked for.
        if let effort = request.effort { body["reasoning_effort"] = .string(effort) }
        if mode == .responseFormat, let schema = request.outputSchema {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "answer", "strict": true, "schema": schema]]
        }
        // Provider-specific knobs (plan 9.3): top-level fields merged last (`temperature`, `seed`, `stop`, ...).
        if case .object(let extra) = request.providerOptions[id] ?? .null { for (k, v) in extra { body[k] = v } }
        return .object(body)
    }

    /// `POST {base}/v1/chat/completions` with `content-type: application/json`; the bearer token is read here and
    /// nowhere else.
    public func buildRequest(_ request: ModelRequest, structuredOutput mode: StructuredOutputMode) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        apiKey?.withValue { req.setValue("Bearer \($0)", forHTTPHeaderField: "authorization") }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        req.httpBody = try enc.encode(try body(for: request, structuredOutput: mode))
        req.timeoutInterval = 600
        return req
    }

    /// Chat Completions messages: the system blocks joined into one `system` message first, then each neutral
    /// message. A user message whose blocks are `toolResult`s becomes one `tool` message per result
    /// (`{"role": "tool", "content": "...", "tool_call_id": "..."}`, https://lmstudio.ai/docs/developer/openai-compat/tools);
    /// an assistant message's `toolUse` blocks become `tool_calls` with the input serialised as the `arguments`
    /// string. Thinking blocks are dropped (neither server documents a field to send them back), and
    /// `providerNative` blocks are sent as is when they are objects.
    static func wireMessages(system: [String], _ messages: [ModelMessage]) throws -> [JSONValue] {
        var out: [JSONValue] = []
        if !system.isEmpty { out.append(["role": "system", "content": .string(system.joined(separator: "\n\n"))]) }
        for m in messages {
            switch m.role {
            case .user:
                var parts: [JSONValue] = []
                var text = ""
                var onlyText = true
                for b in m.content {
                    switch b {
                    case .text(let t): parts.append(["type": "text", "text": .string(t)]); text += t
                    case .image(let b64, let mediaType):
                        // Vision input as a data URL (https://lmstudio.ai/docs/developer/openai-compat: "Chat Completions (text and images)").
                        parts.append(["type": "image_url", "image_url": ["url": .string("data:\(mediaType);base64,\(b64)")]]); onlyText = false
                    case let .toolResult(id, content, isError):
                        out.append(["role": "tool", "tool_call_id": .string(id), "content": .string(Self.resultText(content, isError: isError))])
                    case .providerNative(let raw): if case .object = raw { parts.append(raw); onlyText = false }
                    case .toolUse, .thinking: break
                    }
                }
                if !parts.isEmpty { out.append(["role": "user", "content": onlyText ? .string(text) : .array(parts)]) }
            case .assistant:
                var text = ""
                var calls: [JSONValue] = []
                for b in m.content {
                    switch b {
                    case .text(let t): text += t
                    case let .toolUse(id, name, input):
                        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                        let args = String(decoding: try enc.encode(input), as: UTF8.self)
                        calls.append(["id": .string(id), "type": "function", "function": ["name": .string(name), "arguments": .string(args)]])
                    case .providerNative, .thinking, .image, .toolResult: break
                    }
                }
                var d: [String: JSONValue] = ["role": "assistant", "content": .string(text)]
                if !calls.isEmpty { d["tool_calls"] = .array(calls) }
                out.append(.object(d))
            }
        }
        return out
    }

    /// A tool result's `content` (a string, or an array of Messages-API text blocks) as the one string the
    /// `tool` message carries. An error result is prefixed so the model reads it as one.
    static func resultText(_ content: JSONValue, isError: Bool) -> String {
        var text: String
        switch content {
        case .string(let s): text = s
        case .array(let blocks): text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: text = (try? String(decoding: JSONEncoder().encode(content), as: UTF8.self)) ?? ""
        }
        if isError { text = "Error: " + text }
        return text
    }

    /// A function tool (https://lmstudio.ai/docs/developer/openai-compat/tools: `{"type": "function", "function":
    /// {"name", "description", "parameters"}}`). `strict` is not sent: it is not in either server's documentation.
    static func wireTool(_ t: ModelToolDefinition) -> JSONValue {
        ["type": "function", "function": ["name": .string(t.name), "description": .string(t.description), "parameters": t.inputSchema]]
    }

    // MARK: Stream

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var mode = structuredOutput
                    var response = try await client.stream(try buildRequest(request, structuredOutput: mode))
                    if response.status == 400, mode == .responseFormat, request.outputSchema != nil {
                        // The documented fallback: a server (or model) that refuses `response_format` gets the
                        // schema as an instruction instead.
                        let body = try await response.collectBody()
                        onStructuredOutputFallback?(Self.error(status: 400, body: body, requestId: response.header("x-request-id")))
                        mode = .instruction
                        response = try await client.stream(try buildRequest(request, structuredOutput: mode))
                    }
                    guard (200..<300).contains(response.status) else {
                        let body = try await response.collectBody()
                        throw Self.error(status: response.status, body: body, requestId: response.header("x-request-id"))
                    }
                    var parser = SSEParser()
                    var mapper = EventMapper(model: request.model)
                    for try await chunk in StallWatchdog.guarded(response.body, timeout: stallTimeout) {
                        for sse in try parser.feed(chunk) { for event in try mapper.map(sse) { continuation.yield(event) } }
                    }
                    if let last = parser.flush() { for event in try mapper.map(last) { continuation.yield(event) } }
                    // A server that closes after the last chunk without `[DONE]` still ended the message when it
                    // sent a finish_reason.
                    if !mapper.finished, mapper.stopReason != nil { for event in mapper.finish() { continuation.yield(event) } }
                    guard mapper.finished else { throw ProviderError.invalidResponse("stream ended before [DONE]") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `GET {base}/v1/models`: `{"object": "list", "data": [{"id", "object": "model", "created", "owned_by"}]}`.
    /// Both servers return this shape; Ollama documents `created` as the model's last modification time and
    /// `owned_by` as the Ollama username, "defaulting to `library`" (https://docs.ollama.com/api/openai-compatibility);
    /// LM Studio's `id` is the model identifier its My Models tab shows (https://lmstudio.ai/docs/developer/openai-compat).
    public func models() async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        req.httpMethod = "GET"
        apiKey?.withValue { req.setValue("Bearer \($0)", forHTTPHeaderField: "authorization") }
        let response = try await client.stream(req)
        let body = try await response.collectBody()
        guard (200..<300).contains(response.status) else { throw Self.error(status: response.status, body: body, requestId: response.header("x-request-id")) }
        let json = try JSONValue(data: body)
        guard let data = json["data"]?.arrayValue else { throw ProviderError.invalidResponse("/v1/models without a data array") }
        return data.compactMap { $0["id"]?.stringValue }
    }

    /// The error body. OpenAI's shape is `{"error": {"message", "type", "code"}}`, which Ollama uses; LM Studio
    /// has been observed to answer `{"error": "text"}`, so a string `error` is taken as the message.
    static func error(status: Int, body: Data, requestId: String?) -> ProviderError {
        let json = try? JSONValue(data: body)
        if let text = json?["error"]?.stringValue { return .http(status: status, type: nil, message: text, requestId: requestId) }
        return .http(status: status, type: json?["error"]?["type"]?.stringValue ?? json?["error"]?["code"]?.stringValue,
                     message: json?["error"]?["message"]?.stringValue, requestId: requestId)
    }

    /// Chat Completions chunks to `ModelEvent`s. Each `data:` line is one chunk with `choices[0].delta`
    /// (`role`, `content`, `reasoning_content` or `reasoning`, `tool_calls`) and `finish_reason`; `usage` arrives on
    /// the final chunk when `stream_options.include_usage` was honoured (Ollama sends it on a chunk with
    /// `choices: []`, as OpenAI does); `data: [DONE]` ends the stream. Blocks are given indices in order of
    /// appearance: one text block, one thinking block, and one `toolUse` block per `tool_calls[].index`.
    ///
    /// Tool calls: LM Studio streams "function names and arguments ... in pieces via
    /// `delta.tool_calls.function.name` and `delta.tool_calls.function.arguments`"
    /// (https://lmstudio.ai/docs/developer/openai-compat/tools), so a call's block is opened once its name has
    /// finished arriving (the first arguments piece, the next call, or the end); Ollama delivers a whole call in
    /// one chunk, which is the same path with one piece. A call without an `id` gets a minted one (`synthetic`).
    struct EventMapper {
        var model: String
        var started = false
        var usage = ModelUsage()
        var stopReason: ModelStopReason?
        var finished = false
        private var nextIndex = 0
        private var openText: Int?
        private var openThinking: Int?
        private struct PendingCall { var wireIndex: Int; var id: String?; var name: String; var arguments: String; var blockIndex: Int? }
        private var calls: [PendingCall] = []
        private var currentCall: Int?   // position in `calls`

        init(model: String) { self.model = model }

        mutating func map(_ sse: SSEEvent) throws -> [ModelEvent] {
            let data = sse.data.trimmingCharacters(in: .whitespaces)
            guard !data.isEmpty else { return [] }
            if data == "[DONE]" { return finish() }
            let d = try JSONValue(data: Data(data.utf8))
            if let err = d["error"], !err.isNull {
                throw ProviderError.stream(type: err["type"]?.stringValue ?? "error", message: err["message"]?.stringValue ?? err.stringValue ?? "")
            }
            var out: [ModelEvent] = []
            if !started {
                started = true
                if let m = d["model"]?.stringValue, !m.isEmpty { model = m }
                out.append(.started(model: model, usage: nil))
            }
            if let u = d["usage"], !u.isNull { usage = usage.merged(with: Self.usage(u)) }
            guard let choice = d["choices"]?.arrayValue?.first else { return out }
            let delta = choice["delta"] ?? .null
            if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"])?.stringValue, !reasoning.isEmpty {
                if openThinking == nil { out += closeText(); out += closeCurrentCall(); openThinking = nextIndex; nextIndex += 1; out.append(.blockStarted(index: openThinking!, block: .thinking)) }
                out.append(.thinkingDelta(index: openThinking!, text: reasoning))
            }
            if let text = delta["content"]?.stringValue, !text.isEmpty {
                if openText == nil { out += closeThinking(); out += closeCurrentCall(); openText = nextIndex; nextIndex += 1; out.append(.blockStarted(index: openText!, block: .text)) }
                out.append(.textDelta(index: openText!, text: text))
            }
            if let toolCalls = delta["tool_calls"]?.arrayValue {
                out += closeText(); out += closeThinking()
                for tc in toolCalls {
                    let fn = tc["function"] ?? .null
                    let id = tc["id"]?.stringValue
                    // Which call this piece belongs to: the wire `index` when given, else a piece with an id is a
                    // new call and a piece without one continues the current call.
                    let position: Int
                    if let wireIndex = tc["index"]?.intValue, let p = calls.firstIndex(where: { $0.wireIndex == wireIndex }) { position = p }
                    else if tc["index"]?.intValue == nil, id == nil, let c = currentCall { position = c }
                    else {
                        out += closeCurrentCall()
                        calls.append(PendingCall(wireIndex: tc["index"]?.intValue ?? calls.count, id: nil, name: "", arguments: "", blockIndex: nil))
                        position = calls.count - 1
                    }
                    if position != currentCall { out += closeCurrentCall(); currentCall = position }
                    if let id, calls[position].id == nil { calls[position].id = id }
                    if let namePiece = fn["name"]?.stringValue { calls[position].name += namePiece }
                    if let args = fn["arguments"]?.stringValue, !args.isEmpty {
                        out += openCall(position)
                        out.append(.toolInputDelta(index: calls[position].blockIndex!, partialJSON: args))
                    }
                }
            }
            // `finish_reason`: stop, length, tool_calls, content_filter (the Chat Completions values).
            if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty {
                stopReason = Self.stopReason(reason)
            }
            return out
        }

        /// Ends the message: closes open blocks, then `.finished`.
        mutating func finish() -> [ModelEvent] {
            guard !finished else { return [] }
            var out = closeText() + closeThinking() + closeCurrentCall()
            for p in calls.indices where calls[p].blockIndex == nil { out += openCall(p); out.append(.blockStopped(index: calls[p].blockIndex!)) }
            finished = true
            let reason = stopReason ?? (calls.isEmpty ? .endTurn : .toolUse)
            out.append(.finished(stopReason: reason, usage: usage, stopDetails: nil))
            return out
        }

        private mutating func openCall(_ p: Int) -> [ModelEvent] {
            guard calls[p].blockIndex == nil else { return [] }
            let id = calls[p].id ?? "call_" + UUID().uuidString.lowercased()
            calls[p].blockIndex = nextIndex; nextIndex += 1
            var out: [ModelEvent] = [.blockStarted(index: calls[p].blockIndex!, block: .toolUse(id: id, name: calls[p].name, synthetic: calls[p].id == nil))]
            if !calls[p].arguments.isEmpty { out.append(.toolInputDelta(index: calls[p].blockIndex!, partialJSON: calls[p].arguments)); calls[p].arguments = "" }
            return out
        }
        private mutating func closeCurrentCall() -> [ModelEvent] {
            guard let c = currentCall else { return [] }
            currentCall = nil
            var out = openCall(c)
            out.append(.blockStopped(index: calls[c].blockIndex!))
            return out
        }
        private mutating func closeText() -> [ModelEvent] { guard let i = openText else { return [] }; openText = nil; return [.blockStopped(index: i)] }
        private mutating func closeThinking() -> [ModelEvent] { guard let i = openThinking else { return [] }; openThinking = nil; return [.blockStopped(index: i)] }

        static func stopReason(_ s: String) -> ModelStopReason {
            switch s {
            case "stop": return .endTurn
            case "length": return .maxTokens
            case "tool_calls", "function_call": return .toolUse
            case "content_filter": return .refusal
            default: return .other(s)
            }
        }

        /// `usage`: `prompt_tokens`, `completion_tokens`, and `prompt_tokens_details.cached_tokens` when present
        /// (Ollama sends it; observed 2026-09-20).
        static func usage(_ u: JSONValue) -> ModelUsage {
            ModelUsage(inputTokens: u["prompt_tokens"]?.intValue ?? 0, outputTokens: u["completion_tokens"]?.intValue ?? 0,
                       cacheReadInputTokens: u["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0)
        }
    }
}
