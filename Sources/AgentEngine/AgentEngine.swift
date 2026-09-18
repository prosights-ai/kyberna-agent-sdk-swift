import Foundation
import AgentProtocol
import AgentSession

/// What every engine provides to a host. `ClaudeCodeEngine` wraps `ClaudeSession`; a direct-API engine is Phase 8.
public protocol AgentEngine: AnyObject, Sendable {
    var messages: AsyncStream<Message> { get }
    var sessionId: String? { get }
    func start() async throws
    func send(_ prompt: String) async throws
    func steer(_ text: String) async throws
    /// Stop the running tool and turn, then deliver `text` as the next turn.
    func steerNow(_ text: String) async throws
    func pause()
    func resume()
    func stop(_ severity: StopSeverity) async
}

public final class ClaudeCodeEngine: AgentEngine, Sendable {
    public let session: ClaudeSession
    public init(options: SessionOptions) { session = ClaudeSession(options: options) }
    public var messages: AsyncStream<Message> { session.messages }
    public var sessionId: String? { session.sessionId }
    public func start() async throws { try await session.start() }
    public func send(_ prompt: String) async throws { session.send(prompt) }
    public func steer(_ text: String) async throws { session.steer(text) }
    public func steerNow(_ text: String) async throws { _ = try await session.steerNow(text) }
    public func pause() { session.pause() }
    public func resume() { session.resume() }
    public func stop(_ severity: StopSeverity) async { await session.stop(severity) }
}
