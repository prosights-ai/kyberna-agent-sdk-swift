import Foundation

/// String-level path containment, evaluated before any filesystem call. Rejects rooted paths outside the
/// allowed roots, `..` and `.` segments, and prefix collisions such as `/project` versus `/project-backup`.
public struct PathPolicy: Sendable, Equatable {
    public var allowedRoots: [String]
    public init(allowedRoots: [String]) { self.allowedRoots = allowedRoots.map(PathPolicy.normalize) }

    public enum Verdict: Sendable, Equatable { case allowed(String), denied(reason: String) }

    public func check(_ path: String, relativeTo cwd: String? = nil) -> Verdict {
        var p = path
        if !p.hasPrefix("/") {
            guard let cwd else { return .denied(reason: "relative path without a working directory") }
            p = PathPolicy.normalize(cwd) + "/" + p
        }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains("..") || parts.contains(".") { return .denied(reason: "path contains '.' or '..' segments") }
        let norm = "/" + parts.joined(separator: "/")
        for root in allowedRoots where norm == root || norm.hasPrefix(root + "/") { return .allowed(norm) }
        return .denied(reason: "outside allowed roots")
    }

    static func normalize(_ s: String) -> String {
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return "/" + parts.joined(separator: "/")
    }
}
