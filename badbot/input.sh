#!/usr/bin/env bash
# input: the head of the pipeline, where every line comes in. What is typed
# goes onto the bus: a plain line is a send; a line starting with { is a
# command, put as is with its type first; a slash command is the command it
# stands for; /usage, the last turn's usage, as is; at the end of stdin, eof. And the bus comes down the pipeline:
# every event anyone says, in order, until exit.
#   echo hi | badbot/input.sh       (run alone: what is typed, to stdout)
. "$(dirname "$0")/lib.sh"

# slash LINE: the command a slash command stands for. A setting's name, alone,
# lists its choices; with a value, sets it ("default": the provider's own).
#   /provider [NAME [MODEL]]   /model [NAME]   /effort [LEVEL]
# A line that does not start with one of these is not a slash command.
slash() {
    [[ $1 =~ ^/(provider|model|effort)([[:space:]]|$) ]] || return 1
    local key=${BASH_REMATCH[1]} w i
    read -ra w <<<"${1#/"$key"}"
    for i in "${!w[@]}"; do [[ ${w[i]} == default ]] && w[i]=; done
    case $key:${#w[@]} in
        *:0) put '{type:"list",key:$k}' --arg k "$key" ;;
        *:1) put '{type:"set"} + {($k):$v}' --arg k "$key" --arg v "${w[0]}" ;;
        provider:2) put '{type:"set",provider:$p,model:$m}' --arg p "${w[0]}" --arg m "${w[1]}" ;;
        *) put '{type:"error",where:"command",message:"/\($k): too many words"}' --arg k "$key" ;;
    esac
}

typed() {
    while IFS= read -r line || [[ $line ]]; do
        case $line in
            '') ;;
            '{'*) line=$(jq -c '{type} + .' <<<"$line" 2>/dev/null) && say "$line" ||
                put '{type:"error",where:"command",message:"invalid JSON"}' ;;
            /usage) put '{type:"usage"} + (($t | fromjson? | .usage) // {})' \
                --arg t "$(grep '^{"type":"turn_end"' "$session" 2>/dev/null | grep '"usage"' | tail -n 1)" ;;
            /*) slash "$line" || put '{type:"send",content:$c}' --arg c "$line" ;;
            *) put '{type:"send",content:$c}' --arg c "$line" ;;
        esac
    done
    say '{"type":"eof"}'
}
[[ ${scratch-} ]] && { typed; exit; } # run alone: no bus to follow

[[ -t 0 ]] && t=true || t=false # a person typing, at a terminal: show.jq gives them a prompt
put '{type:"hello",session:$s,provider:$p,model:$m,typing:$t}' --arg s "$session" --arg p "$provider" --arg m "$model" --argjson t $t
typed <&0 & # beside the bus, while it lasts
typing=$!
exec {bus}< <(exec tail -n +1 -f "$session.d/bus")
tailing=$!

while IFS= read -r -u "$bus" line; do
    printf '%s\n' "$line"
    [[ $line == '{"type":"exit"'* ]] && break
done
kill "$typing" "$tailing" 2>/dev/null # the bus has ended
