import Foundation
import AgentProtocol

/// Workspace trust, done the way Claude Code does it.
///
/// The CLI asks "do you trust the files in this folder" the first time it runs interactively in a directory and
/// records the answer as `projects[<path>].hasTrustDialogAccepted` in `~/.claude.json`. Until then it ignores the
/// directory's `.claude/settings.json` permission rules ("this workspace has not been trusted", observed 2.1.271).
/// Home-directory trust is never persisted (docs: Security, Trust verification). the CLI's own hosted runner
/// pre-records trust by writing that same flag for the path, its NFC-normalized form, and its realpath, with file
/// mode 0600 (observed in the 2.1.271 binary). This type does exactly that: a host presents its own dialog, and on
/// acceptance calls `record`. Nothing else changes; the CLI still decides what trust unlocks.
public struct WorkspaceTrust: Sendable {
    public enum Status: Sendable, Equatable { case trusted, untrusted, homeDirectoryNeverPersisted }

    public var configPath: String
    public init(configPath: String = NSHomeDirectory() + "/.claude.json") { self.configPath = configPath }

    /// The facts the dialog must state; hosts word the UI, the substance matches the CLI's dialog.
    public static let dialogFacts = [
        "Claude Code will read files in this folder, including CLAUDE.md, .claude/settings.json rules, and hooks.",
        "Reading untrusted files can change how Claude Code behaves.",
        "With your permission Claude Code may execute files in this folder. Executing untrusted code is unsafe.",
    ]

    public func status(of directory: String) -> Status {
        let path = Self.normalized(directory)
        if path == Self.normalized(NSHomeDirectory()) { return .homeDirectoryNeverPersisted }
        guard let root = load() else { return .untrusted }
        for key in Self.variants(of: path) {
            if root["projects"]?[key]?["hasTrustDialogAccepted"]?.boolValue == true { return .trusted }
        }
        return .untrusted
    }

    /// Records acceptance for `directory`. Refuses the home directory, as the CLI does. Preserves every other key
    /// in the file and in the project entry. Atomic write, mode 0600.
    @discardableResult
    public func record(_ directory: String) throws -> Status {
        let path = Self.normalized(directory)
        if path == Self.normalized(NSHomeDirectory()) { return .homeDirectoryNeverPersisted }
        var root = load() ?? [:]
        var projects = root["projects"]?.objectValue ?? [:]
        for key in Self.variants(of: path) {
            var entry = projects[key]?.objectValue ?? [:]
            entry["hasTrustDialogAccepted"] = .bool(true)
            projects[key] = .object(entry)
        }
        root["projects"] = .object(projects)
        try save(root)
        return .trusted
    }

    // MARK: - Internals

    static func normalized(_ p: String) -> String {
        var s = (p as NSString).expandingTildeInPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
    /// The path as given, NFC-normalized, and its realpath (symlinks resolved), de-duplicated in that order.
    static func variants(of path: String) -> [String] {
        var out = [path]
        let nfc = path.precomposedStringWithCanonicalMapping
        if nfc != path { out.append(nfc) }
        if let real = try? FileManager.default.destinationOfSymbolicLink(atPath: path) { out.append(real) }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if !out.contains(resolved) { out.append(resolved) }
        return out
    }
    private func load() -> [String: JSONValue]? {
        guard let data = FileManager.default.contents(atPath: configPath), let v = try? JSONValue(data: data) else { return nil }
        return v.objectValue
    }
    private func save(_ root: [String: JSONValue]) throws {
        let data = try JSONValue.object(root).data()
        let tmp = configPath + ".claudeagentkit-\(ProcessInfo.processInfo.processIdentifier).tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
        if FileManager.default.fileExists(atPath: configPath) { _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: configPath), withItemAt: URL(fileURLWithPath: tmp)) }
        else { try FileManager.default.moveItem(atPath: tmp, toPath: configPath) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
    }
}
