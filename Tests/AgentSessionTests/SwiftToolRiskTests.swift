import Testing
import Foundation
import AgentProtocol
@testable import AgentSession

/// `SwiftTool.riskOfCall` (Kyberna release plan v0.2.13 Phase 2 step 2): a tool's baseline risk lives with its
/// definition, is optional, reads the call's arguments, and stays off the wire.
@Suite struct SwiftToolRiskTests {
    static let schema: JSONValue = ["type": "object", "properties": ["path": ["type": "string"]]]

    @Test func aToolWithoutAJudgmentStatesNoBaseline() throws {
        let tool = try SwiftTool(name: "plain", description: "d", inputSchema: Self.schema) { _ in "x" }
        #expect(tool.riskOfCall == nil)
        #expect(tool.risk(of: ["path": "/x"]) == nil)
    }

    @Test func aFixedJudgmentReadsEveryCallTheSame() throws {
        let tool = try SwiftTool(name: "reader", description: "d", inputSchema: Self.schema, riskOfCall: SwiftTool.fixedRisk(.low)) { _ in "x" }
        #expect(tool.risk(of: [:]) == .low)
        #expect(tool.risk(of: ["path": "/etc/shadow"]) == .low)
    }

    @Test func aJudgmentReadsTheArgumentsAndMayDecline() throws {
        let tool = try SwiftTool(name: "writer", description: "d", inputSchema: Self.schema, riskOfCall: { input in
            guard let path = input["path"]?.stringValue else { return nil }
            return path.hasPrefix("/etc/") ? .high : .medium
        }) { _ in .text("x") }
        #expect(tool.risk(of: ["path": "/etc/hosts"]) == .high)
        #expect(tool.risk(of: ["path": "/tmp/x"]) == .medium)
        #expect(tool.risk(of: [:]) == nil, "no path: the tool has no opinion and the host's tables decide")
    }

    @Test func theJudgmentIsNotOnTheWireAndTheGradeIsCodable() throws {
        let tool = try SwiftTool(name: "reader", description: "d", inputSchema: Self.schema, riskOfCall: SwiftTool.fixedRisk(.high)) { _ in "x" }
        guard case .object(let wire) = tool.wire else { Issue.record("wire is not an object"); return }
        #expect(Set(wire.keys) == ["name", "description", "inputSchema"])
        #expect(ToolCallRisk.allCases.map(\.rawValue) == ["unknown", "low", "medium", "high"])
        let data = try JSONEncoder().encode(ToolCallRisk.medium)
        #expect(String(decoding: data, as: UTF8.self) == "\"medium\"")
        #expect(try JSONDecoder().decode(ToolCallRisk.self, from: data) == .medium)
    }
}
