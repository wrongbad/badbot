# lib.sh: what every actor shares. Sourced, never run.
#
# An actor is a filter in the kernel's pipeline. Every line it reads it passes
# on to stdout, unchanged; what it has to say, it writes to fd 3, the bus,
# which input.sh, at the head of the pipeline, follows, so every actor sees it
# in its turn. Fd 4 is the bus's lock. In a kernel, both are inherited, and
# the environment says the rest:
#   BADBOT_SESSION  the session file    BADBOT_PROVIDER  NAME: NAME.sh
#                                      BADBOT_MODEL     the model it asks for
# Run alone, an actor needs none of them: fd 3 is stdout, with a lock of its
# own, and the session is a scratch one, removed at exit.

((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 404)) || { echo "badbot: needs bash 4.4 or later" >&2; exit 2; }
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) # badbot/: every script, side by side
tmp=${TMPDIR:-/tmp}
provider=${BADBOT_PROVIDER:-openai} model=${BADBOT_MODEL-}

# pipe FD: an anonymous pipe in fd FD, open for reading and writing. The fifo
# is unlinked at once: nothing to clean up, nothing anyone else can open.
pipe() {
    local f=${tmp%/}/badbot-fifo.$$
    mkfifo "$f" && eval "exec $1<>\"\$f\"" && rm "$f"
}
if [[ -e /dev/fd/3 ]]; then # in a kernel: signals are for input.sh, at the head
    trap '' INT             # Ctrl-C: ignored here, and by all this actor starts
    trap : TERM HUP         # kept going, until the exit input.sh says
else
    exec 3>&1 # run alone: the bus is stdout
fi
[[ -e /dev/fd/4 ]] || { pipe 4 && printf . >&4; } # the bus's lock, holding the one byte
if [[ ${BADBOT_SESSION-} ]]; then
    session=$BADBOT_SESSION
else # run alone: a scratch session in a directory of its own, removed at exit
    scratch=$(mktemp -d "${tmp%/}/badbot-actor-XXXXXX") || exit 2
    readonly scratch # the trap removes this directory and nothing else
    session=$scratch/session.jsonl
    trap 'rm -rf -- "$scratch"' EXIT
fi
mkdir -p "$session.d"

# say LINE: puts one line on the bus. The lock is a pipe holding one byte:
# whoever reads it may write, then puts it back. So a line goes onto the bus
# whole, however long it is and however many actors talk at once.
say() {
    local _
    read -rn1 -u 4 _
    printf '%s\n' "$1" >&3
    printf . >&4
}

# put JQ [JQ-ARGS...]: says the line a jq expression builds.
put() { say "$(jq -nc "${@:2}" "$1")"; }

# join ITEM...: the items, comma-separated: JSON values into an array's insides.
join() { local IFS=,; echo "$*"; }

# bare CMD...: runs CMD, in place of this process, outside this kernel: without
# the bus, its lock, or its session. A badbot it starts is a kernel of its own.
bare() { BADBOT_SESSION= exec "$@" 3>&- 4>&-; }

# deaf CMD...: runs CMD, in place of this process, deaf to Ctrl-C, SIGTERM and
# SIGHUP: plumbing of the pipeline, which must keep going until exit has passed.
deaf() { trap '' INT TERM HUP; exec "$@"; }

CALL='^\{"type":"[a-z_]+","call":"([^"]+)"' # a line about one tool call
