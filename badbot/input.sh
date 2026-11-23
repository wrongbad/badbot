#!/usr/bin/env bash
# input: the head of the pipeline, where every line comes in. What is typed
# goes onto the bus: a plain line is a send; a line starting with { is a
# command, put as is with its type first; arguments are a first send; at the
# end of stdin, eof. And the bus comes down the pipeline: every line anyone
# says, in order, until exit. Ctrl-C says abort, and a second within 3 seconds
# exit; SIGTERM and SIGHUP say exit.
#   echo hi | badbot/input.sh       (run alone: what is typed, to stdout)
. "$(dirname "$0")/lib.sh"

typed() {
    (($#)) && put '{type:"send",content:$c}' --arg c "$*"
    while IFS= read -r line || [[ $line ]]; do
        case $line in
            '') ;;
            '{'*) line=$(jq -c '{type} + .' <<<"$line" 2>/dev/null) && say "$line" ||
                put '{type:"error",where:"command",message:"invalid JSON"}' ;;
            *) put '{type:"send",content:$c}' --arg c "$line" ;;
        esac
    done
    say '{"type":"eof"}'
}
[[ ${scratch-} ]] && { typed "$@"; exit; } # run alone: no bus to follow

last_int=-9
on_int() {
    ((SECONDS - last_int < 3)) && { say '{"type":"exit"}'; return; }
    say '{"type":"abort"}'
    echo $'\nPress Ctrl-C again to exit.' >&2
    last_int=$SECONDS
}
trap on_int INT
trap 'say "{\"type\":\"exit\"}"' TERM HUP

put '{type:"hello",session:$s,provider:$p,model:$m}' --arg s "$session" --arg p "$provider" --arg m "$model"
(trap '' INT; typed "$@") <&0 & # beside the bus, while it lasts
typing=$!
while IFS= read -r line; do
    printf '%s\n' "$line"
    [[ $line == '{"type":"exit"'* ]] && break
done < <(deaf tail -n +1 -f "$session.d/bus")
kill "$typing" 2>/dev/null; kill -KILL $! # and tail, deaf to the rest: the bus has ended
