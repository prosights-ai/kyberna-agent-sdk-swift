import Foundation

/// Engine enhancement 9: the CLI's `--settings` payload as a value, so a profile is something a host can store,
/// diff, and show, rather than a string it has to parse. Only the fields a host commonly sets are modeled; anything else
/// the CLI accepts goes in `extra` and is merged at encode time. Unset fields are omitted, so an empty
/// `SessionSettings` encodes as `{}` and changes nothing about the CLI's own settings resolution.
public struct SessionSettings: Sendable, Equatable, Codable {
    public struct Permissions: Sendable, Equatable, Codable {
        public var allow: [String]
        public var deny: [String]
        public var ask: [String]
        /// `default`, `acceptEdits`, `bypassPermissions`, or `plan`; nil leaves the CLI's own default.
        public var defaultMode: String?
        public var additionalDirectories: [String]
        public init(allow: [String] = [], deny: [String] = [], ask: [String] = [], defaultMode: String? = nil,
                    additionalDirectories: [String] = []) {
            self.allow = allow; self.deny = deny; self.ask = ask; self.defaultMode = defaultMode
            self.additionalDirectories = additionalDirectories
        }
        public var isEmpty: Bool { allow.isEmpty && deny.isEmpty && ask.isEmpty && defaultMode == nil && additionalDirectories.isEmpty }
    }

    /// Claude Code's own sandbox for Bash and file tools (plan section 5: on in every profile that has Bash).
    public struct Sandbox: Sendable, Equatable, Codable {
        public var enabled: Bool
        public var allowUnixSockets: [String]
        public var allowLocalBinding: Bool
        public var autoAllowBashIfSandboxed: Bool
        public var network: Network?
        public struct Network: Sendable, Equatable, Codable {
            public var allowUnixSockets: [String]
            public var allowLocalBinding: Bool
            public init(allowUnixSockets: [String] = [], allowLocalBinding: Bool = false) {
                self.allowUnixSockets = allowUnixSockets; self.allowLocalBinding = allowLocalBinding
            }
        }
        public init(enabled: Bool = true, allowUnixSockets: [String] = [], allowLocalBinding: Bool = false,
                    autoAllowBashIfSandboxed: Bool = false, network: Network? = nil) {
            self.enabled = enabled; self.allowUnixSockets = allowUnixSockets; self.allowLocalBinding = allowLocalBinding
            self.autoAllowBashIfSandboxed = autoAllowBashIfSandboxed; self.network = network
        }
    }

    public var permissions: Permissions?
    public var sandbox: Sandbox?
    public var env: [String: String]
    public var model: String?
    public var outputStyle: String?
    public var includeCoAuthoredBy: Bool?
    /// Anything the CLI accepts that this type does not model; merged into the encoded object.
    public var extra: [String: JSONValue]

    public init(permissions: Permissions? = nil, sandbox: Sandbox? = nil, env: [String: String] = [:], model: String? = nil,
                outputStyle: String? = nil, includeCoAuthoredBy: Bool? = nil, extra: [String: JSONValue] = [:]) {
        self.permissions = permissions; self.sandbox = sandbox; self.env = env; self.model = model
        self.outputStyle = outputStyle; self.includeCoAuthoredBy = includeCoAuthoredBy; self.extra = extra
    }

    public var isEmpty: Bool {
        (permissions?.isEmpty ?? true) && sandbox == nil && env.isEmpty && model == nil && outputStyle == nil
            && includeCoAuthoredBy == nil && extra.isEmpty
    }

    /// The object the CLI reads from `--settings`. Empty collections are dropped so the payload says only what
    /// the profile decided.
    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        for (k, v) in extra { o[k] = v }
        if let p = permissions, !p.isEmpty {
            var d: [String: JSONValue] = [:]
            if !p.allow.isEmpty { d["allow"] = .array(p.allow.map { .string($0) }) }
            if !p.deny.isEmpty { d["deny"] = .array(p.deny.map { .string($0) }) }
            if !p.ask.isEmpty { d["ask"] = .array(p.ask.map { .string($0) }) }
            if let m = p.defaultMode { d["defaultMode"] = .string(m) }
            if !p.additionalDirectories.isEmpty { d["additionalDirectories"] = .array(p.additionalDirectories.map { .string($0) }) }
            o["permissions"] = .object(d)
        }
        if let s = sandbox {
            var d: [String: JSONValue] = ["enabled": .bool(s.enabled)]
            if !s.allowUnixSockets.isEmpty { d["allowUnixSockets"] = .array(s.allowUnixSockets.map { .string($0) }) }
            if s.allowLocalBinding { d["allowLocalBinding"] = .bool(true) }
            if s.autoAllowBashIfSandboxed { d["autoAllowBashIfSandboxed"] = .bool(true) }
            if let n = s.network {
                var nd: [String: JSONValue] = [:]
                if !n.allowUnixSockets.isEmpty { nd["allowUnixSockets"] = .array(n.allowUnixSockets.map { .string($0) }) }
                if n.allowLocalBinding { nd["allowLocalBinding"] = .bool(true) }
                if !nd.isEmpty { d["network"] = .object(nd) }
            }
            o["sandbox"] = .object(d)
        }
        if !env.isEmpty { o["env"] = .object(env.mapValues { .string($0) }) }
        if let m = model { o["model"] = .string(m) }
        if let s = outputStyle { o["outputStyle"] = .string(s) }
        if let c = includeCoAuthoredBy { o["includeCoAuthoredBy"] = .bool(c) }
        return .object(o)
    }

    /// The string form passed to `--settings`.
    public var encoded: String { json.canonicalJSON }
}
