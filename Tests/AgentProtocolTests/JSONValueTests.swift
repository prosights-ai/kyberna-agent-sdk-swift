import Foundation
import Testing
@testable import AgentProtocol

@Suite struct JSONValueTests {
    @Test func roundTripsThroughCanonicalJSON() throws {
        let v: JSONValue = ["b": 1, "a": ["x", true, .null], "n": 2.5]
        let text = v.canonicalJSON
        #expect(text == #"{"a":["x",true,null],"b":1,"n":2.5}"#)
        let back = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(back == v)
    }
    @Test func bridgesNSNumberBooleans() {
        let any: [String: Any] = ["flag": true, "count": 3]
        let v = JSONValue(any: any)
        #expect(v["flag"] == .bool(true))
        #expect(v["count"] == .number(3))
    }
    @Test func secretNeverPrints() {
        let s = Secret("sk-ant-example")
        #expect("\(s)" == "Secret(<redacted>)")
        #expect(s.withValue { $0.count } == 14)
        #expect(throws: (any Error).self) { try JSONEncoder().encode([s]) }
    }
    @Test func approvalPayloadEscapesHostileInput() {
        let p = ApprovalPayload(tool: "Bash", input: ["command": "rm -rf /\u{200B}tmp"])
        #expect(p.display.contains("\\u{200B}"))
        #expect(!p.display.contains("\u{200B}"))
        let same = ApprovalPayload(tool: "Bash", input: ["command": "rm -rf /\u{200B}tmp"])
        #expect(p.hash == same.hash)
    }
    @Test func interruptedResultIsNotAnError() {
        let r = ResultMessage(subtype: "error_during_execution", isError: true, sessionId: "s", errors: ["[ede_diagnostic] result_type=user"])
        #expect(r.wasInterrupted)
        #expect(r.errorText == nil)
    }
    @Test func authenticationFailureTexts() {
        for text in ["Not logged in · Please run /login", "Login expired · Please run /login",
                     "Failed to authenticate: OAuth session expired and could not be refreshed"] {
            #expect(ResultMessage(subtype: "success", isError: true, sessionId: "s", result: text).isAuthenticationFailure, "\(text)")
        }
        #expect(!ResultMessage(subtype: "success", isError: false, sessionId: "s", result: "Not logged in").isAuthenticationFailure)
        #expect(!ResultMessage(subtype: "success", isError: true, sessionId: "s", result: "Failed to read file").isAuthenticationFailure)
    }
}

/// Engine enhancement 9: the typed `--settings` payload.
struct SessionSettingsTests {
    @Test func emptySettingsEncodeToAnEmptyObject() {
        #expect(SessionSettings().isEmpty)
        #expect(SessionSettings().encoded == "{}")
    }

    @Test func onlyTheFieldsTheProfileSetAppear() {
        var s = SessionSettings(permissions: .init(allow: ["Read", "Glob"], deny: ["Bash"], defaultMode: "default"),
                                sandbox: .init(enabled: true, autoAllowBashIfSandboxed: true),
                                env: ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"])
        let o = s.json
        #expect(o["permissions"]?["allow"] == .array([.string("Read"), .string("Glob")]))
        #expect(o["permissions"]?["deny"] == .array([.string("Bash")]))
        #expect(o["permissions"]?["ask"] == nil)
        #expect(o["sandbox"]?["enabled"] == .bool(true))
        #expect(o["sandbox"]?["autoAllowBashIfSandboxed"] == .bool(true))
        #expect(o["sandbox"]?["allowLocalBinding"] == nil)
        #expect(o["env"]?["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == .string("1"))
        #expect(o["model"] == nil)
        // Two profiles differing in one rule differ in one place, which is the point of the type.
        var t = s; t.permissions?.deny = ["Bash", "WebFetch"]
        #expect(t != s)
        #expect(t.json["permissions"]?["deny"] == .array([.string("Bash"), .string("WebFetch")]))
        s.extra["statusLine"] = .object(["type": .string("command")])
        #expect(s.json["statusLine"]?["type"] == .string("command"))
        #expect((try? JSONSerialization.jsonObject(with: Data(s.encoded.utf8))) != nil)
    }

    @Test func settingsRoundTripAsCodable() throws {
        let s = SessionSettings(permissions: .init(allow: ["Read"], additionalDirectories: ["/tmp"]),
                                sandbox: .init(enabled: true, network: .init(allowUnixSockets: ["/x.sock"])),
                                model: "haiku", includeCoAuthoredBy: false)
        let back = try JSONDecoder().decode(SessionSettings.self, from: try JSONEncoder().encode(s))
        #expect(back == s)
    }
}
