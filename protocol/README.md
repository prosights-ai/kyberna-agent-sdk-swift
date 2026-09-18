# protocol

The language-neutral half of the SDK: the wire-protocol document for Claude Code's stream-json interface
(`wire-protocol.md`) and the recorded conversations the test kit replays (`fixtures/cli/<claude-code-version>/<scenario>/`:
`args.json`, `stdin.jsonl`, `stdout.jsonl`, `meta.json`). The home directory, user name and e-mail addresses in the
recordings are scrubbed (`/Users/USER`, `USER`, `user@example.com`). A protocol change lands here as a new fixture
set under the new CLI version, with a section-9 delta in the document, before the SDK changes (`docs/decisions/0003`).

Recorded sets: Claude Code 2.1.270, 2.1.271, 2.1.272, 2.1.273.
