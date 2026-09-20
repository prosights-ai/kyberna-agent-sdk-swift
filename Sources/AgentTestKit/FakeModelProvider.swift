import Foundation
import Synchronization
import AgentProtocol
import AgentDirect

/// A scripted `ModelProvider` for tests that run without a network (plan 9.7, ADR 0015 point 4). Each call to
/// `stream` consumes the next script entry: a list of `ModelEvent`s to replay, an error to throw, or a closure
/// that looks at the request and answers. Every request is recorded for assertions.
public final class FakeModelProvider: ModelProvider, Sendable {
    public enum Turn: Sendable {
        /// Replayed in order, each after `delay`.
        case events([ModelEvent])
        case failure(any Error)
        /// Decides from the request it receives.
        case respond(@Sendable (ModelRequest) -> [ModelEvent])
    }

    public let id: String
    private let script: Mutex<[Turn]>
    private let recorded = Mutex<[ModelRequest]>([])
    /// Pause between events, so a test can interrupt mid-stream.
    public let delay: Duration

    public init(id: String = "fake", script: [Turn], delay: Duration = .zero) {
        self.id = id; self.script = Mutex(script); self.delay = delay
    }

    /// Every request received, in order.
    public var requests: [ModelRequest] { recorded.withLock { $0 } }
    public var remainingTurns: Int { script.withLock { $0.count } }
    public func append(_ turn: Turn) { script.withLock { $0.append(turn) } }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        recorded.withLock { $0.append(request) }
        let next: Turn? = script.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        let delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let next else { continuation.finish(throwing: ProviderError.invalidResponse("FakeModelProvider script exhausted")); return }
                let events: [ModelEvent]
                switch next {
                case .events(let e): events = e
                case .respond(let f): events = f(request)
                case .failure(let error): continuation.finish(throwing: error); return
                }
                for event in events {
                    if delay > .zero { try await Task.sleep(for: delay) }
                    try Task.checkCancellation()
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Script helpers

    /// A complete text reply: started, one text block, finished with `end_turn`.
    public static func text(_ text: String, model: String = "fake-model", usage: ModelUsage = ModelUsage(inputTokens: 10, outputTokens: 5)) -> [ModelEvent] {
        [.started(model: model, usage: ModelUsage(inputTokens: usage.inputTokens)), .blockStarted(index: 0, block: .text),
         .textDelta(index: 0, text: text), .blockStopped(index: 0), .finished(stopReason: .endTurn, usage: usage, stopDetails: nil)]
    }

    /// A reply that calls tools: optional text, then one `tool_use` block per call (input as JSON fragments), `tool_use` stop.
    public static func toolCalls(_ calls: [(id: String, name: String, input: JSONValue)], text: String? = nil, model: String = "fake-model",
                                 usage: ModelUsage = ModelUsage(inputTokens: 20, outputTokens: 15)) -> [ModelEvent] {
        var events: [ModelEvent] = [.started(model: model, usage: ModelUsage(inputTokens: usage.inputTokens))]
        var index = 0
        if let text { events += [.blockStarted(index: 0, block: .text), .textDelta(index: 0, text: text), .blockStopped(index: 0)]; index = 1 }
        for call in calls {
            let json = call.input.canonicalJSON
            let half = json.index(json.startIndex, offsetBy: json.count / 2)
            events += [.blockStarted(index: index, block: .toolUse(id: call.id, name: call.name, synthetic: false)),
                       .toolInputDelta(index: index, partialJSON: String(json[..<half])),
                       .toolInputDelta(index: index, partialJSON: String(json[half...])),
                       .blockStopped(index: index)]
            index += 1
        }
        events.append(.finished(stopReason: .toolUse, usage: usage, stopDetails: nil))
        return events
    }

    /// A refusal: no content, `refusal` stop with details.
    public static func refusal(category: String? = "general_harms", explanation: String? = "Declined.", model: String = "fake-model") -> [ModelEvent] {
        [.started(model: model, usage: nil), .finished(stopReason: .refusal, usage: ModelUsage(inputTokens: 5), stopDetails: ModelStopDetails(category: category, explanation: explanation))]
    }
}

/// A scripted `StreamingHTTPClient`: each call takes the next response, so a test can answer 429 then 200 and
/// feed raw SSE bytes through the real parser (plan 9.7). Requests are recorded.
public final class FakeStreamingHTTPClient: StreamingHTTPClient, Sendable {
    public struct Scripted: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var chunks: [Data]
        public init(status: Int, headers: [String: String] = [:], chunks: [Data]) { self.status = status; self.headers = headers; self.chunks = chunks }
        /// An SSE body from `(event, data)` pairs, one chunk per event.
        public static func sse(status: Int = 200, headers: [String: String] = [:], _ events: [(String, String)]) -> Scripted {
            Scripted(status: status, headers: headers, chunks: events.map { Data("event: \($0.0)\ndata: \($0.1)\n\n".utf8) })
        }
    }
    private let script: Mutex<[Scripted]>
    private let recorded = Mutex<[URLRequest]>([])
    public init(_ script: [Scripted]) { self.script = Mutex(script) }
    public var requests: [URLRequest] { recorded.withLock { $0 } }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        recorded.withLock { $0.append(request) }
        guard let next = script.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw ProviderError.transport("FakeStreamingHTTPClient script exhausted") }
        let chunks = next.chunks
        return HTTPStreamResponse(status: next.status, headers: next.headers, body: AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish()
        })
    }
}
