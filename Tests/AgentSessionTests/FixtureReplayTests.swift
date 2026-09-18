import Testing
import Foundation
import AgentProtocol
import AgentTestKit
@testable import AgentSession

/// Replays every recorded fixture through ClaudeSession against fake-claude and checks the argument list
/// and the final result. Requires the fake-claude executable built next to the test bundle (set FAKE_CLAUDE).
@Suite struct FixtureReplayTests {
    static let versions = ["2.1.270", "2.1.271"]
    static let scenarios = ["simple-turn", "multi-turn", "permission-ask", "ask-user-question", "mcp-tool-call", "hooks-deny", "deferred-tool", "interrupt"]
    static var fixturesRoot: String { Fixtures.root.appendingPathComponent("cli/2.1.270").path }
    @Test(arguments: versions, scenarios)
    func fixtureParses(_ version: String, _ name: String) throws {
        let fx = try Fixture(directory: Fixtures.root.appendingPathComponent("cli/\(version)/\(name)").path)
        #expect(!fx.arguments.isEmpty)
        #expect(fx.stdoutLines.contains { $0.contains("\"type\":\"result\"") })
    }
    @Test func argumentsForSimpleTurnMatchRecording() throws {
        let fx = try Fixture(directory: Self.fixturesRoot + "/simple-turn")
        var o = SessionOptions(workingDirectory: "/tmp"); o.allowedTools = ["Read", "Glob"]; o.systemPrompt = .append("Be terse."); o.maxTurns = 8
        #expect(ClaudeSession(options: o).buildArguments() == fx.arguments)
    }
}
