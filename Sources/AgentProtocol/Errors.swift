import Foundation

public enum SessionError: Error, CustomStringConvertible, Sendable, Equatable {
    case control(String)
    case runFailed(ResultMessage)
    case notStarted
    case alreadyStarted
    case processExited(status: Int32)
    case bufferOverflow(bytes: Int, limit: Int)
    /// The probed CLI version is not in `SessionOptions.allowedClaudeCodeVersions`.
    case versionMismatch(found: String, allowed: String)
    /// The CLI could not authenticate (login expired or absent). The host tells the user to run `claude` and `/login`.
    case authenticationFailed(String)
    /// Two options that cannot hold at once, caught before a process is spawned.
    case invalidOptions(String)
    public var description: String {
        switch self {
        case .control(let s): return s
        case .runFailed(let r): return "run failed: \(r.errorText ?? r.subtype)"
        case .notStarted: return "session not started"
        case .alreadyStarted: return "session already started"
        case .processExited(let st): return "claude exited with status \(st)"
        case .bufferOverflow(let b, let l): return "stdout line of \(b) bytes exceeds the \(l)-byte limit"
        case .versionMismatch(let f, let a): return "Claude Code \(f) is not the pinned engine (\(a))"
        case .authenticationFailed(let m): return "Claude Code is not logged in: \(m)"
        case .invalidOptions(let m): return "these session options conflict: \(m)"
        }
    }
    /// The wording fed back to a model when an error must be reported inside a tool result.
    public var feedbackMessage: String {
        switch self {
        case .runFailed(let r): return "The previous run failed: \(r.errorText ?? r.subtype)."
        case .bufferOverflow: return "A tool produced more output than the host can accept; try a narrower request."
        default: return description
        }
    }
}
