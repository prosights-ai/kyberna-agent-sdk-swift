import Testing
import Foundation
import AgentProtocol
import AgentSession
import AgentEngine
import AgentTestKit
@testable import AgentDirect

/// Compaction for engines without their own (release plan v0.2.12 Phase 3 step 3): the cut, the tool pair, the
/// marker, the boundary reuse, the failure path, the spill.
@Suite struct CompactionTests {
    static let big = ModelUsage(inputTokens: 500, outputTokens: 5)

    /// Trigger at 100 tokens, a two-message head, a one-token tail: the smallest history that compacts.
    static func options(_ change: (inout CompactionOptions) -> Void = { _ in }) -> CompactionOptions {
        var c = CompactionOptions()
        c.triggerTokens = 100; c.keepFirst = 2; c.keepRecentTokens = 1; c.minimumProgress = 0.1
        change(&c)
        return c
    }

    static func summary(_ text: String) -> FakeModelProvider.Turn { .respond { _ in FakeModelProvider.text(text) } }

    static func toolPair(_ id: String, result: String = "r") -> [ModelMessage] {
        [ModelMessage(role: .assistant, content: [.toolUse(id: id, name: "x", input: [:])]),
         ModelMessage(role: .user, content: [.toolResult(toolUseId: id, content: .string(result), isError: false)])]
    }

    // MARK: The cut

    @Test func theCutNeverSeparatesAToolCallFromItsResult() {
        // 0 u1, 1 a1, 2 u2, 3 a2(tool_use), 4 u(tool_result), 5 a3, 6 u3, 7 a4, 8 u4
        let h = ConversationHistory(messages: [.user("one!"), .assistant("aaaa"), .user("two!")] + Self.toolPair("t") + [.assistant("cccc"), .user("thr!"), .assistant("dddd"), .user("for!")])
        #expect(h.safeCutIndices == [2, 6, 8])
        #expect(Compactor.cut(h, headEnd: 2, keepRecentTokens: 1) == 8)
        #expect(Compactor.cut(h, headEnd: 2, keepRecentTokens: 1_000) == 5)   // nothing keeps that much: the oldest cut after the head, here the wave boundary after the tool pair
        #expect(Compactor.cut(h, headEnd: 8, keepRecentTokens: 1) == nil)
        for keep in [1, 2, 3, 5, 50] { #expect(Compactor.cut(h, headEnd: 2, keepRecentTokens: keep) != 4) }
    }

    @Test func theHeadExtendsPastAToolPairItWouldSplit() {
        // keepFirst 2 would end the head after the assistant's tool_use and start the middle with its result.
        let h = ConversationHistory(messages: [.user("one!")] + Self.toolPair("t") + [.assistant("aaaa"), .user("two!"), .assistant("bbbb"), .user("thr!")])
        #expect(Compactor.headEnd(h, keepFirst: 2) == 3)
        #expect(Compactor.headEnd(h, keepFirst: 0) == 0)
        #expect(Compactor.headEnd(h, keepFirst: 9) == 7)
        let plan = Compactor.plan(h, options: Self.options { $0.triggerTokens = 0 }, window: 1_000)
        #expect(plan?.headEnd == 3); #expect(plan?.cut == 6)
        // The head never swallows the previous pass's marker: the middle starts with it.
        let again = ConversationHistory(messages: [.user("one!"), .assistant("aaaa"), .assistant("[compacted: 2 messages]\nS1"), .user("two!"), .assistant("bbbb"), .user("thr!")])
        #expect(Compactor.headEnd(again, keepFirst: 2) == 2)
    }

    @Test func minimumProgressShrinksTheKeptTail() {
        // 0 u1, 1 a, 2 u2, 3 b, 4 u3, 5 c (4,000 characters), 6 u4: keeping 3 tokens lands the cut at u3 and removes
        // two tokens of a thousand; the retries scale the tail to one token and the cut moves to u4.
        let h = ConversationHistory(messages: [.user("one!"), .assistant("aaaa"), .user("two!"), .assistant("bbbb"), .user("thr!"),
                                               .assistant(String(repeating: "c", count: 4_000)), .user("for!")])
        let plan = Compactor.plan(h, options: Self.options { $0.keepRecentTokens = 3 }, window: 1_000)
        #expect(plan?.cut == 6); #expect(plan?.retries == 2); #expect((plan?.removed ?? 0) > 900)
        let noRetry = Compactor.plan(h, options: Self.options { $0.keepRecentTokens = 3; $0.maxProgressRetries = 0 }, window: 1_000)
        #expect(noRetry?.cut == 4); #expect(noRetry?.retries == 0)
        #expect(Compactor.plan(h, options: Self.options { $0.triggerTokens = 5_000 }, window: 1_000) == nil)
    }

    @Test func theDefaultsFollowTheWindow() {
        let c = CompactionOptions()
        #expect(c.resolvedTrigger(window: 8_000) == 5_600)
        #expect(c.resolvedKeepRecent(window: 8_000) == 2_000)
        #expect(c.resolvedSpillDirectory(workingDirectory: "/work") == "/work/.kyberna/tool-output")
        #expect(Compactor.estimatedTokens(ConversationHistory(messages: [.user(String(repeating: "x", count: 400))])) == 100)
        #expect(Compactor.estimatedTokens(ConversationHistory(messages: [.user("x")], lastContextTokens: 777)) == 777)
    }

    // MARK: The engine

    @Test func aPassReplacesTheMiddleWithOneMarkedMessageAndReportsIt() async throws {
        let b = String(repeating: "b", count: 400)
        let (engine, provider) = makeEngine([.events(FakeModelProvider.text("a")), .events(FakeModelProvider.text(b, usage: Self.big)),
                                             Self.summary("S1"), .events(FakeModelProvider.text("c"))]) {
            $0.contextWindowTokens = 1_000; $0.compaction = Self.options()
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        for p in ["one", "two", "three"] { try await engine.send(p); _ = await collector.untilResult() }

        let summaryRequest = provider.requests[2]
        #expect(summaryRequest.system == [CompactionOptions.summaryPrompt])
        #expect(summaryRequest.messages.count == 1)
        #expect(summaryRequest.messages[0].text.contains("USER: two")); #expect(summaryRequest.messages[0].text.contains("ASSISTANT: \(b)"))
        #expect(summaryRequest.cachesPrefix == false)

        let after = provider.requests[3].messages
        #expect(after.map(\.text) == ["one", "a", "[compacted: 2 messages]\nS1", "three"])
        #expect(after[2].role == .assistant)
        let history = await engine.testHistory()
        #expect(history.keptBoundary == 3); #expect(history.compactions == 1)

        let report = try #require(collector.all.systems.first { $0.0 == "compaction" })
        // 500 from the provider, plus its 5 output tokens and the estimate of the prompt appended since.
        #expect(report.1["messages"]?.intValue == 2); #expect((500..<520).contains(report.1["tokensBefore"]?.intValue ?? 0))
        #expect((report.1["tokensAfter"]?.intValue ?? 999) < 500)
        #expect(!collector.all.systems.contains { $0.0 == "compaction_failed" })
    }

    @Test func aSecondPassSummarisesFromThePreviousKeptBoundary() async throws {
        let (engine, provider) = makeEngine([.events(FakeModelProvider.text("a")), .events(FakeModelProvider.text("b", usage: Self.big)),
                                             Self.summary("S1"), .events(FakeModelProvider.text("c", usage: Self.big)),
                                             Self.summary("S2"), .events(FakeModelProvider.text("d"))]) {
            $0.contextWindowTokens = 1_000; $0.compaction = Self.options()
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        for p in ["one", "two", "three", "four"] { try await engine.send(p); _ = await collector.untilResult() }

        // The second summary reads the first summary and the messages the first pass kept, not only what came after it.
        let second = provider.requests[4].messages[0].text
        #expect(second.contains("PREVIOUS SUMMARY: [compacted: 2 messages]\nS1"))
        #expect(second.contains("USER: three")); #expect(second.contains("ASSISTANT: c"))
        #expect(!second.contains("USER: one"))
        #expect(provider.requests[5].messages.map(\.text) == ["one", "a", "[compacted: 3 messages]\nS2", "four"])
        let history = await engine.testHistory()
        #expect(history.keptBoundary == 3); #expect(history.compactions == 2)
        #expect(collector.all.systems.filter { $0.0 == "compaction" }.count == 2)
    }

    @Test func aPassKeepsAToolPairWholeInTheHistory() async throws {
        let (engine, provider) = makeEngine([
            .events(FakeModelProvider.text("a")),
            .events(FakeModelProvider.toolCalls([("t1", "mcp__kyberna__upper", ["text": "x"])])), .events(FakeModelProvider.text("b", usage: Self.big)),
            Self.summary("S1"), .events(FakeModelProvider.text("c")),
        ]) { $0.contextWindowTokens = 1_000; $0.compaction = Self.options() }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        for p in ["one", "two", "three"] { try await engine.send(p); _ = await collector.untilResult() }
        // Before: u1 a u2 a(tool_use) u(result) b u3. The middle is u2 through b; the pair went whole into the summary.
        let summaryText = provider.requests[3].messages[0].text
        #expect(summaryText.contains("[called mcp__kyberna__upper")); #expect(summaryText.contains("[tool result: X]"))
        let after = provider.requests[4].messages
        #expect(after.map(\.text) == ["one", "a", "[compacted: 4 messages]\nS1", "three"])
        for m in after { #expect(m.toolUseIds.isEmpty); #expect(m.toolResultIds.isEmpty) }
    }

    @Test func aFailedSummaryLeavesTheHistoryAndReportsOnce() async throws {
        struct Boom: Error {}
        let (engine, provider) = makeEngine([.events(FakeModelProvider.text("a")), .events(FakeModelProvider.text("b", usage: Self.big)),
                                             .failure(Boom()), .events(FakeModelProvider.text("c", usage: Self.big)),
                                             .failure(Boom()), .events(FakeModelProvider.text("d"))]) {
            $0.contextWindowTokens = 1_000; $0.compaction = Self.options()
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        for p in ["one", "two", "three", "four"] { try await engine.send(p); _ = await collector.untilResult() }
        #expect(collector.all.systems.filter { $0.0 == "compaction_failed" }.count == 1)
        #expect(!collector.all.systems.contains { $0.0 == "compaction" })
        #expect(provider.requests[5].messages.map(\.text) == ["one", "a", "two", "b", "three", "c", "four"])
        #expect(collector.all.result?.subtype == "success")
    }

    @Test func aPassUsesTheSummaryModelWhenSet() async throws {
        let (engine, provider) = makeEngine([.events(FakeModelProvider.text("a")), .events(FakeModelProvider.text("b", usage: Self.big)),
                                             Self.summary("S1"), .events(FakeModelProvider.text("c"))]) {
            $0.contextWindowTokens = 1_000; $0.compaction = Self.options { $0.summaryModel = "small-model" }
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        for p in ["one", "two", "three"] { try await engine.send(p); _ = await collector.untilResult() }
        #expect(provider.requests[2].model == "small-model"); #expect(provider.requests[3].model == "fake-model")
    }

    // MARK: The spill

    @Test func oversizedToolOutputGoesToAFileAndTheHistoryKeepsTheHead() async throws {
        let directory = NSTemporaryDirectory() + "compaction-spill-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let long = try! SwiftTool(name: "long", description: "Long output.", inputSchema: ["type": "object", "properties": [:]],
                                  annotations: ToolAnnotations(readOnlyHint: true)) { _ in String(repeating: "L", count: 25_000) }
        let (engine, provider) = makeEngine([.events(FakeModelProvider.toolCalls([("t-1", "mcp__kyberna__long", [:])])), .events(FakeModelProvider.text("done"))],
                                            tools: [long]) {
            $0.compaction = Self.options { $0.spillDirectory = directory }
        }
        let collector = MessageCollector(engine)
        try await engine.start(); _ = await collector.next()
        try await engine.send("go"); let turn = await collector.untilResult()

        let path = directory + "/t-1.txt"
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.size] as? Int) == 25_000)

        let recorded = provider.requests[1].messages.last!.content[0].resultTextValue
        #expect(recorded.hasPrefix(String(repeating: "L", count: 2_000) + "\n[output truncated: 25000 characters"))
        #expect(recorded.contains(path)); #expect(recorded.contains("25000 bytes")); #expect(recorded.count < 2_400)
        let shown = turn.users.first!.content[0]
        if case .toolResult(_, let content, _) = shown { #expect(Compactor.flatten(content).contains(path)) } else { Issue.record("no tool result row") }
    }

    @Test func outputUnderTheLimitAndAFailedWriteAreLeftAlone() {
        let outcome = ToolOutcome(call: ToolCall(id: "t/2", name: "x", input: [:]), result: .text(String(repeating: "s", count: 30)))
        #expect(Compactor.spill(outcome, maxChars: 100, headChars: 10, directory: "/nonexistent-root/x") == outcome)
        let long = ToolOutcome(call: ToolCall(id: "t/2", name: "x", input: [:]), result: .text(String(repeating: "s", count: 300)))
        #expect(Compactor.spill(long, maxChars: 100, headChars: 10, directory: "/nonexistent-root/x") == long)
        let directory = NSTemporaryDirectory() + "compaction-spill-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let spilled = Compactor.spill(long, maxChars: 100, headChars: 10, directory: directory)
        #expect(FileManager.default.fileExists(atPath: directory + "/t_2.txt"))   // the id's slash is not a path separator
        if case .text(let t) = spilled.result.content[0] { #expect(t.hasPrefix("ssssssssss\n[output truncated")) } else { Issue.record("no text") }
    }
}
