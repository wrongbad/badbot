# badbot

An agent in bash, built as a concurrent actor bus: one pipeline of small
programs, each reacting to the session events it cares about.

```bash
input.sh | inbox.sh | model.sh | tools.sh | tee -a "$session" | show.sh
```

Everything that happens is a session event: what you type, what the model
says, every command and its result. Every event goes past every actor, and an
actor that has something to say puts it on the bus, which feeds the pipeline
again at the head. No part of the program runs the conversation, so nothing
waits on anything else:

- **Talk to it while it works.** What you type reaches the model at its next
  step, without stopping it.
- **Commands run in the background.** A build, a test suite, a server: once
  its wait runs out, or you speak, it goes on as a job. The model goes on too,
  and the job's result wakes it when it ends.
- **Subagents are commands.** Any agent with a command line, badbot included,
  runs as a job: the model starts one, keeps working, and hears back when it
  is done.

## Why not a loop

Most agents are a loop: send the conversation to the model, run the commands
it asks for, send the results back, until it stops asking.
[`docs/2-agent.sh`](docs/2-agent.sh) is one, in 34 lines, that works with a
real model. A loop does one thing at a time, and while it does it, it hears
nothing.

| | A loop | badbot |
|---|---|---|
| You type while it works | waits for the run to end | reaches the model at its next step ([6](#6-talking-while-it-works)) |
| You stop it mid-command | the session cannot go on: a call has no answer | Ctrl-C; run it again on the same session, and it goes on ([7](#7-pre-emption)) |
| A long command | holds everything; a server, forever | goes on as a job, and wakes the model when it ends ([8](#8-jobs)) |
| A subagent | holds the parent until it ends | is a job: the parent keeps working ([8](#8-jobs)) |
| Several commands in one turn | one after another | all at once |

The first and third rows at once, with a real model. You ask about a command
while it runs: it goes on as a job, the model answers you, and the job's
result wakes the model again when it ends. Nobody polls:

<pre>
$ badbot/badbot.sh
<b>session</b> /var/folders/56/…/T/badbot-session-d3kkJl
<b>you</b> can you run sleep 10
<b>bash</b> sleep 10 &amp;&amp; echo done
Is it running?
<b>background</b> sleep 10 &amp;&amp; echo done
<b>agent</b> Yes — the `sleep 10` is running now. It should finish in about 10 seconds and the result will arrive here on its own; I won't poll it.
<b>you</b>
<b>exit 0</b> sleep 10 &amp;&amp; echo done
<b>output</b> done
<b>agent</b> It finished — exit 0, "done". 10 seconds elapsed as expected.
</pre>

What you type mid-run has no label: the terminal shows it as you type, and a
prompt only waits for you between runs.

[The story](#the-story-of-a-kernel), below, builds badbot from a bare `tee`
up, one idea per chapter. It needs bash, `jq`, and `curl` for a real model.

## Try it

Needs bash 4.4 or later (macOS: `brew install bash`), `jq` and `curl`.
Installing is a clone and a symlink. The scripts stay together in the clone,
and only `badbot` goes on your PATH (here `~/.local/bin`; any directory on
your PATH will do):

```bash
git clone https://github.com/wrongbad/badbot.git ~/badbot
ln -s ~/badbot/badbot/badbot.sh ~/.local/bin/badbot
```

`git pull` in the clone updates it; `rm ~/.local/bin/badbot` uninstalls it.
Then:

```bash
export OPENAI_API_KEY=sk-... BADBOT_MODEL=gpt-5   # or OPENAI_MODEL
badbot [session]
```

Or with Claude, by API key or on a Claude subscription, through Claude Code:

```bash
BADBOT_PROVIDER=anthropic ANTHROPIC_API_KEY=sk-ant-... badbot
```

```bash
BADBOT_PROVIDER=claudecode BADBOT_MODEL=opus badbot
```

Type, and it answers. Type again while it works, and it reads you at its next
step, without stopping. Ctrl-C quits at once; Ctrl-D once it is done. It
shows its session file when it starts: give it that file to carry on where
it stopped. The session holds every event: [docs/events.md](docs/events.md)
lists them, and a script can send it commands, as JSON events, on stdin.

| Variable | Default | |
|---|---|---|
| `BADBOT_PROVIDER` | `openai` | [`openai`](badbot/openai.sh): any Chat Completions server, by `OPENAI_BASE_URL`; [`anthropic`](badbot/anthropic.sh): Anthropic's Messages API, by `ANTHROPIC_API_KEY` (and `ANTHROPIC_BASE_URL`); [`claudecode`](badbot/claudecode.sh): the `claude` CLI on your PATH, on your Claude subscription; [`echo`](badbot/echo.sh): a stand-in, no key needed, that echoes you, and asks for shell commands when a line starts with `!` |
| `BADBOT_MODEL` | by provider | the model: for `openai`, `OPENAI_MODEL`; for `anthropic`, `ANTHROPIC_MODEL`, else `claude-opus-5-5`; for `claudecode`, an alias (`fable`, `opus`, `sonnet`, `haiku`) or an id, else Claude Code's default |
| `BADBOT_EFFORT` | by provider | how hard the model thinks: for `anthropic` and `claudecode`, `low`, `medium`, `high`, `xhigh` or `max`; for `openai`, its `reasoning_effort` |

In a session, `/provider`, `/model` and `/effort` list the choices, and with
a name, choose one (`default`: the provider's own). `/provider NAME MODEL`
does both, and a new provider starts with its own defaults. The next step asks
for what was chosen, and the session keeps it: resumed, it goes on with it.
`/model` asks `openai`'s server and Anthropic's API for their models.

<pre>
<b>you</b> /effort
<b>effort</b> anthropic: default (high); choose with /effort NAME, or default
      low  medium  high  xhigh  max
<b>you</b> /effort max
<b>using</b> anthropic, model default, effort max
</pre>

`anthropic` asks for adaptive thinking, high effort, server-side fallbacks and
prompt caching, and retries an overloaded or rate-limited API before any text
comes. `claudecode` keeps one `claude -p` for the session, between turns, and
gives it badbot's tools over MCP (the model sees `mcp__badbot__shell`); Claude
Code's own tools, settings, CLAUDE.md and memory are off. Claude Code adds its
own lines to the system prompt, and thinking arrives without its text.

The system prompt is what [`badbot/system-prompt.sh`](badbot/system-prompt.sh)
prints.

The tests take about ten seconds, with no key and no network (python3 for the
providers' mock server and stand-in `claude`; `-v` for details, names to run some):

```bash
tests/test.sh
```

## The story of a kernel

An agent kernel, built up from nothing, one idea at a time. Each chapter adds
one thing and says why it was needed. Chapters 0 to 2 are small scripts in
[`docs/`](docs), [`0-tee.sh`](docs/0-tee.sh) to [`2-agent.sh`](docs/2-agent.sh);
from chapter 4 on, the program is [`badbot/badbot.sh`](badbot/badbot.sh) and the
actors beside it, each short enough to read whole.

The examples need no API key: they assume `export BADBOT_PROVIDER=echo`, which runs
[`badbot/echo.sh`](badbot/echo.sh), a stand-in model that echoes you, and
asks for shell commands when a line starts with `!`. Without it, the model is
OpenAI's.

### 0. A session with no one else in it

```bash
#!/usr/bin/env bash
exec tee -a "${1:-session.log}"
```

Run `docs/0-tee.sh` and type. Every line comes back to you, and every line is
kept in `session.log`.

This is a chat session with one user in it. It already has the two things
every later chapter keeps:

- **a stream**: lines go in, lines come out, in order;
- **a log**: the file remembers what the stream said. Quit, come back, and
  `cat session.log` is the conversation so far.

Nothing else is needed to have a session. Everything after this is about who
else gets to speak in it. (Keep an eye on this `tee`: it is still there at the
end, as the last stage of the kernel.)

### 1. Someone to talk to

A model is a program. Not a library, not an SDK: a program that reads one
request line on stdin and writes lines on stdout. badbot calls it a
**provider** ([events.md](docs/events.md#providers) has the details):

```
stdin:   {"model":"…","system":…,"messages":[…],"tools":[…]}
stdout:  {"type":"text_delta","text":"Hel"}
         {"type":"text_delta","text":"lo"}
         {"type":"result","stop":"end_turn","message":{"role":"assistant","content":[…]}}
```

Deltas are for the eyes. The `result` is the record: the whole assistant
message, and why it stopped. So the session file stops being plain text and
becomes JSON lines, one message each, and a request is just the file's
messages in order. [`docs/1-chat.sh`](docs/1-chat.sh):

```bash
while IFS= read -r text; do
    jq -nc --arg t "$text" '{type:"message", message:{role:"user", content:[{type:"text", text:$t}]}}' >>"$session"
    while IFS= read -r line; do
        case $line in
            '{"type":"text_delta"'*) jq -j .text <<<"$line" ;;
            '{"type":"result"'*) jq -c '{type:"message", message}' <<<"$line" >>"$session" && echo ;;
        esac
    done < <(jq -sc --arg m "${BADBOT_MODEL-}" '{model:$m, messages:map(select(.type == "message").message)}' \
        "$session" | "$provider")
done
```

Three ideas live in these lines and never leave:

- **The file is the state.** The context is the session's messages. Resume
  is opening the file again; nothing else is remembered.
- **Route by the start of a line.** An event is a JSON object whose first key
  is `type`, and the session file holds one per line, so
  `case $line in '{"type":"result"'*)` routes it without parsing. A `"` inside a JSON string is always escaped, so that prefix can
  only be structure.
- **A provider is replaceable.** `BADBOT_PROVIDER=echo` runs the stand-in;
  unset, it is [`badbot/openai.sh`](badbot/openai.sh), which talks to a real
  model with `curl`; [`anthropic`](badbot/anthropic.sh) and
  [`claudecode`](badbot/claudecode.sh) talk to Claude. Nothing in the loop
  knows which model it talks to.

### 2. Hands

When the model wants to act, its `result` says `stop: tool_use` and its
message holds `tool_use` blocks: `{"type":"tool_use","id":"tu_1","name":"shell","input":{"command":"ls"}}`.
The agent loop is: run them, send back one user message of `tool_result`
blocks, ask again, until the answer stops for anything else.
[`docs/2-agent.sh`](docs/2-agent.sh):

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
$ docs/2-agent.sh
!echo hi; date +%Y
$ echo hi
$ date +%Y
The tool said: [exit 0]
```

This is a complete agent, in about forty lines. Most agent harnesses are this
loop with more features bolted on. It is also where they get stuck.

### 3. The wall

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

So turn it inside out. Let no part of the program run the conversation.
Instead, everything that happens becomes an event, every event goes past
every part, and each part reacts to the events it cares about. Who does what
becomes a question of who listens for which event. The rest of this story is that
design, in bash, where it turns out to be a pipeline.

### 4. The kernel is a pipeline

Here is the whole kernel, as the last line of [`badbot.sh`](badbot/badbot.sh)
runs it, less its paths and flags:

```bash
input.sh | inbox.sh | model.sh | tools.sh | tee -a "$session" | show.sh
```

Every event goes through the inbox, then the model, then the tools, and ends
in chapter 0's `tee`: in the session file, and on your screen, through
[`show.sh`](badbot/show.sh), which runs `jq` with [`show.jq`](badbot/show.jq) to
turn the events into what a person reads. Each actor is a filter that passes every event on, unchanged, and reacts
to the ones it cares about.

A pipeline only flows one way, though, and actors need to speak: the model's
answer has to reach the inbox, upstream of it. So there is one more stream,
the **bus**, which every actor can write to, on fd 3, and which feeds the
head of the pipeline:

```
input.sh | inbox.sh | model.sh | tools.sh | tee
    ^          │          │          │
    └── fd 3 ──┴──────────┴──────────┴── and what is typed
```

An event an actor says goes to the head and comes down the pipeline like any
other, past every actor, including the one that said it. One head, so one
order: every actor sees every event in the same sequence, which is what makes
the system easy to reason about.

The bus is a file. `badbot.sh` opens it before it starts anyone:

```bash
exec 3>"$session.d/bus"    # the bus: fd 3, empty, in every actor
```

Every process the kernel starts inherits fd 3, the way it inherits stdin,
stdout and stderr: **fd 3 is the bus**, by convention, like stdin is fd 0.
And the head of the pipeline, [`input.sh`](badbot/input.sh), follows the
file as it grows, and passes each event down, until the last:

```bash
exec {bus}< <(exec tail -n +1 -f "$session.d/bus")
while IFS= read -r -u "$bus" line; do
    printf '%s\n' "$line"
    [[ $line == '{"type":"exit"'* ]] && break
done
```

Why a file, and not a pipe? A pipe is a queue with a limit, 64 KB on macOS,
and a full pipe makes its writer wait. Here that is a trap. Say a worker
writes a 100 KB tool result onto a bus that is a pipe. The head copies it
down the pipeline, which backs up at the tools actor; but the tools actor is
not reading, it is waiting to say an event of its own, and the worker holds the
bus until its write is done. Each waits for the other, and the kernel stops.
A file never fills: whoever says an event waits only for the disk, never for
an actor, however long the event and however slow the actor. **The file is the
queue, and it has no limit.** (It is also a record of the bus, kept in the
session's directory.)

Everyone writes to it with `say`, from [`badbot/lib.sh`](badbot/lib.sh):

```bash
say() {
    local _
    read -rn1 -u 4 _
    printf '%s\n' "$1" >&3
    printf . >&4
}
```

Fd 4 is the bus's lock: a pipe holding one byte. Whoever reads the byte may
write; then they put it back. **A pipe with one byte in it is a mutex.** It
matters because a long event is written in pieces, and without the lock, two
actors writing at once could splice their events together. bash makes
anonymous pipes only for pipelines, so the lock is a fifo, opened for reading
and writing and unlinked at once: an anonymous pipe in an fd.

```bash
pipe() {
    local f=${tmp%/}/badbot-fifo.$$
    mkfifo "$f" && eval "exec $1<>\"\$f\"" && rm "$f"
}
[[ -e /dev/fd/4 ]] || { pipe 4 && printf . >&4; } # the bus's lock, holding the one byte
```

`lib.sh` is sourced by every actor, and by `badbot.sh`, which is where the
kernel's lock is made; every actor inherits it. One that runs alone, with no
fd 3 or 4, gets its own: stdout as its bus, and a lock. So an actor runs
alone as it runs in the kernel.

That is the whole of the machinery: a file, a lock, and a pipeline.

### 5. Actors are filters

An actor is a program in [`badbot/`](badbot). Each has the same shape:

```bash
while IFS= read -r line; do
    printf '%s\n' "$line" # pass it on
    case $line in
        '{"type":"…"'*) … say '{"type":"…"}' ;;
    esac
done
```

Read an event, pass it on, react if it is yours, say what you have to say. A
few variables hold the actor's state. That is the whole contract, and it
means an actor runs on its own, with no kernel: outside one, fd 3 is stdout,
so you see its events among the ones it passes on.

```
$ printf '%s\n' '{"type":"send","content":"hi"}' '{"type":"eof"}' | badbot/inbox.sh
{"type":"send","content":"hi"}
{"type":"queued","when":"turn","n":1}
{"type":"run_start","run":1}
{"type":"message","source":"inbox","run":1,"message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
{"type":"continue"}
{"type":"eof"}
```

And because they are filters, they chain by hand. Half a kernel, one turn of
a conversation:

```
$ echo '{"type":"send","content":"hi"}' | badbot/inbox.sh | badbot/model.sh
… queued, run_start, the user message, turn_start, text_delta…, the assistant message, turn_end
```

There are four:

| Actor | Listens for | Says | Its job |
|---|---|---|---|
| [`input`](badbot/input.sh) | the bus; stdin | `hello`; `send`, commands, `eof` | the head: every event comes in here. A typed line is a `send`; a line starting with `{` is a command as is |
| [`inbox`](badbot/inbox.sh) | `send`, `abort`, assistant `message`, `turn_end`, `job`, `block`, `eof` | `queued`, `error`, `returned`, `run_start`, user `message`, `continue`, `job`, `preempt`, `cancel`, `run_end`, `settled`, `exit` | **when**: what is due goes into the conversation, as one user message, and when the model talks |
| [`model`](badbot/model.sh) | `run_start`, `message`, `continue`, `preempt`, `turn_end`, `exit` | `turn_start`, the provider's events, assistant `message`, `turn_end` | **talking**: `continue` means a turn |
| [`tools`](badbot/tools.sh) | assistant `message`, `job`, `cancel`, `block`, `exit` | `tool_start`, `job`, `block` | **doing**: each `tool_use` runs, each gets a `block` with its `tool_result` |

No actor calls another, and none knows the others exist. The model does not
know there are tools: told to `continue`, it asks the provider with the
messages it has seen. The tools
do not know there is a model: they see `tool_use` blocks in an assistant
message and run them. The inbox knows neither: it counts the calls in a
message and the blocks that answer them. They agree only on events
([events.md](docs/events.md)). The order of the pipeline does not matter for the
same reason: what one actor says reaches the others through the bus.

The rule that keeps the pipeline moving: **an actor's loop never does slow
work.** An actor that stops reading stops every actor after it. Anything that
takes time runs in a *worker*, a background child that `say`s its events on
fd 3 when it has them. The model actor runs the provider like this:

```bash
exec {from}< <(bare "$provider" <"$request")
pid=$!
relay <&"$from" >/dev/null &
exec {from}<&-
```

`$!` is the provider's pid, kept so the actor can stop it later. `relay` is
the worker: it says the provider's events, then turns its `result` into the
assistant `message` and `turn_end`. Meanwhile the model actor is back at
`read`, listening. A worker's stdout goes to `/dev/null`: it speaks only on
the bus, and must not hold the next actor's pipe open. (`bare` runs a program
outside the kernel: fds 3 and 4 closed and no session, so nothing it starts
can write to the bus, and a badbot it starts, a subagent, is a kernel of its
own.)

Here is one turn, `!ls` typed with the echo provider, as the bus carries it:

```
input   {"type":"send","content":"!ls"}
inbox   {"type":"queued","when":"turn","n":1}
inbox   {"type":"run_start","run":1}
inbox   {"type":"message","source":"inbox","run":1,"message":{"role":"user",…}}
inbox   {"type":"continue"}
model   {"type":"turn_start","run":1,"turn":1}
relay   {"type":"message","source":"assistant",…{"type":"tool_use","id":"tu_…_1",…}}
relay   {"type":"turn_end","run":1,"turn":1,"stop":"tool_use",…}
tools   {"type":"tool_start","call":"tu_…_1","name":"shell",…}
worker  {"type":"block","call":"tu_…_1","block":{"type":"tool_result",…}}
inbox   {"type":"message","source":"results","run":1,…}
inbox   {"type":"continue"}
model   {"type":"turn_start","run":1,"turn":2}
relay   {"type":"text_delta",…} … {"type":"message","source":"assistant",…}
relay   {"type":"turn_end","run":1,"turn":2,"stop":"end_turn",…}
inbox   {"type":"run_end","run":1,"reason":"done"}
inbox   {"type":"settled"}
```

Chapter 2's loop is still there, but nobody runs it: it is the shape the
events take when nothing interrupts them. The inbox sends a message, the model
answers, the tools act, the inbox sends the results. Now see what happens
when something does interrupt.

### 6. Talking while it works

Type while a turn streams, and `input` says `send` like any other time. The
inbox queues it (`queued`) and keeps it until the model's `turn_end`; then
everything due goes in as **one** user message: the turn's tool results
first, in call order, then your text (`source: results+inbox`). The model
reads your correction at its very next step, without the run ending.

The decision is a few lines at the top of `deliver`, which the inbox runs
after every event:

```bash
[[ $busy ]] && return # everything waits for the model's turn_end
if ((${#pending[@]})); then
    ((${#queue[@]} + ${#news[@]})) && [[ ! $abort ]] || return # wait for the calls
    for id in "${!pending[@]}"; do # a message never waits for a call:
        jobs[$id]=1                # the calls still running go on as jobs
        put '{type:"job",call:$id}' --arg id "$id"
    done
    pending=()
fi
```

And if the turn is waiting on calls, say a slow build, your message does not
wait for them. **A message never waits for a call.** The calls still running
go on as *jobs* (chapter 8), the ones that ended give their results, and the
model reads your message with them. You speak up because something is going
the wrong way, so it is read at once. Chapter 3's first two complaints are
gone.

### 7. Pre-emption

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
    { sleep 2 && kill -KILL "$pid"; } >/dev/null 2>&1 &
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

**Abort** is the same move for the whole run: `{"type":"abort"}` on stdin.
Only the inbox acts on `abort`. It hands back what was queued
(`returned`), says `preempt` if the model is talking, and `cancel` for each
call of the turn (and each job, if the abort says `"jobs":true`), which the
tools kill. Then it sends the killed calls' results, so every `tool_use` has
its answer, and ends the run `aborted`.

Why only the inbox? Because each actor sees an event at its own moment. Type a
line and abort at once: the inbox reads the `send`, opens a run and says
`run_start`, the message and `continue`, and only then reads the `abort`. But
its events join the back of the bus, so the model and the tools see the
`abort` *before* the run it aborts. An actor that judged the abort on its own
would judge the wrong run: the model would start the turn anyway, the tools
would run its calls to the end. So the inbox decides, and the others follow
events that come after the ones they concern: `preempt` after `continue`,
`cancel` after the `tool_use` it names. A call asked for after the abort, by
a provider that finished just before it was stopped, gets its `cancel` as it
arrives. **One actor decides; the others hear decisions in order.**

Killing a call has to kill everything it started, so the tools kill it as a
tree, with `killtree` from `lib.sh`. It lists the tree first, parents before
children, then sends the whole list `SIGTERM`, and two seconds later
`SIGKILL`: whatever was in it, deaf to `SIGTERM` or orphaned since, goes.

```bash
killtree() {
    local pids=("$@") i
    kill -0 "$@" || return
    for ((i = 0; i < ${#pids[@]}; i++)); do pids+=($(pgrep -P "${pids[i]}")); done
    kill -TERM "${pids[@]}" 2>/dev/null
    { sleep 2; kill -KILL "${pids[@]}"; } >/dev/null 2>&1 &
}
export -f killtree
```

`export -f` puts the function in the environment, so every call's `bash`
has it too, and the model can stop a job itself, a sub-agent included: a
`kill` of one pid would stop only that process, and leave a pipeline's others,
or a sub-agent's actors, running.

The call's `.killed` file closes a race: a `cancel` that arrives before the
call has started leaves the file, the call sees it, and kills itself.

**Ctrl-C** quits, and nothing in badbot catches it. It goes to every process
in the terminal's foreground, which is the whole kernel: the actors, the
provider, the plumbing, and the calls, which run in the kernel's process
group too. Each one ends, as any program does. A closed terminal is the same,
by `SIGHUP`. Only what a command puts in the background itself, with `&`,
outlives Ctrl-C: bash makes such commands ignore it, in badbot as in any
script. A closed terminal ends them too.

What is left is the conversation, with calls that were never answered, which
no model's API accepts. So when the model actor builds a request, every
`tool_use` without an answer in the next message gets one: `[interrupted: the
session ended before this call did]`. Run badbot again on the same session,
and it goes on from where it stopped.

### 8. Jobs

Some commands should not be waited for at all: a dev server, a watcher, a
sub-agent. The shell tool takes `wait`, in seconds:

```
!@shell {"command":"sleep 5; echo server up","wait":0}
```

The call's worker starts a timer next to the command. When the wait runs out
and the command still runs, the timer says `job`. To the inbox, that call no
longer holds the turn back. But every call still gets its answer in the next
message, as every model API requires; a job's answer is a note:

```bash
[[ ${results[$id]-} ]] || results[$id]=$(jq -nc … '{type:"tool_result", tool_use_id:$id,
    content:[{type:"text", text:"[a job now: its result comes later, in a message of its own. Its output: \($c).out. To stop it: killtree $(<\($c).pid)]"}]}')
```

So the model goes on at once, knowing the call runs, where its output is
(`<session>.d/calls/<id>.out`), and how to stop it.

When the job ends, its worker says `block`, the same event as any call. The
inbox sees that the call is no longer pending but a job. Its call has been
answered, so its result is news, and is queued as text, like a typed message:

```bash
elif [[ ${jobs[$id]-} ]]; then # its call was answered: its result is news, and wakes the model
    unset 'jobs[$id]'; queue+=("$(jq -c '{type:"text", text:"[the job \(.call) has ended] …"}' <<<"$line")")
```

**Every completion wakes the model.** A server that crashes at 3am is a
message, not a silence. And the kernel does not exit while a job runs: `echo
"start the server and run the e2e tests" | ./badbot/badbot.sh` waits for the tests.

A sub-agent is the same: `echo "its task" | badbot.sh`, as a job. It needs
nothing new, only the tools a job already has: its output file to `tail`,
its session to read, `killtree` to stop it, and badbot's own resume to
continue it, or to steer it once it is stopped. How to use them is a skill,
[`badbot/skills/subagent/SKILL.md`](badbot/skills/subagent/SKILL.md): a file
the system prompt lists, by name and description, for the model to read when
it needs it. Each directory in `badbot/skills/` with a `SKILL.md` is one.

### 9. Ending

Shutdown is an event too. When stdin ends, `input` says `eof`. The inbox, each
time it has nothing left (no run, nothing queued, no job), says `settled`,
and if `eof` has come, `exit`. Each actor passes `exit` on, cleans up (the
tools kill what still runs, the model stops its provider) and ends. The
head, `input`, ends after it, so the end of input runs down the pipeline
like the last event did, and when it reaches `tee`, the kernel is done.

### 10. What bash costs

It runs: about 300 lines of code in the kernel and its actors (the providers
and the system prompt aside), 5 of them in `badbot.sh` itself. It is
built to be read, not to be fast, and where it is weaker, plainly:

- **Every event goes through every actor**, read a byte at a time: bash `read`
  takes one system call per byte from a pipe, because it cannot put back what
  it read past the newline. Fine for a conversation; slow for a firehose.
- **The queue is a file.** The bus goes to disk and back (`<session>.d/bus`):
  one more copy of every event, and `tail -f` to follow it.
- **jq per event.** Every event that is built or parsed costs a process.
- **The session keeps the deltas.** It is the whole bus, as `tee` saw it,
  every streamed piece of text as well as the message it adds up to.
- **One tool, text only.** `shell` is the only tool, results are text, and
  there is no way to write to a job's stdin. A provider is started fresh each
  turn, with the whole conversation (`claudecode` keeps its `claude` between
  turns, so that Claude Code's prompt cache holds, and gives it only what is new).

What it shows is the part that does not depend on the language: one stream,
one order, actors that only react to events, and slow work pushed into
workers. Once no part of the program runs the conversation, steering,
pre-emption, aborts and jobs are each a few lines in the actor they concern.
