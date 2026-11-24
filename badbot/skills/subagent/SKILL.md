---
name: subagent
description: Sub-agents: running another badbot (or claude, codex, pi…) as a job — starting one, watching it, steering it, stopping it, continuing it. Read it before handing a task to another agent.
---

# Sub-agents

A sub-agent is just another agent, run with `shell` like any program, usually
as a job. It starts with none of your context, works on its own, and its
result arrives as a message when it exits. Mostly that's another badbot:
`BADBOT` below is `badbot.sh`, two directories above this file.

```
echo "TASK" | BADBOT [SESSION]
```

- `TASK`: the task. Each line of its stdin is a message of its own, so keep it
  to one line, or see below for longer ones.
- `SESSION`: its conversation, one JSON event per line, continued if it
  exists and created if not. Leave it out for a fresh one in `$TMPDIR`; either
  way, its output starts with `session PATH`.
- `BADBOT_PROVIDER`, `BADBOT_MODEL` in the environment pick another provider
  or model; otherwise it uses yours.

It works in your directory (`cd DIR && echo … | BADBOT` for another), with
your environment, and runs commands like you do. Like you, it stops and asks
before anything hard to undo, so its result may end in a question. It exits
once its stdin has ended and it has nothing left to do, its own jobs
included.

Other agents work the same way, as long as they have a command line that
takes a task and exits: `claude -p "…"`, `codex exec "…"`, `pi -p "…"`, and
so on. Run them as a job, `tail` their output, `killtree` them. How each one
keeps and resumes a session is its own; its `--help` will say.

## Starting one

Give it `"wait": 0` so you can keep working; the job's note tells you its
output file and how to stop it.

```json
{"command": "echo 'Run the test suite, fix what fails, and end with a short list of what you changed and why.' | BADBOT", "wait": 0}
```

For a task over several lines, or full of quotes, write it to a file and send
it as one message:

```json
{"command": "jq -Rsc '{type:\"send\", content:.}' task.md | BADBOT", "wait": 0}
```

Several at once is fine: one call each, each with its own session.

## Its result

Its output is what a person would see: `session`, its messages (`agent …`),
its commands and their results. When it exits, all of that arrives as the
job's result (or, past 100000 bytes, where to find it). Asking it to end with
a summary makes the end easy to read with `tail`.

## Watching it

```
tail -n 40 OUTPUT                   # what it says and does
tail -n 3 SESSION | cut -c1-400     # its latest events, in full
jq -r 'select(.type == "message" and .source == "assistant") | .message.content[]
  | select(.type == "text") | .text' SESSION    # everything it has said
```

## Stopping it

Run the `killtree` from its job's note. That ends it and everything it
started, its own commands and sub-agents too. Its result still arrives, as
`exit 143`.

## Steering it, or carrying on

To send it something new, run it again on the same session once the last run
has ended. It picks up where it left off, with everything it knew.

```json
{"command": "echo 'Yes, delete build/. Carry on.' | BADBOT SESSION", "wait": 0}
```

To change course mid-task, stop it, wait for its result, then carry on with
the correction. Just don't run two on one session at the same time: they
trip over each other.
