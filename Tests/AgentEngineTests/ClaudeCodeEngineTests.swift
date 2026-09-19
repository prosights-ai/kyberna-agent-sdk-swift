import Testing
import Foundation
import AgentProtocol
import AgentSession
import AgentTestKit
@testable import AgentEngine

/// The Claude Code engine adopts every capability and forwards each to the session: before start the calls shape
/// the CLI's argument list, after start they become control requests or are refused with `alreadyStarted`.
@Suite(.serialized) struct ClaudeCodeEngineTests {
    static var fakePath: String? {
        if let p = ProcessInfo.processInfo.environment["FAKE_CLAUDE"], FileManager.default.isExecutableFile(atPath: p) { return p }
        var url = Bundle(for: Marker.self).bundleURL
        for _ in 0..<4 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("fake-claude").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
    final class Marker {}

    static func options(fake: String, fixture: String) -> SessionOptions {
        var o = SessionOptions(workingDirectory: "/tmp")
        o.claudePath = fake
        o.env["FAKE_CLAUDE_FIXTURE"] = Fixtures.root.appendingPathComponent("cli/2.1.270/" + fixture).path
        o.env["FAKE_CLAUDE_IGNORE_ARGS"] = "1"
        o.allowedTools = ["Read", "Glob"]; o.systemPrompt = .append("Be terse."); o.maxTurns = 8
        return o
    }

    @Test func adoptsEveryCapability() {
        let engine: any AgentEngine = ClaudeCodeEngine(options: SessionOptions(workingDirectory: "/tmp"))
        #expect(engine is ModelSwitching)
        #expect(engine is EffortSetting)
        #expect(engine is ReasoningControl)
        #expect(engine is Resumable)
        #expect(engine is PermissionGating)
        #expect(engine is HookCapable)
        #expect(engine is ToolHosting)
        #expect(engine is ImageAttaching)
        #expect(engine is ContextReporting)
        #expect(engine is FileRewinding)
        #expect(engine is RateLimitReporting)
    }

    @Test func capabilitiesBeforeStartShapeTheArgumentList() async throws {
        let engine = ClaudeCodeEngine(options: SessionOptions(workingDirectory: "/tmp"))
        try await engine.setModel("haiku")
        try await engine.setEffort("low")
        try engine.resume("session-42")
        try engine.setReasoningDisplay(.summarized)
        #expect(try await engine.setThinking(.disabled))
        let tool = try SwiftTool(name: "ping", description: "Replies pong.", inputSchema: ["type": "object", "properties": [:]], text: { _ in "pong" })
        try engine.host([tool], serverName: "kyberna")
        try engine.setPolicy { _, _ in .allow }
        try engine.setPermissionHandler { _, _, _ in .allow() }
        try engine.setQuestionHandler { _ in [:] }
        try engine.addHook(.preToolUse, HookMatcher(hooks: [{ _, _ in .proceed }]))
        let args = engine.session.buildArguments()
        #expect(args.contains("--model") && args.contains("haiku"))
        #expect(args.contains("--effort") && args.contains("low"))
        #expect(args.contains("--resume=session-42"))
        #expect(args.contains("--thinking-display") && args.contains("summarized"))
        #expect(engine.hostedTools.map(\.name) == ["ping"])
        #expect(engine.options.serverName == "kyberna")
        #expect(engine.options.thinking == .disabled)
        #expect(engine.options.policy != nil && engine.options.canUseTool != nil && engine.options.askUserQuestion != nil)
        #expect(engine.options.hooks[.preToolUse]?.count == 1)
    }

    @Test func startTimeCapabilitiesRefuseAfterStartAndATurnRuns() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-claude not built; run `swift build --product fake-claude` first"); return }
        let engine = ClaudeCodeEngine(options: Self.options(fake: fake, fixture: "simple-turn"))
        let neutral: any AgentEngine = engine
        let collector = Task { () -> (initialized: Bool, result: Bool) in
            var initialized = false, result = false
            for await m in neutral.messages {
                if case .initialized = m { initialized = true }
                if case .result = m { result = true; break }
            }
            return (initialized, result)
        }
        try await neutral.start()
        #expect(neutral.engineVersion == "2.1.270")
        #expect((neutral as? ModelSwitching)?.availableModels != nil)
        // Start-time capabilities now refuse; the running ones do not.
        #expect(throws: EngineError.alreadyStarted(operation: "resume")) { try engine.resume("later") }
        #expect(throws: EngineError.alreadyStarted(operation: "setPermissionHandler")) { try engine.setPermissionHandler(nil) }
        #expect(throws: EngineError.alreadyStarted(operation: "host")) { try engine.host([], serverName: "x") }
        #expect(try await engine.setThinking(.adaptive) == false)
        try await neutral.send("Read utils.py and say in one sentence what it does.")
        let seen = await collector.value
        #expect(seen.initialized && seen.result)
        await neutral.stop(.session)
    }

    @Test func imageAttachmentIsCodableAndBase64() throws {
        let a = ImageAttachment(data: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png")
        #expect(a.base64 == "iVBORw==")
        let round = try JSONDecoder().decode(ImageAttachment.self, from: JSONEncoder().encode(a))
        #expect(round == a)
    }
}
