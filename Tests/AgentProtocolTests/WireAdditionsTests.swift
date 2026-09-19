import Testing
import Foundation
@testable import AgentProtocol

/// One hand-written wire line per field added from the upstream SDK review (`docs/research/upstream-sdks-v0.2.0.md`),
/// decoded, re-encoded, and decoded again.
@Suite struct WireAdditionsTests {
    static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
    static func decode<T: Decodable>(_ type: T.Type, _ line: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(line.utf8))
    }

    // MARK: mcp_server {name, source}

    @Test func mcpServerOnPermissionRequest() throws {
        let line = """
        {"subtype":"can_use_tool","tool_name":"mcp__checker__check_syntax","input":{"path":"utils.py"},\
        "tool_use_id":"toolu_1","mcp_server":{"name":"checker","source":"sdk"}}
        """
        let request = try JSONValue(data: Data(line.utf8))
        let server = try #require(MCPServerRef.inFrame(request))
        #expect(server == MCPServerRef(name: "checker", source: "sdk"))
        #expect(try Self.roundTrip(server) == server)

        var context = PermissionContext(toolUseId: "toolu_1", suggestions: [], blockedPath: nil, decisionReason: nil,
                                        title: nil, description: nil,
                                        payload: ApprovalPayload(tool: "mcp__checker__check_syntax", input: ["path": "utils.py"]))
        #expect(context.mcpServer == nil)
        context.mcpServer = server
        #expect(context.mcpServer?.source == "sdk")
    }

    @Test func mcpServerOnHookInput() throws {
        let input = try JSONValue(data: Data("""
        {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"mcp__notes__append",\
        "tool_input":{},"mcp_server":{"name":"notes","source":"projectSettings"}}
        """.utf8))
        #expect(MCPServerRef.inFrame(input) == MCPServerRef(name: "notes", source: "projectSettings"))
    }

    @Test func mcpServerAbsentAndNameless() throws {
        #expect(MCPServerRef.inFrame(try JSONValue(data: Data("{\"subtype\":\"can_use_tool\"}".utf8))) == nil)
        #expect(MCPServerRef(wire: ["source": "sdk"]) == nil)
        #expect(MCPServerRef(wire: ["name": "notes"]) == MCPServerRef(name: "notes", source: nil))
    }

    @Test func mcpServerStatusRow() throws {
        let row = try Self.decode(MCPServerStatus.self, #"{"name":"plugin:data:hex","source":"plugin","status":"needs-auth"}"#)
        #expect(row == MCPServerStatus(name: "plugin:data:hex", status: "needs-auth", source: "plugin"))
        #expect(try Self.roundTrip(row) == row)
        let old = try Self.decode(MCPServerStatus.self, #"{"name":"checker","status":"connected"}"#)
        #expect(old.source == nil)
    }

    // MARK: result message

    @Test func startupFailureReasonAndLatencyFields() throws {
        let line = """
        {"type":"result","subtype":"success","is_error":false,"duration_ms":10,"duration_api_ms":8,"num_turns":1,\
        "session_id":"s1","startup_failure_reason":"cwd_unavailable","first_text_post_ms":120,\
        "first_text_post_wall_ms":340,"first_stream_post_queue_wait_ms":45,"first_stream_post_queued_behind":2}
        """
        let result = ResultMessage(wire: try JSONValue(data: Data(line.utf8)))
        #expect(result.startupFailureReason == .cwdUnavailable)
        #expect(result.firstTextPostMs == 120)
        #expect(result.firstTextPostWallMs == 340)
        #expect(result.firstStreamPostQueueWaitMs == 45)
        #expect(result.firstStreamPostQueuedBehind == 2)
        #expect(try Self.roundTrip(result) == result)
    }

    @Test func resultWithoutTheNewFieldsDecodes() throws {
        let result = ResultMessage(wire: try JSONValue(data: Data(
            #"{"type":"result","subtype":"success","session_id":"s1","total_cost_usd":0.5}"#.utf8)))
        #expect(result.startupFailureReason == nil)
        #expect(result.firstTextPostMs == nil && result.firstStreamPostQueuedBehind == nil)
        #expect(result.totalCostUSD == 0.5)
    }

    @Test func startupFailureReasonKeepsUnknownValues() throws {
        for raw in ["org_pin_api_key_conflict", "worktree_unverified", "bypass_root"] {
            let reason = StartupFailureReason(rawValue: raw)
            if case .unknown = reason { Issue.record("\(raw) should be a known case") }
            #expect(reason.rawValue == raw)
            #expect(try Self.roundTrip(reason) == reason)
        }
        let future = try Self.decode(StartupFailureReason.self, "\"a_reason_from_a_later_cli\"")
        #expect(future == .unknown("a_reason_from_a_later_cli"))
        #expect(try Self.roundTrip(future) == future)
    }

    // MARK: system/init

    @Test func startupTimingAndScratchpadPath() throws {
        let line = """
        {"type":"system","subtype":"init","session_id":"s1","cwd":"/tmp","model":"claude-haiku-4-5","tools":["Read"],\
        "mcp_servers":[{"name":"checker","source":"sdk","status":"connected"}],"slash_commands":["clear"],\
        "claude_code_version":"2.1.278","scratchpad_path":"/private/tmp/claude-501/k/s1/scratchpad",\
        "startup_timing":{"total_ms":412,"phases":{"mcp":180,"settings":12}}}
        """
        let info = try Self.decode(SystemInit.self, line)
        #expect(info.scratchpadPath == "/private/tmp/claude-501/k/s1/scratchpad")
        #expect(info.startupTiming?["total_ms"]?.intValue == 412)
        #expect(info.startupTiming?["phases"]?["mcp"]?.intValue == 180)
        #expect(info.mcpServers == [MCPServerStatus(name: "checker", status: "connected", source: "sdk")])
        #expect(try Self.roundTrip(info) == info)
    }

    @Test func initWithoutTheNewFieldsDecodes() throws {
        let info = try Self.decode(SystemInit.self,
            #"{"type":"system","subtype":"init","session_id":"s1","tools":[],"mcp_servers":[{"name":"a","status":"connected"}]}"#)
        #expect(info.scratchpadPath == nil && info.startupTiming == nil)
        #expect(info.mcpServers.first?.source == nil)
    }

    // MARK: usage_report

    @Test func usageReportOnAssistantMessage() throws {
        let report = try Self.decode(UsageReport.self, """
        {"session":{"total_cost_usd":1.25,"total_api_duration_ms":9000,"total_duration_ms":12000,\
        "total_lines_added":40,"total_lines_removed":7,"model_usage":{"claude-haiku-4-5":{"costUSD":1.25}}},\
        "rate_limits":[{"name":"seven_day","utilization":0.4,"severity":"none","is_active":true}]}
        """)
        #expect(report.session?.totalCostUSD == 1.25)
        #expect(report.session?.totalAPIDurationMs == 9000)
        #expect(report.session?.totalDurationMs == 12000)
        #expect(report.session?.totalLinesAdded == 40)
        #expect(report.session?.totalLinesRemoved == 7)
        #expect(report.session?.modelUsage?["claude-haiku-4-5"]?["costUSD"]?.doubleValue == 1.25)
        #expect(report.rateLimits?[0]?["severity"]?.stringValue == "none")
        #expect(try Self.roundTrip(report) == report)

        var message = AssistantMessage(content: [.text("/usage")], model: "claude-haiku-4-5")
        #expect(message.usageReport == nil)
        message.usageReport = report
        let again = try Self.roundTrip(message)
        #expect(again.usageReport == report)
        let encoded = String(data: try JSONEncoder().encode(message), encoding: .utf8) ?? ""
        #expect(encoded.contains("\"usage_report\""))
    }

    // MARK: initialize commands, pasted_content, task_notification

    @Test func builtinOnInitializeCommands() throws {
        let commands = try Self.decode([SlashCommand].self, """
        [{"name":"clear","description":"Clear the conversation","argumentHint":"","builtin":true},\
        {"name":"deep-research","description":"Deep research harness","argumentHint":""}]
        """)
        #expect(commands[0].builtin == true)
        #expect(commands[1].builtin == nil)
        #expect(try Self.roundTrip(commands) == commands)
        let fromJSON = try #require(SlashCommand(wire: try JSONValue(data: Data(#"{"name":"clear","builtin":true}"#.utf8))))
        #expect(fromJSON.builtin == true)
        #expect(SlashCommand(wire: ["description": "no name"]) == nil)
    }

    @Test func pastedContentOnUserMessage() throws {
        let message = UserMessage(uuid: "u1", content: [.text("explain this")])
            .withPastedContent([.string("a pasted paragraph"), .array([["type": "text", "text": "a pasted block"]])])
        let again = try Self.roundTrip(message)
        #expect(again == message)
        #expect(again.pastedContent?.count == 2)
        let encoded = String(data: try JSONEncoder().encode(message), encoding: .utf8) ?? ""
        #expect(encoded.contains("\"pasted_content\""))
        #expect(UserMessage(content: [.text("typed only")]).pastedContent == nil)
    }

    @Test func workerRestartOnTaskNotification() throws {
        let frame = try JSONValue(data: Data("""
        {"type":"system","subtype":"task_notification","task_id":"t1","status":"stopped",\
        "summary":"restarted","reason":"worker_restart"}
        """.utf8))
        let reason = TaskNotificationReason(rawValue: try #require(frame["reason"]?.stringValue))
        #expect(reason == .workerRestart)
        #expect(reason.rawValue == "worker_restart")
        #expect(try Self.roundTrip(reason) == reason)
        let future = try Self.decode(TaskNotificationReason.self, "\"host_shutdown\"")
        #expect(future == .unknown("host_shutdown"))
        #expect(try Self.roundTrip(future) == future)
    }
}
