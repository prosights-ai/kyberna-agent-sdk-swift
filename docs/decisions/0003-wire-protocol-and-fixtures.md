# ADR 0003: The wire-protocol document and recorded fixtures are the binding contract

Date: 2026-09-13. Status: accepted.

Decision: `docs/wire-protocol.md` (observed on Claude Code 2.1.270) and `Fixtures/cli/<version>/<scenario>/` are the single source of truth for how any port of the SDK talks to the Claude Code CLI. Each port is correct when it produces the recorded argument list for a scenario and completes the scenario against `fake-claude`, which replays the recording with causal ordering (a CLI response waits for the client request it answers; a turn waits for its user message; lines after a CLI request wait for the client's answer).

Consequences: a protocol change is recorded as a new fixture set under a new CLI version directory plus a documented diff, before any port changes. Fixtures contain no credentials, no real channel messages, and have the home directory, macOS username, and email addresses replaced with placeholders. `kyb replay-all Fixtures/cli/<version>` is the conformance check; it runs without network or subscription usage.
