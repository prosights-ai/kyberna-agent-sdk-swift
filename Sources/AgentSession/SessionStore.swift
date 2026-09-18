import Foundation
import AgentProtocol

/// Where a session's transcript is mirrored, beyond the file the CLI writes locally (engine enhancement 14,
/// plan section 2.3). The CLI writes its own `.jsonl` first and, with `--session-mirror`, also streams every
/// batch of entries on stdout; `ClaudeSession` hands those batches here. Entries are opaque JSON objects: a
/// store must not interpret them beyond the `uuid` it uses to deduplicate, since retried batches can repeat.
public protocol SessionStore: Sendable {
    /// Appends a batch. Called in order per session, and may be called again with entries already seen.
    func append(_ entries: [JSONValue], for key: SessionStoreKey) async throws
    /// Every entry for a session, oldest first, deduplicated.
    func load(_ key: SessionStoreKey) async throws -> [JSONValue]
    func listSessions(projectKey: String) async throws -> [String]
    func listSubkeys(_ key: SessionStoreKey) async throws -> [String]
    func delete(_ key: SessionStoreKey) async throws
}

public extension SessionStore {
    func listSessions(projectKey: String) async throws -> [String] { [] }
    func listSubkeys(_ key: SessionStoreKey) async throws -> [String] { [] }
    func delete(_ key: SessionStoreKey) async throws {}
}

/// Names one transcript: the CLI's project key (its encoded working directory), the session id, and, for a
/// subagent's own transcript, the subpath the CLI writes it under.
public struct SessionStoreKey: Sendable, Hashable, Codable {
    public var projectKey: String
    public var sessionId: String
    public var subpath: String?
    public init(projectKey: String, sessionId: String, subpath: String? = nil) {
        self.projectKey = projectKey; self.sessionId = sessionId; self.subpath = subpath
    }

    /// Reads a key back from the path in a `transcript_mirror` frame, which is the CLI's own transcript path:
    /// `…/projects/<projectKey>/<sessionId>.jsonl`, or `…/projects/<projectKey>/<sessionId>/subagents/<name>.jsonl`.
    public init?(mirrorPath: String) {
        let parts = mirrorPath.split(separator: "/").map(String.init)
        guard let last = parts.last, last.hasSuffix(".jsonl"), parts.count >= 2 else { return nil }
        let name = String(last.dropLast(6))
        if parts.count >= 4, parts[parts.count - 2] == "subagents" {
            projectKey = parts[parts.count - 4]
            sessionId = parts[parts.count - 3]
            subpath = "subagents~" + name
        } else {
            projectKey = parts[parts.count - 2]
            sessionId = name
            subpath = nil
        }
    }

    /// A stable relative path for this key, used by folder-backed stores.
    public var relativePath: String { subpath.map { "\(projectKey)/\(sessionId)/\($0)" } ?? "\(projectKey)/\(sessionId)/main" }
}

public extension SessionStoreKey {
    /// The project key the CLI derives from a working directory: the path with every separator and dot replaced
    /// by a dash, which is how `~/.claude/projects` is laid out. Separators, dots, underscores, and spaces all
    /// become dashes (observed on 2.1.271: `/Users/u/Library/Application Support/Host/scratch/x` is stored as
    /// `-Users-u-Library-Application-Support-Host-scratch-x`).
    static func projectKey(for workingDirectory: String) -> String {
        let resolved = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path
        var out = ""
        for ch in resolved { out.append(ch == "/" || ch == "." || ch == "_" || ch == " " ? "-" : ch) }
        return out
    }
}

/// Deduplicates entries by `uuid`, keeping the first of each and everything that has no uuid.
public func deduplicateEntries(_ entries: [JSONValue]) -> [JSONValue] {
    var seen = Set<String>()
    return entries.filter { e in
        guard let id = e["uuid"]?.stringValue else { return true }
        return seen.insert(id).inserted
    }
}
