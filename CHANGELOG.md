# Changelog

## 0.1.2 (2026-09-17)

The wire document and fixtures moved into this repository as the `protocol` folder; no submodule, so `git clone` and SwiftPM resolution need nothing else. Comments no longer describe another vendor's software in our voice.

## 0.1.1 (2026-09-17)

README only: removed statements that characterised Anthropic's terms; authentication is described as what the SDK passes through, and the terms are left to Anthropic's own documentation.

## 0.1.0 (2026-09-17, first public release)

Published from the Kyberna repository into this one, with the wire document and fixtures as the `protocol` submodule. The package and module are `KybernaAgentKit` (earlier working name `ClaudeAgentKit`), following the convention Anthropic uses for its own Agent SDKs: the vendor's product in the package name, the engine in the type names, so `ClaudeSession` and `ClaudeCodeEngine` name the Claude Code engine. MIT.

## 0.1.0-pre (2026-09-16)

First tagged version inside the Kyberna repository (`sdk-swift/v0.1.0`). The five library targets, the fake CLI, four fixture sets
recorded against Claude Code 2.1.270 through 2.1.273, the wire-protocol document, and 36 tests. The fake CLI's
body became `FakeCLIMain.run()` so an executable around it is one line. The fixtures are shared under
`SDKs/protocol/fixtures`, one copy for every SDK, copied into `AgentTestKit`'s bundle at build time as a
resource and reached through `Fixtures.root`.
