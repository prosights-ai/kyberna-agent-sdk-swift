import Testing
@testable import AgentEngine

@Suite struct PathPolicyTests {
    let policy = PathPolicy(allowedRoots: ["/Users/USER/project"])
    @Test func allowsInsideRoot() { #expect(policy.check("/Users/USER/project/src/a.swift") == .allowed("/Users/USER/project/src/a.swift")) }
    @Test func rejectsPrefixCollision() { #expect(policy.check("/Users/USER/project-backup/x") == .denied(reason: "outside allowed roots")) }
    @Test func rejectsDotDot() { #expect(policy.check("/Users/USER/project/../etc/passwd") == .denied(reason: "path contains '.' or '..' segments")) }
    @Test func resolvesRelativeAgainstCwd() { #expect(policy.check("src/a.swift", relativeTo: "/Users/USER/project") == .allowed("/Users/USER/project/src/a.swift")) }
    @Test func rejectsRelativeWithoutCwd() { #expect(policy.check("src/a.swift") == .denied(reason: "relative path without a working directory")) }
}
