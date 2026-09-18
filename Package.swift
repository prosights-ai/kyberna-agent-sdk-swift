// swift-tools-version: 6.0
import PackageDescription

// KybernaAgentKit: the Kyberna Agent SDK for Swift. Its engine drives Claude Code over the stream-json protocol,
// which makes it the Swift peer of Anthropic's Python and TypeScript Agent SDKs; the engine-neutral layer
// (AgentEngine, SwiftTool, Message, the test kit) is what further engines build on. Zero non-Apple dependencies.
// The wire document and the recorded fixtures every port reads live in the `protocol` submodule.
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
        // The engine protocols and the Claude Code engine; the direct API engine arrives in a later phase.
        .target(name: "AgentEngine", dependencies: ["AgentProtocol", "AgentSession"], swiftSettings: settings),
        // The fake CLI, and the recorded, language-neutral fixtures it replays. The fixtures live in the shared
        // SDKs/protocol folder, read by every SDK; this target copies them into its bundle at build time so a test
        // in any Swift package finds them through `Fixtures.root`.
        .target(name: "AgentTestKit", dependencies: ["AgentProtocol"],
                resources: [.copy("../../protocol/fixtures")], swiftSettings: settings),
        .executableTarget(name: "fake-claude", dependencies: ["AgentTestKit"], swiftSettings: settings),
        // Tests (Xcode's toolchain; the Command Line Tools cannot link the Testing framework)
        .testTarget(name: "AgentProtocolTests", dependencies: ["AgentProtocol"]),
        .testTarget(name: "AgentSessionTests", dependencies: ["AgentSession", "AgentTestKit"]),
        .testTarget(name: "AgentTestKitTests", dependencies: ["AgentTestKit"]),
        .testTarget(name: "AgentEngineTests", dependencies: ["AgentEngine", "AgentSession"]),
    ],
    swiftLanguageModes: [.v6]
)
