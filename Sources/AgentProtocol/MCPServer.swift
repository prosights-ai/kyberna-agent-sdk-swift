import Foundation

/// Where an MCP server came from, carried beside its name so a host keys trust on provenance rather than on the
/// server name or the `mcp__<server>__` tool prefix (TypeScript SDK 0.3.274, `sdk.d.ts` lines 235-243:
/// "Key trust decisions on `source`, not on the name or the tool-name prefix").
///
/// Travels as `mcp_server` on a `can_use_tool` request and on tool hook inputs. `source` values observed in the
/// 2.1.278 fixtures on `system`/`init` rows: `plugin`, `claudeai`, `sdk`; the TypeScript SDK types the field as an
/// open string, so this type keeps it a string.
public struct MCPServerRef: Sendable, Equatable, Codable {
    public var name: String
    public var source: String?

    public init(name: String, source: String? = nil) { self.name = name; self.source = source }

    /// Reads a `{"name": …, "source": …}` object; nil when absent or nameless.
    public init?(wire json: JSONValue?) {
        guard let name = json?["name"]?.stringValue else { return nil }
        self.init(name: name, source: json?["source"]?.stringValue)
    }

    /// The `mcp_server` object on a `can_use_tool` request or a tool hook input, if the CLI sent one.
    public static func inFrame(_ frame: JSONValue) -> MCPServerRef? { MCPServerRef(wire: frame["mcp_server"]) }
}

/// One row of `system`/`init`'s `mcp_servers`. `source` arrived in 2.1.278 (absent in 2.1.270 through 2.1.273,
/// where rows are `{name, status}` alone).
public struct MCPServerStatus: Sendable, Equatable, Codable {
    public var name: String
    public var status: String
    public var source: String?

    public init(name: String, status: String, source: String? = nil) { self.name = name; self.status = status; self.source = source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    /// The server as a provenance reference, for a policy that keys on `source`.
    public var reference: MCPServerRef { MCPServerRef(name: name, source: source) }
}
