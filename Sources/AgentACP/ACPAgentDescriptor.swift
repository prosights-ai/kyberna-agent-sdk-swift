import Foundation

/// One ACP agent as a host launches it: the command with its version pin, how a model is named on the command
/// line, what the vendor's own pages say about signing in, and whether the agent advertises `session/load`.
/// A host keeps a registry of these (Kyberna: `ACPAgentRegistry`); the SDK only runs what it is handed.
public struct ACPAgentDescriptor: Sendable, Equatable, Codable {
    /// How the model reaches the agent's command line. Nil: the agent takes no model argument the vendor documents,
    /// and `ACPEngine` runs it on the agent's own default.
    public enum ModelArgument: Sendable, Equatable, Codable {
        /// `--model NAME` (two arguments).
        case flag(String)
        /// `--model=NAME` (one argument).
        case flagEquals(String)
        /// An environment variable set to the model name.
        case environment(String)

        func apply(_ model: String, to arguments: inout [String], environment: inout [String: String]) {
            switch self {
            case .flag(let f): arguments += [f, model]
            case .flagEquals(let f): arguments.append(f + "=" + model)
            case .environment(let v): environment[v] = model
            }
        }
    }

    /// Short stable name (`gemini`, `codex-acp`); the ACP registry's `id` where one exists.
    public var id: String
    public var displayName: String
    /// The executable as a name to find on the child's PATH (`npx`, `vibe-acp`) or an absolute path.
    public var executable: String
    /// Everything after the executable, version pin included (`-y`, `@google/gemini-cli@0.60.0`, `--acp`).
    public var arguments: [String]
    public var modelArgument: ModelArgument?
    /// What the vendor's own documentation says about signing in and where the credential lives, as text for a
    /// person; "not established" where the host's research found nothing first-party.
    public var authNote: String
    /// Whether the agent is known to advertise `loadSession` in `initialize`. Decides which engine class
    /// `ACPEngine.make` returns (`Resumable` or not); the engine still reads the live answer at start.
    public var supportsSessionLoad: Bool

    public init(id: String, displayName: String, executable: String, arguments: [String], modelArgument: ModelArgument? = nil,
                authNote: String, supportsSessionLoad: Bool = false) {
        self.id = id; self.displayName = displayName; self.executable = executable; self.arguments = arguments
        self.modelArgument = modelArgument; self.authNote = authNote; self.supportsSessionLoad = supportsSessionLoad
    }

    /// The command line and environment for a launch on `model` (nil: the agent's default).
    public func launch(model: String?, environment base: [String: String]) -> (arguments: [String], environment: [String: String]) {
        var args = arguments, env = base
        if let model, let m = modelArgument { m.apply(model, to: &args, environment: &env) }
        return (args, env)
    }
}
