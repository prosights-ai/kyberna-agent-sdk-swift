import Testing
import Foundation
@testable import AgentProtocol

/// `Message` on the wire and in stores (gateway backlog 9): every field named, nothing positional, and the
/// `_0` spelling that 0.1.x wrote for the four single-value cases still decodes.
@Suite struct MessageCodingTests {
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    static func text(_ m: Message) throws -> String { String(decoding: try encoder.encode(m), as: UTF8.self) }
    static func decode(_ s: String) throws -> Message { try JSONDecoder().decode(Message.self, from: Data(s.utf8)) }

    static let samples: [Message] = [
        .initialized(sessionId: "s", model: "haiku", tools: ["Read"], data: .object(["k": .string("v")])),
        .assistant(AssistantMessage(uuid: "u1", content: [.text("hi")], model: "haiku")),
        .user(UserMessage(uuid: "u2", content: [.text("hello")])),
        .streamEvent(event: .object([:]), parentToolUseId: nil),
        .taskStarted(taskId: "t", description: "d", taskType: nil),
        .taskProgress(taskId: "t", description: "d", lastToolName: "Read"),
        .taskNotification(taskId: "t", status: "done", summary: "s", reason: .workerRestart),
        .taskNotification(taskId: "t", status: "done", summary: "s"),
        .taskUpdated(taskId: "t", status: nil),
        .hookEvent(subtype: "hook_started", hookEventName: "PreToolUse", data: .null),
        .rateLimit(info: .object(["status": .string("allowed")])),
        .conversationReset(newConversationId: "n"),
        .system(subtype: "x", data: .null),
        .permissionRequest(ApprovalPayload(tool: "Bash", input: .object(["command": .string("ls")]), toolUseId: "tu")),
        .permissionDenied(tool: "Bash", toolUseId: nil, reasonType: "rule", reason: "no"),
        .steeringQueued(text: "later"),
        .result(ResultMessage(subtype: "success", sessionId: "s")),
        .exited(status: 0, signal: nil),
    ]

    @Test func everyCaseRoundTripsWithoutPositionalKeys() throws {
        for m in Self.samples {
            let t = try Self.text(m)
            #expect(!t.contains("\"_0\""), "positional key in \(t)")
            #expect(try Self.decode(t) == m)
        }
    }

    @Test func singleValueCasesUseNamedKeys() throws {
        #expect(try Self.text(.user(UserMessage(content: [.text("x")]))).hasPrefix("{\"user\":{\"message\":"))
        #expect(try Self.text(.result(ResultMessage(subtype: "success", sessionId: "s"))).hasPrefix("{\"result\":{\"result\":"))
        #expect(try Self.text(.permissionRequest(ApprovalPayload(tool: "Bash", input: .null))).hasPrefix("{\"permissionRequest\":{\"payload\":"))
    }

    @Test func legacyPositionalSpellingStillDecodes() throws {
        let legacy = [
            (#"{"user":{"_0":{"content":[{"text":{"_0":"hello"}}],"uuid":"u2"}}}"#, Message.user(UserMessage(uuid: "u2", content: [.text("hello")]))),
            (#"{"result":{"_0":{"subtype":"success","sessionId":"s","isError":false,"durationMs":0,"durationApiMs":0,"numTurns":0}}}"#,
             Message.result(ResultMessage(subtype: "success", sessionId: "s"))),
        ]
        for (line, expected) in legacy { #expect(try Self.decode(line) == expected) }
        // A 0.1.x assistant row: decoded through the same path, whatever its content.
        let a = try Self.decode(#"{"assistant":{"_0":{"content":[],"model":"haiku","uuid":"u"}}}"#)
        if case .assistant(let m) = a { #expect(m.model == "haiku") } else { Issue.record("not an assistant message") }
        let p = try Self.decode(try Self.text(.permissionRequest(ApprovalPayload(tool: "Bash", input: .null))).replacingOccurrences(of: "\"payload\":", with: "\"_0\":"))
        if case .permissionRequest(let payload) = p { #expect(payload.tool == "Bash") } else { Issue.record("not a permission request") }
    }

    @Test func contentBlocksUseNamedKeysAndAcceptLegacy() throws {
        let e = String(decoding: try Self.encoder.encode([ContentBlock.text("a"), .thinking("b")]), as: UTF8.self)
        #expect(e == #"[{"text":{"text":"a"}},{"thinking":{"thinking":"b"}}]"#)
        let legacy = try JSONDecoder().decode([ContentBlock].self, from: Data(#"[{"text":{"_0":"a"}},{"thinking":{"_0":"b"}}]"#.utf8))
        #expect(legacy == [.text("a"), .thinking("b")])
    }

    @Test func twoCaseKeysAreRejected() {
        #expect(throws: DecodingError.self) { try Self.decode(#"{"steeringQueued":{"text":"a"},"system":{"subtype":"x","data":null}}"#) }
    }
}
