# Lines

Every line on the bus, on stdout and in the session file. Each is one JSON
object on one line, and its first key is `type`: actors route by the start
of the line. The writer prints every line and stores all but the deltas.
Unknown types are ignored by everyone. Names follow akern's
[protocol](../../akern/docs/akern.md) where the two overlap.

## From outside

| Line | Put by | Fields | Effect |
|---|---|---|---|
| `send` | `input` (a typed line or a positional prompt), or a command | `content`: string or content blocks; `when`: `turn` (default) or `now` | queued in the inbox |
| `abort` | a command, Ctrl-C | `jobs`: `true` also kills jobs | ends the run: provider stopped, calls killed, queue handed back |
| `eof` | `input`, at the end of stdin | | the kernel exits once nothing is left |
| `exit` | `inbox` when done; Ctrl-C twice, `SIGTERM`, `SIGHUP` | | every actor stops |
| `error` | `input` for a bad command; `model` and providers | `where`, `message` | shown only |

## Inbox

| Line | Fields | When |
|---|---|---|
| `queued` | `when`, `n` (queue size) | a `send` is queued |
| `preempt` | | a `now` send while the model talks |
| `returned` | `content`: the queued blocks | an `abort` finds sends still queued |
| `run_start` | `run` | something is delivered while no run is open |
| `message` | `source`: `inbox`, `results` or `results+inbox`; `run`; `message`: a user message | what is due, delivered: call answers first, in call order, then queued items |
| `job` | `call` | a pending call goes on as a job because a message was delivered past it (also put by `tools`, below) |
| `continue` | | every call of the turn went on as a job and nothing is due: the model goes on |
| `run_end` | `run`; `reason`: `done`, `aborted` or `error` | the model stopped without calls and nothing is due |
| `settled` | | no run, nothing queued, no job |

## Model

| Line | Fields | When |
|---|---|---|
| `turn_start` | `run`, `turn` | a user `message` (outside an aborted run) or `continue` |
| `text_delta`, `thinking_delta`, `tool_use_start`, `tool_use_delta`, … | as the provider writes them | streaming; display only, not stored |
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
| `S` | the session: every line but the deltas |
| `S.d/context.jsonl` | the model actor's context: every message, oldest first |
| `S.d/request.json` | the last request sent to a provider |
| `S.d/calls/ID.out` | a call's stdout and stderr, all of it |
| `S.d/calls/ID.pid`, `.status`, `.killed` | its process group, how it ended, and whether it was killed |
