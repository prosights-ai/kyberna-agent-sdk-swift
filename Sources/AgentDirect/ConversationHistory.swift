import Foundation
import AgentProtocol

/// The direct engine's message log (plan 4.y: with this engine, history is Kyberna's). A value type with a
/// `safeCutIndex`, never cut mid-batch (plan 9.6): a cut lands only where the next message is a user turn that
/// carries no tool results, so no `tool_use` is separated from its `tool_result`. Append-only during a turn, which
/// the preserved-thinking rule on current models requires.
public struct ConversationHistory: Sendable, Equatable, Codable {
    public var messages: [ModelMessage]
    /// Context tokens the last response reported (`ModelUsage.contextTokens`); what compaction decides on.
    public var lastContextTokens: Int
    /// Summaries applied so far, newest last, for the transcript.
    public var compactions: Int
    /// After a compaction (`CompactionOptions`), the index of the first message kept verbatim; the compaction
    /// message sits just before it. Nil until the first pass. Pi's `firstKeptEntryId`: the next pass summarises
    /// from before this boundary, so what survived one pass is folded into the next summary.
    public var keptBoundary: Int?

    public init(messages: [ModelMessage] = [], lastContextTokens: Int = 0, compactions: Int = 0, keptBoundary: Int? = nil) {
        self.messages = messages; self.lastContextTokens = lastContextTokens; self.compactions = compactions; self.keptBoundary = keptBoundary
    }

    public mutating func append(_ message: ModelMessage) {
        // Two consecutive same-role messages merge into one, which the Messages API otherwise rejects.
        if let last = messages.last, last.role == message.role {
            messages[messages.count - 1].content += message.content
        } else { messages.append(message) }
    }

    /// `tool_use` ids in the last assistant message that have no `tool_result` yet.
    public var pendingToolUseIds: [String] {
        guard let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) else { return [] }
        let uses = messages[lastAssistant].toolUseIds
        guard !uses.isEmpty else { return [] }
        let answered = Set(messages[(lastAssistant + 1)...].flatMap(\.toolResultIds))
        return uses.filter { !answered.contains($0) }
    }

    /// Interrupt contract item 3: every pending `tool_use` gets an `is_error` result reading "Interrupted by
    /// user", so the next request is valid. Returns the ids repaired.
    @discardableResult
    public mutating func repairInterrupted() -> [String] {
        let pending = pendingToolUseIds
        guard !pending.isEmpty else { return [] }
        append(ModelMessage(role: .user, content: pending.map {
            .toolResult(toolUseId: $0, content: .array([["type": "text", "text": "Interrupted by user"]]), isError: true)
        }))
        return pending
    }

    /// Indices where the log may be cut: the message there is a user turn without tool results, and it is not the
    /// first message. Ascending.
    public var safeCutIndices: [Int] {
        messages.indices.dropFirst().filter { messages[$0].role == .user && !messages[$0].hasToolResults }
    }

    /// The largest safe cut that keeps at least `keepRecentUserTurns` user turns after it, or nil.
    public func safeCutIndex(keepingRecentUserTurns keep: Int) -> Int? {
        let cuts = safeCutIndices
        guard cuts.count > keep else { return nil }
        return cuts[cuts.count - 1 - keep]
    }

    /// Replaces everything before `index` with one leading text block on the user turn at `index`.
    public mutating func replacePrefix(before index: Int, withSummary summary: String) {
        guard messages.indices.contains(index), messages[index].role == .user else { return }
        var tail = Array(messages[index...])
        tail[0].content.insert(.text(summary), at: 0)
        messages = tail
        compactions += 1
    }
}

/// The compaction contract of 0.4.0. The engine no longer calls it: compaction is `CompactionOptions` on
/// `DirectEngineOptions.compaction` (`Compaction.swift`). Kept for source compatibility; removed at 1.0.
@available(*, deprecated, message: "The engine compacts through CompactionOptions; see Compaction.swift.")
public protocol CompactionStrategy: Sendable {
    func shouldCompact(_ history: ConversationHistory) -> Bool
    /// Returns the compacted history, or nil when nothing could be done (the loop then carries on unchanged).
    func compact(_ history: ConversationHistory, model: String, provider: any ModelProvider) async throws -> ConversationHistory?
}

/// Summarises the oldest turns with the same model when the last response's context passed `thresholdTokens`,
/// keeping the most recent `keepRecentUserTurns` user turns verbatim. A failure leaves the history as it was;
/// after `maxConsecutiveFailures` the strategy truncates without a summary (plan 9.6: degrade on failure).
/// The 0.4.0 strategy; the engine now compacts through `CompactionOptions`. Kept for source compatibility.
@available(*, deprecated, message: "The engine compacts through CompactionOptions; see Compaction.swift.")
public struct SummarizingCompaction: CompactionStrategy {
    public var thresholdTokens: Int
    public var keepRecentUserTurns: Int
    public var summaryMaxTokens: Int
    public init(thresholdTokens: Int = 150_000, keepRecentUserTurns: Int = 4, summaryMaxTokens: Int = 2_000) {
        self.thresholdTokens = thresholdTokens; self.keepRecentUserTurns = keepRecentUserTurns; self.summaryMaxTokens = summaryMaxTokens
    }

    public func shouldCompact(_ history: ConversationHistory) -> Bool { history.lastContextTokens > thresholdTokens }

    public func compact(_ history: ConversationHistory, model: String, provider: any ModelProvider) async throws -> ConversationHistory? {
        guard let cut = history.safeCutIndex(keepingRecentUserTurns: keepRecentUserTurns) else { return nil }
        let prefix = Array(history.messages[..<cut])
        let transcript = prefix.map { m in
            let text = m.content.map { block -> String in
                switch block {
                case .text(let t): return t
                case .toolUse(_, let name, let input): return "[called \(name) \(input.canonicalJSON)]"
                case .toolResult(_, let content, let isError): return "[\(isError ? "tool error" : "tool result"): \(Self.flatten(content))]"
                case .image: return "[image]"
                case .thinking, .providerNative: return ""
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n")
            return "\(m.role.rawValue.uppercased()): \(text)"
        }.joined(separator: "\n\n")
        let request = ModelRequest(
            model: model,
            system: ["You compress conversation transcripts. Write a summary that preserves every fact, decision, file path, identifier and open question a continuing assistant would need. Plain prose, no preamble."],
            messages: [.user("Summarise this transcript:\n\n" + transcript)], maxTokens: summaryMaxTokens, cachesPrefix: false)
        var summary = ""
        for try await event in provider.stream(request) { if case .textDelta(_, let t) = event { summary += t } }
        guard !summary.isEmpty else { return nil }
        var out = history
        out.replacePrefix(before: cut, withSummary: "Summary of the earlier conversation (\(prefix.count) messages compacted):\n\(summary)\n\n")
        return out
    }

    static func flatten(_ content: JSONValue) -> String {
        if let s = content.stringValue { return s }
        return (content.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }
}
