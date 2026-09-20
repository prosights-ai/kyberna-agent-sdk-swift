import Foundation
import Synchronization

// MARK: - The HTTP layer providers stream through
//
// Retry lives here, not in the agent loop (plan 9.3): a provider hands its `URLRequest` to a
// `StreamingHTTPClient` and gets back the status, the headers, and the body as it arrives. Tests inject a scripted
// client; production uses `URLSessionStreamingClient` wrapped in `RetryingHTTPClient`.

/// A streamed HTTP exchange: the response head, then body chunks as the connection delivers them.
public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>
    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.status = status; self.headers = headers; self.body = body
    }
    /// A header by case-insensitive name.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    /// The whole body as one buffer (for error bodies).
    public func collectBody(limit: Int = 1 << 20) async throws -> Data {
        var out = Data()
        for try await chunk in body { out.append(chunk); if out.count >= limit { break } }
        return out
    }
}

/// Opens one request and streams the response. Throws `ProviderError.transport` when no status arrives.
public protocol StreamingHTTPClient: Sendable {
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse
}

/// `URLSession.bytes(for:)`, chunked at newlines so an SSE line reaches the parser as soon as it is complete.
public struct URLSessionStreamingClient: StreamingHTTPClient {
    public var session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request) }
        catch let e as URLError { throw ProviderError.transport(e.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.transport("not an HTTP response") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { headers[k] = v } }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let reader = Task {
                var line = Data()
                do {
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A { continuation.yield(line); line = Data() }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
                catch { continuation.finish(throwing: ProviderError.transport(error.localizedDescription)) }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        return HTTPStreamResponse(status: http.statusCode, headers: headers, body: body)
    }
}

// MARK: - Retry

/// Three attempts, full jitter, `Retry-After` honoured, on 408/429/500/502/503/504 and connection failures
/// (plan 9.3, after AgentRunKit's `RetryPolicy`). A retry happens only before any body byte is consumed; once a
/// stream has started, a failure is the provider's to report.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var retryableStatuses: Set<Int>
    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8, retryableStatuses: Set<Int> = ProviderError.retryableStatuses) {
        self.maxAttempts = maxAttempts; self.baseDelay = baseDelay; self.maxDelay = maxDelay; self.retryableStatuses = retryableStatuses
    }
    /// The wait before attempt `attempt` (1-based, so the first retry is attempt 2): the server's `Retry-After`
    /// in seconds when given and sane, otherwise a uniform draw from 0 to `min(maxDelay, baseDelay * 2^(attempt-1))`.
    public func delay(beforeAttempt attempt: Int, retryAfter: String?, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        if let retryAfter, let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0, seconds <= 60 { return seconds }
        let cap = min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        return cap * random
    }
}

/// Wraps a client with `RetryPolicy`. `sleep` is injectable so tests run without waiting.
public struct RetryingHTTPClient: StreamingHTTPClient {
    public var inner: any StreamingHTTPClient
    public var policy: RetryPolicy
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Called with the attempt number and the reason before each retry, for logs.
    public var onRetry: (@Sendable (Int, ProviderError) -> Void)?

    public init(inner: any StreamingHTTPClient, policy: RetryPolicy = RetryPolicy(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                onRetry: (@Sendable (Int, ProviderError) -> Void)? = nil) {
        self.inner = inner; self.policy = policy; self.sleep = sleep; self.onRetry = onRetry
    }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        var attempt = 1
        while true {
            let failure: ProviderError, retryAfter: String?
            do {
                let response = try await inner.stream(request)
                guard policy.retryableStatuses.contains(response.status), attempt < policy.maxAttempts else { return response }
                let body = try? await response.collectBody()
                failure = AnthropicProvider.error(status: response.status, body: body ?? Data(), requestId: response.header("request-id"))
                retryAfter = response.header("retry-after")
            } catch let e as ProviderError where e.isRetryable && attempt < policy.maxAttempts {
                failure = e; retryAfter = nil
            }
            try Task.checkCancellation()
            onRetry?(attempt, failure)
            attempt += 1
            try await sleep(policy.delay(beforeAttempt: attempt, retryAfter: retryAfter))
        }
    }
}

// MARK: - Stall watchdog

/// Ends a body stream with `ProviderError.stalled` when no chunk arrives for `timeout` (plan 9.3: a stall
/// watchdog from day one). Cancelling the consumer cancels the inner read.
public enum StallWatchdog {
    public static func guarded(_ inner: AsyncThrowingStream<Data, Error>, timeout: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let lastActivity = Mutex<ContinuousClock.Instant>(.now)
            let reader = Task {
                do {
                    for try await chunk in inner {
                        lastActivity.withLock { $0 = .now }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(timeout / 4))
                    if Task.isCancelled { return }
                    let idle = lastActivity.withLock { ContinuousClock.now - $0 }
                    if idle > .seconds(timeout) {
                        reader.cancel()
                        continuation.finish(throwing: ProviderError.stalled(seconds: timeout))
                        return
                    }
                }
            }
            continuation.onTermination = { _ in reader.cancel(); watchdog.cancel() }
        }
    }
}

// MARK: - Server-sent events

/// One SSE event: the `event:` name and the joined `data:` lines.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public init(event: String?, data: String) { self.event = event; self.data = data }
}

/// A byte-fed SSE parser (the wire format at https://html.spec.whatwg.org/multipage/server-sent-events.html):
/// `event:` and `data:` fields, comments starting with `:`, a blank line dispatches. Chunks may split lines and
/// UTF-8 sequences anywhere; the parser buffers bytes and splits on `\n` itself rather than using
/// `AsyncBytes.lines` (plan 9.3).
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    /// Bytes a single event may reach before the stream is treated as corrupt.
    public var maxEventBytes: Int
    public init(maxEventBytes: Int = 8 << 20) { self.maxEventBytes = maxEventBytes }

    /// Feeds a chunk and returns every event completed by it.
    public mutating func feed(_ chunk: Data) throws -> [SSEEvent] {
        buffer.append(chunk)
        guard buffer.count <= maxEventBytes else { throw ProviderError.invalidResponse("SSE event exceeds \(maxEventBytes) bytes") }
        var out: [SSEEvent] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<nl]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let event = consume(line: line) { out.append(event) }
        }
        return out
    }

    /// The event still open when the stream ended, if any (a server that omits the final blank line).
    public mutating func flush() -> SSEEvent? {
        if !buffer.isEmpty { _ = consume(line: String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
        return consume(line: "")
    }

    private mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty || eventName != nil else { return nil }
            let event = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
            eventName = nil; dataLines = []
            return event
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var v = line[line.index(after: colon)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = v
        } else { field = line[...]; value = "" }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break   // id, retry, unknown fields
        }
        return nil
    }
}
