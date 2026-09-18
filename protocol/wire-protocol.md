# Claude Code CLI stream-json control protocol

Observed on Claude Code **2.1.270** (macOS, 2026-09-13). This document is the binding description of the wire protocol for every port (Swift, Python, C#). Every frame, field, and sequence below comes from one of three sources, marked in parentheses where not obvious:

- **Fixtures**: `Fixtures/cli/2.1.270/<scenario>/{args.json, stdin.jsonl, stdout.jsonl, meta.json}`. Scenarios: `simple-turn`, `multi-turn`, `permission-ask`, `ask-user-question`, `mcp-tool-call`, `hooks-deny`, `deferred-tool`, `interrupt`. Home directory, e-mail addresses, and the macOS username are scrubbed (`/Users/USER`, `user@example.com`, `USER`). Sets exist for 2.1.270, 2.1.271, 2.1.272, and 2.1.273; all of them replay, and `kyb replay-all Fixtures/cli/<version>` is run against each.
- **Swift client** that recorded them: `agent-sdk-test/swift-loop/ClaudeSession.swift` (cited as "Swift").
- **Official Python SDK** `claude_agent_sdk` internals: `_internal/query.py`, `_internal/transport/subprocess_cli.py`, `_internal/message_parser.py`, `types.py` (cited as "SDK query.py" etc.).

JSON quoted from fixtures is verbatim except that long string values are cut with `…` and long arrays are cut with `…(N more)`. Key order inside objects is not significant; the fixtures show the Swift client emitting keys in varying order and the CLI accepting all of them.

---

## 1. Overview

### 1.1 Process launch

The client spawns the `claude` executable as a child process with stdin, stdout, and (optionally) stderr piped. Required flags:

```
--output-format stream-json --verbose --input-format stream-json
```

`--verbose` is required with `--output-format stream-json` (SDK `_build_command` always emits the pair; every `args.json` contains all three). The SDK appends `--input-format stream-json` last; the Swift client puts it first. Position does not matter.

The working directory of the child is the session's `cwd` (SDK `anyio.open_process(cwd=...)`; Swift `process.currentDirectoryURL`). The CLI reports it back in the `system`/`init` frame as `cwd`.

The SDK resolves the executable by checking, in order: a bundled `_bundled/claude`, `shutil.which("claude")`, then `~/.npm-global/bin/claude`, `/usr/local/bin/claude`, `~/.local/bin/claude`, `~/node_modules/.bin/claude`, `~/.yarn/bin/claude`, `~/.claude/local/claude` (SDK subprocess_cli.py `_find_cli`). Before launch it runs `claude -v` with a 2 s timeout and warns if the version is below `2.0.0` (SDK `_check_claude_version`; Swift `probeVersion`). On Windows the SDK refuses `.bat`/`.cmd` shims and rejects cmd.exe metacharacters (`&|<>^%!"` and CR/LF) in `--resume`, `--session-id`, `--resume-session-at`, `--resume-drops-turn` values (SDK `_reject_windows_batch_cli`, `_reject_windows_cmd_metacharacters`).

### 1.2 Line framing

Both directions carry newline-delimited JSON: one JSON object per line, UTF-8, terminated by `\n`. The CLI terminates every stdout message with `\n` (SDK `_read_messages_impl`). Rules the SDK applies when reading:

- Lines are reassembled from arbitrary chunks; a chunk boundary can fall inside a string (SDK `_LineFramer`).
- A complete line is stripped of surrounding whitespace (so CRLF is tolerated). Blank lines are ignored. A line that does not start with `{` is ignored (some builds write `[SandboxDebug] ...` to stdout). A line that starts with `{` but fails to parse raises (SDK `_parse_stdout_line`).
- A single line longer than `max_buffer_size` (default 1 MiB) is an error (SDK `guard`; Swift emits a synthetic `system`/`buffer_overflow` and drops the line).
- The CLI writes string values containing raw control characters inside JSON strings in at least one place (the `initialize` control_response `commands[].description` in `simple-turn` fails strict `jq`/`json.loads(strict=True)` parsing). Parsers must accept unescaped control characters inside strings (`json.loads(..., strict=False)` in Python; `JSONSerialization` on Apple platforms accepts them).

### 1.3 stdin lifetime

- stdin stays open for the whole session. The CLI in `--input-format stream-json` mode exits only on stdin EOF (SDK query.py `_track_task_lifecycle` docstring: "the CLI in stream-json mode only exits on stdin EOF").
- Closing stdin ends the CLI: it finishes in-flight work, flushes its session file, and exits (Swift `close()`; SDK `end_input()` then `close()` waits up to 5 s, then SIGTERM, then SIGKILL, each with a 5 s wait; the grace period exists because SIGTERM during the flush loses the last assistant message, SDK #625).
- After a `result` with `is_error: true` the CLI exits non-zero on purpose (SDK query.py `_read_messages` comment). The SDK converts the trailing "exit code 1" into a `ResultError` carrying the result payload.
- **Bidirectional needs.** If the client registered any of: an in-process (`type: "sdk"`) MCP server, hooks, or a `can_use_tool` permission handler, the CLI will write `control_request` frames to stdout and block until the matching `control_response` arrives on stdin. Closing stdin while any of these is configured makes every later request fail CLI-side with "Stream closed" (SDK `_has_bidirectional_needs`). The one-shot `query()` therefore closes stdin only at the first `result` that arrives with no delegated task in flight; without bidirectional needs it closes stdin immediately after writing the prompt (SDK `wait_for_result_and_end_input`; Swift `query()`).
- Delegated tasks: a `system`/`task_started` with `task_type` in `{"local_agent","local_workflow"}` marks a task in flight; `task_notification` or `task_updated` with `patch.status` in `{"completed","failed","stopped","killed"}` clears it. A `result` that arrives while the set is non-empty must not close stdin (SDK `DEFERRING_TASK_TYPES`, `TERMINAL_TASK_STATUSES`; Swift `parseSystem`). Not exercised by this fixture set.
- Multiple user turns in one process are supported: `multi-turn` writes two `user` frames and receives two `result` frames with the same `session_id`.

### 1.4 Environment variables

| Variable | Set by | Value | Source |
|---|---|---|---|
| `CLAUDECODE` | removed from the inherited environment | — | SDK `connect()` ("so SDK-spawned subprocesses don't think they're running inside a Claude Code parent", #573); Swift `env.removeValue(forKey: "CLAUDECODE")` |
| `CLAUDE_CODE_ENTRYPOINT` | set | `sdk-py` (SDK), `sdk-swift` (Swift); overridable by `options.env` in the SDK | SDK `connect()`; Swift `start()` |
| `CLAUDE_AGENT_SDK_VERSION` | set | SDK package version | SDK `connect()` (Python SDK only) |
| `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING` | set to `"true"` when file checkpointing is enabled; required for `rewind_files` | `true` | SDK `connect()`; Swift `enableFileCheckpointing` |
| `PWD` | set to the session cwd | cwd | SDK `connect()` |
| `TRACEPARENT`, `TRACESTATE` | set from the active OpenTelemetry span if one exists | W3C trace context | SDK `connect()` |
| `CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK` | read by the SDK; when set, `claude -v` is not run | any | SDK `connect()` |
| `CLAUDE_AGENT_SDK_CLIENT_APP` | optional; identifies the app in the User-Agent | e.g. `my-app/1.0.0` | SDK types.py `ClaudeAgentOptions.env` doc |

stderr: inherited by default; piped only when the caller registers a stderr callback (SDK `stderr_dest`; Swift `options.stderr`).

---

## 2. Argument mapping

Every option-to-flag mapping from Swift `buildArguments` and SDK `_build_command`. "Two-token" means `--flag value`; "equals" means `--flag=value`.

| Option | Flag | Form | Notes |
|---|---|---|---|
| (always) | `--output-format stream-json` | two-token | required |
| (always) | `--verbose` | bare | required with stream-json |
| (always) | `--input-format stream-json` | two-token | required |
| systemPrompt `.replace(s)` / SDK `str` | `--system-prompt <s>` | two-token | SDK passes `--system-prompt ""` when `system_prompt is None` |
| systemPrompt `.append(s)` / SDK preset with `append` | `--append-system-prompt <s>` | two-token | all fixtures: `"Be terse."` |
| SDK `{"type":"file","path"}` | `--system-prompt-file <path>` | two-token | SDK only |
| tools (base built-in set) | `--tools <a,b,c>` | two-token | `[]` → `--tools ""` (all built-ins removed); SDK preset → `--tools default` |
| allowedTools | `--allowedTools <a,b,c>` | two-token | comma-joined; MCP tools as `mcp__<server>__<tool>` (`mcp-tool-call` args) |
| disallowedTools | `--disallowedTools <a,b,c>` | two-token | |
| maxTurns | `--max-turns <n>` | two-token | fixtures: `8` |
| maxBudgetUSD | `--max-budget-usd <f>` | two-token | |
| SDK `task_budget` | `--task-budget <total>` | two-token | SDK only |
| model | `--model <id>` | two-token | |
| fallbackModel | `--fallback-model <id>` | two-token | |
| SDK `betas` | `--betas <a,b>` | two-token | SDK only |
| effort | `--effort <low\|medium\|high\|xhigh\|max>` | two-token | |
| thinking `.adaptive` | `--thinking adaptive` | two-token | |
| thinking `.budget(n)` / SDK `enabled` | `--max-thinking-tokens <n>` | two-token | SDK also uses this for deprecated `max_thinking_tokens` |
| thinking `.disabled` | `--thinking disabled` | two-token | |
| SDK thinking `display` | `--thinking-display <summarized\|omitted>` | two-token | SDK only; not sent for `disabled` |
| jsonSchema / SDK `output_format.schema` | `--json-schema <json>` | two-token | JSON-serialized schema |
| includePartialMessages | `--include-partial-messages` | bare | enables `stream_event` frames |
| SDK `include_hook_events` | `--include-hook-events` | bare | enables `system`/`hook_started`, `hook_response` |
| canUseTool set / SDK `permission_prompt_tool_name` | `--permission-prompt-tool stdio` | two-token | routes permission prompts to `can_use_tool` control requests (`permission-ask`, `ask-user-question` args) |
| permissionMode | `--permission-mode <mode>` | two-token | `default`, `acceptEdits`, `plan`, `bypassPermissions`, `dontAsk`, `auto` (SDK `PermissionMode`) |
| continueConversation | `--continue` | bare | |
| resume | `--resume=<id>` | **equals** | The CLI declares `--resume` with an optional value; in two-token form a dash-leading value is not bound to the flag and parses as a separate flag, so an untrusted value could inject flags. Equals form always binds (SDK comment; Swift "equals form, as the SDK does"). |
| sessionId | `--session-id=<uuid>` | **equals** | same reason |
| SDK `resume_session_at` | `--resume-session-at=<uuid>` | **equals** | SDK only |
| SDK `resume_drops_turn` | `--resume-drops-turn=<uuid>` | **equals** | SDK only; empty string is forwarded on purpose |
| forkSession | `--fork-session` | bare | |
| settingsJSON / SDK `settings` (+ `sandbox` merged in) | `--settings <json-or-path>` | two-token | SDK merges `sandbox` into the settings object and passes JSON |
| addDirs | `--add-dir <path>` | two-token, repeated | one pair per directory |
| swiftTools / SDK `mcp_servers` | `--mcp-config <json>` | two-token | `{"mcpServers":{"<name>":{"type":"sdk","name":"<name>"}}}` for in-process servers; SDK strips the `instance` key and passes other server types as-is; a string/Path is passed directly |
| strictMcpConfig | `--strict-mcp-config` | bare | |
| SDK `session_store` | `--session-mirror` | bare | SDK only; enables `transcript_mirror` frames |
| settingSources | `--setting-sources=<a,b>` | **equals** | SDK defaults it to `user,project` when `skills` is set |
| pluginDirs / SDK `plugins[type=local]` | `--plugin-dir <path>` | two-token, repeated | |
| extraArgs | `--<flag>` or `--<flag> <value>` or `--<flag>=<value>` | varies | SDK: `None` → bare flag; dash-leading value → equals form; else two-token |

Things that go in the **initialize control request**, not in flags: `hooks`, `agents`, `skills` (as a list), `excludeDynamicSections`, `forwardSubagentText` (SDK query.py `initialize`; "Agents are always sent via initialize request (matching TypeScript SDK). No --agents CLI flag needed"). SDK `skills` additionally injects `Skill(<name>)` rules into `--allowedTools` (or bare `Skill` for `"all"`).

Observed argument list (`permission-ask/args.json`):

```json
["--output-format","stream-json","--verbose","--input-format","stream-json",
 "--append-system-prompt","Be terse.","--allowedTools","Read","--max-turns","8",
 "--permission-prompt-tool","stdio","--permission-mode","default"]
```

---

## 3. Control channel

### 3.1 Envelopes

Requests and responses have the same shape in both directions.

App → CLI request / CLI → app request:

```json
{"type":"control_request","request_id":"<id>","request":{"subtype":"<subtype>", ...}}
```

Success response (either direction):

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<id>","response":{ ... }}}
```

Error response (either direction):

```json
{"type":"control_response","response":{"subtype":"error","request_id":"<id>","error":"<text>"}}
```

(SDK types.py `SDKControlRequest`, `ControlResponse`, `ControlErrorResponse`; Swift `sendControl`, `handleControlRequest`.) `response.response` may be `null` (SDK `ControlResponse.response: dict | None`); the SDK returns `{}` when it is not an object.

Cancel (CLI → app only, observed in SDK source, not in fixtures):

```json
{"type":"control_cancel_request","request_id":"<id>"}
```

The CLI has abandoned the pending request; the client cancels its handler and must not write a response (SDK query.py `control_cancel_request` branch; Swift `route`).

### 3.2 request_id format

- App → CLI: `req_<counter>_<random>`. SDK: `f"req_{counter}_{os.urandom(4).hex()}"` (8 lowercase hex chars). Swift: `req_<counter>_<first 8 chars of a UUID>` (uppercase hex). Fixtures: `req_1_5F23CDA2`, `req_2_2569B394`. The counter starts at 1 and increments per request.
- CLI → app: a UUID v4 string, e.g. `645d1cb6-436d-4644-9298-2672fcd6d117` (`permission-ask`).

Responses are matched purely on `request_id`; any format works as long as it is unique within the process.

### 3.3 Concurrency and ordering

- The client must be able to service incoming `control_request` frames **while its own `initialize` is outstanding**. In `mcp-tool-call` the first stdout line is the CLI's `mcp_message` request (`initialize` JSON-RPC to the sdk server); the `initialize` control_response is line 2 and is only emitted after the client answered. `notifications/initialized` and `tools/list` follow before `system`/`init`.
- Multiple hook callbacks for one event are dispatched concurrently by the CLI (SDK types.py `ClaudeAgentOptions.hooks` doc); handle each request on its own task.
- The CLI answers `interrupt` requests even after the turn's `result` has been written (`interrupt` stdout lines 20-21).
- The default timeout for app → CLI requests is 60 s; `initialize` uses the caller's initialize timeout (also 60 s by default) because MCP servers may take time to start (SDK `_send_control_request`, `initialize`; Swift `initializeTimeout`).

### 3.4 initialize handshake

First frame the client writes. Request fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `subtype` | `"initialize"` | yes | |
| `hooks` | object or `null` | yes (send `null` when none) | `{ "<HookEvent>": [ {"matcher": string\|null, "hookCallbackIds": [string], "timeout"?: number}, ... ] }` |
| `agents` | object | no | `{ "<name>": AgentDefinition }`; AgentDefinition fields (SDK types.py): `description`, `prompt`, `tools`, `disallowedTools`, `model`, `skills`, `memory`, `mcpServers`, `initialPrompt`, `maxTurns`, `background`, `effort`, `permissionMode` |
| `skills` | `[string]` | no | only when an explicit list; `"all"` and omitted are equivalent (SDK) |
| `excludeDynamicSections` | bool | no | SDK only |
| `forwardSubagentText` | bool | no | SDK only |

Hook callback ids are assigned by the client as `hook_<n>` from a counter starting at 0, in the order the client walks its hook table (SDK `initialize`; Swift `buildInitializeRequest`). HookEvent names: `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`, `Stop`, `SubagentStop`, `PreCompact`, `Notification`, `SubagentStart`, `PermissionRequest` (SDK types.py `HookEvent`); Swift additionally registers `Elicitation`.

Observed requests:

```json
{"type":"control_request","request_id":"req_1_5F23CDA2","request":{"subtype":"initialize","hooks":null}}
```
(`simple-turn`)

```json
{"type":"control_request","request_id":"req_1_3C48D252","request":{"subtype":"initialize","hooks":{"PostToolUse":[{"matcher":null,"hookCallbackIds":["hook_1"]}],"PreToolUse":[{"hookCallbackIds":["hook_0"],"matcher":"Bash"}]}}}
```
(`hooks-deny`)

Observed response (`simple-turn`, values abbreviated). Two keys, `pending_permission_requests` and `pending_user_dialog_requests`, sit **beside** `response` inside the envelope, not inside it:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"req_1_5F23CDA2","response":{
  "commands":[{"name":"deep-research","description":"Deep research harness — …","argumentHint":""}, "…(54 more)"],
  "agents":[{"name":"claude","description":"Catch-all for any task …"}, "…(5 more)"],
  "output_style":"default",
  "available_output_styles":["default","Proactive","Concise","Explanatory","Learning"],
  "user_output_styles_dir":"/Users/USER/.claude/output-styles",
  "models":[{"value":"default","resolvedModel":"claude-opus-5[1m]","displayName":"Default (recommended)","description":"Opus 5 with 1M context · Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsFastMode":true,"supportsAutoMode":true}, "…", {"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku","description":"Haiku 4.5 · Fastest for quick answers"}],
  "account":{"email":"user@example.com","organization":"user@example.com's Organization","subscriptionType":"Claude Max","apiProvider":"firstParty"},
  "pid":26519,
  "current_permission_mode":"default",
  "analytics_disabled":false,
  "remote_control_auto_enable":true,
  "remote_control_auto_connect_default":true,
  "remote_control_available":true,
  "remote_control_auto_on_by_default":true,
  "ide_rc_auto_enable_gate":true,
  "fast_mode_state":"off",
  "fast_mode_disabled_reason":"sdk_opt_in_required",
  "session_state":"idle"},
 "pending_permission_requests":[],
 "pending_user_dialog_requests":[]}}
```

Response field table (all from fixtures):

| Field | Type | Notes |
|---|---|---|
| `commands` | `[{name, description, argumentHint}]` | slash commands and skills; 55 entries in this environment |
| `agents` | `[{name, description}]` | agent types available to the Agent tool |
| `output_style` | string | `"default"` |
| `available_output_styles` | `[string]` | |
| `user_output_styles_dir` | string | path |
| `models` | `[{value, resolvedModel, displayName, description, supportsEffort?, supportedEffortLevels?, supportsAdaptiveThinking?, supportsFastMode?, supportsAutoMode?}]` | the optional keys are absent on the `haiku` entry |
| `account` | `{email, organization, subscriptionType, apiProvider}` | |
| `pid` | int | CLI process id; also appears in `messaging_socket_path` |
| `current_permission_mode` | string | echoes `--permission-mode` (`"acceptEdits"` in `hooks-deny`) |
| `hooks_applied` | bool | present (`true`) only when `hooks` was non-null in the request (`hooks-deny`, `deferred-tool`) |
| `analytics_disabled` | bool | |
| `remote_control_auto_enable`, `remote_control_auto_connect_default`, `remote_control_available`, `remote_control_auto_on_by_default`, `ide_rc_auto_enable_gate` | bool | |
| `fast_mode_state` | string | `"off"` |
| `fast_mode_disabled_reason` | string | `"sdk_opt_in_required"` |
| `session_state` | string | `"idle"` |
| `pending_permission_requests` (envelope level) | array | `[]` in all fixtures |
| `pending_user_dialog_requests` (envelope level) | array | `[]` in all fixtures |

The Swift client exposes `commands` and `output_style` (SDK: `get_server_info()` returns the whole object).

### 3.5 App → CLI subtypes

| Subtype | Parameters | Response `response` object | Source |
|---|---|---|---|
| `interrupt` | none | `{"still_queued":[]}` | `interrupt` fixture; SDK `interrupt()` |
| `set_permission_mode` | `mode`: PermissionMode | not observed | SDK `set_permission_mode`; Swift |
| `set_model` | `model`: string or `null` | not observed | SDK `set_model`; Swift sends `NSNull` for nil |
| `mcp_status` | none | `{"mcpServers":[{name, status, serverInfo?, error?, config?, scope?, tools?}]}`; `status` ∈ `connected`, `failed`, `needs-auth`, `pending`, `disabled` | SDK types.py `McpStatusResponse`, `McpServerStatus`; run.log shows `host:connected` alongside claude.ai servers |
| `get_context_usage` | none | object with `categories`, `totalTokens`, `maxTokens`, `rawMaxTokens`, `percentage`, `model`, `isAutoCompactEnabled`, `memoryFiles`, `mcpTools`, `agents`, `gridRows`, and optional `autoCompactThreshold`, `deferredBuiltinTools`, `systemTools`, `systemPromptSections`, `slashCommands`, `skills`, `messageBreakdown`, `apiUsage` | SDK types.py `ContextUsageResponse`; run.log from 2.1.270 also shows `autocompactSource` (not in SDK types) |
| `rewind_files` | `user_message_id`: string (UUID of a user message) | not observed | SDK `rewind_files`; requires `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` |
| `stop_task` | `task_id`: string (from `task_notification`) | not observed | SDK `stop_task` |
| `mcp_reconnect` | `serverName`: string (camelCase) | error for sdk servers, see §7 | SDK `reconnect_mcp_server` |
| `mcp_toggle` | `serverName`: string, `enabled`: bool | error for sdk servers, see §7 | SDK `toggle_mcp_server` |

Observed interrupt exchange:

```json
{"request_id":"req_2_2569B394","request":{"subtype":"interrupt"},"type":"control_request"}
{"type":"control_response","response":{"subtype":"success","request_id":"req_2_2569B394","response":{"still_queued":[]}}}
```

### 3.6 CLI → app subtypes

#### `can_use_tool`

Sent when the permission system evaluates to "ask" and `--permission-prompt-tool stdio` is set. Not sent for tools already allowed by `--allowedTools`, `--permission-mode` (`acceptEdits`, `bypassPermissions`), settings allow rules, or a PreToolUse hook that returned `allow` (SDK types.py `can_use_tool` doc).

| Field | Type | Present | Source |
|---|---|---|---|
| `subtype` | `"can_use_tool"` | always | |
| `tool_name` | string | always | fixtures |
| `input` | object | always | the tool_use input |
| `tool_use_id` | string | always | fixtures; SDK says non-empty is guaranteed |
| `display_name` | string | observed | `"Edit"`, `"AskUserQuestion"` |
| `description` | string | observed on Edit | `"utils.py"` |
| `permission_suggestions` | `[PermissionUpdate]` or null | observed on Edit | `[{"type":"setMode","mode":"acceptEdits","destination":"session"}]` |
| `requires_user_interaction` | bool | observed on AskUserQuestion | `true` |
| `blocked_path` | string or null | SDK types.py | path that triggered the request |
| `decision_reason` | string | SDK types.py | forwarded from a PreToolUse hook's `permissionDecisionReason` when it returned `ask` |
| `title` | string | SDK types.py | full prompt sentence |
| `agent_id` | string | SDK types.py | present inside a sub-agent |

Observed (`permission-ask`):

```json
{"type":"control_request","request_id":"645d1cb6-436d-4644-9298-2672fcd6d117","request":{"subtype":"can_use_tool","tool_name":"Edit","display_name":"Edit","input":{"file_path":"/Users/USER/…/utils.py","old_string":"def calculate_average(numbers):\n    total = 0","new_string":"def calculate_average(numbers):\n    if not numbers:\n        return 0.0\n    total = 0","replace_all":false},"description":"utils.py","permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_014T3pz7NYfvFPzKLxM1b5jC"}}
```

Allow response. `updatedInput` is always sent; when the handler does not rewrite the input the client echoes the original (SDK `_handle_control_request`; Swift). `updatedPermissions` is optional and carries PermissionUpdate objects (usually echoed from `permission_suggestions`):

```json
{"type":"control_response","response":{"subtype":"success","request_id":"645d1cb6-…","response":{"behavior":"allow","updatedInput":{ ...tool input... }}}}
```

with optional `"updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]`.

PermissionUpdate shape (SDK types.py `PermissionUpdate.to_dict`): `type` ∈ `addRules`, `replaceRules`, `removeRules`, `setMode`, `addDirectories`, `removeDirectories`; `destination` ∈ `userSettings`, `projectSettings`, `localSettings`, `session`; rules variants carry `rules: [{toolName, ruleContent}]` and `behavior` ∈ `allow`, `deny`, `ask`; `setMode` carries `mode`; directory variants carry `directories: [string]`.

Deny response. `interrupt: true` aborts the turn (SDK `PermissionResultDeny.interrupt`):

```json
{"behavior":"deny","message":"<reason shown to the model>"}
{"behavior":"deny","message":"<reason>","interrupt":true}
```

If no handler is registered the client answers with an error response (`"canUseTool callback is not provided"` in the SDK; Swift denies with `"no permission handler"`).

#### `hook_callback`

| Field | Type | Notes |
|---|---|---|
| `subtype` | `"hook_callback"` | |
| `callback_id` | string | the `hook_<n>` id from the initialize request |
| `input` | object | the hook input (below) |
| `tool_use_id` | string or null | duplicated at the envelope level for tool hooks |

Hook `input` fields observed for `PreToolUse` and `PostToolUse` (`hooks-deny`, `deferred-tool`):

| Field | Type | Events | Source |
|---|---|---|---|
| `session_id` | string | all | fixture; SDK `BaseHookInput` |
| `transcript_path` | string | all | `~/.claude/projects/<cwd-key>/<session>.jsonl` |
| `cwd` | string | all | |
| `permission_mode` | string | all | `"acceptEdits"` |
| `scratchpad_dir` | string | observed | `/private/tmp/claude-501/<cwd-key>/<session>/scratchpad` (not in SDK types) |
| `prompt_id` | string | observed | UUID; not in SDK types |
| `effort` | `{"level": string}` | observed | `{"level":"medium"}`; not in SDK types |
| `hook_event_name` | string | all | `"PreToolUse"`, `"PostToolUse"` |
| `tool_name` | string | tool events | |
| `tool_input` | object | tool events | |
| `tool_use_id` | string | tool events | |
| `tool_response` | any | PostToolUse | Bash: `{"stdout","stderr","interrupted","isImage","noOutputExpected"}` |
| `duration_ms` | int | PostToolUse | observed (`56`); not in SDK types |
| `agent_id`, `agent_type` | string | tool events inside a sub-agent | SDK types.py |

Other events' inputs (SDK types.py, not exercised): `PostToolUseFailure` adds `error`, `is_interrupt?`; `UserPromptSubmit` has `prompt`; `Stop`/`SubagentStop` have `stop_hook_active` (SubagentStop adds `agent_id`, `agent_transcript_path`, `agent_type`); `PreCompact` has `trigger` ∈ `manual`, `auto` and `custom_instructions`; `Notification` has `message`, `title?`, `notification_type`; `SubagentStart` has `agent_id`, `agent_type`; `PermissionRequest` has `tool_name`, `tool_input`, `permission_suggestions?`.

Observed request (`hooks-deny` line 4, paths cut):

```json
{"type":"control_request","request_id":"5b4cea37-7e0f-4e9c-8357-087336437931","request":{"subtype":"hook_callback","callback_id":"hook_0","input":{"session_id":"d9c4cf39-…","transcript_path":"/Users/USER/.claude/projects/…/d9c4cf39-….jsonl","cwd":"/Users/USER/…/agent-sdk-test","scratchpad_dir":"/private/tmp/claude-501/…/scratchpad","prompt_id":"634f11a1-0fb3-4e71-8681-5f46daa8f894","permission_mode":"acceptEdits","effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -1 *.py","description":"List Python files in current directory"},"tool_use_id":"toolu_018m61ZhquXED1Fq2eXswkwZ"},"tool_use_id":"toolu_018m61ZhquXED1Fq2eXswkwZ"}}
```

Hook output (the `response` object). All fields optional; `{}` means proceed (`hooks-deny` stdin line 3). Field names are the CLI's JSON hook-output names (SDK types.py `SyncHookJSONOutput`, `AsyncHookJSONOutput`; Swift `HookOutput.wire`):

| Field | Type | Meaning |
|---|---|---|
| `continue` | bool | `false` stops Claude |
| `stopReason` | string | shown when `continue` is false |
| `suppressOutput` | bool | |
| `systemMessage` | string | warning shown to the user |
| `decision` | `"block"` | block for PostToolUse / UserPromptSubmit / Stop |
| `reason` | string | feedback for the model |
| `async` | `true` | defer the hook (with optional `asyncTimeout` ms) |
| `hookSpecificOutput` | object | event-specific, below |

`hookSpecificOutput` by event (SDK types.py):

| `hookEventName` | Fields |
|---|---|
| `PreToolUse` | `permissionDecision` ∈ `allow`, `deny`, `ask`, `defer`; `permissionDecisionReason`; `updatedInput`; `additionalContext` |
| `PostToolUse` | `additionalContext`; `updatedToolOutput` (must match the tool's output schema); `updatedMCPToolOutput` |
| `PostToolUseFailure`, `UserPromptSubmit`, `SessionStart`, `Notification`, `SubagentStart` | `additionalContext` |
| `PermissionRequest` | `decision` (object) |

Observed responses:

```json
{"response":{"request_id":"5106ee53-…","response":{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"rm is blocked by the host","permissionDecision":"deny"}},"subtype":"success"},"type":"control_response"}
{"type":"control_response","response":{"request_id":"93ab1a95-…","response":{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Host note: Bash completed."}},"subtype":"success"}}
{"type":"control_response","response":{"subtype":"success","request_id":"79487423-…","response":{"hookSpecificOutput":{"permissionDecision":"defer","permissionDecisionReason":"operator must approve shell commands later","hookEventName":"PreToolUse"}}}}
```

An unknown `callback_id` is answered with an error response `"No hook callback found for ID: <id>"` (SDK; Swift).

#### `mcp_message`

Carries one JSON-RPC 2.0 message for an in-process (`type: "sdk"`) server.

| Field | Type |
|---|---|
| `subtype` | `"mcp_message"` |
| `server_name` | string (the key in `--mcp-config`) |
| `message` | JSON-RPC request, notification, or response object |

Response: `{"mcp_response": <JSON-RPC response>}`. For a notification (no `id`), the control request still expects an ack: the SDK sends `{"jsonrpc":"2.0","result":{}}`; the Swift client sends `{"jsonrpc":"2.0","id":null,"result":{}}`; both were accepted. Unknown server: JSON-RPC error `-32601` `"Server '<name>' not found"`; handler exception: `-32603` (SDK `_handle_sdk_mcp_request`). Unknown method: Swift returns `-32601 "<method> not supported"`.

JSON-RPC methods observed on this channel (`mcp-tool-call`), in order:

1. `initialize` (id 0):
   ```json
   {"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude-code","title":"Claude Code","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code","version":"2.1.270"}},"jsonrpc":"2.0","id":0}
   ```
   Reply:
   ```json
   {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"checker","version":"1.0.0"}}}
   ```
2. `notifications/initialized` (no id): `{"jsonrpc":"2.0","method":"notifications/initialized"}` → `{"jsonrpc":"2.0","id":null,"result":{}}`.
3. `tools/list` (id 1): `{"method":"tools/list","jsonrpc":"2.0","id":1}` → `{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"check_syntax","description":"Compile a Python file …","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},"annotations":{"readOnlyHint":true}}]}}`. Tool entries may also carry `_meta: {"anthropic/maxResultSizeChars": n}` (Swift `SwiftTool.wire`).
4. `tools/call` (id 2):
   ```json
   {"method":"tools/call","params":{"name":"check_syntax","arguments":{"path":"utils.py"},"_meta":{"claudecode/toolUseId":"toolu_016xLebvbF9JgdLgNZocmxkF","progressToken":2}},"jsonrpc":"2.0","id":2}
   ```
   Reply (MCP CallToolResult): `{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"utils.py: syntax OK"}]}}`. Optional `isError: true` and `structuredContent` (Swift `ToolResult.wire`). Content block kinds the Swift server can return: `text`, `image` (`data`, `mimeType`), `resource` (`resource: {uri, mimeType?, text?, blob?}`), `resource_link` (`uri`, `name`, `description?`, `mimeType?`).
5. `ping`: handled by the Swift client (`ok([:])`), not observed in this fixture set.

`params._meta["claudecode/toolUseId"]` equals the `id` of the `tool_use` block that triggered the call.

---

## 4. Message types on stdout

Every non-control frame has `type`. Frames observed in this fixture set: `system` (subtypes `init`, `thinking_tokens`), `assistant`, `user`, `result`, `rate_limit_event`. Not observed but defined in SDK source: `stream_event`, `conversation_reset`, `transcript_mirror`, and `system` subtypes `task_started`, `task_progress`, `task_notification`, `task_updated`, `hook_started`, `hook_response`, `session_state_changed`. The subtypes `api_retry`, `task_summary`, and `post_turn_summary` do not appear in any fixture or in the SDK source and are not specified here. Unknown types must be skipped, not rejected (SDK `parse_message` default branch).

Common envelope keys on `assistant`, `user`, `system`, `result`, `rate_limit_event`: `uuid` (string), `session_id` (string). `assistant` and `user` add `parent_tool_use_id` (string or null; the Agent tool_use id when the frame comes from a sub-agent) and `timestamp` (ISO 8601).

### 4.1 `system` / `init`

Emitted once per user turn, after the initialize response (and after any sdk-MCP handshake). `multi-turn` shows two `init` lines with the same `session_id`.

```json
{"type":"system","subtype":"init","cwd":"/Users/USER/…/agent-sdk-test","session_id":"77d25949-0743-42ff-b7b8-2322b0dd0f17","tools":["Task","Artifact","Bash","CronCreate","CronDelete","CronList","…(23 more)"],"mcp_servers":[],"model":"claude-fable-5-1","permissionMode":"default","slash_commands":["deep-research","design","…(53 more)"],"terminal_slash_commands":["doctor","color","reload-plugins"],"apiKeySource":"none","claude_code_version":"2.1.270","output_style":"default","agents":["claude","claude-code-guide","Explore","general-purpose","Plan","statusline-setup"],"skills":["deep-research","design","…(18 more)"],"plugins":[],"capabilities":["interrupt_receipt_v1","interrupt_cancel_queued_v1","msg_lifecycle_v1"],"analytics_disabled":false,"product_feedback_disabled":false,"uuid":"54c11a02-49fd-4eb8-b22e-7698f6510cc1","memory_paths":{"auto":"/Users/USER/.claude/projects/…/memory/"},"messaging_socket_path":"/tmp/cc-socks/26519.sock","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required"}
```

| Field | Type | Notes |
|---|---|---|
| `cwd` | string | |
| `session_id` | string | the session id to use on subsequent `user` frames and to `--resume` |
| `tools` | `[string]` | built-in and MCP tool names; MCP tools as `mcp__<server>__<tool>` (`mcp__checker__check_syntax` in `mcp-tool-call`) |
| `mcp_servers` | `[{name, status}]` | `status` observed: `connected`, `needs-auth`; the sdk server appears as `{"name":"checker","status":"connected"}` |
| `model` | string | |
| `permissionMode` | string | |
| `slash_commands` | `[string]` | |
| `terminal_slash_commands` | `[string]` | |
| `apiKeySource` | string | `"none"` |
| `claude_code_version` | string | `"2.1.270"` |
| `output_style` | string | |
| `agents` | `[string]` | |
| `skills` | `[string]` | |
| `plugins` | array | `[]` |
| `capabilities` | `[string]` | `interrupt_receipt_v1`, `interrupt_cancel_queued_v1`, `msg_lifecycle_v1` |
| `analytics_disabled`, `product_feedback_disabled` | bool | |
| `memory_paths` | `{auto: string}` | |
| `messaging_socket_path` | string | `/tmp/cc-socks/<pid>.sock` |
| `fast_mode_state`, `fast_mode_disabled_reason` | string | |

### 4.2 `system` / `thinking_tokens`

Emitted while the model is thinking (`interrupt` fixture, 4 occurrences):

```json
{"type":"system","subtype":"thinking_tokens","estimated_tokens":200,"estimated_tokens_delta":150,"session_id":"912f22ec-…","uuid":"de1f59a8-…"}
```

### 4.3 Other `system` subtypes (SDK source only)

| Subtype | Fields | Source |
|---|---|---|
| `task_started` | `task_id`, `description`, `uuid`, `session_id`, `tool_use_id?`, `task_type?` | SDK message_parser.py |
| `task_progress` | `task_id`, `description`, `usage: {total_tokens, tool_uses, duration_ms}`, `uuid`, `session_id`, `tool_use_id?`, `last_tool_name?` | SDK |
| `task_notification` | `task_id`, `status` ∈ `completed`, `failed`, `stopped`; `output_file`, `summary`, `uuid`, `session_id`, `tool_use_id?`, `usage?` | SDK |
| `task_updated` | `task_id`, `patch` (object; `patch.status` ∈ `pending`, `running`, `paused`, `completed`, `failed`, `killed`), `session_id?`, `uuid?` | SDK |
| `hook_started`, `hook_response` | `hook_event` (or `hook_name` / `hook_event_name`), `session_id?`, `uuid?`; `hook_response` adds `output`, `exit_code`, `outcome` | SDK types.py `HookEventMessage`; requires `--include-hook-events` |
| `session_state_changed` | post-turn marker | SDK query.py `_read_messages` |
| `mirror_error` | `error`, `key`, `uuid`, `session_id` | SDK-synthesized, never emitted by the CLI |

### 4.4 `assistant`

One `assistant` line **per content block**. A single API message with several blocks arrives as several lines sharing `message.id` and `request_id` (`hooks-deny` lines 3 and 7: both `msg_011Cf2ZGkBpmZZAUG8xu2unq`; `interrupt` lines 5-7: thinking, text, tool_use). `stop_reason` is `null` on every observed assistant line; the turn's stop reason is on the `result`.

```json
{"type":"assistant","message":{"model":"claude-fable-5-1","id":"msg_011Cf2ZDDzXsP8NpNjRMCWMa","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01FeJaYqmFb5y9dCRDUcmnh6","name":"Read","input":{"file_path":"/Users/USER/…/utils.py"},"caller":{"type":"direct"}}],"container":null,"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":38810,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":38810},"output_tokens":17,"service_tier":"standard","inference_geo":"not_available"},"diagnostics":null,"context_management":null},"parent_tool_use_id":null,"session_id":"77d25949-…","uuid":"d7c4f8f6-…","timestamp":"2026-09-14T02:38:29.166Z","request_id":"req_011Cf2ZDCHLtRy5x67eb4VtW"}
```

| Field | Type | Notes |
|---|---|---|
| `message.model` | string | |
| `message.id` | string | API message id; shared across the lines of one message |
| `message.type` | `"message"` | |
| `message.role` | `"assistant"` | |
| `message.content` | `[ContentBlock]` | one block per line as observed |
| `message.container`, `stop_reason`, `stop_sequence`, `stop_details`, `diagnostics`, `context_management` | null | all null in fixtures |
| `message.usage` | object | `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `cache_creation: {ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`, `output_tokens`, `service_tier`, `inference_geo` |
| `parent_tool_use_id` | string or null | |
| `session_id`, `uuid`, `timestamp` | string | |
| `request_id` | string | API request id (`req_011…`), distinct from control `request_id`s |
| `tool_use_meta` | `[{id, display_name, server_display_name}]` | present on MCP tool_use lines (`mcp-tool-call` line 9) |
| `narration_block_indexes` | `[int]` | present on a thinking line flagged as narration (`interrupt` line 13) |
| `error` | string | SDK message_parser.py: `authentication_failed`, `billing_error`, `rate_limit`, `invalid_request`, `server_error`, `unknown`; not observed |

### 4.5 `user`

Tool results and CLI-injected user text arrive as `user` frames. `message.content` is either a string (prompt echo; not observed in these fixtures) or an array of blocks.

```json
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01FeJaYqmFb5y9dCRDUcmnh6","type":"tool_result","content":"1\tdef calculate_average(numbers):\n…"}]},"parent_tool_use_id":null,"session_id":"77d25949-…","uuid":"e07b0194-…","timestamp":"2026-09-14T02:38:29.190Z","tool_use_result":{"type":"text","file":{"filePath":"/Users/USER/…/utils.py","content":"def calculate_average…","numLines":10,"startLine":1,"totalLines":10}}}
```

| Field | Type | Notes |
|---|---|---|
| `message.role` | `"user"` | |
| `message.content` | string or `[ContentBlock]` | |
| `parent_tool_use_id`, `session_id`, `uuid`, `timestamp` | | |
| `tool_use_result` | any | the tool's raw structured result: Read → `{type, file:{filePath, content, numLines, startLine, totalLines}}`; Bash → `{stdout, stderr, interrupted, isImage, noOutputExpected}`; Edit → `{filePath, oldString, newString, originalFile, structuredPatch, userModified, replaceAll}`; ToolSearch → `{matches, query, total_deferred_tools}`; AskUserQuestion → `{questions, answers}`; MCP tool → the CallToolResult `content` array; denied/rejected tool → a string (`"Error: rm is blocked by the host"`, `"User rejected tool use"`) |
| `tool_result_meta` | `[{id, non_execution_kind}]` | present when the tool did not run; `non_execution_kind` observed: `"permission-rule"` (hook deny, `hooks-deny`), `"user-rejected"` (interrupt) |
| `origin` | `{kind, …}` | SDK types.py `MessageOrigin`; `kind` ∈ `human`, `channel`, `peer`, `task-notification`, `coordinator`, `unclassified`, `observer`, `auto-continuation`, `observer-activity`; not observed |

Injected user text after an interrupt (`interrupt` line 17): `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null,"session_id":"…","uuid":"…","timestamp":"…"}` (no `tool_use_result`).

### 4.6 Content block shapes

| `type` | Fields | Where |
|---|---|---|
| `text` | `text` | assistant, user |
| `thinking` | `thinking` (may be `""`), `signature` (base64) | assistant (`interrupt`) |
| `tool_use` | `id`, `name`, `input`, `caller: {"type":"direct"}` | assistant; `caller` observed on every tool_use block |
| `tool_result` | `tool_use_id`, `content` (string, or `[{"type":"text","text"}]`, or `[{"type":"tool_reference","tool_name"}]`), `is_error?` (bool; present as `false` on Bash results, `true` on denials, absent on Read results) | user |
| `tool_reference` | `tool_name` | inside a ToolSearch `tool_result.content` array (`mcp-tool-call` line 7) |
| `server_tool_use` | `id`, `name` ∈ `advisor`, `web_search`, `web_fetch`, `code_execution`, `bash_code_execution`, `text_editor_code_execution`, `tool_search_tool_regex`, `tool_search_tool_bm25`; `input` | SDK message_parser.py; not observed |
| `advisor_tool_result` | `tool_use_id`, `content` (object) | SDK message_parser.py; not observed |

### 4.7 `rate_limit_event`

Emitted after API calls when rate-limit state is reported (`simple-turn` lines 4 and 7).

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1789363200,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.19,"resetsAt":1789363200},"seven_day":{"utilization":0.17,"resetsAt":1789822800},"seven_day_overage_included":{"utilization":0.29,"resetsAt":1789822800}}},"uuid":"3dd72b21-…","session_id":"77d25949-…"}
```

| Field | Type | Notes |
|---|---|---|
| `rate_limit_info.status` | `allowed`, `allowed_warning`, `rejected` | SDK `RateLimitStatus` |
| `rate_limit_info.resetsAt` | int (unix seconds) | |
| `rate_limit_info.rateLimitType` | `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `overage` | SDK |
| `rate_limit_info.utilization` | float | SDK; absent at top level in fixtures, present per window |
| `rate_limit_info.overageStatus`, `overageResetsAt`, `overageDisabledReason` | | SDK; `overageStatus`, `overageDisabledReason` observed |
| `rate_limit_info.isUsingOverage` | bool | fixture only |
| `rate_limit_info.unifiedWindows` | `{<window>: {utilization, resetsAt}}` | fixture only |

### 4.8 `stream_event` (SDK only)

With `--include-partial-messages`: `{"type":"stream_event","uuid","session_id","event": <raw Anthropic API stream event>,"parent_tool_use_id"?}` (SDK message_parser.py).

### 4.9 `conversation_reset` (SDK only)

`{"type":"conversation_reset","new_conversation_id","uuid","session_id"}`; running totals on later results restart from zero (SDK types.py).

### 4.10 `transcript_mirror` (SDK only)

With `--session-mirror`: `{"type":"transcript_mirror","filePath","entries":[...]}`; consumed by the SDK's session-store batcher and not yielded to consumers (SDK query.py).

---

## 5. Sequences

Notation: `>` a line the client wrote to stdin; `<` a line the CLI wrote to stdout. Numbers are the actual line numbers in the fixture files.

### 5.1 `simple-turn` (Read auto-approved; `--allowedTools Read,Glob`)

```
> 1  control_request initialize {hooks:null}
< 1  control_response initialize (commands, models, …)
> 2  user {"session_id":"","message":{"role":"user","content":"Read utils.py …"},"parent_tool_use_id":null}
< 2  system init (session_id S)
< 3  assistant tool_use Read
< 4  rate_limit_event
< 5  user tool_result (file contents) + tool_use_result
< 6  assistant text
< 7  rate_limit_event
< 8  result success, num_turns 2, stop_reason end_turn, terminal_reason completed
     (client closes stdin; CLI exits)
```

The user frame written by the client has `session_id: ""` on the first turn; the CLI accepts it.

### 5.2 `multi-turn` (two prompts in one process)

```
> 1  control_request initialize
< 1  control_response initialize
> 2  user (session_id "")
< 2  system init (S)
< 3  assistant tool_use Read
< 4  user tool_result
< 5  rate_limit_event
< 6  assistant text
< 7  result success (result_index 0, num_turns 2)
> 3  user (session_id S) "How many functions does it define? …"
< 8  system init (S again)
< 9  assistant text "2"
< 10 result success (result_index 1, num_turns 1)
```

Per-turn `usage` is for that turn only (turn 2 `input_tokens: 2`); `total_cost_usd` and `modelUsage` accumulate across the process (turn 1 `cacheReadInputTokens` 69585, turn 2 110773 = 69585 + 41188). `result_index` counts results in the process from 0.

### 5.3 `permission-ask` (Edit not allowed; `--permission-mode default --permission-prompt-tool stdio`)

```
> 1  control_request initialize
< 1  control_response initialize
> 2  user "In utils.py, add a guard … Use the Edit tool."
< 2  system init
< 3  assistant tool_use Bash (grep …)          -- no can_use_tool was sent for this Bash call
< 4  rate_limit_event
< 5  user tool_result (Bash) is_error false
< 6  assistant tool_use Read
< 7  user tool_result (Read)
< 8  assistant tool_use Edit
< 9  control_request can_use_tool Edit (permission_suggestions setMode acceptEdits)
> 3  control_response {behavior:"allow", updatedInput: <echo of input>}
< 10 user tool_result "The file … has been updated successfully…" + tool_use_result (structuredPatch)
< 11 assistant text
< 12 result success, num_turns 4, permission_denials []
```

### 5.4 `ask-user-question`

```
> 1  control_request initialize
< 1  control_response initialize
> 2  user "Use AskUserQuestion to ask me whether I prefer 'Brief' or 'Detailed' …"
< 2  system init
< 3  assistant tool_use AskUserQuestion {questions:[{question, header, options:[{label, description}], multiSelect}]}
< 4  control_request can_use_tool AskUserQuestion, requires_user_interaction true, input = same questions
> 3  control_response {behavior:"allow", updatedInput:{questions:<same>, answers:{"<question text>":"<label>"}}}
< 5  user tool_result "Your questions have been answered: \"Do you prefer Brief or Detailed answers?\"=\"Brief\". You can now continue with these answers in mind." + tool_use_result {questions, answers}
< 6  rate_limit_event
< 7  assistant text "Brief answers selected."
< 8  result success, num_turns 2
```

AskUserQuestion input shape:

```json
{"questions":[{"question":"Do you prefer Brief or Detailed answers?","header":"Answer style","options":[{"label":"Brief","description":"Short answers with minimal supporting detail."},{"label":"Detailed","description":"Longer answers with full supporting detail."}],"multiSelect":false}]}
```

Answer shape sent back in `updatedInput`: the original `questions` array plus `answers`, an object keyed by question text whose value is the chosen option label:

```json
{"updatedInput":{"answers":{"Do you prefer Brief or Detailed answers?":"Brief"},"questions":[ ...as received... ]},"behavior":"allow"}
```

### 5.5 `mcp-tool-call` (in-process server `checker`, `--mcp-config {"mcpServers":{"checker":{"name":"checker","type":"sdk"}}}`, `--allowedTools Read,mcp__checker__check_syntax`)

```
> 1  control_request initialize
< 1  control_request mcp_message checker: JSON-RPC initialize (id 0)     -- before the initialize response
> 2  control_response {mcp_response: initialize result}
< 2  control_response initialize
> 3  user "Use the check_syntax tool on utils.py …"
< 3  control_request mcp_message: notifications/initialized
> 4  control_response {mcp_response: {id:null, result:{}}}
< 4  control_request mcp_message: tools/list (id 1)
> 5  control_response {mcp_response: {id:1, result:{tools:[…]}}}
< 5  system init (tools include mcp__checker__check_syntax; mcp_servers include {"name":"checker","status":"connected"})
< 6  assistant tool_use ToolSearch {"query":"select:mcp__checker__check_syntax","max_results":1}
< 7  user tool_result [{"type":"tool_reference","tool_name":"mcp__checker__check_syntax"}] + tool_use_result {matches, query, total_deferred_tools:46}
< 8  rate_limit_event
< 9  assistant tool_use mcp__checker__check_syntax {"path":"utils.py"} (+ tool_use_meta)
< 10 control_request mcp_message: tools/call (id 2, _meta.claudecode/toolUseId = tool_use id, progressToken 2)
> 6  control_response {mcp_response: {id:2, result:{content:[{type:text,text:"utils.py: syntax OK"}]}}}
< 11 rate_limit_event
< 12 user tool_result [{"type":"text","text":"utils.py: syntax OK"}] + tool_use_result (same array)
< 13 assistant text
< 14 result success, num_turns 3
```

The stdin order shows the client wrote the `user` prompt (line 3) between answering `initialize` and receiving `notifications/initialized`; the CLI buffers the prompt until the MCP handshake is done.

### 5.6 `hooks-deny` (PreToolUse matcher `Bash` denies `rm`; PostToolUse matcher null adds context; `--permission-mode acceptEdits`)

```
> 1  control_request initialize {hooks:{PostToolUse:[{matcher:null, hookCallbackIds:[hook_1]}], PreToolUse:[{matcher:"Bash", hookCallbackIds:[hook_0]}]}}
< 1  control_response initialize (hooks_applied true, current_permission_mode acceptEdits)
> 2  user "Run `ls -1 *.py` with Bash, then try `rm -f /tmp/does-not-exist` …"
< 2  system init
< 3  assistant tool_use Bash ls (message id M)
< 4  control_request hook_callback hook_0 PreToolUse Bash ls
> 3  control_response {} (proceed)
< 5  control_request hook_callback hook_1 PostToolUse Bash ls (tool_response, duration_ms 56)
> 4  control_response {hookSpecificOutput:{hookEventName:PostToolUse, additionalContext:"Host note: Bash completed."}}
< 6  user tool_result "agent.py\nutils.py" is_error false
< 7  assistant tool_use Bash rm (same message id M)
< 8  control_request hook_callback hook_0 PreToolUse Bash rm
> 5  control_response {hookSpecificOutput:{hookEventName:PreToolUse, permissionDecision:deny, permissionDecisionReason:"rm is blocked by the host"}}
< 9  rate_limit_event
< 10 user tool_result "rm is blocked by the host" is_error true, tool_use_result "Error: rm is blocked by the host", tool_result_meta [{id, non_execution_kind:"permission-rule"}]
< 11 assistant text
< 12 result success, num_turns 3, permission_denials [{tool_name:"Bash", tool_use_id, tool_input:{command:"rm -f /tmp/does-not-exist", description}}]
```

No PostToolUse callback fired for the denied call. The denied tool's `tool_result.content` is the `permissionDecisionReason` text.

### 5.7 `deferred-tool` (PreToolUse returns `defer`)

```
> 1  control_request initialize {hooks:{PreToolUse:[{hookCallbackIds:[hook_0], matcher:"Bash"}]}}
< 1  control_response initialize (hooks_applied true)
> 2  user "Run `ls -1 *.py` with Bash and report the file names."
< 2  system init
< 3  assistant tool_use Bash ls
< 4  control_request hook_callback hook_0 PreToolUse
> 3  control_response {hookSpecificOutput:{permissionDecision:"defer", permissionDecisionReason:"operator must approve shell commands later", hookEventName:"PreToolUse"}}
< 5  rate_limit_event
< 6  result success, is_error false, num_turns 1, stop_reason "tool_deferred", terminal_reason "tool_deferred", result "", deferred_tool_use {id, name:"Bash", input}
```

No `user` tool_result is emitted for the deferred call. The result has no `api_error_status`, `ttft_ms`, `ttft_stream_ms`, `time_to_request_ms`, or `first_content_frame_ms` keys.

### 5.8 `interrupt` (four `interrupt` requests sent from inside the message loop)

```
> 1  control_request initialize
< 1  control_response initialize
> 2  user "Read every file in this directory one at a time …"
< 2  system init
< 3  system thinking_tokens (50)
< 4  system thinking_tokens (200)
< 5  assistant thinking (message id A)
< 6  assistant text (A)
< 7  assistant tool_use Bash (A)
< 8  rate_limit_event
< 9  user tool_result (Bash)
< 10 system thinking_tokens (50)
< 11 system thinking_tokens (252)
< 12 assistant thinking (message id B)
< 13 assistant thinking (B, narration_block_indexes [0])
< 14 assistant tool_use Read (B)
> 3  control_request interrupt (req_2)
< 15 control_response req_2 {still_queued:[]}
< 16 user tool_result is_error true "The user doesn't want to proceed with this tool use. The tool use was rejected …", tool_use_result "User rejected tool use", tool_result_meta [{non_execution_kind:"user-rejected"}]
< 17 user text "[Request interrupted by user]"
> 4  control_request interrupt (req_3)
< 18 control_response req_3 {still_queued:[]}
< 19 result error_during_execution, is_error true, num_turns 4, stop_reason "tool_use", terminal_reason "aborted_streaming", errors ["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"]
> 5  control_request interrupt (req_4)
< 20 control_response req_4 {still_queued:[]}
> 6  control_request interrupt (req_5)
< 21 control_response req_5 {still_queued:[]}
```

(stdin lines 3-6 were written as the client saw the second and later tool_use lines; exact interleaving with stdout lines 15-21 is by request_id.)

---

## 6. Result message

One `result` per user turn. All keys seen across the eight fixtures:

| Field | Type | Values seen / notes |
|---|---|---|
| `type` | `"result"` | |
| `subtype` | string | `success` (7 fixtures), `error_during_execution` (`interrupt`). SDK also names `error_max_turns`, `error_max_budget_usd` (query.py, types.py) |
| `is_error` | bool | `true` only on `error_during_execution`; an API failure arrives as `subtype: "success"` with `is_error: true`, empty `errors`, and the "API Error: …" prose in `result` (SDK query.py `_error_result_text`) |
| `duration_ms` | int | wall time for the turn |
| `duration_api_ms` | int | |
| `num_turns` | int | API round trips in the turn (`2`, `4`, `1`, `3`) |
| `session_id` | string | |
| `uuid` | string | |
| `stop_reason` | string | `end_turn`, `tool_deferred`, `tool_use` |
| `terminal_reason` | string | `completed`, `tool_deferred`, `aborted_streaming`; SDK also lists `max_turns`, `aborted_tools` |
| `total_cost_usd` | float | cumulative over the process (`multi-turn`) |
| `usage` | object | per-turn: `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`, `output_tokens_details: {thinking_tokens}`, `server_tool_use: {web_search_requests, web_fetch_requests}`, `service_tier`, `cache_creation: {ephemeral_1h_input_tokens, ephemeral_5m_input_tokens}`, `inference_geo`, `iterations: [{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, cache_creation, type:"message", model:null}]`, `speed` |
| `modelUsage` | `{<model id>: ModelUsage}` | cumulative; keys `inputTokens`, `outputTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`, `webSearchRequests`, `costUSD`, `contextWindow`, `maxOutputTokens`, `thinkingTokens`, `canonicalModel`, `provider` (`firstParty`), `costBasis` (`list`). SDK types.py `ModelUsage` lists all but `thinkingTokens` and `costBasis`; `provider` values: `firstParty`, `bedrock`, `vertex`, `foundry`, `anthropicAws`, `anthropicGoogleCloud`, `mantle`, `gateway` |
| `permission_denials` | `[{tool_name, tool_use_id, tool_input}]` | `[]` except `hooks-deny` |
| `result` | string | final assistant text; `""` on the deferred result; absent on `error_during_execution` |
| `errors` | `[string]` | present only on `error_during_execution`: `["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"]` |
| `api_error_status` | int or null | `null` on success results; absent on deferred and interrupted results; HTTP status of the failing call when `is_error` with `subtype: success` (SDK; emitted since CLI 2.1.110) |
| `deferred_tool_use` | `{id, name, input}` | only with `terminal_reason: "tool_deferred"` |
| `structured_output` | any | SDK; not observed (no `--json-schema` in fixtures) |
| `fast_mode_state`, `fast_mode_disabled_reason` | string | `"off"`, `"sdk_opt_in_required"` |
| `subagent_stats` | object | `spawned`, `requested: {background, foreground, unset}`, `started_in_background`, `max_depth`, `spawned_by_subagents`, `completed`, `failed`, `killed: {parent, user, system}`, `refused: {depth_limit, concurrency_limit, budget}`, `by_type: {}` |
| `ttft_ms`, `ttft_stream_ms`, `time_to_request_ms`, `first_content_frame_ms` | int | timing; absent on deferred and interrupted results |
| `queued_turn_count` | int | `0` |
| `result_index` | int | `0`, then `1` for the second turn in a process |
| `origin` | `{kind, …}` | SDK types.py; not observed |

Observed success result (`simple-turn`, `usage.iterations` and `subagent_stats` cut):

```json
{"duration_api_ms":8936,"stop_reason":"end_turn","session_id":"77d25949-…","total_cost_usd":0.8200725,"usage":{"input_tokens":34,"cache_creation_input_tokens":40089,"cache_read_input_tokens":38810,"output_tokens":165,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":40089,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[…],"speed":"standard"},"modelUsage":{"claude-fable-5-1":{"inputTokens":34,"outputTokens":165,"cacheReadInputTokens":38810,"cacheCreationInputTokens":40089,"webSearchRequests":0,"costUSD":0.8200725,"contextWindow":1000000,"maxOutputTokens":64000,"thinkingTokens":0,"canonicalModel":"claude-fable-5-1","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"terminal_reason":"completed","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{…},"is_error":false,"num_turns":2,"subtype":"success","api_error_status":null,"result":"`utils.py` defines two helpers: …","ttft_ms":4951,"type":"result","duration_ms":9382,"uuid":"8f348d4c-…","ttft_stream_ms":4063,"time_to_request_ms":428,"first_content_frame_ms":4063,"queued_turn_count":0,"result_index":0}
```

Observed error result (`interrupt`):

```json
{"duration_api_ms":4805,"stop_reason":"tool_use","session_id":"912f22ec-…","total_cost_usd":0.1863455,"usage":{…,"output_tokens_details":{"thinking_tokens":75},…},"modelUsage":{…},"permission_denials":[],"terminal_reason":"aborted_streaming","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{…},"is_error":true,"num_turns":4,"subtype":"error_during_execution","errors":["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"],"type":"result","duration_ms":9696,"uuid":"d10f636d-…","queued_turn_count":0,"result_index":0}
```

Error text selection (SDK query.py `_error_result_text`, mirrored by Swift `errorText`): join `errors[]` if non-empty; else `result` if non-blank; else `subtype` if not `success`; else `"API error (HTTP <api_error_status>)"`; else `"unknown error"`.

---

### 6.x Interrupt-then-send (steerNow)

A user message written while a turn runs is delivered only at the next model call (`probe-steer-mid-turn`). To make an operator message take effect immediately, send `{"subtype":"interrupt"}`, wait for the turn's `result` (subtype `error_during_execution` with an `[ede_diagnostic]` error; the running tool's `tool_result` is `is_error: true` with `tool_result_meta.non_execution_kind: "user-rejected"` and a `[Request interrupted by user]` user line is injected), then write the new user message. Do not write it before the result: the init capability `interrupt_cancel_queued_v1` means the interrupt discards queued messages. Observed on 2.1.270 (`probe-steer-now`): tool killed at +6 s, new turn complete at +9 s.

## 7. Known behaviors and caveats

1. **Interrupt mid-turn** produces `subtype: "error_during_execution"`, `is_error: true`, `terminal_reason: "aborted_streaming"`, and `errors: ["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"]`. The in-flight tool_use gets a synthetic `user` tool_result with `is_error: true`, `tool_result_meta[].non_execution_kind: "user-rejected"`, followed by a `user` text frame `[Request interrupted by user]`. Each `interrupt` request is answered with `{"still_queued":[]}`, including requests that arrive after the result (`interrupt` fixture). The `init` frame advertises `interrupt_receipt_v1` and `interrupt_cancel_queued_v1`.
2. **ToolSearch precedes deferred MCP tools.** An sdk-server tool is listed in `init.tools` but the model first calls `ToolSearch` with `{"query":"select:mcp__checker__check_syntax","max_results":1}` and receives a `tool_reference` block; only then does it call the MCP tool (`mcp-tool-call`). `tool_use_result.total_deferred_tools` was `46` in that environment.
3. **The sdk-MCP handshake runs before the `initialize` control_response.** The client must handle `mcp_message` requests while its own `initialize` is pending (§3.3).
4. **`mcp_toggle` and `mcp_reconnect` reject `type: "sdk"` servers** with an error control_response whose `error` is `SDK servers should be handled in print.ts` (observed on 2.1.270 in `agent-sdk-test/swift-loop/run.log`, lines `[mcp_toggle] CLI error: …` and `[mcp_reconnect] CLI error: …`; not part of the fixture set).
5. **`-p` mode and stdin.** Reported from earlier sessions, not reproduced in this fixture set: with `-p` and stream-json input, the CLI waits about 3 s for stdin if stdin is neither closed nor piped. The fixtures here never use `-p`; they always pipe stdin and keep it open.
6. **One assistant line per content block.** A single API message is split into several `assistant` lines with the same `message.id` (`hooks-deny` lines 3 and 7; `interrupt` lines 5-7 and 12-14). Consumers that group by message must key on `message.id`, not on line count.
7. **`system`/`init` repeats per turn** with the same `session_id` (`multi-turn`).
8. **Accumulation.** `total_cost_usd` and `modelUsage` are process-cumulative; `usage` is per turn; `result_index` counts from 0 (`multi-turn`).
9. **Empty `session_id` on the first user frame** is accepted; later frames carry the id from `init` (`multi-turn` stdin).
10. **Bash with a read-only command did not trigger `can_use_tool`** under `--permission-mode default --allowedTools Read` (`permission-ask` lines 3-5: `grep -n …` ran without a permission request; Edit did trigger one). The rule that produced this is not in the fixture and is not specified here.
11. **Denied tool result text** equals the hook's `permissionDecisionReason`; `tool_use_result` is `"Error: <reason>"`; `permission_denials` on the result lists the call (`hooks-deny`).
12. **PostToolUse does not fire for a denied call** (`hooks-deny`: two PreToolUse callbacks, one PostToolUse callback).
13. **Deferred tool** ends the turn with `subtype: "success"`, `is_error: false`, `stop_reason` and `terminal_reason` both `"tool_deferred"`, `result: ""`, and `deferred_tool_use`; no tool_result is emitted and the timing keys (`ttft_ms` etc.) and `api_error_status` are absent (`deferred-tool`).
14. **Hook `input` carries keys the SDK does not model**: `scratchpad_dir`, `prompt_id`, `effort: {level}`, and on PostToolUse `duration_ms` (`hooks-deny`, `deferred-tool`).
15. **Raw control characters in strings.** The `initialize` control_response contains a string with an unescaped control character; strict JSON parsers reject the line (§1.2).
16. **`initialize` response envelope** carries `pending_permission_requests` and `pending_user_dialog_requests` beside `response`, not inside it (§3.4).
17. **`hooks_applied: true`** appears in the initialize response only when hooks were registered.
18. **AskUserQuestion is a permission request.** It arrives as `can_use_tool` with `requires_user_interaction: true`; answers go back inside `updatedInput.answers` keyed by question text (`ask-user-question`).
19. **`can_use_tool` is shadowed** by whole-tool `--allowedTools` entries (`Read`, `Read()`, `Read(*)`) and by `--permission-mode bypassPermissions` (SDK types.py `_get_can_use_tool_shadowed_warning`).
20. **Tool result `is_error`** is present as `false` on Bash results, `true` on denials, and absent on Read results; treat absence as `false`.
21. **Thinking blocks may have empty `thinking` text** with a non-empty `signature` (`interrupt`); one of them carried `narration_block_indexes: [0]` on the envelope.
22. **Exit code.** After an `is_error: true` result the CLI exits non-zero; the SDK replaces the resulting ProcessError with a `ResultError` built from the result payload (SDK query.py).

---

## 8. Versioning: recording a new fixture set

Directory layout: `Fixtures/cli/<claude_code_version>/<scenario>/` with `args.json` (pretty-printed argument array, without the executable), `stdin.jsonl` (every line the client wrote), `stdout.jsonl` (every line the CLI wrote), and `meta.json`:

```json
{
  "scenario": "<name>",
  "claude_code_version": "2.1.270",
  "recorded": "2026-09-13",
  "recorder": "agent-sdk-test/swift-loop/recorder/main.swift with ClaudeSession.recordDirectory",
  "cwd_placeholder": "/Users/USER/Library/CloudStorage/OneDrive-Personal/Claude/Kyberna/agent-sdk-test",
  "description": "<one sentence>",
  "scrubbed": ["home directory -> /Users/USER", "email addresses -> user@example.com", "macOS username -> USER"]
}
```

Procedure for a new CLI version `V`:

1. Confirm the version: `claude -v` prints `V`. Create `Fixtures/cli/V/`.
2. Point the recorder at it: in `agent-sdk-test/swift-loop/recorder/main.swift` set `fixturesRoot` to `~/Developer/Kyberna/Fixtures/cli/V`. The recorder resets `utils.py` to the known buggy content before each scenario, builds `SessionOptions` with `recordDirectory` set, `systemPrompt = .append("Be terse.")`, `maxTurns = 8`, and runs the eight scenarios with the prompts and options listed in §5. `ClaudeSession.start()` writes `args.json` and opens `stdin.jsonl`/`stdout.jsonl`; `write()` and `consume()` append every line verbatim.
3. Run all scenarios (`recorder` with no arguments) or a subset (`recorder interrupt mcp-tool-call`). Each scenario is one CLI process.
4. Scrub: replace the home directory with `/Users/USER`, the macOS username with `USER`, and e-mail addresses with `user@example.com` in all four files; write `meta.json` with the date and `claude_code_version: V`. Nothing under `Fixtures/` may contain a real credential or a real channel message (repository rule).
5. Diff against the previous version. Compare key sets, not values, because ids, timestamps, token counts, and model text change on every run:
   - Per frame type and subtype, the set of top-level keys (`type`, `subtype`, and for `result` every key; for `system`/`init` every key; for the `initialize` control_response every key of `response.response` and of the envelope).
   - The set of `control_request` subtypes and, for each, its field names.
   - The set of content block `type`s and their field names.
   - The set of JSON-RPC methods on `mcp_message` and their `params` keys.
   - The ordering skeleton of each scenario (sequence of `type`/`subtype`/block type, ignoring `rate_limit_event` and `thinking_tokens`, which are timing-dependent).
   A small script that loads both versions with `json.loads(line, strict=False)`, walks each line, and prints `type/subtype → sorted keys` per version is sufficient; any key added, removed, or moved (such as the envelope-level `pending_*` keys) is a protocol change.
6. Record the outcome: update the version in the title of this document, add or amend the affected sections, and if the change alters what both ports must do, add an ADR in `docs/decisions/`. The SDK package version tracks the CLI version its fixtures were recorded against, and `minimumClaudeCodeVersion` is enforced at start (`docs/architecture-plan.md` §1.5).
7. Replay: run the conformance tests against the new fixtures through the fake CLI before any live test. Live tests stay tagged `requiresNetwork`.

## 9. Version delta: 2.1.270 to 2.1.271 (recorded 2026-09-14)

Same eight scenarios re-recorded on 2.1.271 under `Fixtures/cli/2.1.271/`. Key-set diff per message type (script in `docs/status/2026-09-14-bootstrap.md` history; method in section 8):

- `assistant` lines gained `wire_tool_inputs`: an object keyed by `tool_use` id holding the raw input the CLI sent to the model, and, for MCP tools, a sibling `tool_use_meta` array with `display_name` and `server_display_name`. `narration_block_indexes` no longer appears. The SDK exposes `AssistantMessage.wireToolInputs`.
- New `system` subtype `permission_denied`: `{"type":"system","subtype":"permission_denied","tool_name","tool_use_id","decision_reason_type","decision_reason","message","uuid","session_id"}`. Observed with `decision_reason_type: "other"` and `decision_reason: "Contains simple_expansion"` when the CLI's own rules refused a Bash command before any host callback. The SDK emits `Message.permissionDenied`.
- Argument lists, `control_request`/`control_response` shapes, `result` keys, `system/init` keys and `capabilities`, and the initialize response keys are unchanged.
- Behavior unchanged on: interrupt (`error_during_execution` + `[ede_diagnostic]`), defer (`deferred_tool_use`), AskUserQuestion answer shape, MCP handshake order.

### 9.x `--replay-user-messages` echoes control responses too (observed 2.1.271, fixture `probe-phase1-exit`)

With `--replay-user-messages`, the CLI writes back on stdout not only each user message the client sent (with its `uuid`) but also each `control_response` the client sent in answer to a CLI `control_request` (same `request_id`, same body), immediately after the client's line. A client must ignore a `control_response` whose `request_id` it did not issue as a request. The fake CLI replays these echoes and waits for the client's answer before emitting them (`FakeCLIRunner`).

### 9.x Effort mid-session, and `set_max_thinking_tokens` (verified 2.1.271)

- There is no `set_effort` control request: `{"subtype":"set_effort"}` returns `error: Unsupported control request subtype: set_effort`.
- Slash commands work as user messages over stream-json. A user message whose content is `/effort low` produces an assistant text `Set effort level to low (this session only): …` and a `result` for that turn; later turns run at that level. The same path should serve `/model`, `/compact`, and the other commands listed in the initialize response, untested beyond `/effort`.
- Observed 2026-09-16 on 2.1.271, on a live engine with a real conversation: the `/effort` exchange is handled by the engine itself, with `"model":"<synthetic>"` on the assistant line and `durationApiMs: 0` on the result, so it costs no model call. The engine process survives the change. The desktop app changes effort on its own engine without restarting it either; its process kept its launch `--effort medium` while the transcript recorded `"effort":"low"` on the turns that followed, and every transcript entry carries `effort` and `perTurnEffort`, so effort is a per-turn property inside the engine. How the desktop app conveys the change was not determined; Kyberna uses the slash command.
- `{"subtype":"set_max_thinking_tokens","max_thinking_tokens":N}` returns `success` (not in the SDK's control subtype list; the binary's engine and remote layers both send it). Effect not measured.

### 9.x `--no-session-persistence` and `rewind_files` (verified 2.1.271)

`--no-session-persistence` is accepted in stream-json mode: no transcript is written and `system/init` still reports a session id. With it, `rewind_files` returns success but restores nothing, because file checkpoints are stored with the session. Tests that exercise rewind must persist and delete their transcript afterwards (`kyb probe phase1-exit` does).

## Delta: 2.1.272 to 2.1.273 (recorded 2026-09-15)

The same eight scenarios, re-recorded against 2.1.273 the day it was released, and the pin moved with them. A
key-set diff over every frame in both sets shows **no difference at all**: the same frame types, the same fields.
Nothing in the SDK or the fixtures changed as a result.

Cadence, decided here: the pin moves when we choose to move it, not because a release exists. Claude Code is
releasing roughly daily, and each move costs a re-recording of eight scenarios. The rule that matters is that the
newest fixture set matches the pinned engine, which `Scripts/bootstrap.sh` checks on every run.

## Delta: 2.1.271 to 2.1.272 (recorded 2026-09-15)

The eight scenarios were re-recorded against 2.1.272 with `kyb record all`, on haiku, and scrubbed with `Scripts/scrub-fixtures.sh` per ADR 0003. The pinned engine moved to 2.1.272 at the same time (`engine.lock`), so the version Kyberna runs is the version its newest fixtures came from.

**No protocol change was found.** A key-set diff over every frame in both sets shows no frame type and no field in 2.1.272 that 2.1.271 did not already have. Three frame types and three fields appear only in the 2.1.271 set, and none of them is a removal:

| Only in the 2.1.271 set | Why |
| --- | --- |
| `transcript_mirror` | recorded by the `probe-session-mirror` fixture, which belongs to that set alone |
| `system/api_retry` | recorded by `auth-failed`, which belongs to that set alone |
| `system/permission_denied` | recorded by `probe-phase1-exit`, which belongs to that set alone |
| `assistant.error`, `assistant.is_api_error_message` | present in a 2.1.271 recording that hit an API error; no 2.1.272 run did |
| `user.isReplay` | present only where `--replay-user-messages` was on, which the eight scenarios do not use |

Recording notes that matter for replay: `kyb record` runs on the test model and without session persistence, so a recording's arguments carry `--model haiku` and `--no-session-persistence`. The replay now takes both from the recording itself rather than from the scenario, which is why a set recorded under the model policy replays unchanged.
