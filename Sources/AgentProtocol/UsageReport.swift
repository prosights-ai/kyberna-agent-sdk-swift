import Foundation

/// The structured answer to a headless `/usage`, carried as `usage_report` on the assistant message that
/// answers it (TypeScript SDK 0.3.273, `SDKUsageReport`, `sdk.d.ts` line 5807; marked experimental there).
///
/// `rateLimits` stays open JSON on purpose: the SDK's own doc comment says the plan's usage rows arrive exactly
/// as the server's usage endpoint sent them "so a client renders them verbatim and a new meter needs no client
/// release". From 0.3.277 each row carries `severity` and `is_active`. No recorded fixture contains a
/// `usage_report`; the shape here follows the type definition cited above. The report also carries extra-usage
/// spend, whose wire key the reviewed sources do not name, so it is not modeled here.
public struct UsageReport: Sendable, Equatable, Codable {
    public struct Session: Sendable, Equatable, Codable {
        public var totalCostUSD: Double?
        public var totalAPIDurationMs: Int?
        public var totalDurationMs: Int?
        public var totalLinesAdded: Int?
        public var totalLinesRemoved: Int?
        /// Per-model rows, keyed by model id, the same shape as the result message's `modelUsage`.
        public var modelUsage: JSONValue?

        public init(totalCostUSD: Double? = nil, totalAPIDurationMs: Int? = nil, totalDurationMs: Int? = nil,
                    totalLinesAdded: Int? = nil, totalLinesRemoved: Int? = nil, modelUsage: JSONValue? = nil) {
            self.totalCostUSD = totalCostUSD; self.totalAPIDurationMs = totalAPIDurationMs; self.totalDurationMs = totalDurationMs
            self.totalLinesAdded = totalLinesAdded; self.totalLinesRemoved = totalLinesRemoved; self.modelUsage = modelUsage
        }

        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd"
            case totalAPIDurationMs = "total_api_duration_ms"
            case totalDurationMs = "total_duration_ms"
            case totalLinesAdded = "total_lines_added"
            case totalLinesRemoved = "total_lines_removed"
            case modelUsage = "model_usage"
        }
    }

    public var session: Session?
    /// The plan's usage rows as the server sent them; render verbatim.
    public var rateLimits: JSONValue?

    public init(session: Session? = nil, rateLimits: JSONValue? = nil) {
        self.session = session; self.rateLimits = rateLimits
    }

    enum CodingKeys: String, CodingKey {
        case session
        case rateLimits = "rate_limits"
    }
}
