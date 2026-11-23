#!/usr/bin/env bash
# input: the head of the pipeline, where every line comes in. What is typed
# goes onto the bus: a plain line is a send; a line starting with { is a
# command, put as is with its type first; at the end of stdin, eof. And the bus comes down the pipeline: every event anyone
# says, in order, until exit.
#   echo hi | badbot/input.sh       (run alone: what is typed, to stdout)
. "$(dirname "$0")/lib.sh"

typed() {
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
[[ ${scratch-} ]] && { typed; exit; } # run alone: no bus to follow

put '{type:"hello",session:$s,provider:$p,model:$m}' --arg s "$session" --arg p "$provider" --arg m "$model"
typed <&0 & # beside the bus, while it lasts
typing=$!
exec {bus}< <(exec tail -n +1 -f "$session.d/bus")
tailing=$!

while IFS= read -r -u "$bus" line; do
    printf '%s\n' "$line"
    [[ $line == '{"type":"exit"'* ]] && break
done
kill "$typing" "$tailing" 2>/dev/null # the bus has ended
