# Changelog

## 0.2.0 (2026-09-19)

Minor bump: `AgentEngine` capability protocols, named keys on `Message` and `ContentBlock`, `Message.taskNotification` gains `reason`. Recorded and tested against Claude Code 2.1.270 through 2.1.273 and 2.1.278.

`Message` and `ContentBlock` encode with every field named (2026-09-19, gateway backlog 9): the four single-value `Message` cases write `message`, `payload` and `result` keys and the two single-value `ContentBlock` cases write `text` and `thinking`, where the synthesizer wrote `_0`; both decoders still accept `_0` for rows and parts written by 0.1.x. `Message.taskNotification` gained `reason: TaskNotificationReason?` (the one intended API break in 0.2.0; a four-element pattern is needed to bind it). `SessionOptions` gained `permissionPrompts` (`--permission-prompts host|none`), `systemPromptSnapshot` (`--system-prompt-snapshot on|off`), `mcpStartupWaitMs` and `emitStartupTiming` (the two startup environment variables); `ClaudeSession` decodes result frames through `ResultMessage(wire:)`. `AgentProtocol` gained the 2.1.278 and TypeScript-SDK fields: `MCPServerRef`, `SystemInit` with `scratchpad_path` and `startup_timing`, `StartupFailureReason` and the latency fields on `ResultMessage`, `UsageReport`, `SlashCommand.builtin`, `UserMessage.pastedContent`, `TaskNotificationReason`; every recorded fixture line from 2.1.270 to 2.1.278 decodes.

`AgentEngine` gained `engineVersion` (default nil) and eleven optional capability protocols, each with a documented fallback: `ModelSwitching`, `EffortSetting`, `ReasoningControl`, `Resumable`, `PermissionGating`, `HookCapable`, `ToolHosting`, `ImageAttaching`, `ContextReporting`, `FileRewinding`, and `RateLimitReporting` (2026-09-19). `ClaudeCodeEngine` adopts all of them, exposes `options` and a static `childEnvironment(options:)`, and moved to its own file. `ClaudeSession.options` is now `private(set) var`, with `configure(_:)` and `isStarted` added to edit it before start; `ClaudeSession` emits `system/version_warning` on the stream when the version check produces a warning. `EngineError`, `ReasoningDisplay`, and `ImageAttachment` are new public types. `AgentEngineTests` now depends on `AgentTestKit`. `Scripts/sdk-api-check.sh` against `sdk-swift/v0.1.0` reports no breaking change in any target: `ClaudeSession.options` moving from `let` to `private(set) var` is source-compatible for readers, and `engineVersion` is defaulted, so existing `AgentEngine` conformers still compile.

Renamed the package and module from `ClaudeAgentKit` to `KybernaAgentKit` (2026-09-17), following the convention Anthropic uses for its own Agent SDKs (the vendor's product in the name, the engine in the type names) and its branding guidance that a partner product keeps its own branding. Type names are unchanged: `ClaudeSession` and `ClaudeCodeEngine` still name the Claude Code engine. The API baseline tag stays `sdk-swift/v0.1.0`; `Scripts/sdk-api-check.sh` reads the old folder name from that tag.

## 0.1.0 (2026-09-16)

First tagged version, tagged `sdk-swift/v0.1.0`. The five library targets, the fake CLI, four fixture sets
recorded against Claude Code 2.1.270 through 2.1.273, the wire-protocol document, and 36 tests. The fake CLI's
body became `FakeCLIMain.run()` so an executable around it is one line. The fixtures are shared under
`SDKs/protocol/fixtures`, one copy for every SDK, copied into `AgentTestKit`'s bundle at build time as a
resource and reached through `Fixtures.root`.
