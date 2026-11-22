# The story of a kernel

An agent kernel, built up from nothing, one idea at a time. Each chapter adds
one thing and says why it was needed. Chapters 0 to 2 are small scripts in
[`story/`](../story); from chapter 3 on, the program is [`akern`](../akern)
itself, read top to bottom.

You need bash 4.4 or later and `jq`. No API key: [`providers/echo`](../providers/echo)
is a stand-in model that echoes you, and asks for shell commands when a line
starts with `!`.

## 0. A session with no one else in it

```bash
#!/usr/bin/env bash
exec tee -a "${1:-session.log}"
```

Run `story/0-tee` and type. Every line comes back to you, and every line is
kept in `session.log`.

This is a chat session with one user in it. It already has the two things
every later chapter keeps:

- **a stream**: lines go in, lines come out, in order;
- **a log**: the file remembers what the stream said. Quit, come back, and
  `cat session.log` is the conversation so far.

Nothing else is needed to have a session. Everything after this is about who
else gets to speak in it.

## 1. Someone to talk to

A model is a program. Not a library, not an SDK: a program that reads one
request line on stdin and writes lines on stdout. akern calls it a
**provider** ([providers.md](../../akern/docs/providers.md) in the C repo):

```
stdin:   {"model":"…","system":…,"messages":[…],"tools":[…]}
stdout:  {"type":"text_delta","text":"Hel"}
         {"type":"text_delta","text":"lo"}
         {"type":"result","stop":"end_turn","message":{"role":"assistant","content":[…]}}
```

Deltas are for the eyes. The `result` is the record: the whole assistant
message, and why it stopped. So the session file stops being plain text and
becomes JSON lines, one message each, and a request is just the file's
messages in order. [`story/1-chat`](../story/1-chat):

```bash
while IFS= read -r text; do
    jq -nc --arg t "$text" '{type:"message", message:{role:"user", content:[{type:"text", text:$t}]}}' >>"$session"
    while IFS= read -r line; do
        case $line in
            '{"type":"text_delta"'*) jq -j .text <<<"$line" ;;
            '{"type":"result"'*) jq -c '{type:"message", message}' <<<"$line" >>"$session" && echo ;;
        esac
    done < <(jq -sc --arg m "${model#*/}" '{model:$m, messages:map(select(.type == "message").message)}' \
        "$session" | "$provider")
done
```

Three ideas live in these lines and never leave:

- **The file is the state.** The context is the session's messages. Resume
  is opening the file again; nothing else is remembered.
- **Route by the start of a line.** Every line is a JSON object whose first
  key is `type`, so `case $line in '{"type":"result"'*)` routes it without
  parsing. A `"` inside a JSON string is always escaped, so that prefix can
  only be structure.
- **A provider is replaceable.** `story/1-chat s.jsonl anthropic/claude-opus-5-5`
  runs akern's compiled provider from `~/.akern/system/providers`; nothing in
  the loop knows which model it talks to.

## 2. Hands

When the model wants to act, its `result` says `stop: tool_use` and its
message holds `tool_use` blocks: `{"type":"tool_use","id":"tu_1","name":"shell","input":{"command":"ls"}}`.
The agent loop is: run them, send back one user message of `tool_result`
blocks, ask again, until the answer stops for anything else.
[`story/2-agent`](../story/2-agent):

```bash
while IFS= read -r text; do
    jq -nc --arg t "$text" '{…user message…}' >>"$session"
    ask
    while [[ $stop == tool_use ]]; do run_tools && ask; done
done
```

`ask` is chapter 1's inner loop; `run_tools` runs each call with `bash -c`
and writes the results message. Try it:

```
$ story/2-agent
!echo hi; date +%Y
$ echo hi
$ date +%Y
The tool said: [exit 0]
```

This is a complete agent, in about forty lines. Most agent harnesses are this
loop with more features bolted on. It is also where they get stuck.

## 3. The wall

Use chapter 2 for real work and the loop shows what it is: **a script that
waits**. It does one thing at a time, and while it does it, it hears nothing.

- You cannot talk while it works. You see it heading the wrong way, and your
  correction waits until the run is over.
- A ten-minute build holds everything. A dev server, which never ends, holds
  it forever.
- Ctrl-C does not stop the turn, it kills the program.
- Two calls in one turn run one after the other.

Each fix you can bolt onto the loop (a timeout here, a background `&` there, a
`trap`) makes the loop longer and its order harder to follow, because **the
loop is the program**: control flow and the conversation are the same thing.

So turn it inside out. Let the main loop do no work at all, only **move
lines**: everyone who has something to say writes a line to one place, and
the loop hands every line to everyone. Who does what becomes a question of
who listens for which line. This is what akern's C kernel now does with its
bus and actors, and the rest of this story is that design, in bash.

## 4. The bus

Open [`akern`](../akern). It needs pipes, and bash makes anonymous pipes only
for pipelines. So:

```bash
pipe() {
    local f=$session.d/fifo.$$
    mkfifo "$f" && eval "exec {$1}<>\"\$f\"" && rm "$f" && fds+=("${!1}")
}
```

A fifo opened for reading *and* writing (`<>`) never blocks on open and never
sees EOF, and once it is unlinked, it is an anonymous pipe in an fd: nothing
left on disk, nothing anyone else can open. `pipe BUS` puts one in `$BUS`.

Everyone writes to the bus with `say`:

```bash
say() {
    local _
    read -rn1 -u "$LOCK" _
    printf '%s\n' "$1" >&"$BUS"
    printf . >&"$LOCK"
}
```

`LOCK` is another pipe, holding one byte. Whoever reads the byte may write;
then they put it back. **A pipe with one byte in it is a mutex.** It matters
because a pipe keeps writes whole only up to `PIPE_BUF` (512 bytes on macOS),
and a tool's output is a lot longer than that: without the lock, two actors
writing at once could splice their lines together.

And the main loop, the whole of it:

```bash
bus() {
    local line fd
    while IFS= read -r -u "$BUS" line; do
        printf '%s\n' "$line" >&"$TO_WRITER"
        [[ $line =~ $DELTA ]] && continue
        for fd in "$TO_INBOX" "$TO_MODEL" "$TO_TOOLS"; do
            printf '%s\n' "$line" >&"$fd"
        done
        [[ $line == '{"type":"exit"'* ]] && return
    done
}
```

One reader, so one order: every actor sees every line in the same sequence,
which is what makes the system easy to reason about. An actor that puts a
line hears it come back, in its place, like everyone else.

The first actor is chapter 0, back again:

```bash
writer() {
    local line log
    exec {log}>>"$session"
    while IFS= read -r line; do
        printf '%s\n' "$line"
        [[ $line =~ $DELTA ]] || printf '%s\n' "$line" >&"$log"
        [[ $line == '{"type":"exit"'* ]] && return
    done
}
```

`tee`, as an actor: every line to stdout, all but the deltas to the session
file. The session is no longer a list of messages but the log of the bus,
and the messages are the lines whose type is `message`.

## 5. Actors

An actor is a function, started in the background with its own pipe as
stdin:

```bash
writer <&"$TO_WRITER" &
inbox  <&"$TO_INBOX" >/dev/null &
model  <&"$TO_MODEL" >/dev/null &
tools  <&"$TO_TOOLS" >/dev/null &
input "$@" <&0 >/dev/null &
bus &
```

Each is the same shape: `while read line; case $line in` the lines it cares
about, a few local variables for state, and `say` for anything it has to
tell. That is the whole contract. Every fd is opened before any actor starts,
so every actor holds every pipe and none ever waits for an EOF: **an actor
ends when it reads the `exit` line**.

There are five:

| Actor | Reads | Says | Job |
|---|---|---|---|
| `input` | stdin | `send`, commands, `eof` | a typed line is a `send`; a line starting with `{` is a command as is |
| `inbox` | `send`, `abort`, assistant `message`, `turn_end`, `job`, `block`, `eof` | `queued`, `run_start`, user `message`, `continue`, `preempt`, `run_end`, `settled`, `exit` | **when**: what is due goes into the conversation, as one user message |
| `model` | `message`, `continue`, `preempt`, `abort` | `turn_start`, the provider's lines, assistant `message`, `turn_end` | **talking**: a user message in means a turn |
| `tools` | assistant `message`, `job`, `block`, `abort` | `tool_start`, `block` | **doing**: each `tool_use` runs, each gets a `block` with its `tool_result` |
| `writer` | everything | stdout, session file | **remembering** |

No actor calls another. The model does not know there are tools: it sees a
user message and asks the provider. The tools do not know there is a model:
they see `tool_use` blocks in an assistant message and run them. The inbox
knows neither: it counts the calls in a message and the blocks that answer
them. They agree only on lines ([lines.md](lines.md)).

The rule that keeps the bus moving: **an actor's loop never does slow work.**
Anything that takes time runs in a *worker*, a background child of the
actor, which `say`s its lines when it has them. The model actor runs the
provider like this:

```bash
exec {from}< <(bare "$provider" <"$request")
pid=$!
relay <&"$from" &
exec {from}<&-
```

`$!` is the provider's pid, kept so the actor can stop it later. `relay` is
the worker: it forwards the provider's lines to the bus, then turns its
`result` into the assistant `message` and `turn_end`. Meanwhile the model
actor is back at `read`, listening. (`bare` runs a program with the kernel's
pipes closed, so nothing it starts can write to the bus.)

Here is one turn, `!ls` typed with the echo provider, as the bus carries it:

```
input   {"type":"send","content":"!ls"}
inbox   {"type":"queued","when":"turn","n":1}
inbox   {"type":"run_start","run":1}
inbox   {"type":"message","source":"inbox","run":1,"message":{"role":"user",…}}
model   {"type":"turn_start","run":1,"turn":1}
relay   {"type":"message","source":"assistant",…{"type":"tool_use","id":"tu_1",…}}
relay   {"type":"turn_end","run":1,"turn":1,"stop":"tool_use",…}
tools   {"type":"tool_start","call":"tu_1","name":"shell",…}
worker  {"type":"block","call":"tu_1","block":{"type":"tool_result",…}}
inbox   {"type":"message","source":"results","run":1,…}
model   {"type":"turn_start","run":1,"turn":2}
relay   {"type":"text_delta",…} … {"type":"message","source":"assistant",…}
relay   {"type":"turn_end","run":1,"turn":2,"stop":"end_turn",…}
inbox   {"type":"run_end","run":1,"reason":"done"}
inbox   {"type":"settled"}
```

Chapter 2's loop is still there, but nobody runs it: it is the shape the
lines take when nothing interrupts them. `inbox` sends a message, `model`
answers, `tools` acts, `inbox` sends the results. Now see what happens when
something does interrupt.

## 6. Talking while it works

Type while a turn streams, and `input` says `send` like any other time. The
inbox queues it (`queued`) and keeps it until the model's `turn_end`; then
everything due goes in as **one** user message: the turn's tool results
first, in call order, then your text (`source: results+inbox`). The model
reads your correction at its very next step, without the run ending.

The decision is a few lines at the top of `deliver`, which the inbox runs
after every line:

```bash
[[ $busy ]] && return # the model is talking: everything waits for its turn_end
if ((${#pending[@]})); then
    [[ ${#queue[@]} -gt 0 && ! $abort ]] || return # wait for the calls
    for id in "${!pending[@]}"; do                 # a message never waits for a call:
        jobs[$id]=1                                # the calls still running go on as jobs
        put '{type:"job",call:$id}' --arg id "$id"
    done
    pending=()
fi
```

And if the turn is waiting on calls, say a slow build, your message does not
wait for them. **A message never waits for a call.** The calls still running
go on as *jobs* (chapter 8), your message goes in at once with whatever
results are already in, and the model answers you. Chapter 3's first two
complaints are gone.

## 7. Pre-emption

Sometimes the next step is too late: the model is mid-answer, going the wrong
way. Send with `when: now`:

```json
{"type":"send","content":"stop, wrong file","when":"now"}
```

The inbox queues it as usual, and since the model is talking, also says
`preempt`. The model actor hears that and signals its provider:

```bash
stop_provider() {
    [[ $pid ]] || return 0
    kill -TERM "$pid" 2>/dev/null
    { sleep 2 && kill -KILL "$pid"; } 2>/dev/null &
}
```

A provider that gets `SIGTERM` writes a `result` with `stop: aborted` and the
text it has so far, and exits. The relay commits that partial reply and says
`turn_end`; the inbox, no longer `busy`, delivers your message; the model
starts a new turn with your words after its own half-sentence. Nothing is
lost and the history stays valid: a pre-empted reply keeps its text but never
its `tool_use` blocks.

This works only because of chapter 5's rule. The provider runs in a worker,
so the actor that owns it is free to hear `preempt` while it streams. In
chapter 2 the loop was inside `ask`, and there was nobody left to listen.

**Abort** is the same move for the whole run. `{"type":"abort"}` on stdin,
or Ctrl-C:

```bash
on_int() {
    ((SECONDS - last_int < 3)) && say '{"type":"exit"}' || say '{"type":"abort"}'
    last_int=$SECONDS
}
trap on_int INT
```

Every background child of a non-interactive bash ignores `SIGINT`, so only
the main shell hears Ctrl-C, and it turns it into a line like everything
else. On `abort` the model stops its provider, the tools kill the turn's
calls (jobs keep running unless the abort says `"jobs":true`), and the inbox
hands back what was queued (`returned`), sends the killed calls' results so
every `tool_use` has its answer, and ends the run `aborted`. Ctrl-C twice
within three seconds says `exit`.

Killing a call has to kill everything it started, so each runs in a process
group of its own:

```bash
{
    set -m
    bare bash -c "$cmd" >"$c.out" 2>&1 </dev/null &
    echo $! >"$c.pid"
    [[ -e $c.killed ]] && kill -TERM -- "-$!"
    wait $!
} 2>/dev/null
```

`set -m` (job control) gives the background command its own group, and
`kill -- -PGID` reaches every process in it. The `.killed` file closes a race:
an abort that arrives before the call has started leaves the file, the call
sees it, and kills itself.

## 8. Jobs

Some commands should not be waited for at all: a dev server, a watcher, a
sub-agent. The shell tool takes `wait`, in seconds:

```
!@shell {"command":"sleep 5; echo server up","wait":0}
```

The call's worker starts a timer next to the command. When the wait runs out
and the command still runs, the timer says `job`. To the inbox, that call no
longer holds the turn back; when nothing else is pending, it says `continue`
and the model goes on at once, with the call open. (A real provider answers
an open call with a placeholder of its own, naming the job and its output
file, `<session>.d/calls/<id>.out`.)

When the job ends, its worker says `block`, the same line as any call. The
inbox sees that the call is no longer pending but a job, and queues its
`tool_result` like a typed message:

```bash
elif [[ ${jobs[$id]-} ]]; then
    unset 'jobs[$id]'; queue+=("$blocks") # a job's late result wakes the model
```

**Every completion wakes the model.** A server that crashes at 3am is a
message, not a silence. And the kernel does not exit while a job runs: `echo
"start the server and run the e2e tests" | akern` waits for the tests.

## 9. Ending

Shutdown is a line too. When stdin ends, `input` says `eof`. The inbox,
each time it has nothing left (no run, nothing queued, no job), says
`settled`, and if `eof` has come, `exit`. Every actor stops on `exit`: the
tools kill what still runs, the model stops its provider, the writer writes
the line and returns, `bus` returns, and the main shell waits for the writer
so that the last line is out before it exits.

## 10. What bash costs

The design is the C kernel's; the bash is about 300 lines of code (390 with
comments), and it runs. Where it is weaker, plainly:

- **Pipe buffers are the queues.** The C bus queues without limit. Here, if
  an actor fell 64 KB behind while blocked in `say`, the bus could block on
  it and it on the bus. Workers keep actors' loops short and deltas go only
  to the writer, so this needs a pathologically slow actor, but it is not
  impossible.
- **Byte at a time.** bash `read` reads a pipe one byte per system call,
  because it cannot put back what it read past the newline. A 100 KB tool
  result is 100 000 `read`s; fine for a conversation, slow for a firehose.
- **jq per line.** Every line that is built or parsed costs a process.
- **Messages are re-serialized.** jq rewrites the provider's message; the C
  kernel stores its bytes untouched, which keeps prompt caches warm and
  signatures intact. jq preserves keys and their order, so in practice the
  difference is whitespace.
- **Less of the protocol.** No entry ids, no `idle` or `deferred` sends, no
  `append`, `status`, `settings` or `reset`; no `job` tool to write to a
  job's stdin; no image results; one `shell` tool. A provider that stays
  between requests is started fresh each turn.
- **Ctrl-C mid-exit** leaves calls unanswered in the session, where the C
  kernel writes a last message with every open call's result.

What it shows is the part that does not depend on the language: one stream,
one order, actors that only react to lines, and slow work pushed into
workers. Once the main loop does nothing but move lines, steering,
pre-emption, aborts and jobs are each a few lines in the actor they concern.
