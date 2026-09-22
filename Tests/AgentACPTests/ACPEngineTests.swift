import Testing
import Foundation
import Synchronization
import AgentProtocol
import AgentSession
import AgentEngine
import AgentTestKit
@testable import AgentACP

/// `ACPEngine` over the fake ACP agent: the handshake, a prompt with a tool call and a permission request, the
/// policy and the person answering it, cancellation, an error from the agent, the model argument, `session/load`
/// only when advertised, and the child's end. Nothing here needs the network or a real agent.
@Suite(.serialized) struct ACPEngineTests {
    static var fakePath: String? {
        if let p = ProcessInfo.processInfo.environment["FAKE_ACP"], FileManager.default.isExecutableFile(atPath: p) { return p }
        var url = Bundle(for: Marker.self).bundleURL
        for _ in 0..<4 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("fake-acp").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
    final class Marker {}

    static func descriptor(fake: String, load: Bool = false) -> ACPAgentDescriptor {
        ACPAgentDescriptor(id: "fake", displayName: "Fake agent", executable: fake, arguments: ["--acp"], modelArgument: .flag("--model"),
                           authNote: "none; a test double", supportsSessionLoad: load)
    }
    static func options(fake: String, load: Bool = false, env: [String: String] = [:]) -> ACPEngineOptions {
        var o = ACPEngineOptions(descriptor: descriptor(fake: fake, load: load), workingDirectory: "/tmp", environment: ["PATH": "/usr/bin:/bin"])
        o.environment.merge(env) { _, new in new }
        o.cancelGrace = 2; o.exitGrace = 2
        return o
    }

    /// Collects messages until the first `result`; the reader keeps running so later messages are not lost.
    final class Collector: Sendable {
        final class Box: Sendable { let seen = Mutex<[Message]>([]) }
        let box: Box
        let stream: AsyncStream<Message>
        let reader: Task<Void, Never>
        init(_ engine: any AgentEngine) {
            let box = Box()
            self.box = box
            var k: AsyncStream<Message>.Continuation!
            stream = AsyncStream { k = $0 }
            let out = k!
            reader = Task { for await m in engine.messages { box.seen.withLock { $0.append(m) }; out.yield(m) }; out.finish() }
        }
        func untilResult() async -> [Message] {
            var out: [Message] = []
            for await m in stream { out.append(m); if case .result = m { break } }
            return out
        }
        func untilExit() async { for await m in stream { if case .exited = m { break } } }
        /// The `initialized` message's data, awaited on the stream.
        func initializedData() async -> (model: String, data: JSONValue)? {
            for await m in stream { if case .initialized(_, let model, _, let data) = m { return (model, data) } }
            return nil
        }
        var all: [Message] { box.seen.withLock { $0 } }
    }

    @Test func adoptsTheCapabilitiesTheProtocolSupportsAndNoOthers() throws {
        let plain: any AgentEngine = ACPEngine.make(options: Self.options(fake: "/bin/echo"))
        #expect(plain is PermissionGating)
        #expect(plain is ModelSwitching)
        #expect(!(plain is Resumable))
        #expect(plain is ToolHosting)   // v0.2.14 P2e: MCP pass-through
        #expect(plain is HostedToolServing)
        #expect(!(plain is ContextReporting))
        #expect(!(plain is FileRewinding))
        #expect(!(plain is HookCapable))
        #expect(!(plain is ImageAttaching))
        let loading: any AgentEngine = ACPEngine.make(options: Self.options(fake: "/bin/echo", load: true))
        #expect(loading is Resumable)
        #expect(loading is PermissionGating)
        #expect(loading is ModelSwitching)
        // The launch line: the model as the descriptor says, over the base environment.
        let launch = Self.descriptor(fake: "/bin/echo").launch(model: "fake-large", environment: ["PATH": "/bin"])
        #expect(launch.arguments == ["--acp", "--model", "fake-large"])
        #expect(launch.environment == ["PATH": "/bin"])
        var byEnv = Self.descriptor(fake: "/bin/echo"); byEnv.modelArgument = .environment("AGENT_MODEL")
        #expect(byEnv.launch(model: "m", environment: [:]).environment == ["AGENT_MODEL": "m"])
        var equals = Self.descriptor(fake: "/bin/echo"); equals.modelArgument = .flagEquals("--model")
        #expect(equals.launch(model: "m", environment: [:]).arguments == ["--acp", "--model=m"])
    }

    @Test func aMissingExecutableIsAStartErrorNamingThePath() async {
        var o = Self.options(fake: "no-such-agent-binary")
        o.environment["PATH"] = "/nonexistent"
        let engine = ACPEngine(options: o)
        await #expect(throws: ACPEngineError.executableNotFound(name: "no-such-agent-binary", path: "/nonexistent")) { try await engine.start() }
    }

    @Test func aTurnWithAToolCallAndAPermissionThePolicyAllows() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built; run `swift build --product fake-acp` first"); return }
        var o = Self.options(fake: fake); o.model = "fake-large"; o.includePartialMessages = true
        let engine = ACPEngine(options: o)
        try engine.setPolicy { tool, _ in tool == "read_file" ? .allow : .ask }
        try engine.setPermissionHandler { _, _, _ in Issue.record("the person was asked although the policy allowed"); return .deny("no") }
        let c = Collector(engine)
        try await engine.start()
        #expect(engine.sessionId == FakeACPAgent.sessionId)
        #expect(engine.engineVersion == "fake-acp 0.1.0")
        #expect(engine.availableModels.map(\.value) == ["fake-default", "fake-large"])
        try await engine.send("Read utils.py and say what it does.")
        let seen = await c.untilResult()
        guard case .initialized(let sid, let model, _, let data) = seen.first else { Issue.record("no initialized first: \(seen.first.map { "\($0)" } ?? "nothing")"); return }
        #expect(sid == FakeACPAgent.sessionId)
        #expect(model == "fake-large")   // the launch argument, not the agent's default
        #expect(data["agentName"]?.stringValue == "fake-acp")
        #expect(data["loadSession"]?.boolValue == false)
        #expect(data["engine"]?.stringValue == "acp")
        let assistants = seen.compactMap { if case .assistant(let a) = $0 { return a }; return nil }
        #expect(assistants.count == 2)
        // Thought, text and the tool use in the first message; the closing text in the second.
        #expect(assistants[0].content.contains(.thinking("Thinking about the file.")))
        #expect(assistants[0].content.contains(.text("I will read utils.py.")))
        #expect(assistants[0].content.contains(.toolUse(id: "call-1", name: "read_file", input: ["path": "utils.py"])))
        #expect(assistants[0].model == "fake-large")
        #expect(assistants[1].content == [.text("utils.py defines calculate_average. (permission: allow-once)")])
        #expect(assistants[1].stopReason == "end_turn")
        let results = seen.compactMap { if case .user(let u) = $0 { return u }; return nil }
        #expect(results.count == 1)
        #expect(results.first?.content.first?.resultText.contains("calculate_average") == true)
        if case .toolResult(let id, _, let isError) = results.first?.content.first { #expect(id == "call-1"); #expect(!isError) } else { Issue.record("no tool result") }
        // Nobody was asked: no permissionRequest on the stream; the deltas came as the Console's stream events.
        #expect(!seen.contains { if case .permissionRequest = $0 { return true }; return false })
        #expect(seen.contains { if case .streamEvent(let e, _) = $0 { return e["delta"]?["type"]?.stringValue == "thinking_delta" }; return false })
        guard case .result(let r) = seen.last else { Issue.record("no result"); return }
        #expect(r.subtype == "success")
        #expect(r.stopReason == "end_turn")
        #expect(r.sessionId == FakeACPAgent.sessionId)
        #expect(r.result?.contains("calculate_average") == true)
        #expect(r.numTurns == 1)
        // Ending the session ends the child, and the stream says so.
        await engine.stop(.session)
        await c.untilExit()
        #expect(c.all.contains { if case .exited = $0 { return true }; return false })
    }

    @Test func thePersonIsAskedWhenThePolicySaysAskAndRememberPicksAllowAlways() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let engine = ACPEngine(options: Self.options(fake: fake))
        let asked = Mutex<[String]>([])
        try engine.setPermissionHandler { tool, input, ctx in
            asked.withLock { $0.append(tool) }
            #expect(input == ["path": "utils.py"])
            #expect(ctx.toolUseId == "call-1")
            #expect(ctx.title == "Read utils.py")
            #expect(ctx.payload.tool == "read_file")
            return .allow(updatedPermissions: [["type": "addRules"]])
        }
        let c = Collector(engine)
        try await engine.start()
        try await engine.send("Read utils.py.")
        let seen = await c.untilResult()
        #expect(asked.withLock { $0 } == ["read_file"])
        let request = seen.compactMap { if case .permissionRequest(let p) = $0 { return p }; return nil }
        #expect(request.count == 1)
        #expect(request.first?.tool == "read_file")
        #expect(request.first?.toolUseId == "call-1")
        // The request went on the stream before the handler answered.
        let requestIndex = seen.firstIndex { if case .permissionRequest = $0 { return true }; return false }
        let resultIndex = seen.firstIndex { if case .user = $0 { return true }; return false }
        #expect(requestIndex != nil && resultIndex != nil && requestIndex! < resultIndex!)
        let texts = seen.compactMap { if case .assistant(let a) = $0 { return a.content.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined() }; return nil }
        #expect(texts.last == "utils.py defines calculate_average. (permission: allow-always)")
        await engine.stop(.session)
    }

    @Test func aDenialPicksRejectOnceAndIsSaidOnTheStream() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let engine = ACPEngine(options: Self.options(fake: fake))
        try engine.setPolicy { _, _ in .deny("read_file is not allowed for this profile") }
        let c = Collector(engine)
        try await engine.start()
        try await engine.send("Read utils.py.")
        let seen = await c.untilResult()
        let denied = seen.compactMap { if case .permissionDenied(let t, let id, let rt, let r) = $0 { return (t, id, rt, r) }; return nil }
        #expect(denied.count == 1)
        #expect(denied.first?.0 == "read_file" && denied.first?.1 == "call-1" && denied.first?.2 == "policy")
        #expect(denied.first?.3 == "read_file is not allowed for this profile")
        let results = seen.compactMap { if case .user(let u) = $0 { return u }; return nil }
        if case .toolResult(_, _, let isError) = results.first?.content.first { #expect(isError) } else { Issue.record("no tool result") }
        let texts = seen.compactMap { if case .assistant(let a) = $0 { return a.content.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined() }; return nil }
        #expect(texts.last == "I could not read the file. (permission: reject-once)")
        guard case .result(let r) = seen.last else { Issue.record("no result"); return }
        #expect(r.subtype == "success")
        await engine.stop(.session)
    }

    @Test func stopTurnCancelsAndAnswersTheOpenPermissionRequestCancelled() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let engine = ACPEngine(options: Self.options(fake: fake))
        let askedAt = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let asked = Mutex(false)
        try engine.setPermissionHandler { _, _, _ in
            asked.withLock { $0 = true }
            // The person never answers; the cancel must resolve the request on its own.
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in askedAt.withLock { $0 = k } }
            return .deny("late")
        }
        let c = Collector(engine)
        try await engine.start()
        try await engine.send("Read utils.py.")
        for _ in 0..<200 where !asked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(asked.withLock { $0 })
        await engine.stop(.turn)
        let seen = await c.untilResult()
        guard case .result(let r) = seen.last else { Issue.record("no result"); return }
        #expect(r.wasInterrupted)
        #expect(r.stopReason == "cancelled")
        // The tool call that never finished got a result saying so.
        let results = seen.compactMap { if case .user(let u) = $0 { return u }; return nil }
        #expect(results.count == 1)
        // The agent is still alive for the next turn.
        #expect(engine.sessionId == FakeACPAgent.sessionId)
        askedAt.withLock { $0 }?.resume()
        await engine.stop(.session)
    }

    @Test func steerNowCancelsTheRunningPromptAndSendsTheNextOne() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let engine = ACPEngine(options: Self.options(fake: fake))
        try engine.setPolicy { _, _ in .allow }
        let c = Collector(engine)
        try await engine.start()
        try await engine.send("please sleep")
        // Queued steering waits for the running prompt.
        try await engine.steer("second")
        try await engine.steerNow("Read utils.py now.")
        let first = await c.untilResult()
        guard case .result(let r1) = first.last else { Issue.record("no first result"); return }
        #expect(r1.stopReason == "cancelled")
        // The queued "second" runs next (a read scenario), then the steered prompt; both end.
        let second = await c.untilResult()
        guard case .result(let r2) = second.last else { Issue.record("no second result"); return }
        #expect(r2.stopReason == "end_turn")
        let third = await c.untilResult()
        guard case .result(let r3) = third.last else { Issue.record("no third result"); return }
        #expect(r3.stopReason == "end_turn")
        #expect(c.all.contains { if case .steeringQueued(let t) = $0 { return t == "second" }; return false })
        await engine.stop(.session)
    }

    @Test func anErrorFromTheAgentIsAnErrorResultNotAThrow() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let engine = ACPEngine(options: Self.options(fake: fake))
        let c = Collector(engine)
        try await engine.start()
        try await engine.send("please fail")
        let seen = await c.untilResult()
        guard case .result(let r) = seen.last else { Issue.record("no result"); return }
        #expect(r.subtype == "error_during_execution")
        #expect(r.isError)
        #expect(r.errorText?.contains("failed on purpose") == true)
        #expect(r.errorText?.contains("-32000") == true)
        await engine.stop(.session)
    }

    @Test func theChildEndingMidTurnEndsTheTurnAndTheStream() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let engine = ACPEngine(options: Self.options(fake: fake, env: ["FAKE_ACP_EXIT_ON_PROMPT": "1"]))
        let c = Collector(engine)
        try await engine.start()
        try await engine.send("Read utils.py.")
        let seen = await c.untilResult()
        guard case .result(let r) = seen.last else { Issue.record("no result"); return }
        #expect(r.subtype == "error_during_execution")
        #expect(r.errorText?.contains("exited with status 3") == true)
        await c.untilExit()
        let exit = c.all.compactMap { if case .exited(let s, _) = $0 { return s }; return nil }
        #expect(exit == [3])
        // A send after the end is an error result too, not a throw into the loop... the request layer throws
        // `exited`, which the turn turns into a result.
        try await engine.send("again")
        let again = await c.untilResult()
        #expect(again.isEmpty)   // the stream finished with `.exited`; nothing more arrives
    }

    @Test func sessionLoadIsAskedOnlyWhenAdvertisedAndResumeIsBeforeStart() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        // Advertised: the earlier id is loaded and the replayed history stays off the stream.
        let loading = ACPEngine.make(options: Self.options(fake: fake, load: true, env: ["FAKE_ACP_LOAD_SESSION": "1"]))
        let resumable = try #require(loading as? Resumable)
        try resumable.resume("earlier-session")
        let c = Collector(loading)
        try await loading.start()
        #expect(loading.sessionId == "earlier-session")
        let init1 = await c.initializedData()
        #expect(init1?.data["resumed"]?.boolValue == true)
        #expect(!c.all.contains { if case .assistant = $0 { return true }; return false })
        #expect(throws: EngineError.alreadyStarted(operation: "resume")) { try resumable.resume("later") }
        await loading.stop(.session)
        // Wrapped as resumable but the live agent says no: a fresh session, said on the stream.
        let fresh = ACPEngine.make(options: Self.options(fake: fake, load: true))
        try (fresh as? Resumable)?.resume("earlier-session")
        let c2 = Collector(fresh)
        try await fresh.start()
        #expect(fresh.sessionId == FakeACPAgent.sessionId)
        _ = await c2.initializedData()
        #expect(c2.all.contains { if case .system(let s, _) = $0 { return s == "resume_unavailable" }; return false })
        await fresh.stop(.session)
    }

    @Test func setModelAfterStartRestartsTheChildAndIsRememberedForTheNextStart() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let engine = ACPEngine(options: Self.options(fake: fake))
        let c = Collector(engine)
        try await engine.start()
        try await engine.setModel("fake-large")
        await c.untilExit()
        #expect(c.all.contains { if case .system(let s, let d) = $0 { return s == "model_restart" && d["model"]?.stringValue == "fake-large" }; return false })
        #expect(engine.options.model == "fake-large")
        // The next engine built from these options launches on it.
        let next = ACPEngine(options: engine.options)
        let c2 = Collector(next)
        try await next.start()
        #expect(await c2.initializedData()?.model == "fake-large")
        await next.stop(.session)
    }

    @Test func startShapingCallsAfterStartThrowAlreadyStarted() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built"); return }
        let engine = ACPEngine(options: Self.options(fake: fake))
        try await engine.start()
        #expect(throws: EngineError.alreadyStarted(operation: "setPolicy")) { try engine.setPolicy(nil) }
        #expect(throws: EngineError.alreadyStarted(operation: "setPermissionHandler")) { try engine.setPermissionHandler(nil) }
        #expect(throws: EngineError.alreadyStarted(operation: "setQuestionHandler")) { try engine.setQuestionHandler(nil) }
        await engine.stop(.session)
    }

    /// Kyberna console 93: GitHub Copilot CLI's "Info: …/hello.txt" (a message chunk while the edit ran) and
    /// "Done." (a chunk after it) rendered as "hello.txtDone.", one text block. The text before a tool's end is its
    /// own assistant message, the result's content blocks are joined with a newline, and the closing chunk is a
    /// new block, so the transcript shows the three on their own lines.
    @Test func textAroundAToolsEndAndAMultiBlockResultKeepTheirSeparators() async throws {
        guard let fake = Self.fakePath else { Issue.record("fake-acp not built; run `swift build --product fake-acp` first"); return }
        var o = Self.options(fake: fake); o.includePartialMessages = true
        let engine = ACPEngine(options: o)
        try engine.setPolicy { _, _ in .allow }
        let c = Collector(engine)
        try await engine.start()
        try await engine.send("Write hello.txt and say when it is done.")
        let seen = await c.untilResult()
        let assistants = seen.compactMap { if case .assistant(let a) = $0 { return a }; return nil }
        let texts = assistants.flatMap { $0.content.compactMap { if case .text(let t) = $0 { return t }; return nil } }
        #expect(texts == ["I will read utils.py.", "Info: /tmp/hello.txt", "Done."])
        #expect(assistants.last?.stopReason == "end_turn")
        let results = seen.compactMap { if case .user(let u) = $0 { return u }; return nil }
        #expect(results.count == 1)
        #expect(results.first?.content.first?.resultText == "wrote 6 bytes\nok")
        // The message before the result precedes it on the stream, as it did on the agent's side.
        let order = seen.compactMap { m -> String? in
            if case .assistant(let a) = m, a.content.contains(.text("Info: /tmp/hello.txt")) { return "info" }
            if case .user = m { return "result" }
            if case .assistant(let a) = m, a.content.contains(.text("Done.")) { return "done" }
            return nil
        }
        #expect(order == ["info", "result", "done"])
        // The stream events for "Done." index a new content block, so a live view does not append it to the earlier text.
        let indices = seen.compactMap { m -> (Int, String)? in
            guard case .streamEvent(let e, _) = m, let text = e["delta"]?["text"]?.stringValue, let i = e["index"]?.intValue else { return nil }
            return (i, text)
        }
        let infoIndex = indices.first { $0.1 == "Info: /tmp/hello.txt" }?.0
        let doneIndex = indices.first { $0.1 == "Done." }?.0
        #expect(infoIndex != nil && doneIndex != nil && infoIndex != doneIndex)
        guard case .result(let r) = seen.last else { Issue.record("no result"); return }
        #expect(r.result == "I will read utils.py.\nInfo: /tmp/hello.txt\nDone.")
        await engine.stop(.session)
        await c.untilExit()
    }

    @Test func theRecordMergesToolCallUpdatesAndReadsContentShapes() {
        let first = ACPEngine.record(from: ["toolCallId": "t", "title": "Edit main.swift", "kind": "edit", "status": "pending"], merging: nil)
        #expect(first.name == "edit")   // no programmatic name: the kind stands in
        #expect(first.input == ["title": "Edit main.swift"])
        let done = ACPEngine.record(from: ["toolCallId": "t", "status": "completed",
                                           "content": [["type": "diff", "path": "main.swift", "oldText": "a", "newText": "b"],
                                                       ["type": "content", "content": ["type": "text", "text": "ok"]]]], merging: first)
        #expect(done.status == "completed")
        #expect(done.title == "Edit main.swift")
        #expect(done.output.count == 2)
        #expect(done.output[0].hasPrefix("diff main.swift:"))
        #expect(done.output[1] == "ok")
        #expect(ACPEngine.text(of: ["type": "resource_link", "uri": "file:///x", "name": "x"]) == "[x](file:///x)")
        #expect(ACPEngine.text(of: ["type": "image", "mimeType": "image/png", "data": "…"]) == "[image image/png]")
    }
}
