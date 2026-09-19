import Testing
import Foundation
import AgentTestKit
@testable import AgentProtocol

/// Every recorded stdout line of every fixture set, through the wire types: a set recorded before a field
/// existed must still decode, and 2.1.278's `system`/`init` must carry `scratchpad_path`.
@Suite struct FixtureDecodeTests {
    static let versions = ["2.1.270", "2.1.271", "2.1.272", "2.1.273", "2.1.278"]

    static func scenarios(_ version: String) throws -> [URL] {
        let dir = Fixtures.cli(version)
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("stdout.jsonl").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func lines(_ scenario: URL) throws -> [String] {
        let text = try String(contentsOf: scenario.appendingPathComponent("stdout.jsonl"), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test(arguments: versions)
    func everyLineDecodes(_ version: String) throws {
        let scenarios = try Self.scenarios(version)
        #expect(!scenarios.isEmpty)
        var inits = 0, results = 0
        for scenario in scenarios {
            for (n, line) in try Self.lines(scenario).enumerated() {
                let data = Data(line.utf8)
                let json: JSONValue
                do { json = try JSONValue(data: data) } catch {
                    Issue.record("\(version)/\(scenario.lastPathComponent) line \(n + 1) is not JSON: \(error)")
                    continue
                }
                switch json["type"]?.stringValue {
                case "system" where json["subtype"]?.stringValue == "init":
                    let info = try JSONDecoder().decode(SystemInit.self, from: data)
                    #expect(!info.sessionId.isEmpty)
                    #expect(!info.tools.isEmpty)
                    #expect(info.claudeCodeVersion == version)
                    inits += 1
                case "result":
                    let result = ResultMessage(wire: json)
                    #expect(!result.subtype.isEmpty)
                    #expect(!result.sessionId.isEmpty)
                    #expect(result.startupFailureReason == nil)   // local sessions: the field is remote-only
                    #expect(result.firstTextPostMs == nil)
                    results += 1
                case "control_request":
                    let request = json["request"] ?? .null
                    // Absent in every recorded set; the accessor must tolerate that, not fail.
                    #expect(MCPServerRef.inFrame(request) == nil)
                default: break
                }
            }
        }
        #expect(inits > 0 && results > 0)
    }

    @Test func scratchpadPathArrivedIn2_1_278() throws {
        for scenario in try Self.scenarios("2.1.278") {
            let line = try #require(try Self.lines(scenario).first { $0.contains("\"subtype\":\"init\"") })
            let info = try JSONDecoder().decode(SystemInit.self, from: Data(line.utf8))
            let path = try #require(info.scratchpadPath, "2.1.278 \(scenario.lastPathComponent) init has no scratchpad_path")
            #expect(path.hasSuffix("/scratchpad"))
            #expect(info.startupTiming == nil)   // only with CLAUDE_CODE_EMIT_STARTUP_TIMING=1
        }
        for version in ["2.1.270", "2.1.271", "2.1.272", "2.1.273"] {
            for scenario in try Self.scenarios(version) {
                let line = try #require(try Self.lines(scenario).first { $0.contains("\"subtype\":\"init\"") })
                let info = try JSONDecoder().decode(SystemInit.self, from: Data(line.utf8))
                #expect(info.scratchpadPath == nil)
            }
        }
    }

    @Test func mcpServerSourceArrivedIn2_1_278() throws {
        let line = try #require(try Self.lines(Fixtures.scenario("mcp-tool-call", version: "2.1.278"))
            .first { $0.contains("\"subtype\":\"init\"") })
        let info = try JSONDecoder().decode(SystemInit.self, from: Data(line.utf8))
        let sdkServer = try #require(info.mcpServers.first { $0.name == "checker" })
        #expect(sdkServer.source == "sdk")
        #expect(sdkServer.status == "connected")
        #expect(sdkServer.reference == MCPServerRef(name: "checker", source: "sdk"))

        let old = try #require(try Self.lines(Fixtures.scenario("mcp-tool-call", version: "2.1.273"))
            .first { $0.contains("\"subtype\":\"init\"") })
        let before = try JSONDecoder().decode(SystemInit.self, from: Data(old.utf8))
        #expect(before.mcpServers.first { $0.name == "checker" }?.source == nil)
    }
}
