# akern-bash

An agent kernel in one bash script: a message bus, and actors for input,
inbox, model, tools and writer, joined by pipes in file descriptors. It
follows the bus-and-actors architecture of [akern](../akern), the C kernel,
and speaks the same provider protocol, so akern's providers run under it
unchanged.

Start with **[docs/story.md](docs/story.md)**: it builds the kernel from a bare
`tee` up, one idea per chapter: a model, tools, the bus, steering,
pre-emption, jobs.

## Try it

Needs bash 4.4 or later (macOS: `brew install bash`) and `jq`.

```bash
./akern | jq --unbuffered -rj -f show.jq
```

Type a line and the echo provider echoes it. Start a line with `!` to make it
ask for shell commands (`!ls; date`); `!@shell {"command":"sleep 5; echo up","wait":0}`
runs one as a background job. While it works, type again, or send
`{"type":"send","content":"stop","when":"now"}` to pre-empt it. Ctrl-C aborts
the run; twice exits. Without `show.jq` you see the raw event lines.

A real model, through akern's installed providers:

```bash
./akern -m anthropic/claude-opus-5-5 | jq --unbuffered -rj -f show.jq
```

One prompt, answer only:

```bash
./akern -m claude-code/sonnet "what is in this directory?" </dev/null | jq -rj 'select(.type == "text_delta").text'
```

## Usage

```
akern [-s session.jsonl] [-m provider/model] [-S system.md] [prompt...]
```

| Flag | Default | |
|---|---|---|
| `-s` | a new `$TMPDIR/akern-session-XXXXXX` | session file; an existing one is resumed |
| `-m` | `$AKERN_MODEL`, else `echo` | provider, from `./providers`, then `$AKERN_HOME/providers`, then `$AKERN_HOME/system/providers` (`AKERN_HOME` defaults to `~/.akern`) |
| `-S` | none | system prompt file |
| `prompt...` | | sent first, as if typed |

Stdin: a plain line is a message; a line starting with `{` is a command
(`send`, `abort`). Stdout and the session file: [docs/lines.md](docs/lines.md).

## Layout

| Path | |
|---|---|
| [`akern`](akern) | the kernel |
| [`story/`](story) | chapters 0–2 of the story, before the bus: `0-tee`, `1-chat`, `2-agent` |
| [`providers/echo`](providers/echo) | a stand-in model, no key needed |
| [`tools.json`](tools.json) | the one tool, `shell` |
| [`show.jq`](show.jq) | the event stream as a person reads it |
