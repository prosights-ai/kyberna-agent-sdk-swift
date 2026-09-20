import Testing
import Foundation
import AgentProtocol
import AgentSession
@testable import AgentDirect

@Suite struct ToolExecutorTests {
    func executor(_ tools: [SwiftTool], timeout: TimeInterval = 30) async -> ToolExecutor {
        let e = ToolExecutor(toolTimeout: timeout)
        await e.register(tools)
        return e
    }

    @Test func wavesGroupReadOnlyToolsAndIsolateTheRest() async {
        let e = await executor([Tools.wordCount, Tools.upper, Tools.failing])
        let calls = ["word_count", "upper", "failing", "word_count", "failing", "failing", "upper"].enumerated().map { ToolCall(id: "\($0)", name: $1, input: [:]) }
        #expect(await e.waves(calls) == [[0, 1], [2], [3], [4], [5], [6]])
    }

    @Test func failuresUnknownToolsAndBadInputNeverThrow() async {
        let e = await executor([Tools.failing, Tools.upper])
        let out = await e.run([ToolCall(id: "1", name: "failing", input: [:]), ToolCall(id: "2", name: "nope", input: [:]),
                               ToolCall(id: "3", name: "upper", input: .string("not an object")), ToolCall(id: "4", name: "upper", input: ["text": "ok"])])
        #expect(out.map(\.call.id) == ["1", "2", "3", "4"])
        #expect(out[0].result.isError); #expect(out[0].result.content.first == .text("Tool 'failing' failed: Boom()"))
        #expect(out[1].result.isError); #expect(out[1].result.content.first == .text("Unknown tool 'nope'. Available: failing, upper"))
        #expect(out[2].result.isError)
        #expect(out[3].result == .text("OK"))
    }

    @Test func timeoutBoundsAToolThatNeverChecksCancellation() async {
        let e = await executor([Tools.slow], timeout: 0.3)
        let out = await e.run([ToolCall(id: "1", name: "slow", input: [:])])
        #expect(out[0].timedOut); #expect(out[0].result.isError)
        #expect(out[0].result.content.first == .text("Tool 'slow' timed out after 0 s"))
        #expect(out[0].duration < 2)
    }

    @Test func resultsAreCappedWithAMarker() async throws {
        let big = try SwiftTool(name: "big", description: "", inputSchema: ["type": "object"], annotations: ToolAnnotations(maxResultSizeChars: 10)) { _ in String(repeating: "x", count: 100) }
        let e = await executor([big])
        let out = await e.run([ToolCall(id: "1", name: "big", input: [:])])
        #expect(out[0].result.content == [.text("xxxxxxxxxx"), .text("\n[output truncated at 10 characters]")])
    }

    @Test func gateDeniesBeforeRunningAndCanEndTheTurn() async {
        let e = await executor([Tools.upper])
        await e.setGate { call in call.id == "2" ? .deny(reason: "deferred to the person", endsTurn: true) : .allow(input: nil) }
        let out = await e.run([ToolCall(id: "1", name: "upper", input: ["text": "a"]), ToolCall(id: "2", name: "upper", input: ["text": "b"])])
        #expect(out[0].result == .text("A")); #expect(out[0].endsTurn)
        #expect(out[1].wasDenied); #expect(out[1].result.isError); #expect(out[1].endsTurn)
        #expect(out[1].block == .toolResult(toolUseId: "2", content: .array([["type": "text", "text": "Permission denied: deferred to the person"]]), isError: true))
    }

    @Test func cancellationMarksUnfinishedCallsInterruptedInOrder() async throws {
        let e = await executor([Tools.slow, Tools.upper], timeout: 30)
        let task = Task { await e.run([ToolCall(id: "1", name: "upper", input: ["text": "a"]), ToolCall(id: "2", name: "slow", input: [:]), ToolCall(id: "3", name: "upper", input: ["text": "c"])]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let out = await task.value
        #expect(out.map(\.call.id) == ["1", "2", "3"])
        #expect(out[0].result == .text("A"))
        #expect(out[1].wasInterrupted); #expect(out[1].result.content.first == .text("Interrupted by user"))
        #expect(out[2].wasInterrupted)
    }

    @Test func toolContextRunsRegisteredProcessesWithCapsAndTimeouts() async throws {
        let registry = ProcessRegistry()
        let ctx = ToolContext(registry: registry, toolUseId: "t", maxOutputBytes: 16)
        let ok = try await ctx.run(command: "printf 'hello'; printf 'err' >&2; exit 3")
        #expect(ok.status == 3); #expect(ok.stdout == "hello"); #expect(ok.stderr == "err"); #expect(!ok.truncated)
        let capped = try await ctx.run(command: "printf '%0100d' 0")
        #expect(capped.stdout.count == 16); #expect(capped.truncated)
        let timed = try await ctx.run(command: "sleep 20", timeout: 0.3)
        #expect(timed.timedOut); #expect(timed.signal == SIGTERM || timed.status == -1)
        #expect(registry.registeredPIDs.isEmpty)
        let env = try await ctx.run("/usr/bin/env", [])
        #expect(env.stdout.contains("PATH=")); #expect(!env.stdout.contains("HOME="))
    }

    @Test func terminateAllEndsProcessGroupsWithinTheGrace() async throws {
        let registry = ProcessRegistry()
        let ctx = ToolContext(registry: registry, toolUseId: "t")
        let running = Task { try await ctx.run(command: "sh -c 'sleep 40' & sleep 40", timeout: 60) }
        for _ in 0..<100 where registry.registeredPIDs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let pids = registry.registeredPIDs
        #expect(pids.count == 1)
        let killed = await registry.terminateAll(grace: 1)
        let out = try await running.value
        #expect(out.signal == SIGTERM || killed == pids)
        try await Task.sleep(for: .milliseconds(100))
        #expect(pids.allSatisfy { kill($0, 0) != 0 })
    }
}

@Suite struct ConversationHistoryTests {
    @Test func repairAddsErrorResultsForPendingToolUses() {
        var h = ConversationHistory(messages: [
            .user("go"),
            ModelMessage(role: .assistant, content: [.toolUse(id: "a", name: "x", input: [:]), .toolUse(id: "b", name: "y", input: [:])]),
        ])
        #expect(h.pendingToolUseIds == ["a", "b"])
        #expect(h.repairInterrupted() == ["a", "b"])
        #expect(h.pendingToolUseIds.isEmpty)
        #expect(h.messages.count == 3)
        #expect(h.messages[2] == ModelMessage(role: .user, content: ["a", "b"].map { .toolResult(toolUseId: $0, content: .array([["type": "text", "text": "Interrupted by user"]]), isError: true) }))
        #expect(h.repairInterrupted().isEmpty)
        // A partial repair keeps the answered one.
        var partial = ConversationHistory(messages: [.user("go"), ModelMessage(role: .assistant, content: [.toolUse(id: "a", name: "x", input: [:]), .toolUse(id: "b", name: "y", input: [:])]),
                                                     ModelMessage(role: .user, content: [.toolResult(toolUseId: "a", content: "ok", isError: false)])])
        #expect(partial.repairInterrupted() == ["b"])
        #expect(partial.messages.count == 3)   // merged into the existing user message
        #expect(partial.messages[2].toolResultIds == ["a", "b"])
    }

    @Test func safeCutsNeverSeparateAToolUseFromItsResult() {
        let h = ConversationHistory(messages: [
            .user("1"), .assistant("a"),
            .user("2"), ModelMessage(role: .assistant, content: [.toolUse(id: "t", name: "x", input: [:])]),
            ModelMessage(role: .user, content: [.toolResult(toolUseId: "t", content: "r", isError: false)]), .assistant("b"),
            .user("3"), .assistant("c"),
        ])
        #expect(h.safeCutIndices == [2, 6])
        #expect(h.safeCutIndex(keepingRecentUserTurns: 1) == 2)
        #expect(h.safeCutIndex(keepingRecentUserTurns: 2) == nil)
        var cut = h
        cut.replacePrefix(before: 2, withSummary: "SUM ")
        #expect(cut.messages.count == 6); #expect(cut.messages[0].text == "SUM 2"); #expect(cut.compactions == 1)
    }

    @Test func consecutiveSameRoleMessagesMerge() {
        var h = ConversationHistory()
        h.append(.user("a")); h.append(.user("b"))
        #expect(h.messages.count == 1); #expect(h.messages[0].text == "ab")
    }
}
