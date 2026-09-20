import Testing
import Foundation
import Synchronization
import AgentProtocol
import AgentSession
import AgentTestKit
@testable import AgentDirect

extension Tag { @Tag static var requiresNetwork: Self }

@Suite struct SSEParserTests {
    @Test func splitsEventsAcrossArbitraryChunks() throws {
        let text = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n: comment\nevent: content_block_delta\ndata: {\"a\":1,\ndata: \"b\":2}\r\n\r\nevent: message_stop\ndata: {}\n\n"
        let bytes = Array(text.utf8)
        var parser = SSEParser()
        var events: [SSEEvent] = []
        var i = 0
        while i < bytes.count { let n = min(7, bytes.count - i); events += try parser.feed(Data(bytes[i..<i + n])); i += n }
        #expect(events.count == 3)
        #expect(events[0] == SSEEvent(event: "message_start", data: "{\"type\":\"message_start\"}"))
        #expect(events[1].data == "{\"a\":1,\n\"b\":2}")
        #expect(events[2].event == "message_stop")
        #expect(parser.flush() == nil)
    }
}

@Suite struct AnthropicProviderTests {
    static let key = Secret("sk-ant-test-not-a-real-key")
    static let request = ModelRequest(model: "claude-test", system: ["S1", "S2"], messages: [.user("hi")],
                                      tools: [ModelToolDefinition(name: "a", description: "A", inputSchema: ["type": "object"]),
                                              ModelToolDefinition(name: "b", description: "B", inputSchema: ["type": "object"], strict: true)],
                                      maxTokens: 123, thinking: .adaptive(display: .summarized), effort: "low",
                                      outputSchema: ["type": "object", "additionalProperties": false])

    @Test func bodyAndHeadersFollowTheMessagesAPI() throws {
        let provider = AnthropicProvider(apiKey: Self.key, betas: ["x-beta"], client: FakeStreamingHTTPClient([]))
        let body = try provider.body(for: Self.request)
        #expect(body["model"] == "claude-test"); #expect(body["max_tokens"] == 123); #expect(body["stream"] == true)
        // Cache markers on the stable prefix only: the last tool and the last system block.
        let tools = body["tools"]!.arrayValue!
        #expect(tools[0]["cache_control"] == nil); #expect(tools[1]["cache_control"] == ["type": "ephemeral"]); #expect(tools[1]["strict"] == true)
        let system = body["system"]!.arrayValue!
        #expect(system[0] == ["type": "text", "text": "S1"]); #expect(system[1] == ["type": "text", "text": "S2", "cache_control": ["type": "ephemeral"]])
        #expect(body["messages"]![0] == ["role": "user", "content": [["type": "text", "text": "hi"]]])
        #expect(body["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(body["output_config"] == ["effort": "low", "format": ["type": "json_schema", "schema": ["type": "object", "additionalProperties": false]]])
        var uncached = Self.request; uncached.cachesPrefix = false
        let uncachedTools = try provider.body(for: uncached)["tools"]!.arrayValue!
        #expect(uncachedTools[1]["cache_control"] == nil)

        let req = try provider.buildRequest(Self.request)
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages"); #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "x-beta")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-not-a-real-key")
        #expect(String(describing: provider.apiKey) == "Secret(<redacted>)")
        // Sorted keys: the same request encodes to the same bytes, so the cache prefix is stable.
        let again = try provider.buildRequest(Self.request)
        #expect(req.httpBody == again.httpBody)
    }

    @Test func toolResultsImagesAndContinuityBlocksMap() throws {
        let m = ModelMessage(role: .user, content: [
            .toolResult(toolUseId: "t", content: .array([["type": "text", "text": "x"]]), isError: true),
            .image(base64: "QUJD", mediaType: "image/png"), .thinking("t", signature: "sig"), .providerNative(["type": "redacted_thinking", "data": "d"])])
        let wire = try AnthropicProvider.wireMessage(m)
        #expect(wire["content"]![0] == ["type": "tool_result", "tool_use_id": "t", "content": [["type": "text", "text": "x"]], "is_error": true])
        #expect(wire["content"]![1] == ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "QUJD"]])
        #expect(wire["content"]![2] == ["type": "thinking", "thinking": "t", "signature": "sig"])
        #expect(wire["content"]![3] == ["type": "redacted_thinking", "data": "d"])
        #expect(throws: ProviderError.capabilityMismatch("image media type image/tiff; Anthropic accepts image/jpeg, image/png, image/gif, image/webp")) {
            try AnthropicProvider.wireBlock(.image(base64: "", mediaType: "image/tiff"))
        }
    }

    static let toolUseSSE: [(String, String)] = [
        ("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-test","content":[],"stop_reason":null,"usage":{"input_tokens":472,"output_tokens":2,"cache_read_input_tokens":400,"cache_creation_input_tokens":0}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        ("ping", #"{"type":"ping"}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Okay"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"get_weather","input":{}}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \"SF\"}"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ]

    @Test func retriesA429ThenParsesTheStream() async throws {
        let http = FakeStreamingHTTPClient([
            .init(status: 429, headers: ["retry-after": "0", "request-id": "req_a"], chunks: [Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8)]),
            .sse(Self.toolUseSSE),
        ])
        let slept = Mutex<[TimeInterval]>([])
        let retried = Mutex<[(Int, ProviderError)]>([])
        let client = RetryingHTTPClient(inner: http, sleep: { s in slept.withLock { $0.append(s) } }, onRetry: { a, e in retried.withLock { $0.append((a, e)) } })
        let provider = AnthropicProvider(apiKey: Self.key, client: client)
        var events: [ModelEvent] = []
        for try await e in provider.stream(Self.request) { events.append(e) }
        #expect(http.requests.count == 2)
        #expect(slept.withLock { $0 } == [0])
        #expect(retried.withLock { $0.map { $0.0 } } == [1])
        #expect(retried.withLock { $0[0].1 } == .http(status: 429, type: "rate_limit_error", message: "slow down", requestId: "req_a"))
        #expect(events.first == .started(model: "claude-test", usage: ModelUsage(inputTokens: 472, outputTokens: 2, cacheReadInputTokens: 400)))
        #expect(events.contains(.textDelta(index: 0, text: "Okay")))
        #expect(events.contains(.blockStarted(index: 1, block: .toolUse(id: "toolu_01", name: "get_weather", synthetic: false))))
        #expect(events.last == .finished(stopReason: .toolUse, usage: ModelUsage(inputTokens: 472, outputTokens: 89, cacheReadInputTokens: 400), stopDetails: nil))
        // The engine's accumulator turns that into blocks with parsed input.
        var acc = ResponseAccumulator(model: "")
        for e in events { acc.apply(e) }
        #expect(acc.blocks == [.text("Okay"), .toolUse(id: "toolu_01", name: "get_weather", input: ["location": "SF"])])
    }

    @Test func nonRetryableStatusAndStreamErrorsSurfaceAsProviderErrors() async {
        let http = FakeStreamingHTTPClient([
            .init(status: 400, headers: ["request-id": "req_b"], chunks: [Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#.utf8)]),
            .sse([("message_start", #"{"type":"message_start","message":{"model":"m","usage":{"input_tokens":1}}}"#), ("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)]),
            .sse([("message_start", #"{"type":"message_start","message":{"model":"m","usage":{"input_tokens":1}}}"#)]),
        ])
        let provider = AnthropicProvider(apiKey: Self.key, client: RetryingHTTPClient(inner: http, sleep: { _ in }))
        func firstError() async -> ProviderError? {
            do { for try await _ in provider.stream(Self.request) {} } catch let e as ProviderError { return e } catch { return nil }
            return nil
        }
        #expect(await firstError() == .http(status: 400, type: "invalid_request_error", message: "bad", requestId: "req_b"))
        #expect(await firstError() == .stream(type: "overloaded_error", message: "Overloaded"))
        #expect(await firstError() == .invalidResponse("stream ended before message_stop"))
        #expect(http.requests.count == 3)
    }

    @Test func retryPolicyDelays() {
        let p = RetryPolicy()
        #expect(p.delay(beforeAttempt: 2, retryAfter: "3") == 3)
        #expect(p.delay(beforeAttempt: 2, retryAfter: "nonsense", random: 1) == 1)   // 0.5 * 2^1
        #expect(p.delay(beforeAttempt: 6, retryAfter: nil, random: 1) == 8)         // capped
        #expect(p.delay(beforeAttempt: 3, retryAfter: nil, random: 0) == 0)         // full jitter reaches zero
    }

    @Test func stallWatchdogEndsAnIdleStream() async {
        let never = AsyncThrowingStream<Data, Error> { _ in }
        var caught: ProviderError?
        do { for try await _ in StallWatchdog.guarded(never, timeout: 0.2) {} } catch let e as ProviderError { caught = e } catch {}
        #expect(caught == .stalled(seconds: 0.2))
    }

    @Test func refusalStopDetailsAreMapped() throws {
        var mapper = AnthropicProvider.EventMapper()
        _ = try mapper.map(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{"model":"m","usage":{"input_tokens":3}}}"#))
        _ = try mapper.map(SSEEvent(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"no"}},"usage":{"output_tokens":0}}"#))
        let done = try mapper.map(SSEEvent(event: "message_stop", data: #"{"type":"message_stop"}"#))
        #expect(done == [.finished(stopReason: .refusal, usage: ModelUsage(inputTokens: 3), stopDetails: ModelStopDetails(category: "cyber", explanation: "no"))])
    }

    /// Off by default: runs only with `KYBERNA_LIVE=1` and an `ANTHROPIC_API_KEY` in the environment, on the
    /// cheapest current model, one short exchange with one tool call.
    @Test(.tags(.requiresNetwork), .enabled(if: ProcessInfo.processInfo.environment["KYBERNA_LIVE"] == "1" && ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil))
    func liveAnthropicToolCall() async throws {
        let key = Secret(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!)
        let provider = AnthropicProvider(apiKey: key)
        var options = DirectEngineOptions(model: ProcessInfo.processInfo.environment["KYBERNA_LIVE_MODEL"] ?? "claude-haiku-4-5")
        options.systemPrompt = "Use the word_count tool to count words when asked; answer with the number only."
        options.maxTokens = 300
        let engine = DirectAPIEngine(provider: provider, options: options)
        try engine.host([Tools.wordCount], serverName: "kyberna")
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("How many words: 'the quick brown fox jumps'?")
        let turn = await collector.untilResult()
        let r = try #require(turn.result)
        #expect(r.subtype == "success")
        #expect(turn.users.first?.content.first?.resultText == "5")
        #expect(r.result?.contains("5") == true)
    }
}
