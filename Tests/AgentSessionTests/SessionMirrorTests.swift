import Testing
import Foundation
import AgentProtocol
import AgentTestKit
@testable import AgentSession

/// Engine enhancement 14 against the recorded `--session-mirror` run: batches reach the store, in order, named
/// by the transcript they came from, and a store that fails says so without failing the turn.
@Suite(.serialized) struct SessionMirrorTests {
    static var fixture: String { Fixtures.root.appendingPathComponent("cli/2.1.271/probe-session-mirror").path }

    actor Recorder: SessionStore {
        private(set) var batches: [[JSONValue]] = []
        private(set) var keys: [SessionStoreKey] = []
        func append(_ e: [JSONValue], for k: SessionStoreKey) async throws { batches.append(e); keys.append(k) }
        func load(_ k: SessionStoreKey) async throws -> [JSONValue] { batches.flatMap { $0 } }
        var entryCount: Int { batches.reduce(0) { $0 + $1.count } }
    }

    actor Failing: SessionStore {
        struct Boom: Error {}
        private(set) var attempts = 0
        func append(_ e: [JSONValue], for k: SessionStoreKey) async throws { attempts += 1; throw Boom() }
        func load(_ k: SessionStoreKey) async throws -> [JSONValue] { [] }
    }

    static func options(fake: String, store: SessionStore) -> SessionOptions {
        var o = SessionOptions(workingDirectory: "/tmp")
        o.claudePath = fake
        o.env["FAKE_CLAUDE_FIXTURE"] = fixture
        o.env["FAKE_CLAUDE_IGNORE_ARGS"] = "1"
        o.env["FAKE_CLAUDE_LENIENT"] = "1"
        o.allowedTools = []; o.systemPrompt = .append("Be terse."); o.maxTurns = 2
        o.sessionStore = store
        return o
    }

    @Test func mirroredBatchesReachTheStoreAndNeverTheConsumer() async throws {
        guard let fake = FakeCLIReplayTests.fakePath else { Issue.record("fake-claude not built"); return }
        let store = Recorder()
        let s = ClaudeSession(options: Self.options(fake: fake, store: store))
        let seen = Locked<[String]>([])
        let printer = Task {
            for await m in s.messages {
                if case .system(let sub, _) = m { seen.with { $0.append("system/" + sub) } }
                if case .result = m { seen.with { $0.append("result") } }
            }
        }
        _ = try await s.query("Reply with the single word ok.")
        await s.flushMirror()
        await printer.value
        // The recording carries five batches of transcript entries.
        #expect(await store.batches.count >= 3)
        #expect(await store.entryCount >= 10)
        // Every batch names the same transcript, parsed from the path the CLI sent.
        let keys = await Set(store.keys.map { $0.projectKey + "/" + $0.sessionId })
        #expect(keys.count == 1)
        #expect(await store.keys.first?.subpath == nil)
        // The consumer never sees a mirror frame, and the turn still completes.
        #expect(!seen.value.contains { $0.hasPrefix("system/transcript") })
        #expect(seen.value.contains("result"))
    }

    @Test func aStoreThatFailsIsRetriedAndReportedWithoutFailingTheTurn() async throws {
        guard let fake = FakeCLIReplayTests.fakePath else { Issue.record("fake-claude not built"); return }
        let store = Failing()
        var o = Self.options(fake: fake, store: store)
        o.sessionMirrorAttempts = 2
        let s = ClaudeSession(options: o)
        let errors = Locked<Int>(0)
        let printer = Task {
            for await m in s.messages { if case .system(let sub, _) = m, sub == "mirror_error" { errors.with { $0 += 1 } } }
        }
        let r = try await s.query("Reply with the single word ok.")
        await s.flushMirror()
        await printer.value
        #expect(r.subtype == "success")                    // mirroring never fails a turn
        #expect(errors.value >= 1)
        #expect(await store.attempts >= 2)                 // the batch was retried before it was reported
    }

    @Test func aStoreAndFileCheckpointingAreRefusedTogether() async throws {
        var o = SessionOptions(workingDirectory: "/tmp")
        o.sessionStore = Recorder()
        o.enableFileCheckpointing = true
        o.skipVersionCheck = true
        let s = ClaudeSession(options: o)
        await #expect(throws: SessionError.invalidOptions("a session store and file checkpointing cannot be used together")) {
            try await s.start()
        }
    }

    @Test func theMirrorFlagIsPassedOnlyWithAStore() {
        var o = SessionOptions(workingDirectory: "/tmp")
        #expect(!ClaudeSession(options: o).buildArguments().contains("--session-mirror"))
        o.sessionStore = Recorder()
        #expect(ClaudeSession(options: o).buildArguments().contains("--session-mirror"))
    }
}

/// A lock around a value, for collecting from a printer task inside a test.
final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T { lock.withLock { stored } }
    func with(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}
