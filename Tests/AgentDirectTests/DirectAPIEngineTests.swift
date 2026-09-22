import Testing
import Foundation
import Synchronization
import AgentProtocol
import AgentSession
import AgentEngine
import AgentTestKit
@testable import AgentDirect

/// Pulls messages from an engine until a result arrives.
final class MessageCollector {
    var iterator: AsyncStream<Message>.AsyncIterator
    var all: [Message] = []
    init(_ engine: DirectAPIEngine) { iterator = engine.messages.makeAsyncIterator() }

    /// Messages up to and including the next `.result`.
    func untilResult() async -> [Message] {
        var turn: [Message] = []
        while let m = await iterator.next() {
            turn.append(m); all.append(m)
            if case .result = m { break }
        }
        return turn
    }
    func next() async -> Message? { let m = await iterator.next(); if let m { all.append(m) }; return m }
}

extension [Message] {
    var result: ResultMessage? { for m in self { if case .result(let r) = m { return r } }; return nil }
    var assistants: [AssistantMessage] { compactMap { if case .assistant(let a) = $0 { return a }; return nil } }
    var users: [UserMessage] { compactMap { if case .user(let u) = $0 { return u }; return nil } }
    var systems: [(String, JSONValue)] { compactMap { if case .system(let s, let d) = $0 { return (s, d) }; return nil } }
}

enum Tools {
    static let wordCount = try! SwiftTool(name: "word_count", description: "Counts words.", inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]],
                                          annotations: ToolAnnotations(readOnlyHint: true)) { input in
        "\(input["text"]?.stringValue?.split(separator: " ").count ?? 0)"
    }
    static let upper = try! SwiftTool(name: "upper", description: "Uppercases.", inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]],
                                      annotations: ToolAnnotations(readOnlyHint: true)) { input in (input["text"]?.stringValue ?? "").uppercased() }
    /// Returns `n` characters, for histories of a known size.
    static let pad = try! SwiftTool(name: "pad", description: "Pads.", inputSchema: ["type": "object", "properties": ["n": ["type": "integer"]], "required": ["n"]],
                                    annotations: ToolAnnotations(readOnlyHint: true)) { input in String(repeating: "x", count: input["n"]?.intValue ?? 0) }
    static let failing = try! SwiftTool(name: "failing", description: "Throws.", inputSchema: ["type": "object", "properties": [:]]) { _ -> String in
        struct Boom: Error {}; throw Boom()
    }
    static let slow = try! SwiftTool(name: "slow", description: "Sleeps.", inputSchema: ["type": "object", "properties": [:]]) { _ -> String in
        try await Task.sleep(for: .seconds(30)); return "done"
    }
    /// Spawns a long process through the registry and reports its pid before it ends (it never ends on its own).
    static let sleeper = try! SwiftTool(name: "sleeper", description: "Runs sleep 45.", inputSchema: ["type": "object", "properties": [:]]) { _ -> String in
        let ctx = ToolContext.current!
        let out = try await ctx.run(command: "sleep 45", timeout: 60)
        return "status \(out.status) signal \(out.signal.map(String.init) ?? "none")"
    }
}

func makeEngine(_ script: [FakeModelProvider.Turn], tools: [SwiftTool] = [Tools.wordCount, Tools.upper], delay: Duration = .zero,
                configure: (inout DirectEngineOptions) -> Void = { _ in }) -> (DirectAPIEngine, FakeModelProvider) {
    let provider = FakeModelProvider(script: script, delay: delay)
    var options = DirectEngineOptions(model: "fake-model")
    options.systemPrompt = "Be terse."
    options.compaction = nil
    configure(&options)
    let engine = DirectAPIEngine(provider: provider, options: options)
    try! engine.host(tools, serverName: "kyberna")
    return (engine, provider)
}

@Suite struct DirectAPIEngineTests {
    @Test func adoptsTheRightCapabilities() {
        let (engine, _) = makeEngine([])
        let e: any AgentEngine = engine
        #expect(e is ModelSwitching); #expect(e is EffortSetting); #expect(e is ReasoningControl)
        #expect(e is PermissionGating); #expect(e is ToolHosting); #expect(e is ImageAttaching); #expect(e is ContextReporting)
        #expect(!(e is Resumable)); #expect(!(e is HookCapable)); #expect(!(e is FileRewinding)); #expect(!(e is RateLimitReporting))
        #expect(e.engineVersion == "direct/fake")
    }

    @Test func twoTurnsWithOneToolCallAndOneParallelWave() async throws {
        let (engine, provider) = makeEngine([
            .events(FakeModelProvider.toolCalls([("t1", "mcp__kyberna__word_count", ["text": "one two three"])], text: "Counting.")),
            .events(FakeModelProvider.text("Three words.")),
            .events(FakeModelProvider.toolCalls([("t2", "mcp__kyberna__upper", ["text": "a"]), ("t3", "mcp__kyberna__word_count", ["text": "x y"])])),
            .events(FakeModelProvider.text("A and 2.")),
        ])
        let collector = MessageCollector(engine)
        try await engine.start()
        guard case .initialized(let sid, let model, let tools, let data)? = await collector.next() else { Issue.record("no initialized"); return }
        #expect(sid == engine.sessionId); #expect(model == "fake-model")
        #expect(tools == ["mcp__kyberna__word_count", "mcp__kyberna__upper"])
        #expect(data["apiKeySource"]?.stringValue == "direct")

        try await engine.send("How many words in 'one two three'?")
        let turn1 = await collector.untilResult()
        #expect(turn1.assistants.count == 2)
        #expect(turn1.assistants[0].content == [.text("Counting."), .toolUse(id: "t1", name: "mcp__kyberna__word_count", input: ["text": "one two three"])])
        #expect(turn1.users.count == 1)
        #expect(turn1.users[0].content[0].resultText == "3")
        let r1 = try #require(turn1.result)
        #expect(r1.subtype == "success"); #expect(r1.result == "Three words."); #expect(r1.numTurns == 2); #expect(r1.stopReason == "end_turn")
        #expect(r1.inputTokens == 30); #expect(r1.outputTokens == 20)
        // The second request carried the tool result in one user message, in the shape the API takes.
        let req2 = provider.requests[1]
        #expect(req2.messages.count == 3)
        #expect(req2.messages[2].role == .user)
        #expect(req2.messages[2].content == [.toolResult(toolUseId: "t1", content: .array([["type": "text", "text": "3"]]), isError: false)])
        #expect(req2.system == ["Be terse."]); #expect(req2.tools.map(\.name) == ["mcp__kyberna__word_count", "mcp__kyberna__upper"])

        try await engine.send("Now uppercase 'a' and count 'x y'.")
        let turn2 = await collector.untilResult()
        let waveResults = try #require(turn2.users.first).content
        #expect(waveResults.count == 2)
        #expect(waveResults[0] == .toolResult(toolUseId: "t2", content: .array([["type": "text", "text": "A"]]), isError: false))
        #expect(waveResults[1].resultText == "2")
        #expect(turn2.result?.result == "A and 2.")
        #expect(provider.requests.count == 4)
        #expect(provider.requests[3].messages.count == 7)   // user, assistant, user(result), assistant, user, assistant, user(results)
        // Both tool calls in the wave were answered in one user message, in call order.
        #expect(provider.requests[3].messages[6].toolResultIds == ["t2", "t3"])
        let waves = await engine.executor.waves([ToolCall(id: "a", name: "mcp__kyberna__upper", input: [:]), ToolCall(id: "b", name: "mcp__kyberna__word_count", input: [:])])
        #expect(waves == [[0, 1]])
    }

    /// A local runtime reports the reused prompt prefix as `cacheReadInputTokens`, on the `started` event and again
    /// on `finished`, or on `started` alone. The turn's result carries the sum over its model calls, so a Console
    /// row can show what the cache served.
    @Test func cacheReadsAreSummedIntoTheResult() async throws {
        var call1 = FakeModelProvider.toolCalls([("t1", "mcp__kyberna__word_count", ["text": "one two three"])],
                                                usage: ModelUsage(inputTokens: 20, outputTokens: 15, cacheReadInputTokens: 1_000))
        call1[0] = .started(model: "fake-model", usage: ModelUsage(inputTokens: 20, cacheReadInputTokens: 1_000))
        var call2 = FakeModelProvider.text("Three words.", usage: ModelUsage(inputTokens: 10, outputTokens: 5))
        call2[0] = .started(model: "fake-model", usage: ModelUsage(inputTokens: 10, cacheReadInputTokens: 1_200))   // finished says nothing about the cache
        let (engine, _) = makeEngine([.events(call1), .events(call2)])
        let collector = MessageCollector(engine)
        try await engine.start()
        _ = await collector.next()
        try await engine.send("How many words in 'one two three'?")
        let turn = await collector.untilResult()
        #expect(turn.assistants.map { $0.usage?["cache_read_input_tokens"]?.intValue } == [1_000, 1_200])
        let r = try #require(turn.result)
        #expect(r.usage?["cache_read_input_tokens"]?.intValue == 2_200)
        #expect(r.inputTokens == 30); #expect(r.outputTokens == 20)
        #expect(r.usage?["cache_creation_input_tokens"]?.intValue == 0)
    }

    @Test func deniedToolBecomesAnErrorResultTheModelSees() async throws {
        let (engine, provider) = makeEngine([
            .events(FakeModelProvider.toolCalls([("t1", "mcp__kyberna__upper", ["text": "hi"]), ("t2", "mcp__kyberna__word_count", ["text": "a b"])])),
            .events(FakeModelProvider.text("Could not uppercase; two words.")),
        ])
        try engine.setPolicy { tool, _ in tool.hasSuffix("upper") ? .deny("uppercasing is off in this profile") : .allow }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("go")
        let turn = await collector.untilResult()
        let denied = turn.compactMap { if case .permissionDenied(let t, let id, let rt, let reason) = $0 { return (t, id, rt, reason) }; return nil }
        #expect(denied.count == 1); #expect(denied[0].0 == "mcp__kyberna__upper"); #expect(denied[0].1 == "t1"); #expect(denied[0].2 == "policy")
        let results = try #require(turn.users.first).content
        guard case .toolResult("t1", let content, true) = results[0] else { Issue.record("expected an error result first"); return }
        #expect(content[0]?["text"]?.stringValue?.contains("Permission denied: uppercasing is off") == true)
        #expect(results[1].resultText == "2")
        #expect(provider.requests[1].messages[2].content[0] == .toolResult(toolUseId: "t1", content: content, isError: true))
        #expect(turn.result?.subtype == "success")
    }

    @Test func askOutcomeGoesToThePersonAndTheDecisionIsHonoured() async throws {
        let (engine, provider) = makeEngine([
            .events(FakeModelProvider.toolCalls([("t1", "mcp__kyberna__upper", ["text": "hi"])])),
            .events(FakeModelProvider.text("ok")),
        ])
        try engine.setPolicy { _, _ in .ask }
        try engine.setPermissionHandler { tool, input, ctx in
            #expect(ctx.payload.tool == tool); #expect(ctx.toolUseId == "t1")
            return .allow(updatedInput: ["text": "changed"])
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("go")
        let turn = await collector.untilResult()
        #expect(turn.contains { if case .permissionRequest(let p) = $0 { return p.toolUseId == "t1" }; return false })
        #expect(turn.users[0].content[0].resultText == "CHANGED")
        #expect(provider.requests.count == 2)
    }

    @Test func interruptDuringTheStreamDiscardsPartialOutput() async throws {
        let (engine, provider) = makeEngine([
            .events(FakeModelProvider.text("This reply takes a while to stream.")),
            .events(FakeModelProvider.text("Second answer.")),
        ], delay: .milliseconds(400)) { $0.includePartialMessages = true }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("first")
        try await Task.sleep(for: .milliseconds(500))   // inside the stream: started arrived, text pending
        await engine.stop(.turn)
        let turn = await collector.untilResult()
        #expect(turn.assistants.isEmpty)
        let r = try #require(turn.result)
        #expect(r.wasInterrupted); #expect(r.subtype == "error_during_execution"); #expect(r.errorText == nil)
        #expect(await engine.runnerHistory().messages.count == 1)
        // The conversation continues; the next request is valid and carries both user prompts.
        try await engine.send("second")
        let turn2 = await collector.untilResult()
        #expect(turn2.result?.result == "Second answer.")
        #expect(provider.requests[1].messages.map(\.role) == [.user])
        #expect(provider.requests[1].messages[0].text == "firstsecond")
    }

    @Test func interruptDuringAWaveRepairsHistoryAndEndsProcesses() async throws {
        let (engine, provider) = makeEngine([
            .events(FakeModelProvider.toolCalls([("t1", "mcp__kyberna__sleeper", [:]), ("t2", "mcp__kyberna__slow", [:])])),
            .events(FakeModelProvider.text("After the interrupt.")),
        ], tools: [Tools.sleeper, Tools.slow]) { $0.toolTimeout = 60 }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("go")
        // Wait until the sleeper has registered its process.
        var pids: [pid_t] = []
        for _ in 0..<100 { pids = engine.executor.registry.registeredPIDs; if !pids.isEmpty { break }; try await Task.sleep(for: .milliseconds(50)) }
        #expect(pids.count == 1)
        let started = ContinuousClock.now
        await engine.stop(.turn)
        #expect(ContinuousClock.now - started < .seconds(5))
        let turn = await collector.untilResult()
        let r = try #require(turn.result)
        #expect(r.wasInterrupted)
        #expect(engine.executor.registry.registeredPIDs.isEmpty)
        // The process group is gone: signal 0 to the pid fails once it is reaped, or reports ESRCH.
        try await Task.sleep(for: .milliseconds(200))
        #expect(pids.allSatisfy { kill($0, 0) != 0 })
        // History: the assistant's two tool_use blocks both have an is_error result reading "Interrupted by user".
        let repaired = turn.users.flatMap(\.content)
        #expect(repaired.count == 2)
        for block in repaired {
            guard case .toolResult(_, let content, true) = block else { Issue.record("expected error results"); continue }
            #expect(content[0]?["text"]?.stringValue == "Interrupted by user")
        }
        let history = await engine.runnerHistory()
        #expect(history.pendingToolUseIds.isEmpty)
        #expect(history.messages.map(\.role) == [.user, .assistant, .user])
        try await engine.send("continue")
        let turn2 = await collector.untilResult()
        #expect(turn2.result?.result == "After the interrupt.")
        #expect(provider.requests[1].messages[2].toolResultIds == ["t1", "t2"])
        #expect(provider.requests[1].messages[2].text == "continue")
    }

    @Test func steerDuringATurnRidesTheNextRequest() async throws {
        let (engine, provider) = makeEngine([
            .events(FakeModelProvider.toolCalls([("t1", "mcp__kyberna__slow", [:])])),
            .events(FakeModelProvider.text("Steered.")),
        ], tools: [Tools.slow]) { $0.toolTimeout = 1 }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("go")
        try await Task.sleep(for: .milliseconds(200))
        try await engine.steer("actually, stop and summarise")
        let turn = await collector.untilResult()
        #expect(turn.contains { if case .steeringQueued(let t) = $0 { return t == "actually, stop and summarise" }; return false })
        let toolMessage = provider.requests[1].messages[2]
        #expect(toolMessage.toolResultIds == ["t1"])
        #expect(toolMessage.text == "actually, stop and summarise")
        #expect(toolMessage.content[0].isErrorResult)   // the slow tool timed out at 1 s
        #expect(turn.result?.result == "Steered.")
    }

    @Test func structuredOutputIsParsedIntoTheResult() async throws {
        let (engine, provider) = makeEngine([.events(FakeModelProvider.text(#"{"reply":"yes","options":[1,2]}"#))]) {
            $0.outputSchema = ["type": "object", "properties": ["reply": ["type": "string"], "options": ["type": "array", "items": ["type": "integer"]]], "required": ["reply", "options"], "additionalProperties": false]
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("yes or no?")
        let r = try #require(await collector.untilResult().result)
        #expect(r.structuredOutput == ["reply": "yes", "options": [1, 2]])
        #expect(provider.requests[0].outputSchema?["required"] == ["reply", "options"])
    }

    @Test func refusalEndsTheTurnWithAnExplanation() async throws {
        let (engine, _) = makeEngine([.events(FakeModelProvider.refusal(category: "cyber", explanation: "Declined: cyber."))])
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("do the thing")
        let turn = await collector.untilResult()
        #expect(turn.systems.contains { $0.0 == "refusal" && $0.1["category"]?.stringValue == "cyber" })
        let r = try #require(turn.result)
        #expect(r.stopReason == "refusal"); #expect(r.result == "Declined: cyber."); #expect(!r.isError)
    }

    @Test func maxTokensIsContinuedAndProviderErrorsEndTheTurn() async throws {
        let cut: [ModelEvent] = [.started(model: "m", usage: nil), .blockStarted(index: 0, block: .text), .textDelta(index: 0, text: "Part one"), .blockStopped(index: 0),
                                 .finished(stopReason: .maxTokens, usage: ModelUsage(outputTokens: 10), stopDetails: nil)]
        let (engine, provider) = makeEngine([.events(cut), .events(FakeModelProvider.text(" and part two.")),
                                             .failure(ProviderError.http(status: 401, type: "authentication_error", message: "bad key", requestId: "req_1"))])
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("write")
        let turn = await collector.untilResult()
        #expect(turn.result?.result == " and part two.")
        #expect(provider.requests[1].messages.count == 3)
        #expect(provider.requests[1].messages[2].text.contains("cut off"))
        try await engine.send("again")
        let r = try #require(await collector.untilResult().result)
        #expect(r.isError); #expect(r.subtype == "error_during_execution")
        #expect(r.errors?.first == "HTTP 401 authentication_error: bad key (request-id req_1)")
    }

    @Test func partialMessagesStreamInTheMessagesAPIShape() async throws {
        let (engine, _) = makeEngine([.events(FakeModelProvider.toolCalls([("t1", "mcp__kyberna__upper", ["text": "q"])], text: "Hi")), .events(FakeModelProvider.text("done"))]) {
            $0.includePartialMessages = true
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("go")
        let turn = await collector.untilResult()
        let events = turn.compactMap { if case .streamEvent(let e, nil) = $0 { return e }; return nil }
        #expect(events.contains(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hi"]]))
        #expect(events.contains { $0["type"]?.stringValue == "content_block_start" && $0["content_block"]?["name"]?.stringValue == "mcp__kyberna__upper" })
        #expect(events.contains { $0["delta"]?["type"]?.stringValue == "input_json_delta" })
    }

    @Test func capabilitiesApplyToTheNextRequest() async throws {
        let (engine, provider) = makeEngine([.events(FakeModelProvider.text("a")), .events(FakeModelProvider.text("b"))]) {
            $0.availableModels = [ModelChoice(value: "fake-model", resolvedModel: "fake-model", displayName: "Fake", description: "", supportedEffortLevels: ["low", "high"])]
        }
        try engine.setReasoningDisplay(.hidden)
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        #expect(throws: EngineError.alreadyStarted(operation: "setPolicy")) { try engine.setPolicy { _, _ in .allow } }
        #expect(throws: EngineError.alreadyStarted(operation: "host")) { try engine.host([Tools.upper], serverName: "x") }
        try await engine.send("one"); _ = await collector.untilResult()
        try await engine.setModel("other-model"); try await engine.setEffort("low")
        #expect(try await engine.setThinking(.adaptive))
        #expect(engine.availableModels.count == 1)
        try await engine.send("two"); _ = await collector.untilResult()
        #expect(provider.requests[0].model == "fake-model"); #expect(provider.requests[0].thinking == nil)
        #expect(provider.requests[1].model == "other-model"); #expect(provider.requests[1].effort == "low")
        #expect(provider.requests[1].thinking == .adaptive(display: .omitted))
        let usage = try await engine.contextUsage()
        #expect(usage.totalTokens == 10); #expect(usage.maxTokens == 200_000); #expect(usage.model == "other-model")
    }

    @Test func imagesBecomeImageBlocks() async throws {
        let (engine, provider) = makeEngine([.events(FakeModelProvider.text("a cat"))])
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("what is this?", images: [ImageAttachment(base64: "AAAA", mediaType: "image/png")])
        _ = await collector.untilResult()
        #expect(provider.requests[0].messages[0].content == [.image(base64: "AAAA", mediaType: "image/png"), .text("what is this?")])
    }

    @Test func loopDetectionFeedsBackAndThenEndsTheTurn() async throws {
        let same = FakeModelProvider.toolCalls([("t", "mcp__kyberna__upper", ["text": "x"])])
        let (engine, provider) = makeEngine((0..<6).map { _ in .events(same) })
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("loop")
        let turn = await collector.untilResult()
        let r = try #require(turn.result)
        #expect(r.stopReason == "loop_detected"); #expect(r.subtype == "loop_detected"); #expect(r.isError); #expect(r.numTurns == 5)
        // The wave signal's note on the third identical wave; the per-call refusal from the fourth (three runs made).
        #expect(provider.requests[3].messages.last?.content[0].resultTextValue.contains("same call as the previous 2 turns") == true)
        #expect(provider.requests[4].messages.last?.content[0].resultTextValue.contains("already made 3 times") == true)
        #expect(turn.systems.contains { $0.0 == "loop_detected" })
    }

    /// Gateway 38: one call, then five identical ones, repeated (1 5 5 5 …) never repeats a whole wave, so the wave
    /// signal never fired and the certification run made the same `file_glob` call 221 times. Per call: the third
    /// identical call in a wave is refused, the next wave with a refusal ends the turn.
    @Test func alternatingWaveSizesStopWithinBudget() async throws {
        let one = FakeModelProvider.toolCalls([("a", "mcp__kyberna__upper", [:])])
        let five = FakeModelProvider.toolCalls((0..<5).map { ("b\($0)", "mcp__kyberna__upper", [:]) })
        var script: [FakeModelProvider.Turn] = []
        for _ in 0..<5 { script += [.events(one), .events(five), .events(five), .events(five)] }
        let (engine, provider) = makeEngine(script)
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("glob everything")
        let turn = await collector.untilResult()
        let r = try #require(turn.result)
        #expect(r.subtype == "loop_detected"); #expect(r.stopReason == "loop_detected"); #expect(r.isError)
        #expect(r.numTurns <= 4); #expect(provider.requests.count == r.numTurns)
        // Wave 2: two of the five ran (three runs in all), three were refused with the count and the arguments named.
        let wave2 = turn.users[1].content
        #expect(wave2.filter(\.isErrorResult).count == 3)
        let refusal = wave2.last?.resultText ?? ""
        #expect(refusal.contains("already made 3 times")); #expect(refusal.contains("Nothing differed")); #expect(refusal.contains("{}"))
        // Wave 3: every call refused; the second wave with a refusal ends the turn.
        #expect(turn.users[2].content.filter(\.isErrorResult).count == 5)
        let note = try #require(turn.systems.first { $0.0 == "loop_detected" })
        #expect(note.1["tools"] == ["mcp__kyberna__upper"]); #expect(note.1["refusals"]?.intValue == 2)
        #expect(r.errors?.first?.contains("mcp__kyberna__upper") == true)
        // Every tool_use in the history has its result: the refusals are results too.
        let history = await engine.testHistory()
        #expect(history.pendingToolUseIds.isEmpty)
    }

    /// The per-call signal reads outcomes: a call whose result changes each time is not a loop.
    @Test func aCallWithChangingResultsIsNotRefused() async throws {
        let counter = Mutex(0)
        let clock = try! SwiftTool(name: "clock", description: "Ticks.", inputSchema: ["type": "object", "properties": [:]],
                                   annotations: ToolAnnotations(readOnlyHint: true)) { _ in counter.withLock { $0 += 1; return "\($0)" } }
        let tick = FakeModelProvider.toolCalls([("t", "mcp__kyberna__clock", [:])])
        let (engine, _) = makeEngine((0..<3).map { _ in .events(tick) } + [.events(FakeModelProvider.text("done"))], tools: [clock]) {
            $0.repeatedCallLimit = 2
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("tick")
        let turn = await collector.untilResult()
        #expect(turn.result?.subtype == "success"); #expect(turn.result?.numTurns == 4)
        #expect(turn.users.flatMap(\.content).filter(\.isErrorResult).isEmpty)
    }

    /// Gateway 39: a single turn of tool waves has no user message to cut at, so compaction never ran and the
    /// context overflowed. The boundary between two waves is a cut now, checked after each wave's results are
    /// appended; the summarised pair goes, the newest wave stays whole, and a user line bridges the marker to it.
    @Test func aTurnOfManyToolCallsCompactsInsideTheLoop() async throws {
        let big = FakeModelProvider.toolCalls([("a", "mcp__kyberna__pad", ["n": 1_200])])
        let big2 = FakeModelProvider.toolCalls([("b", "mcp__kyberna__pad", ["n": 1_201])])
        let (engine, provider) = makeEngine([.events(big), .events(big2), .respond { _ in FakeModelProvider.text("S1") }, .events(FakeModelProvider.text("done"))],
                                            tools: [Tools.pad]) {
            $0.contextWindowTokens = 1_000
            var c = CompactionOptions(); c.triggerTokens = 300; c.keepRecentTokens = 100; c.keepFirst = 1
            $0.compaction = c
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("go")
        let turn = await collector.untilResult()
        #expect(turn.result?.subtype == "success"); #expect(turn.result?.result == "done")
        // Requests: wave a, wave b, the summary, the final answer.
        #expect(provider.requests.count == 4)
        #expect(provider.requests[2].system == [CompactionOptions.summaryPrompt])
        let after = provider.requests[3].messages
        #expect(after.count == 5)
        #expect(after.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(after[1].text.hasPrefix("[compacted: 2 messages]")); #expect(after[2].text == Compactor.bridgeText)
        #expect(after[3].toolUseIds == ["b"]); #expect(after[4].toolResultIds == ["b"])
        let report = try #require(turn.systems.first { $0.0 == "compaction" })
        #expect(report.1["messages"]?.intValue == 2)
    }

    /// Gateway 39: when the estimate before a call already exceeds the window, the oldest tool results become a
    /// one-line stub (the newest wave is left alone) and the turn goes on.
    @Test func anOversizedPromptDropsOldToolResultsBeforeTheCall() async throws {
        let read = ModelUsage(inputTokens: 1_000, outputTokens: 15)
        let waves: [FakeModelProvider.Turn] = ["a", "b", "c"].enumerated().map { i, id in
            .events(FakeModelProvider.toolCalls([(id, "mcp__kyberna__pad", ["n": .number(Double(2_000 + i))])], usage: i == 2 ? read : ModelUsage(inputTokens: 20, outputTokens: 15)))
        }
        let (engine, provider) = makeEngine(waves + [.events(FakeModelProvider.text("done"))], tools: [Tools.pad]) { $0.contextWindowTokens = 1_000 }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("go")
        let turn = await collector.untilResult()
        #expect(turn.result?.subtype == "success")
        let forced = try #require(turn.systems.first { $0.0 == "compaction_forced" })
        #expect(forced.1["dropped"]?.intValue == 2); #expect(forced.1["reason"]?.stringValue?.contains("against a window of 1000") == true)
        let last = provider.requests[3].messages
        #expect(last[2].content[0].resultTextValue.hasPrefix("[tool result dropped to fit the context window: 2000 characters]"))
        #expect(last[4].content[0].resultTextValue.hasPrefix("[tool result dropped"))
        #expect(last[6].content[0].resultTextValue.count == 2_002)
        #expect(last[2].toolResultIds == ["a"]); #expect(last[4].toolResultIds == ["b"])
    }

    /// Gateway 39: a provider's overflow error compacts and calls again once; when that fails too the turn ends,
    /// and the next turn compacts before its first call rather than failing the same way.
    @Test func anOverflowErrorRecoversInTheTurnOrOnTheNext() async throws {
        let overflow = ProviderError.capabilityMismatch("a prompt of 32796 tokens in a context of 32768")
        let wave = FakeModelProvider.toolCalls([("a", "mcp__kyberna__pad", ["n": 400])])
        let (engine, provider) = makeEngine([.events(wave), .failure(overflow), .events(FakeModelProvider.text("recovered")),
                                             .failure(overflow), .failure(overflow),
                                             .events(FakeModelProvider.text("third"))], tools: [Tools.pad]) { $0.contextWindowTokens = 1_000 }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("one")
        let first = await collector.untilResult()
        #expect(first.result?.subtype == "success"); #expect(first.result?.result == "recovered")
        #expect(first.systems.filter { $0.0 == "compaction_forced" }.count == 1)
        #expect(first.systems.first { $0.0 == "compaction_forced" }?.1["reason"]?.stringValue?.contains("in a context of 32768") == true)

        try await engine.send("two")
        let second = await collector.untilResult()
        #expect(second.result?.isError == true); #expect(second.result?.errors?.first?.contains("in a context of") == true)
        #expect(second.systems.filter { $0.0 == "compaction_forced" }.count == 1)

        try await engine.send("three")
        let third = await collector.untilResult()
        #expect(third.result?.subtype == "success"); #expect(third.result?.result == "third")
        let forced = try #require(third.systems.first { $0.0 == "compaction_forced" })
        #expect(forced.1["reason"]?.stringValue?.contains("previous turn") == true)
        #expect(provider.requests.count == 6)
        #expect(provider.requests[5].messages.last?.text.hasSuffix("three") == true)   // "two" never got its answer; the prompts merged
    }
}


extension ContentBlock {
    var isErrorResult: Bool { if case .toolResult(_, _, true) = self { return true }; return false }
}
extension ModelContentBlock {
    var isErrorResult: Bool { if case .toolResult(_, _, true) = self { return true }; return false }
    var resultTextValue: String {
        guard case .toolResult(_, let c, _) = self else { return "" }
        return c.stringValue ?? (c.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
    }
}

extension DirectAPIEngine {
    func runnerHistory() async -> ConversationHistory { await testHistory() }
}
