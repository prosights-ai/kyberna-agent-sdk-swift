import Testing
import Foundation
@testable import AgentSession

/// Options added for CLI 2.1.278 (release plan v0.2.0 Phase 1 step 5): each maps to exactly one flag or variable.
@Suite struct CLIOptionsTests {
    var base: SessionOptions { SessionOptions(workingDirectory: "/tmp") }

    @Test func permissionPromptsFlag() {
        var o = base; o.permissionPrompts = PermissionPrompts.none
        let a = ClaudeSession(options: o).buildArguments()
        #expect(a.contains("--permission-prompts")); #expect(a[a.firstIndex(of: "--permission-prompts")! + 1] == "none")
        #expect(!ClaudeSession(options: base).buildArguments().contains("--permission-prompts"))
    }

    @Test func systemPromptSnapshotFlag() {
        var on = base; on.systemPromptSnapshot = true
        var off = base; off.systemPromptSnapshot = false
        let a = ClaudeSession(options: on).buildArguments(), b = ClaudeSession(options: off).buildArguments()
        #expect(a[a.firstIndex(of: "--system-prompt-snapshot")! + 1] == "on")
        #expect(b[b.firstIndex(of: "--system-prompt-snapshot")! + 1] == "off")
        #expect(!ClaudeSession(options: base).buildArguments().contains("--system-prompt-snapshot"))
    }

    @Test func startupEnvironmentVariables() {
        var o = base; o.mcpStartupWaitMs = 2500; o.emitStartupTiming = true
        let env = ClaudeSession.childEnvironment(options: o, parent: [:])
        #expect(env["CLAUDE_CODE_MCP_STARTUP_WAIT_MS"] == "2500"); #expect(env["CLAUDE_CODE_EMIT_STARTUP_TIMING"] == "1")
        let plain = ClaudeSession.childEnvironment(options: base, parent: [:])
        #expect(plain["CLAUDE_CODE_MCP_STARTUP_WAIT_MS"] == nil); #expect(plain["CLAUDE_CODE_EMIT_STARTUP_TIMING"] == nil)
    }
}
