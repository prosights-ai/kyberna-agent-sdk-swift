// swift-tools-version: 6.0
import PackageDescription

// KybernaAgentKit: the Kyberna Agent SDK for Swift. Today its one engine drives Claude Code (the Claude Agent engine, the Swift peer of Anthropic's Python and TypeScript Agent SDKs); the engine-neutral layer (AgentEngine, SwiftTool, Message, the test kit) is what Phase 8's direct engine and providers build on (ADR 0015).
// Named for the product, as Anthropic names its SDKs for Claude, and per Anthropic's branding guidance that a partner product keeps its own branding (plan section 1.5, ADR 0002 as amended
// by ADR 0013). One of the SDK folders in the Kyberna repository, kept as its own package so it can be split
// into a repository of its own when it is published. Zero non-Apple dependencies. Nothing here knows about
// channels, users, SQLite, or SwiftUI; the Kyberna product depends on this package and adds those.
let settings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "KybernaAgentKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentProtocol", targets: ["AgentProtocol"]),
        .library(name: "AgentTransport", targets: ["AgentTransport"]),
        .library(name: "AgentSession", targets: ["AgentSession"]),
        .library(name: "AgentEngine", targets: ["AgentEngine"]),
        .library(name: "AgentDirect", targets: ["AgentDirect"]),
        .library(name: "AgentTestKit", targets: ["AgentTestKit"]),
        .executable(name: "fake-claude", targets: ["fake-claude"]),
    ],
    targets: [
        // Wire types only: every stream-json message, control request and response, options. Codable structs
        // and enums, a JSONValue for the genuinely open fields.
        .target(name: "AgentProtocol", swiftSettings: settings),
        // Launches the CLI, frames stdin and stdout lines, correlates control requests, caps buffers.
        .target(name: "AgentTransport", dependencies: ["AgentProtocol"], swiftSettings: settings),
        // ClaudeSession: options to arguments, handshake, hooks, permissions, typed messages, stop, steer.
        .target(name: "AgentSession", dependencies: ["AgentProtocol", "AgentTransport"], swiftSettings: settings),
        // The engine protocols and the Claude Code engine.
        .target(name: "AgentEngine", dependencies: ["AgentProtocol", "AgentSession"], swiftSettings: settings),
        // The direct API engine (plan Phase 8, ADR 0015): the ModelProvider contract, the Anthropic provider over the
        // Messages API, the provider-neutral ToolExecutor with its process registry, and DirectAPIEngine. Apple
        // frameworks only; the loop is always streaming.
        .target(name: "AgentDirect", dependencies: ["AgentProtocol", "AgentSession", "AgentEngine"], swiftSettings: settings),
        // The fake CLI, and the recorded, language-neutral fixtures it replays. The fixtures live in the shared
        // SDKs/protocol folder, read by every SDK; this target copies them into its bundle at build time so a test
        // in any Swift package finds them through `Fixtures.root`.
        // FakeModelProvider (scripted ModelEvent streams) lives here beside the fake CLI, so it depends on AgentDirect.
        .target(name: "AgentTestKit", dependencies: ["AgentProtocol", "AgentDirect"],
                resources: [.copy("../../protocol/fixtures")], swiftSettings: settings),
        .executableTarget(name: "fake-claude", dependencies: ["AgentTestKit"], swiftSettings: settings),
        // Tests (Xcode's toolchain; the Command Line Tools cannot link the Testing framework)
        // AgentTestKit is a dependency only for `Fixtures.root`: the protocol tests decode every recorded
        // stdout line of every fixture set through the wire types.
        .testTarget(name: "AgentProtocolTests", dependencies: ["AgentProtocol", "AgentTestKit"]),
        .testTarget(name: "AgentSessionTests", dependencies: ["AgentSession", "AgentTestKit"]),
        .testTarget(name: "AgentTestKitTests", dependencies: ["AgentTestKit"]),
        .testTarget(name: "AgentEngineTests", dependencies: ["AgentEngine", "AgentSession", "AgentTestKit"]),
        .testTarget(name: "AgentDirectTests", dependencies: ["AgentDirect", "AgentEngine", "AgentSession", "AgentTestKit"]),
    ],
    swiftLanguageModes: [.v6]
)
