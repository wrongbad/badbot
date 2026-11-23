# Lines

Every line on the bus and in the session file (the kernel's stdout is these
lines rendered by `badbot/show.jq`). Each is one JSON
object on one line, and its first key is `type`: actors route by the start
of the line. Every line is written to the bus file, follows it to `input`,
at the head of the pipeline, passes through every actor and then `tee`, which
appends it to the session and passes it on to `show`. Unknown types are ignored by
everyone.

## From outside

| Line | Put by | Fields | Effect |
|---|---|---|---|
| `hello` | `input`, first | `session`, `provider`, `model` | shown only |
| `send` | `input` (a typed line or a positional prompt), or a command | `content`: string or content blocks; `when`: `turn` (default) or `now` | queued in the inbox |
| `abort` | a command; `input` on Ctrl-C | `jobs`: `true` also kills jobs | the inbox ends the run: provider stopped (`preempt`), calls killed (`cancel`), queue handed back |
| `eof` | `input`, at the end of stdin | | the kernel exits once nothing is left |
| `exit` | `inbox` when done; `input` on Ctrl-C twice within 3 seconds, `SIGTERM` or `SIGHUP` | | every actor stops; `input` stops following the bus |
| `error` | `input` for a bad command; `model` and providers | `where`, `message` | shown only |

## Inbox

| Line | Fields | When |
|---|---|---|
| `queued` | `when`, `n` (queue size) | a `send` is queued |
| `preempt` | | a `now` send, or an `abort`, while the model talks |
| `cancel` | `call` | an `abort` finds the call pending (or a job, with `"jobs":true`), or the call is asked for in an aborted run: the tools kill it |
| `returned` | `content`: the queued blocks | an `abort` finds sends still queued |
| `run_start` | `run` | something is delivered while no run is open |
| `message` | `source`: `inbox`, `results` or `results+inbox`; `run`; `message`: a user message | what is due, delivered: an answer for each call first, in call order (for a job, a note saying so and where its output goes), then queued items (a job's late result is one, as text) |
| `job` | `call` | a pending call goes on as a job because a message was delivered past it (also put by `tools`, below) |
| `continue` | | the model's turn: a user message went in, outside an aborted run |
| `run_end` | `run`; `reason`: `done`, `aborted` or `error` | the model stopped without calls and nothing is due |
| `settled` | | no run, nothing queued, no job |

## Model

| Line | Fields | When |
|---|---|---|
| `turn_start` | `run`, `turn` | `continue` |
| `text_delta`, `thinking_delta`, `tool_use_start`, `tool_use_delta`, … | as the provider writes them | streaming; for display |
| `message` | `source: assistant`; `run`, `turn`, `message` | the provider's `result`; `tool_use` blocks kept only when `stop` is `tool_use`; none when it has no content |
| `turn_end` | `run`, `turn`; `stop`: `end_turn`, `tool_use`, `max_tokens`, `aborted`, `error`…; `usage` | after the message; `error` when the provider gave no result |

## Tools

| Line | Fields | When |
|---|---|---|
| `tool_start` | `call`, `name`, `input` | for each `tool_use` of an assistant message |
| `job` | `call` | the call's `wait` ran out while it still runs |
| `block` | `call`; `block`: its `tool_result`, text `[exit N]` or `[signal N]`, then the output (100 000 bytes at most), plus `name`, `status`, `ran` | the call ended |

## Files

| Path | What |
|---|---|
| `S` | the session: every line on the bus, deltas included |
| `S.d/bus` | the bus: every line said, as said, this run; what `input` follows |
| `S.d/context.jsonl` | the model actor's context: every message, oldest first |
| `S.d/request.json` | the last request sent to a provider |
| `S.d/calls/ID.out` | a call's stdout and stderr, all of it |
| `S.d/calls/ID.pid`, `.status`, `.killed` | its process group, how it ended, and whether it was killed |

## Providers

A provider is a program: `BADBOT_PROVIDER=NAME` runs `badbot/NAME.sh`
once per turn. It reads one line on stdin, the request, which the model actor
also keeps in `S.d/request.json`:

| Field | |
|---|---|
| `model` | `BADBOT_MODEL`, or `""` |
| `session` | the session file's path, `S` |
| `system` | the system prompt: what [`badbot/system-prompt.sh`](../badbot/system-prompt.sh) printed |
| `messages` | the conversation: `{"role":"user"\|"assistant","content":[…]}`, content blocks `text`, `tool_use` (`id`, `name`, `input`) and `tool_result` (`tool_use_id`, `content`, and `name`, `status`, `ran`) |
| `tools` | [badbot/tools.json](../badbot/tools.json): `name`, `description`, `input_schema` |
| `params` | `{}` |

Every `tool_use` is answered by a `tool_result` in the next user message;
for a call that went on as a job, a note, and its result comes later as text.

It writes lines on stdout: anything to show (`text_delta` with `text`,
`error` with `where` and `message`, …), which goes onto the bus as it is, and
last, the one that counts:

| Field | |
|---|---|
| `type` | `result` |
| `stop` | `end_turn`, `tool_use`, `max_tokens`, `aborted`, `error`, … |
| `message` | the assistant message: `role`, and `content`, blocks `text` and `tool_use` |
| `usage` | `input`, `output`, `cache_read`, `cache_write` (tokens) |

On `SIGTERM` it stops, and writes its `result` with `stop: aborted` and what it
has so far. A provider that exits without a `result` ends the turn `error`.
