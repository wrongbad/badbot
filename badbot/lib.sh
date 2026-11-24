# lib.sh: what every actor shares. Sourced, never run.
#
# An actor is a filter in the kernel's pipeline. Every event it reads it passes
# on to stdout, unchanged; what it has to say, it writes to fd 3, the bus,
# which input.sh, at the head of the pipeline, follows, so every actor sees it
# in its turn. Fd 4 is the bus's lock. In a kernel, both are inherited, and
# the environment says the rest (BADBOT_SESSION set means: in a kernel):
#   BADBOT_SESSION  the session file    BADBOT_PROVIDER  NAME: NAME.sh
#                                      BADBOT_MODEL     the model it asks for
#                                      BADBOT_EFFORT    how hard it thinks
# Run alone, an actor needs none of them: fd 3 is stdout, with a lock of its
# own, and the session is a scratch one, removed at exit.

((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 404)) || { echo "badbot: needs bash 4.4 or later" >&2; exit 2; }
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) # badbot/: every script, side by side
tmp=${TMPDIR:-/tmp}
provider=${BADBOT_PROVIDER:-openai} model=${BADBOT_MODEL-} effort=${BADBOT_EFFORT-}

# pipe FD: an anonymous pipe in fd FD, open for reading and writing. The fifo
# is unlinked at once: nothing to clean up, nothing anyone else can open.
pipe() {
    local f=${tmp%/}/badbot-fifo.$$
    mkfifo "$f" && eval "exec $1<>\"\$f\"" && rm "$f"
}
if [[ ${BADBOT_SESSION-} ]]; then # in a kernel: badbot.sh says so, and opened the bus
    session=$BADBOT_SESSION
    { : >&3; } 2>/dev/null || { echo "badbot: ${0##*/} has no bus (fd 3)" >&2; exit 2; }
else # run alone: the bus is stdout, and the session a scratch one, removed at exit
    exec 3>&1
    scratch=$(mktemp -d "${tmp%/}/badbot-actor-XXXXXX") || exit 2
    readonly scratch # the trap removes this directory and nothing else
    session=$scratch/session.jsonl
    trap 'rm -rf -- "$scratch"' EXIT
fi
{ : <&4; } 2>/dev/null || { pipe 4 && printf . >&4; } # the bus's lock, holding the one byte
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

# killtree PID...: ends each process and everything it started. The whole tree
# gets SIGTERM, parents first, so none starts another, and 2 seconds on,
# SIGKILL: what was in it, even if deaf to SIGTERM or orphaned since. Exported,
# so every call can run it too: on a job, a sub-agent, anything.
killtree() {
    local pids=("$@") i
    kill -0 "$@" || return
    for ((i = 0; i < ${#pids[@]}; i++)); do pids+=($(pgrep -P "${pids[i]}")); done
    kill -TERM "${pids[@]}" 2>/dev/null
    { sleep 2; kill -KILL "${pids[@]}"; } >/dev/null 2>&1 &
}
export -f killtree

# bare CMD...: runs CMD, in place of this process, outside this kernel: without
# the bus, its lock, or its session. A badbot it starts is a kernel of its own.
bare() { BADBOT_SESSION= exec "$@" 3>&- 4>&-; }

CALL='^\{"type":"[a-z_]+","call":"([^"]+)"' # an event about one tool call

# calls ID: where a call's files go, $(calls ID).out and the rest. An id comes
# from a model: anything but letters, digits, _ and - becomes _.
calls() { echo "$session.d/calls/${1//[^A-Za-z0-9_-]/_}"; }
