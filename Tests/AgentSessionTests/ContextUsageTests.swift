import Testing
import Foundation
import AgentProtocol

struct ContextUsageTests {
    /// Shape observed from `get_context_usage` on 2.1.271 right after the initialize handshake.
    static let sample: JSONValue = [
        "categories": [
            ["name": "System prompt", "tokens": 4037, "kind": "used"],
            ["name": "System tools", "tokens": 22580, "kind": "used"],
            ["name": "System tools (deferred)", "tokens": 13395, "kind": "deferred", "isDeferred": true],
            ["name": "Memory files", "tokens": 5136, "kind": "used"],
            ["name": "Autocompact buffer", "tokens": 33000, "kind": "buffer"],
            ["name": "Free space", "tokens": 932481, "kind": "free"],
        ],
        "totalTokens": 34519, "maxTokens": 1000000, "percentage": 3, "model": "claude-fable-5-1",
        "memoryFiles": [["path": "/Users/USER/.claude/CLAUDE.md", "type": "User", "tokens": 2540]],
        "mcpTools": [], "skills": ["totalSkills": 1, "tokens": 343, "skillFrontmatter": [["name": "design", "source": "built-in", "tokens": 343]]],
        "slashCommands": ["tokens": 919], "autoCompactThreshold": 967000, "apiUsage": .null,
    ]

    @Test func parsesCategoriesAndTotals() {
        let u = ContextUsage(Self.sample)
        #expect(u.totalTokens == 34519 && u.maxTokens == 1_000_000 && u.model == "claude-fable-5-1")
        #expect(u.tokens(for: "System tools") == 22580)
        #expect(u.loadedTokens == 4037 + 22580 + 5136)
        #expect(u.categories.first { $0.isDeferred }?.tokens == 13395)
        #expect(u.memoryFiles.first?.type == "User")
        #expect(u.skills.first?.name == "design" && u.skillTokens == 343)
        #expect(u.slashCommandTokens == 919 && u.autoCompactThreshold == 967000)
    }
}
