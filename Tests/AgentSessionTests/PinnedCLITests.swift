import Testing
import Foundation
import AgentTestKit
import AgentProtocol
@testable import AgentSession

/// Test plan T4 (version lock) and T6 (environment hygiene), see docs/testing/pinned-cli-test-plan.md.
@Suite(.serialized) struct PinnedCLITests {
    static var fixture270: String { Fixtures.root.appendingPathComponent("cli/2.1.270/simple-turn").path }

    func options() -> SessionOptions {
        var o = SessionOptions(workingDirectory: "/tmp")
        o.claudePath = FakeCLIReplayTests.fakePath ?? ""
        o.env["FAKE_CLAUDE_FIXTURE"] = Self.fixture270
        o.env["FAKE_CLAUDE_IGNORE_ARGS"] = "1"
        o.allowedTools = ["Read", "Glob"]; o.systemPrompt = .append("Be terse."); o.maxTurns = 8
        return o
    }

    @Test func versionLockRefusesOtherVersion() async throws {
        guard FakeCLIReplayTests.fakePath != nil else { Issue.record("fake-claude not built"); return }
        var o = options(); o.allowedClaudeCodeVersions = [[2, 1, 271]]
        let s = ClaudeSession(options: o)
        await #expect(throws: SessionError.versionMismatch(found: "2.1.270", allowed: "2.1.271")) { try await s.start() }
        s.close()
    }

    @Test func versionLockAcceptsListedVersion() async throws {
        guard FakeCLIReplayTests.fakePath != nil else { Issue.record("fake-claude not built"); return }
        var o = options(); o.allowedClaudeCodeVersions = [[2, 1, 270], [2, 1, 271]]
        let s = ClaudeSession(options: o)
        let printer = Task { for await _ in s.messages {} }
        let r = try await s.query("Read utils.py and say in one sentence what it does.")
        await printer.value
        #expect(r.subtype == "success")
        #expect(s.cliVersion == [2, 1, 270])
        #expect(s.versionWarning == nil)
    }

    /// T5 negative: the CLI's "not logged in" result becomes `SessionError.authenticationFailed`.
    @Test func authFailureIsTyped() async throws {
        guard FakeCLIReplayTests.fakePath != nil else { Issue.record("fake-claude not built"); return }
        var o = SessionOptions(workingDirectory: "/tmp")
        o.claudePath = FakeCLIReplayTests.fakePath ?? ""
        o.env["FAKE_CLAUDE_FIXTURE"] = Fixtures.root.appendingPathComponent("cli/2.1.271/auth-failed").path
        o.env["FAKE_CLAUDE_IGNORE_ARGS"] = "1"
        o.maxTurns = 2
        let s = ClaudeSession(options: o)
        let printer = Task { for await _ in s.messages {} }
        await #expect(throws: SessionError.authenticationFailed("Not logged in · Please run /login")) { try await s.query("Reply with the single word ok.") }
        await printer.value
    }

    @Test func childEnvironmentIsAllowlisted() {
        var o = SessionOptions(workingDirectory: "/tmp")
        o.env["FAKE_CLAUDE_FIXTURE"] = "/x"
        let parent = ["PATH": "/usr/bin", "HOME": "/Users/u", "ANTHROPIC_API_KEY": "sk-leak", "ANTHROPIC_BASE_URL": "https://proxy",
                      "CLAUDE_CODE_OAUTH_TOKEN": "tok", "CLAUDECODE": "1", "CLAUDE_CODE_EXECPATH": "/desktop/claude", "CLAUDE_CONFIG_DIR": "/elsewhere", "SSH_AUTH_SOCK": "/s"]
        let env = ClaudeSession.childEnvironment(options: o, parent: parent)
        #expect(env["PATH"] == "/usr/bin" && env["HOME"] == "/Users/u" && env["SSH_AUTH_SOCK"] == "/s")
        for leaked in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_EXECPATH", "CLAUDE_CONFIG_DIR"] { #expect(env[leaked] == nil, Comment(rawValue: leaked)) }
        #expect(env["DISABLE_AUTOUPDATER"] == "1" && env["DISABLE_UPDATES"] == "1")
        #expect(env["CLAUDE_CODE_ENTRYPOINT"] == "sdk-swift")
        #expect(env["FAKE_CLAUDE_FIXTURE"] == "/x")
        o.disableUpdates = false
        #expect(ClaudeSession.childEnvironment(options: o, parent: parent)["DISABLE_UPDATES"] == nil)
    }
}
