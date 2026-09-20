import Testing
import Foundation
import Synchronization
import AgentProtocol
import AgentTestKit
@testable import AgentDirect

/// A `URLProtocol` that answers scripted responses, so the provider is exercised through `URLSession.bytes(for:)`
/// and the real newline chunking rather than a fake client. Scripts are keyed by URL path and consumed in order;
/// every request is recorded.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable { var status: Int; var headers: [String: String] = [:]; var chunks: [Data] }
    nonisolated(unsafe) static let script = Mutex<[String: [Response]]>([:])
    nonisolated(unsafe) static let requests = Mutex<[URLRequest]>([])

    static func reset(_ s: [String: [Response]]) { script.withLock { $0 = s }; requests.withLock { $0 = [] } }
    /// A Chat Completions SSE body: one `data:` line per chunk, then `[DONE]` unless `done` is false.
    static func sse(_ lines: [String], done: Bool = true, status: Int = 200) -> Response {
        Response(status: status, headers: ["content-type": "text/event-stream"],
                 chunks: lines.map { Data("data: \($0)\n\n".utf8) } + (done ? [Data("data: [DONE]\n\n".utf8)] : []))
    }
    static func json(_ text: String, status: Int = 200) -> Response {
        Response(status: status, headers: ["content-type": "application/json"], chunks: [Data(text.utf8)])
    }
    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {   // URLSession hands the body over as a stream
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            recorded.httpBody = data
        }
        Self.requests.withLock { $0.append(recorded) }
        let path = request.url?.path ?? ""
        guard let next = Self.script.withLock({ s -> Response? in guard var list = s[path], !list.isEmpty else { return nil }; let r = list.removeFirst(); s[path] = list; return r }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in next.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct OpenAICompatibleProviderTests {
    static let base = URL(string: "http://127.0.0.1:1235")!
    static func provider(_ mode: OpenAICompatibleProvider.StructuredOutputMode = .responseFormat, key: Secret? = nil,
                         onFallback: (@Sendable (ProviderError) -> Void)? = nil) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(baseURL: Self.base, apiKey: key, client: URLSessionStreamingClient(session: StubURLProtocol.session),
                                 stallTimeout: 5, structuredOutput: mode, onStructuredOutputFallback: onFallback)
    }
    static let request = ModelRequest(model: "qwen3", system: ["Be brief."], messages: [.user("hi")],
                                      tools: [ModelToolDefinition(name: "get_weather", description: "Weather", inputSchema: ["type": "object", "properties": ["location": ["type": "string"]]])],
                                      maxTokens: 64)
    static func collect(_ p: OpenAICompatibleProvider, _ r: ModelRequest = request) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await e in p.stream(r) { events.append(e) }
        return events
    }
    static func lastBody() throws -> JSONValue { try JSONValue(data: StubURLProtocol.requests.withLock { $0 }.last!.httpBody ?? Data()) }

    @Test func bodyFollowsTheChatCompletionsShapeAndStripsV1() throws {
        let p = OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:1234/v1")!, apiKey: Secret("lm-token"), client: FakeStreamingHTTPClient([]))
        #expect(p.baseURL.absoluteString == "http://localhost:1234")
        var r = Self.request
        r.messages = [.user("hi"),
                      ModelMessage(role: .assistant, content: [.text("Let me check."), .toolUse(id: "call_1", name: "get_weather", input: ["location": "SF"]), .thinking("hmm", signature: nil)]),
                      ModelMessage(role: .user, content: [.toolResult(toolUseId: "call_1", content: .array([["type": "text", "text": "Sunny"]]), isError: false),
                                                          .toolResult(toolUseId: "call_2", content: "boom", isError: true)]),
                      ModelMessage(role: .user, content: [.text("and a picture"), .image(base64: "QUJD", mediaType: "image/png")])]
        r.effort = "low"; r.outputSchema = ["type": "object"]
        r.providerOptions["openai-compatible"] = ["temperature": 0.2]
        let body = try p.body(for: r, structuredOutput: .responseFormat)
        #expect(body["model"] == "qwen3"); #expect(body["stream"] == true); #expect(body["max_tokens"] == 64)
        #expect(body["stream_options"] == ["include_usage": true]); #expect(body["temperature"] == 0.2); #expect(body["reasoning_effort"] == "low")
        #expect(body["tools"] == [["type": "function", "function": ["name": "get_weather", "description": "Weather", "parameters": ["type": "object", "properties": ["location": ["type": "string"]]]]]])
        #expect(body["response_format"] == ["type": "json_schema", "json_schema": ["name": "answer", "strict": true, "schema": ["type": "object"]]])
        let messages = body["messages"]!.arrayValue!
        #expect(messages[0] == ["role": "system", "content": "Be brief."])
        #expect(messages[1] == ["role": "user", "content": "hi"])
        #expect(messages[2] == ["role": "assistant", "content": "Let me check.", "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "get_weather", "arguments": "{\"location\":\"SF\"}"]]]])
        #expect(messages[3] == ["role": "tool", "tool_call_id": "call_1", "content": "Sunny"])
        #expect(messages[4] == ["role": "tool", "tool_call_id": "call_2", "content": "Error: boom"])
        #expect(messages[5] == ["role": "user", "content": [["type": "text", "text": "and a picture"], ["type": "image_url", "image_url": ["url": "data:image/png;base64,QUJD"]]]])
        // Instruction mode: no response_format, schema appended to the system message.
        let instructed = try p.body(for: r, structuredOutput: .instruction)
        #expect(instructed["response_format"] == nil)
        #expect(instructed["messages"]![0]!["content"]!.stringValue!.contains("JSON Schema"))
        let req = try p.buildRequest(r, structuredOutput: .responseFormat)
        #expect(req.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer lm-token")
        #expect(try OpenAICompatibleProvider(baseURL: Self.base, client: FakeStreamingHTTPClient([])).buildRequest(r, structuredOutput: .instruction).value(forHTTPHeaderField: "authorization") == nil)
        var budget = r; budget.thinking = .budget(tokens: 100, display: .summarized)
        #expect(throws: ProviderError.self) { try p.body(for: budget, structuredOutput: .responseFormat) }
    }

    @Test func plainAnswerWithUsageOnTheFinalChunk() async throws {
        // Ollama's chunks as recorded on this Mac 2026-09-20: content deltas, a finish_reason chunk, a usage-only chunk, [DONE].
        StubURLProtocol.reset(["/v1/chat/completions": [StubURLProtocol.sse([
            #"{"id":"chatcmpl-1","object":"chat.completion.chunk","model":"lfm2:latest","choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-1","object":"chat.completion.chunk","model":"lfm2:latest","choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-1","object":"chat.completion.chunk","model":"lfm2:latest","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"{"id":"chatcmpl-1","object":"chat.completion.chunk","model":"lfm2:latest","choices":[],"usage":{"prompt_tokens":15,"prompt_tokens_details":{"cached_tokens":3},"completion_tokens":2,"total_tokens":17}}"#,
        ])]])
        let events = try await Self.collect(Self.provider())
        #expect(events == [.started(model: "lfm2:latest", usage: nil), .blockStarted(index: 0, block: .text), .textDelta(index: 0, text: "Hel"),
                           .textDelta(index: 0, text: "lo"), .blockStopped(index: 0),
                           .finished(stopReason: .endTurn, usage: ModelUsage(inputTokens: 15, outputTokens: 2, cacheReadInputTokens: 3), stopDetails: nil)])
        #expect(StubURLProtocol.requests.withLock { $0 }.count == 1)
        #expect(try Self.lastBody()["response_format"] == nil)
    }

    @Test func toolCallSplitAcrossDeltas() async throws {
        // LM Studio's style: name and arguments in pieces (tools page), one call at wire index 0; then a second
        // call delivered whole, Ollama's style, without an id.
        StubURLProtocol.reset(["/v1/chat/completions": [StubURLProtocol.sse([
            #"{"model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"Checking"},"finish_reason":null}]}"#,
            #"{"model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_","arguments":""}}]},"finish_reason":null}]}"#,
            #"{"model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"weather"}}]},"finish_reason":null}]}"#,
            #"{"model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"loc"}}]},"finish_reason":null}]}"#,
            #"{"model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ation\":\"SF\"}"}}]},"finish_reason":null}]}"#,
            #"{"model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"type":"function","function":{"name":"get_weather","arguments":"{\"location\":\"LA\"}"}}]},"finish_reason":null}]}"#,
            #"{"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])]])
        let events = try await Self.collect(Self.provider())
        #expect(events[0] == .started(model: "m", usage: nil))
        #expect(events[1] == .blockStarted(index: 0, block: .text)); #expect(events[2] == .textDelta(index: 0, text: "Checking")); #expect(events[3] == .blockStopped(index: 0))
        #expect(events[4] == .blockStarted(index: 1, block: .toolUse(id: "call_abc", name: "get_weather", synthetic: false)))
        #expect(events[5] == .toolInputDelta(index: 1, partialJSON: "{\"loc")); #expect(events[6] == .toolInputDelta(index: 1, partialJSON: "ation\":\"SF\"}"))
        #expect(events[7] == .blockStopped(index: 1))
        guard case .blockStarted(2, .toolUse(let id, "get_weather", true)) = events[8] else { Issue.record("second call not started: \(events[8])"); return }
        #expect(id.hasPrefix("call_"))
        #expect(events[9] == .toolInputDelta(index: 2, partialJSON: "{\"location\":\"LA\"}")); #expect(events[10] == .blockStopped(index: 2))
        #expect(events[11] == .finished(stopReason: .toolUse, usage: ModelUsage(), stopDetails: nil))
        #expect(events.count == 12)
    }

    @Test func doneWithoutUsageAndLengthStop() async throws {
        StubURLProtocol.reset(["/v1/chat/completions": [StubURLProtocol.sse([
            #"{"model":"m","choices":[{"index":0,"delta":{"reasoning_content":"think"},"finish_reason":null}]}"#,
            #"{"model":"m","choices":[{"index":0,"delta":{"content":"cut"},"finish_reason":"length"}]}"#,
        ])]])
        let events = try await Self.collect(Self.provider())
        #expect(events == [.started(model: "m", usage: nil), .blockStarted(index: 0, block: .thinking), .thinkingDelta(index: 0, text: "think"), .blockStopped(index: 0),
                           .blockStarted(index: 1, block: .text), .textDelta(index: 1, text: "cut"), .blockStopped(index: 1),
                           .finished(stopReason: .maxTokens, usage: ModelUsage(), stopDetails: nil)])
    }

    @Test func streamEndingWithoutDoneOrFinishIsInvalid() async throws {
        StubURLProtocol.reset(["/v1/chat/completions": [StubURLProtocol.sse([#"{"model":"m","choices":[{"index":0,"delta":{"content":"x"},"finish_reason":null}]}"#], done: false)]])
        await #expect(throws: ProviderError.invalidResponse("stream ended before [DONE]")) { _ = try await Self.collect(Self.provider()) }
    }

    @Test func responseFormat400FallsBackToAnInstruction() async throws {
        StubURLProtocol.reset(["/v1/chat/completions": [
            StubURLProtocol.json(#"{"error":{"message":"response_format is not supported by this model","type":"invalid_request_error"}}"#, status: 400),
            StubURLProtocol.sse([#"{"model":"m","choices":[{"index":0,"delta":{"content":"{\"ok\":true}"},"finish_reason":"stop"}]}"#]),
        ]])
        let fallback = Mutex<ProviderError?>(nil)
        var r = Self.request; r.outputSchema = ["type": "object"]
        let events = try await Self.collect(Self.provider(onFallback: { e in fallback.withLock { $0 = e } }), r)
        #expect(fallback.withLock { $0 } == .http(status: 400, type: "invalid_request_error", message: "response_format is not supported by this model", requestId: nil))
        let requests = StubURLProtocol.requests.withLock { $0 }
        #expect(requests.count == 2)
        let first = try JSONValue(data: requests[0].httpBody!), second = try JSONValue(data: requests[1].httpBody!)
        #expect(first["response_format"] != nil); #expect(second["response_format"] == nil)
        #expect(second["messages"]![0]!["content"]!.stringValue!.contains("{\"type\":\"object\"}"))
        #expect(events.contains(.textDelta(index: 0, text: "{\"ok\":true}")))
        // A 400 on a request without a schema is an error, with LM Studio's string-form body read as the message.
        StubURLProtocol.reset(["/v1/chat/completions": [StubURLProtocol.json(#"{"error":"Model not loaded"}"#, status: 400)]])
        await #expect(throws: ProviderError.http(status: 400, type: nil, message: "Model not loaded", requestId: nil)) { _ = try await Self.collect(Self.provider()) }
    }

    @Test func modelsList() async throws {
        StubURLProtocol.reset(["/v1/models": [StubURLProtocol.json(#"{"object":"list","data":[{"id":"qwen3.5:latest","object":"model","created":1773363860,"owned_by":"library"},{"id":"gemma3:latest","object":"model","created":1,"owned_by":"library"}]}"#)]])
        let models = try await Self.provider(key: Secret("t")).models()
        #expect(models == ["qwen3.5:latest", "gemma3:latest"])
        let req = StubURLProtocol.requests.withLock { $0 }.last!
        #expect(req.url?.absoluteString == "http://127.0.0.1:1235/v1/models"); #expect(req.httpMethod == "GET")
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer t")
    }
}
