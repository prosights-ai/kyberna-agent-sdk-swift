# KybernaAgentKit

The Kyberna Agent SDK for Swift. It drives Claude Code as an agent engine over its stream-json protocol, the same
protocol Anthropic's Python and TypeScript Agent SDKs use, so a Swift application gets the Claude Code agent loop,
tools, hooks, permissions, sessions and MCP without implementing the loop itself. Typed `Codable` wire types, a
transport that runs the CLI and frames its output, a session with hooks, permission callbacks and steering, an
engine protocol, and a test kit that replays recorded conversations through a fake CLI so tests need no network
and no account.

Requirements: macOS 15 or later, Swift 6 tools, and Claude Code 2.0 or later on the machine (`claude` on the
PATH, or a path you give the session). Zero non-Apple dependencies.

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/prosights-ai/kyberna-agent-sdk-swift", from: "0.1.0"),
],
targets: [
    .target(name: "MyAgent", dependencies: [
        .product(name: "AgentSession", package: "kyberna-agent-sdk-swift"),
    ]),
]
```

Products: `AgentProtocol` (wire types), `AgentTransport` (process and framing), `AgentSession` (`ClaudeSession`,
`SessionOptions`, `SwiftTool`), `AgentEngine` (the `AgentEngine` protocol and `ClaudeCodeEngine`), `AgentTestKit`
(fixtures, `FakeCLIRunner`), and the `fake-claude` executable.

## A first agent

```swift
import AgentSession
import AgentProtocol

var options = SessionOptions(workingDirectory: FileManager.default.currentDirectoryPath)
options.allowedTools = ["Read", "Glob", "Grep"]
options.model = "haiku"
options.canUseTool = { tool, input, _ in
    // Every tool call not pre-allowed lands here; answer .allow(...) or .deny(...).
    print("tool \(tool): \(input)")
    return .allow()
}

let session = ClaudeSession(options: options)
try await session.start()
Task { for await message in session.messages {
    if case .assistant(let a) = message { for block in a.content { if case .text(let t) = block { print(t) } } }
} }
let result = try await session.query("Read utils.py and say in one sentence what it does.")
print(result.subtype, result.totalCostUSD ?? 0)
await session.stop(.session)
```

`send(_:)` and the `messages` stream carry a multi-turn conversation; `steer(_:)` queues a message into a running
turn and `steerNow(_:)` interrupts the turn first; `pause()`, `resume()` and `stop(_:)` with a severity cover the
rest. A `SwiftTool` is an in-process tool the model can call, served to the CLI as an MCP server; hooks
(`HookMatcher`) run before and after tool calls. `WorkspaceTrust` records the CLI's own trust flag for a
directory.

## Authentication

Anthropic's terms allow a third-party product to use Claude Code's claude.ai login only on the developer's own
machine. A product for other people authenticates with an Anthropic API key (`ANTHROPIC_API_KEY` in
`SessionOptions.env`) or a cloud provider's credentials (Bedrock, Vertex AI, Foundry, through the CLI's own
environment variables). The SDK passes an allowlisted environment to the CLI and never reads credentials itself.

## Claude Code versions

| SDK | Recorded and tested against | Minimum |
|---|---|---|
| 0.1.0 | Claude Code 2.1.270, 2.1.271, 2.1.272, 2.1.273 | 2.0.0 |

At start the session runs `claude --version`: below `SessionOptions.minimumClaudeCodeVersion` it sets
`versionWarning` and continues; when `allowedClaudeCodeVersions` is set, any other version throws before anything
starts. The wire types ignore unknown fields, so a newer CLI usually works untouched; protocol deltas between the
recorded versions are in `protocol/wire-protocol.md`, section 9.

## Tests and fixtures

```bash
git clone --recurse-submodules https://github.com/prosights-ai/kyberna-agent-sdk-swift
cd kyberna-agent-sdk-swift
swift build
swift test
```

The `protocol` submodule ([kyberna-agent-protocol](https://github.com/prosights-ai/kyberna-agent-protocol)) holds
the wire document and the recorded fixtures, one copy for every language the SDK is ported to; `AgentTestKit`
copies the fixtures into its bundle and reaches them through `Fixtures.root`, `Fixtures.cli(version)` and
`Fixtures.scenario(name, version)`. Recording your own: set `SessionOptions.recordDirectory`, run the
conversation against the real CLI, and scrub the home directory, user name and e-mail addresses before committing
(`docs/decisions/0003`).

## Naming

"Claude Agent" is Anthropic's permitted descriptor for products built on its Agent SDK; "Claude Code" is not
permitted in a third-party product name. This package is named for Kyberna, the product it belongs to, in the
same way Anthropic names its SDKs for Claude; the engine keeps its name in the types (`ClaudeSession`,
`ClaudeCodeEngine`).

## License

MIT License; see `LICENSE`. Use of Claude Code and the Anthropic API is governed by Anthropic's terms.
