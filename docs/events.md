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
| `hello` | `input`, first | `session`, `provider`, `model`, `typing` (stdin is a terminal: a person types, and gets a prompt) | shown: the session's path, to resume it |
| `send` | `input` (a typed line), or a command | `content`: a string, or content blocks (objects with a `type`); `when`: `turn` (default) or `now` | queued in the inbox; with no content, an `error` instead |
| `set` | `input` (a typed `/provider NAME [MODEL]`, `/model NAME`, `/effort LEVEL`; `default` is `""`), or a command | settings: `provider`, `model`, `effort`, each a string; `""` is the provider's default | `model` changes them, and says `settings`; a provider that differs starts with its defaults for the rest |
| `usage` | `input` (a typed `/usage`) | the last `turn_end`'s `usage`, as is: `input`, `output`, `cache_read`, `cache_write`; none before the first turn | shown: `context`, the sum of `input`, `cache_read` and `cache_write`: how full the context was when that turn started |
| `list` | `input` (a typed `/provider`, `/model`, `/effort`), or a command | `key`: a setting | `model` says its choices: `options` |
| `abort` | a command | `jobs`: `true` also kills jobs, whose results are then dropped | the inbox ends the run: provider stopped (`preempt`), calls killed (`cancel`), what was sent and is still queued handed back |
| `eof` | `input`, at the end of stdin | | the kernel exits once nothing is left |
| `exit` | `inbox` when done, or a command | | every actor stops; `input` stops following the bus |
| `error` | `input` for a bad command; `inbox` for a `send` with nothing to send; `model` for a `set` or `list` it cannot do, and providers | `where`, `message` | shown only |

## Inbox

| Event | Fields | When |
|---|---|---|
| `queued` | `when`, `n` (queue size) | a `send` is queued |
| `preempt` | | a `now` send, or an `abort`, while the model talks |
| `cancel` | `call` | an `abort` finds the call pending (or a job, with `"jobs":true`), or the call is asked for in an aborted run: the tools kill it |
| `returned` | `content`: the blocks of the sends still queued | an `abort` finds sends still queued; jobs' results stay, and go in after |
| `run_start` | `run` | something is delivered while no run is open |
| `message` | `source`: `inbox`, `results` or `results+inbox`; `run`; `message`: a user message | what is due, delivered: an answer for each call first, in call order (for a job, a note saying so and where its output goes), then queued items (a job's late result is one, as text) |
| `job` | `call` | something is due while the turn's calls still run: each goes on as a job at once (also put by `tools`, below) |
| `continue` | | the model's turn: a user message went in, outside an aborted run |
| `run_end` | `run`; `reason`: `done`, `aborted` or `error` | the model stopped without calls and nothing is due |
| `settled` | | no run, nothing queued, no job |

## Model

| Event | Fields | When |
|---|---|---|
| `turn_start` | `run`, `turn` | `continue` |
| `text_delta`, `thinking`, and anything else a provider writes | as the provider writes them | streaming; for display. `thinking`, with no fields: the model starts to think (what it thinks is not shown) |
| `message` | `source: assistant`; `run`, `turn`, `message` | the provider's `result`; `tool_use` blocks kept only when `stop` is `tool_use`; none when it has no content |
| `settings` | `provider`, `model`, `effort` | a `set` changed them: what the next turn asks for. Resuming, the last one is what the session starts with, over the environment. `tools` runs every call with them as `BADBOT_PROVIDER`, `BADBOT_MODEL` and `BADBOT_EFFORT`, so a sub-agent asks the same |
| `options` | `key`, `provider`, `current`, `default`, `choices` | a `list`: the providers (the scripts whose second line says `# NAME: a provider`), or what the provider's `--list` printed |
| `turn_end` | `run`, `turn`; `stop`: `end_turn`, `tool_use`, `max_tokens`, `aborted`, `error`…; `usage` | after the message; `error` when the provider gave no result, or one that does not read |

## Tools

| Event | Fields | When |
|---|---|---|
| `tool_start` | `call`, `name`, `input` | for each `tool_use` of an assistant message |
| `job` | `call` | the call still runs when its `wait` runs out |
| `block` | `call`; `block`: its `tool_result`, text `[exit N]`, `[killed]` (stopped by the kernel) or `[not run]` (no such tool, or no command), then the output; or, for output over 100 000 bytes, only its size, its line count and the file it is in (output that is not text: its size and file), plus `name`, `status`, `ran`; and when the output is too long, `preview`: `lines`, and the `head` and `tail` lines (5 each) for the screen, which the model does not get. A command that succeeds and prints a PNG, JPEG, GIF or WebP image (3 MB at most) gets an `image` block after the text, its header `[exit 0; image/png, N bytes]` | the call ended |

## Files

| Path | What |
|---|---|
| `S` | the session: every event, deltas included |
| `S.d/bus` | the bus: every event said, as said, this run; what `input` follows |
| `S.d/context.jsonl` | the model actor's context: every message, oldest first |
| `S.d/request.json` | the last request sent to a provider |
| `S.d/calls/ID.out` | a call's stdout and stderr, all of it (in ID, anything but letters, digits, `_` and `-` becomes `_`) |
| `S.d/calls/ID.pid`, `.status`, `.killed`, `.job` | its process, how it ended, whether it was killed, and whether it went on as a job |
| `S.d/claude/` | the `claude` provider's: `state.json` (what its `claude` holds), and a directory for the `claude` it keeps: its stdin (a fifo), stdout (`out`), stderr, pid, and the calls it waits on |

## Providers

A provider is a program: `BADBOT_PROVIDER=NAME` runs `badbot/providers/NAME.sh`
once per turn. It reads one line on stdin, the request, which the model actor
also keeps in `S.d/request.json`:

| Field | |
|---|---|
| `model` | the setting: `BADBOT_MODEL`, `/model`, or `""` |
| `effort` | the setting: `BADBOT_EFFORT`, `/effort`, or `""`, the provider's default |
| `session` | the session file's path, `S` |
| `system` | the system prompt: what [`badbot/system-prompt.sh`](../badbot/system-prompt.sh) printed |
| `messages` | the conversation: `{"role":"user"\|"assistant","content":[…]}`, content blocks `text`, `tool_use` (`id`, `name`, `input`) and `tool_result` (`tool_use_id`, `content`, and `name`, `status`, `ran`) |
| `tools` | [badbot/tools.json](../badbot/tools.json): `name`, `description`, `input_schema` |
| `params` | `{}` |

Every `tool_use` is answered by a `tool_result` in the next user message:
for a call that went on as a job, a note, and its result comes later as text;
for one the session ended before, `[interrupted: …]`.

It writes events on stdout, one per line: anything to show (`text_delta` with `text`,
`thinking` when the model starts to think, `error` with `where` and `message`, …), which goes onto the bus as it is, and
last, the one that counts:

| Field | |
|---|---|
| `type` | `result` |
| `stop` | `end_turn`, `tool_use`, `max_tokens`, `aborted`, `error`, … |
| `message` | the assistant message: `role`, and `content`, blocks `text` and `tool_use` |
| `usage` | `input`, `output`, `cache_read`, `cache_write` (tokens) |

On `SIGTERM` it stops, and writes its `result` with `stop: aborted` and what it
has so far. A provider that exits without a `result` ends the turn `error`.

Its second line says it is one, `# NAME: a provider …`, so `/provider` lists it
and may choose it. Run as `NAME.sh --list KEY`, it reads nothing, and prints
the choices for a setting, `model` or `effort`, as
`{"choices":[…],"default":"…"}`, or says why not on stderr and exits non-zero.
A `set` of a choice other than a model must be one it lists, if it lists any.

| Provider | `--list model` | `--list effort` | `effort` is |
|---|---|---|---|
| `openai` | the server's `GET /models`, sorted | `none` to `xhigh` | `reasoning_effort` |
| `anthropic` | the API's `GET /v1/models` | `low` to `max` | `output_config.effort` (else `high`) |
| `claude` | `fable`, `opus`, `sonnet`, `haiku` | `low` to `max` | `--effort` (else `params.effort`) |
| `echo` | none | none | not used |

A provider runs once per turn, but what it starts need not: `claude`
keeps a `claude` process for the session in `S.d/claude`, and ends it when
the model actor, its parent, is gone. Each turn it checks that the request
goes on from what that `claude` holds, and starts a new one, given the whole
conversation, when it does not.

| Provider | `params` it reads |
|---|---|
| `openai` | any: merged into the request body |
| `anthropic` | any: merged into the request body over its defaults (`thinking`, `output_config`, `fallbacks`, `cache_control`, `max_tokens`); `null` leaves a field out |
| `claude` | `effort` (`--effort`), `max_tokens` (`CLAUDE_CODE_MAX_OUTPUT_TOKENS`) |
