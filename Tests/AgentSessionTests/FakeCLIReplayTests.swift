import Testing
import Foundation
import AgentProtocol
import AgentTestKit
@testable import AgentSession

/// End-to-end: ClaudeSession drives the real `fake-claude` executable replaying a fixture.
/// Locates fake-claude next to the test bundle's build products (SwiftPM) or via FAKE_CLAUDE.
@Suite(.serialized) struct FakeCLIReplayTests {
    static var fakePath: String? {
        if let p = ProcessInfo.processInfo.environment["FAKE_CLAUDE"], FileManager.default.isExecutableFile(atPath: p) { return p }
        // Bundle.main for a test host is the xctest runner; walk up from the test bundle to the products dir.
        var url = Bundle(for: Marker.self).bundleURL
        for _ in 0..<4 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("fake-claude").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
    final class Marker {}
    static var fixturesRoot: String { Fixtures.root.appendingPathComponent("cli/2.1.270").path }

    @Test func simpleTurnReplays() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-claude not built; run `swift build` first"); return }
        var o = SessionOptions(workingDirectory: "/tmp")
        o.claudePath = fake
        o.env["FAKE_CLAUDE_FIXTURE"] = Self.fixturesRoot + "/simple-turn"
        o.env["FAKE_CLAUDE_IGNORE_ARGS"] = "1"
        o.allowedTools = ["Read", "Glob"]; o.systemPrompt = .append("Be terse."); o.maxTurns = 8
        let s = ClaudeSession(options: o)
        let seen = Seen()
        let printer = Task {
            for await m in s.messages {
                if case .initialized = m { await seen.mark(init: true) }
                if case .assistant(let a) = m, a.content.contains(where: { if case .toolUse = $0 { return true }; return false }) { await seen.mark(toolUse: true) }
            }
        }
        let r = try await s.query("Read utils.py and say in one sentence what it does.")
        await printer.value
        #expect(r.subtype == "success")
        #expect(r.numTurns == 2)
        let (i, t) = await seen.snapshot()
        #expect(i && t)
        #expect(s.cliVersion == [2, 1, 270])
    }

    @Test func permissionRoundTrip() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-claude not built"); return }
        var o = SessionOptions(workingDirectory: "/tmp")
        o.claudePath = fake
        o.env["FAKE_CLAUDE_FIXTURE"] = Self.fixturesRoot + "/permission-ask"
        o.env["FAKE_CLAUDE_IGNORE_ARGS"] = "1"
        o.allowedTools = ["Read"]; o.permissionMode = "default"; o.systemPrompt = .append("Be terse."); o.maxTurns = 8
        let asked = Asked()
        o.canUseTool = { tool, _, ctx in await asked.record(tool, hash: ctx.payload.hash); return .allow() }
        let s = ClaudeSession(options: o)
        let printer = Task { for await _ in s.messages {} }
        let r = try await s.query("In utils.py, add a guard so calculate_average returns 0.0 for an empty list. Use the Edit tool.")
        await printer.value
        #expect(r.subtype == "success")
        let (tools, hashes) = await asked.snapshot()
        #expect(tools == ["Edit"])
        #expect(hashes.first?.isEmpty == false)
    }
    actor Seen {
        var sawInit = false, sawToolUse = false
        func mark(init: Bool = false, toolUse: Bool = false) { if `init` { sawInit = true }; if toolUse { sawToolUse = true } }
        func snapshot() -> (Bool, Bool) { (sawInit, sawToolUse) }
    }
    actor Asked {
        var tools: [String] = []; var hashes: [String] = []
        func record(_ t: String, hash: String) { tools.append(t); hashes.append(hash) }
        func snapshot() -> ([String], [String]) { (tools, hashes) }
    }
}
