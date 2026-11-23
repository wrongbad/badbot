# Events

Everything that happens in a session is an event: a JSON object whose first
key is `type`. They travel and are kept one per line, so actors route them by
the start of the line. Every event is written to the bus file, follows it to
`input`, at the head of the pipeline, passes through every actor and then
`tee`, which appends it to the session file and passes it on to `show.jq`,
which renders it as the kernel's stdout. Unknown types are ignored by
everyone.

## From outside

| Event | Put by | Fields | Effect |
|---|---|---|---|
| `hello` | `input`, first | `session`, `provider`, `model` | shown: the session's path, to resume it |
| `send` | `input` (a typed line), or a command | `content`: a string, or content blocks (objects with a `type`); `when`: `turn` (default) or `now` | queued in the inbox; with no content, an `error` instead |
| `abort` | a command | `jobs`: `true` also kills jobs, whose results are then dropped | the inbox ends the run: provider stopped (`preempt`), calls killed (`cancel`), what was sent and is still queued handed back |
| `eof` | `input`, at the end of stdin | | the kernel exits once nothing is left |
| `exit` | `inbox` when done, or a command | | every actor stops; `input` stops following the bus |
| `error` | `input` for a bad command; `inbox` for a `send` with nothing to send; `model` and providers | `where`, `message` | shown only |

## Inbox

| Event | Fields | When |
|---|---|---|
| `queued` | `when`, `n` (queue size) | a `send` is queued |
| `preempt` | | a `now` send, or an `abort`, while the model talks |
| `cancel` | `call` | an `abort` finds the call pending (or a job, with `"jobs":true`), or the call is asked for in an aborted run: the tools kill it |
| `returned` | `content`: the blocks of the sends still queued | an `abort` finds sends still queued; jobs' results stay, and go in after |
| `run_start` | `run` | something is delivered while no run is open |
| `message` | `source`: `inbox`, `results` or `results+inbox`; `run`; `message`: a user message | what is due, delivered: an answer for each call first, in call order (for a job, a note saying so and where its output goes), then queued items (a job's late result is one, as text) |
| `hurry` | | a message waits for the turn's calls: the tools give each two more seconds |
| `continue` | | the model's turn: a user message went in, outside an aborted run |
| `run_end` | `run`; `reason`: `done`, `aborted` or `error` | the model stopped without calls and nothing is due |
| `settled` | | no run, nothing queued, no job |

## Model

| Event | Fields | When |
|---|---|---|
| `turn_start` | `run`, `turn` | `continue` |
| `text_delta`, and anything else a provider writes | as the provider writes them | streaming; for display |
| `message` | `source: assistant`; `run`, `turn`, `message` | the provider's `result`; `tool_use` blocks kept only when `stop` is `tool_use`; none when it has no content |
| `turn_end` | `run`, `turn`; `stop`: `end_turn`, `tool_use`, `max_tokens`, `aborted`, `error`…; `usage` | after the message; `error` when the provider gave no result, or one that does not read |

## Tools

| Event | Fields | When |
|---|---|---|
| `tool_start` | `call`, `name`, `input` | for each `tool_use` of an assistant message |
| `job` | `call` | the call still runs when its `wait` runs out, or two seconds after a `hurry` |
| `block` | `call`; `block`: its `tool_result`, text `[exit N]`, `[killed]` (stopped by the kernel) or `[not run]` (no such tool, or no command), then the output (100 000 bytes at most), plus `name`, `status`, `ran` | the call ended |

## Files

| Path | What |
|---|---|
| `S` | the session: every event, deltas included |
| `S.d/bus` | the bus: every event said, as said, this run; what `input` follows |
| `S.d/context.jsonl` | the model actor's context: every message, oldest first |
| `S.d/request.json` | the last request sent to a provider |
| `S.d/calls/ID.out` | a call's stdout and stderr, all of it (in ID, anything but letters, digits, `_` and `-` becomes `_`) |
| `S.d/calls/ID.pid`, `.status`, `.killed`, `.job` | its process, how it ended, whether it was killed, and whether it went on as a job |

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

Every `tool_use` is answered by a `tool_result` in the next user message:
for a call that went on as a job, a note, and its result comes later as text;
for one the session ended before, `[interrupted: …]`.

It writes events on stdout, one per line: anything to show (`text_delta` with `text`,
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
