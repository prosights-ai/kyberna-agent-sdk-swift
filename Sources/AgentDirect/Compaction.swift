import Foundation
import AgentProtocol

/// Compaction for the engines that have none of their own (the direct API, local models, the OpenAI-compatible
/// servers; Claude Code compacts itself). Set on `DirectEngineOptions.compaction`; nil leaves the history alone.
///
/// The rules are adapted from three MIT-licensed harnesses (THIRD-PARTY-NOTICES.md at the repository root):
/// Pi's `CompactionEntry`/`firstKeptEntryId` (`packages/coding-agent/src/core/session-manager.ts`,
/// `docs/compaction.md`): the cut lands at a message boundary chosen from the newest message backwards until
/// `keepRecentTokens` is kept, never between a `tool_use` and its `tool_result`, and a repeated compaction
/// summarises from the previous kept boundary, so the messages that survived the earlier pass and its summary are
/// folded into the next one rather than left behind. OpenHands' `LLMSummarizingCondenser`
/// (`openhands-sdk/openhands/sdk/context/condenser/llm_summarizing_condenser.py`): `keep_first` messages are never
/// summarised, `minimum_progress` is the fraction a pass must remove, and when a pass falls short the kept tail is
/// scaled by 0.8 and the cut retried, at most five times, as its hard reset scales its inputs. OpenCode's
/// "Managed Tool Output File" (`CONTEXT.md`): tool output over `maxToolResultChars` is written to a side file and
/// the history keeps a bounded head plus the file's path and size, so a file tool can read the rest.
public struct CompactionOptions: Sendable, Equatable {
    /// Estimated context tokens above which a pass runs before the next model call; nil is 70 percent of
    /// `DirectEngineOptions.contextWindowTokens`.
    public var triggerTokens: Int?
    /// Messages at the start of the history that are never summarised (the opening request and its first answer).
    public var keepFirst = 2
    /// Estimated tokens of the newest messages kept verbatim; nil is 25 percent of the window.
    public var keepRecentTokens: Int?
    /// The fraction of the history's tokens a pass must remove; below it the kept tail shrinks by 0.8 and the cut
    /// is chosen again, at most `maxProgressRetries` times, and the last attempt applies.
    public var minimumProgress = 0.1
    public var maxProgressRetries = 5
    /// The model that writes the summary, on the same provider; nil is the conversation's model.
    public var summaryModel: String?
    /// Output cap for the summary call.
    public var summaryMaxTokens = 2_000
    /// Tool output longer than this (text characters) goes to a side file; the history keeps `spillHeadChars`.
    public var maxToolResultChars = 20_000
    public var spillHeadChars = 2_000
    /// Where spilled output is written, created on first use; nil is `.kyberna/tool-output/` under the engine's
    /// working directory (the temporary directory when the engine has none).
    public var spillDirectory: String?

    public init() {}

    /// The system prompt of the summary call.
    public static let summaryPrompt = "Summarise the conversation so far for a model that will continue it: what was asked, what was done, decisions, open items, file paths and identifiers; no tool call syntax"

    func resolvedTrigger(window: Int) -> Int { triggerTokens ?? window * 7 / 10 }
    func resolvedKeepRecent(window: Int) -> Int { keepRecentTokens ?? window / 4 }
    func resolvedSpillDirectory(workingDirectory: String?) -> String {
        if let spillDirectory { return spillDirectory }
        let base = workingDirectory ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent(".kyberna/tool-output")
    }
}

/// The pure parts of a compaction pass, on `ConversationHistory` values; `TurnRunner` runs the summary call and
/// the spill writes around them.
enum Compactor {
    static let markerPrefix = "[compacted: "
    static let charactersPerToken = 4
    static let imageTokens = 1_600

    /// Four characters per token over text, tool input and tool result text; a fixed figure per image.
    static func estimatedTokens(_ message: ModelMessage) -> Int {
        var chars = 0, images = 0
        for block in message.content {
            switch block {
            case .text(let t): chars += t.utf8.count
            case .toolUse(_, let name, let input): chars += name.utf8.count + input.canonicalJSON.utf8.count
            case .toolResult(_, let content, _): chars += flatten(content).utf8.count
            case .thinking(let t, _): chars += t.utf8.count
            case .providerNative(let raw): chars += raw.canonicalJSON.utf8.count
            case .image: images += 1
            }
        }
        return chars / charactersPerToken + images * imageTokens
    }

    static func estimatedTokens<S: Sequence>(_ messages: S) -> Int where S.Element == ModelMessage {
        messages.reduce(0) { $0 + estimatedTokens($1) }
    }

    /// The provider's figure from the last call when it has one, else the character estimate.
    static func estimatedTokens(_ history: ConversationHistory) -> Int {
        history.lastContextTokens > 0 ? history.lastContextTokens : estimatedTokens(history.messages)
    }

    /// Where the never-summarised head ends: `keepFirst`, moved past any message carrying tool results so a
    /// `tool_use` in the head is never parted from its result (OpenHands' `find_next(keep_first)` on atomic
    /// boundaries). It stops at the previous pass's compaction message, which then leads the middle.
    static func headEnd(_ history: ConversationHistory, keepFirst: Int) -> Int {
        let messages = history.messages
        var i = min(max(0, keepFirst), messages.count)
        while i < messages.count, messages[i].hasToolResults { i += 1 }
        return i
    }

    /// The index of the first kept message: the newest safe cut (a user message without tool results, after the
    /// head) that keeps at least `keepRecentTokens` after it, else the oldest safe cut after the head, else nil
    /// when there is nothing to summarise. A cut there never separates a `tool_use` from its `tool_result`, since
    /// every result sits in the user message right after its call.
    static func cut(_ history: ConversationHistory, headEnd: Int, keepRecentTokens: Int) -> Int? {
        let messages = history.messages
        let candidates = history.safeCutIndices.filter { $0 > headEnd }
        guard let oldest = candidates.first else { return nil }
        var kept = 0
        for i in stride(from: messages.count - 1, through: oldest, by: -1) {
            kept += estimatedTokens(messages[i])
            if kept >= keepRecentTokens, candidates.contains(i) { return i }
        }
        return oldest
    }

    /// One pass's shape before the summary call.
    struct Plan: Equatable {
        var headEnd: Int
        var cut: Int
        var tokensBefore: Int
        /// Estimated tokens of the middle, `messages[headEnd..<cut]`.
        var removed: Int
        /// Cuts tried before this one was accepted or the retries ran out.
        var retries: Int
        var middle: Range<Int> { headEnd..<cut }
    }

    /// Nil when the history is under the trigger or has nothing to summarise. Otherwise the cut, retried with the
    /// kept tail scaled by 0.8 while the pass would remove less than `minimumProgress` of the tokens (OpenHands'
    /// hard-reset scaling), up to `maxProgressRetries` times; the last attempt stands.
    static func plan(_ history: ConversationHistory, options: CompactionOptions, window: Int) -> Plan? {
        let tokensBefore = estimatedTokens(history)
        guard tokensBefore > options.resolvedTrigger(window: window) else { return nil }
        let headEnd = headEnd(history, keepFirst: max(0, options.keepFirst))
        var keepRecent = options.resolvedKeepRecent(window: window)
        var plan: Plan?
        for attempt in 0...max(0, options.maxProgressRetries) {
            guard let cut = cut(history, headEnd: headEnd, keepRecentTokens: keepRecent) else { break }
            let removed = estimatedTokens(history.messages[headEnd..<cut])
            plan = Plan(headEnd: headEnd, cut: cut, tokensBefore: tokensBefore, removed: removed, retries: attempt)
            if Double(removed) >= Double(tokensBefore) * options.minimumProgress { break }
            keepRecent = Int(Double(keepRecent) * 0.8)
        }
        return plan
    }

    /// The summarised span as prose the summary model reads; an earlier compaction message is labelled as such.
    static func transcript(_ messages: ArraySlice<ModelMessage>) -> String {
        messages.map { m in
            let text = m.content.compactMap { block -> String? in
                switch block {
                case .text(let t): return t
                case .toolUse(_, let name, let input): return "[called \(name) with \(input.canonicalJSON)]"
                case .toolResult(_, let content, let isError): return "[\(isError ? "tool error" : "tool result"): \(flatten(content))]"
                case .image: return "[image]"
                case .thinking, .providerNative: return nil
                }
            }.joined(separator: "\n")
            let label = isCompaction(m) ? "PREVIOUS SUMMARY" : m.role.rawValue.uppercased()
            return "\(label): \(text)"
        }.joined(separator: "\n\n")
    }

    static func isCompaction(_ message: ModelMessage) -> Bool {
        guard message.role == .assistant, case .text(let t)? = message.content.first else { return false }
        return t.hasPrefix(markerPrefix)
    }

    /// The first `keepFirst` messages, one assistant message carrying the marker and the summary, then the kept
    /// tail from `cut`. The summary stands as its own message even after an assistant message: the Messages API
    /// combines consecutive same-role turns, and keeping it separate is what lets the next pass find it at
    /// `keptBoundary - 1` and fold it into the next summary (Pi's boundary rule).
    static func apply(summary: String, to history: ConversationHistory, plan: Plan) -> ConversationHistory {
        let messages = history.messages
        let head = Array(messages[..<plan.headEnd])
        let marker = ModelMessage(role: .assistant, content: [.text("\(markerPrefix)\(plan.middle.count) messages]\n\(summary)")])
        return ConversationHistory(messages: head + [marker] + Array(messages[plan.cut...]), lastContextTokens: 0,
                                   compactions: history.compactions + 1, keptBoundary: head.count + 1)
    }

    /// Spills text past `maxChars` to `<directory>/<toolUseId>.txt` and returns the outcome with the head and a
    /// line naming the file; the outcome unchanged when the write fails (a failed spill never fails the tool).
    static func spill(_ outcome: ToolOutcome, maxChars: Int, headChars: Int, directory: String) -> ToolOutcome {
        let text = outcome.result.content.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
        guard text.count > maxChars else { return outcome }
        let name = outcome.call.id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        let path = (directory as NSString).appendingPathComponent("\(String(name)).txt")
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { return outcome }
        let head = String(text.prefix(headChars))
        let note = "\n[output truncated: \(text.count) characters in total; the full output is in \(path) (\(text.utf8.count) bytes). Read that file for the rest.]"
        var out = outcome
        out.result.content = outcome.result.content.filter { if case .text = $0 { return false }; return true }
        out.result.content.insert(.text(head + note), at: 0)
        return out
    }

    static func flatten(_ content: JSONValue) -> String {
        if let s = content.stringValue { return s }
        return (content.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }
}
