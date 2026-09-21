import Foundation
import Synchronization
import AgentProtocol
import AgentTransport

/// An error from the ACP side: the agent answered a request with a JSON-RPC error, the child ended, or a line
/// was not the protocol.
public enum ACPError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The agent answered with a JSON-RPC error object (`code`, `message`; `data` kept as text when present).
    case remote(code: Int, message: String, data: String?)
    /// The child ended while a request was outstanding, or before it was asked.
    case exited(status: Int32)
    /// A line the client could not read as JSON-RPC 2.0, or a response with neither result nor error.
    case protocolViolation(String)
    /// `initialize` did not answer within the configured time.
    case timeout(String)
    /// The client was asked to send before `start()` or after the child ended.
    case notRunning
    /// The agent answered `initialize` with a protocol version this client does not speak.
    case unsupportedProtocolVersion(Int)

    public var description: String {
        switch self {
        case let .remote(code, message, data): return "agent error \(code): \(message)" + (data.map { " (\($0))" } ?? "")
        case .exited(let status): return "the agent exited with status \(status)"
        case .protocolViolation(let s): return "not ACP JSON-RPC: \(s)"
        case .timeout(let what): return "\(what) timed out"
        case .notRunning: return "the agent is not running"
        case .unsupportedProtocolVersion(let v): return "the agent speaks ACP protocol version \(v); this client speaks \(ACPClient.protocolVersion)"
        }
    }
}

/// JSON-RPC 2.0 over an ACP agent's stdio, one object per line (agentclientprotocol.com, protocol version 1).
/// The client sends requests (`initialize`, `session/new`, `session/load`, `session/prompt`) and notifications
/// (`session/cancel`); the agent sends notifications (`session/update`) and requests of its own
/// (`session/request_permission`, `fs/*`, `terminal/*`), which the owner answers through `respond`.
///
/// Knows nothing of sessions or messages: `ACPEngine` interprets the methods. The child and its pipes belong
/// to `CLITransport`, the SDK's one `@unchecked Sendable`; everything here is under a `Mutex`.
public final class ACPClient: Sendable {
    /// The wire-level `protocolVersion` this client negotiates (`schema/v1/meta.json`).
    public static let protocolVersion = 1

    public struct Configuration: Sendable {
        public var executable: String
        public var arguments: [String]
        public var workingDirectory: String
        public var environment: [String: String]
        public var maxLineBytes = 1024 * 1024
        public var recordDirectory: String?
        public var stderr: (@Sendable (String) -> Void)?
        public init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String]) {
            self.executable = executable; self.arguments = arguments; self.workingDirectory = workingDirectory; self.environment = environment
        }
    }

    /// A request the agent made of the client. `id` goes back in the answer.
    public struct IncomingRequest: Sendable {
        public var id: JSONValue
        public var method: String
        public var params: JSONValue
    }

    /// What the owner hears: the agent's notifications, its requests, and the child's end.
    public struct Handlers: Sendable {
        public var notification: @Sendable (_ method: String, _ params: JSONValue) -> Void
        public var request: @Sendable (IncomingRequest) -> Void
        public var exited: @Sendable (_ status: Int32, _ signal: Int32?) -> Void
        public init(notification: @escaping @Sendable (String, JSONValue) -> Void, request: @escaping @Sendable (IncomingRequest) -> Void,
                    exited: @escaping @Sendable (Int32, Int32?) -> Void) {
            self.notification = notification; self.request = request; self.exited = exited
        }
    }

    /// A request's slot: sent and not yet awaited, awaited, or answered before anyone awaited it.
    private enum Slot: Sendable {
        case open
        case waiting(CheckedContinuation<JSONValue, any Error>)
        case done(Result<JSONValue, any Error>)
    }
    private struct State: Sendable {
        var nextId = 1
        var pending: [Int: Slot] = [:]
        var started = false
        var exited: Int32?
    }

    public let configuration: Configuration
    private let handlers: Handlers
    private let state = Mutex(State())
    private let transportBox = Mutex<CLITransport?>(nil)

    public init(configuration: Configuration, handlers: Handlers) {
        self.configuration = configuration
        self.handlers = handlers
    }

    public var isRunning: Bool { transportBox.withLock { $0?.isRunning ?? false } }
    public var processIdentifier: Int32 { transportBox.withLock { $0?.processIdentifier ?? 0 } }

    /// Spawns the agent. Lines it writes are dispatched to the handlers from the transport's event queue.
    public func start() throws {
        var c = CLITransport.Configuration(executable: configuration.executable, arguments: configuration.arguments,
                                           workingDirectory: configuration.workingDirectory, environment: configuration.environment)
        c.maxLineBytes = configuration.maxLineBytes
        c.recordDirectory = configuration.recordDirectory
        c.stderr = configuration.stderr
        let transport = CLITransport(configuration: c) { [weak self] event in self?.handle(event) }
        transportBox.withLock { $0 = transport }
        state.withLock { $0.started = true }
        try transport.start()
    }

    // MARK: Sending

    /// A request; returns the agent's `result` or throws its `error` as `ACPError.remote`.
    public func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        try await response(for: try send(method, params: params))
    }

    /// Writes a request now and returns its id; `response(for:)` awaits the answer. Split from `request` so a
    /// caller can put the line on the wire before it suspends, which keeps what the agent reads in the order of
    /// the caller's calls (a `session/cancel` must not overtake the prompt it cancels).
    public func send(_ method: String, params: JSONValue = .object([:])) throws -> Int {
        guard let transport = transportBox.withLock({ $0 }) else { throw ACPError.notRunning }
        let id = try state.withLock { s -> Int in
            if let e = s.exited { throw ACPError.exited(status: e) }
            defer { s.nextId += 1 }
            s.pending[s.nextId] = .open
            return s.nextId
        }
        transport.write(Self.encode(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]))
        return id
    }

    /// The answer to the request `send` returned the id of.
    public func response(for id: Int) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<JSONValue, any Error>) in
                let ready = state.withLock { s -> Result<JSONValue, any Error>? in
                    switch s.pending[id] {
                    case .done(let r): s.pending.removeValue(forKey: id); return r
                    case .open: s.pending[id] = .waiting(k); return nil
                    case .waiting: return .failure(ACPError.protocolViolation("request \(id) is already awaited"))
                    case nil: return .failure(s.exited.map { ACPError.exited(status: $0) } ?? ACPError.protocolViolation("request \(id) was never sent"))
                    }
                }
                if let ready { k.resume(with: ready) }
            }
        } onCancel: {
            // The caller gave up on the answer; the agent may still send one, which then finds no waiter.
            let k = state.withLock { s -> CheckedContinuation<JSONValue, any Error>? in
                guard case .waiting(let k) = s.pending.removeValue(forKey: id) else { return nil }
                return k
            }
            k?.resume(throwing: CancellationError())
        }
    }

    /// A notification: no id, no answer.
    public func notify(_ method: String, params: JSONValue = .object([:])) {
        guard let transport = transportBox.withLock({ $0 }) else { return }
        transport.write(Self.encode(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }

    /// The answer to a request the agent made.
    public func respond(_ id: JSONValue, result: JSONValue) {
        guard let transport = transportBox.withLock({ $0 }) else { return }
        transport.write(Self.encode(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    /// An error answer to a request the agent made. `-32601` is JSON-RPC's method-not-found.
    public func respond(_ id: JSONValue, errorCode: Int, message: String) {
        guard let transport = transportBox.withLock({ $0 }) else { return }
        transport.write(Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(errorCode)), "message": .string(message)]]))
    }

    // MARK: Ending

    /// Closes stdin; a well-behaved agent exits on its own.
    public func closeInput() { transportBox.withLock { $0 }?.closeInput() }
    /// SIGTERM to the child.
    public func terminate() { transportBox.withLock { $0 }?.terminate() }
    /// SIGKILL to the child and its descendants.
    public func kill() { transportBox.withLock { $0 }?.kill() }
    /// SIGSTOP and SIGCONT, for `AgentEngine.pause` and `resume`.
    public func suspend() { let pid = processIdentifier; if pid > 0 { Darwin.kill(pid, SIGSTOP) } }
    public func `continue`() { let pid = processIdentifier; if pid > 0 { Darwin.kill(pid, SIGCONT) } }

    // MARK: Receiving

    private func handle(_ event: CLITransport.Event) {
        switch event {
        case .line(let data):
            guard let v = try? JSONValue(data: data), case .object = v else {
                // Agents print banners and warnings on stdout as well; a non-JSON line is not a protocol failure.
                configuration.stderr?(String(data: data, encoding: .utf8) ?? "")
                return
            }
            dispatch(v)
        case .overflow(let bytes, let limit):
            configuration.stderr?("a line of \(bytes) bytes exceeded the \(limit)-byte limit and was dropped")
        case .exited(let status, let signal):
            let waiters = state.withLock { s -> [CheckedContinuation<JSONValue, any Error>] in
                s.exited = status
                var w: [CheckedContinuation<JSONValue, any Error>] = []
                for (id, slot) in s.pending {
                    switch slot {
                    case .waiting(let k): w.append(k); s.pending.removeValue(forKey: id)
                    case .open: s.pending[id] = .done(.failure(ACPError.exited(status: status)))
                    case .done: break
                    }
                }
                return w
            }
            for w in waiters { w.resume(throwing: ACPError.exited(status: status)) }
            handlers.exited(status, signal)
        }
    }

    private func dispatch(_ v: JSONValue) {
        let method = v["method"]?.stringValue
        let id = v["id"]
        if let method {
            if let id, !id.isNull { handlers.request(IncomingRequest(id: id, method: method, params: v["params"] ?? .object([:]))) }
            else { handlers.notification(method, v["params"] ?? .object([:])) }
            return
        }
        // A response: ours are integer ids.
        let outcome: Result<JSONValue, any Error>
        if let err = v["error"] {
            outcome = .failure(ACPError.remote(code: err["code"]?.intValue ?? 0, message: err["message"]?.stringValue ?? "unknown error",
                                               data: err["data"].map { $0.stringValue ?? $0.canonicalJSON }))
        } else if let result = v["result"] {
            outcome = .success(result)
        } else {
            outcome = .failure(ACPError.protocolViolation("response \(id?.canonicalJSON ?? "?") carries neither result nor error"))
        }
        let waiter = state.withLock { s -> CheckedContinuation<JSONValue, any Error>?? in
            guard let n = id?.intValue, let slot = s.pending[n] else { return nil }
            switch slot {
            case .waiting(let k): s.pending.removeValue(forKey: n); return .some(k)
            case .open: s.pending[n] = .done(outcome); return .some(nil)
            case .done: return .some(nil)
            }
        }
        switch waiter {
        case nil: configuration.stderr?("response with no waiting request: \(v.canonicalJSON.prefix(200))")
        case .some(nil): break
        case .some(let k?): k.resume(with: outcome)
        }
    }

    static func encode(_ v: JSONValue) -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(v)) ?? Data("{}".utf8)
    }
}
