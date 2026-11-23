#!/usr/bin/env bash
# tools: runs every tool call an assistant message asks for, each in a worker.
# Kills one on cancel (the inbox decides which), and all at exit.
#   echo '{"type":"message","source":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"shell","input":{"command":"date"}}]}}' | badbot/tools.sh
. "$(dirname "$0")/lib.sh"

declare -A running=() # call id: its worker's pid
mkdir -p "$session.d/calls"

# A call's files: $c.out (stdout and stderr), $c.pid, $c.status, and $c.killed,
# which kill_call leaves in case the call has not started yet: whichever of the
# two comes second does the killing.
kill_call() {
    local c=$session.d/calls/$1
    touch "$c.killed"
    [[ -s $c.pid ]] && kill -TERM -- "-$(<"$c.pid")" 2>/dev/null
}

# Worker: one call, after its tool_start, to its block. The command runs in a
# process group of its own (set -m), so killing the call kills everything it
# started. Past its wait, a timer says it goes on as a job.
run_call() {
    local id name cmd wait c status timer limit=100000 start=$SECONDS
    { read -r id; read -r name; read -r wait; } < <(jq -r '.id, .name, (.input.wait // "")' <<<"$1")
    cmd=$(jq -r '.input.command // ""' <<<"$1")
    c=$session.d/calls/$id
    : >"$c.out" # there even if the call is killed before it starts
    if [[ $name != shell ]]; then
        echo "no tool named $name" >"$c.out" && status="not run"
    else
        if [[ $wait ]]; then
            { sleep "$wait" & wait $!; [[ -e $c.status ]] || put '{type:"job",call:$id}' --arg id "$id"; } &
            timer=$!
        fi
        {
            set -m
            bare bash -c "$cmd" >"$c.out" 2>&1 </dev/null &
            echo $! >"$c.pid"
            [[ -e $c.killed ]] && kill -TERM -- "-$!"
            wait $!
        } 2>/dev/null
        status=$?
        ((status > 128)) && status="signal $((status - 128))" || status="exit $status"
        echo "$status" >"$c.status"
        [[ ${timer-} ]] && pkill -P "$timer" sleep # the timer's sleep, never the timer: it may hold the lock
    fi
    local size head="[$status]"
    size=$(wc -c <"$c.out")
    ((size > limit)) && head="[$status; cut at $limit of $((size)) bytes, all of it in $c.out]" # $((…)): wc pads
    say "$(head -c "$limit" "$c.out" | jq -Rsc --arg id "$id" --arg name "$name" --arg h "$head" \
        --arg st "$status" --argjson ran $((SECONDS - start)) '{type:"block", call:$id,
        block:{type:"tool_result", tool_use_id:$id, is_error:false,
               content:[{type:"text", text:($h + "\n" + .)}], name:$name, status:$st, ran:$ran}}')"
}

while IFS= read -r line; do
    printf '%s\n' "$line" # pass it on
    case $line in
        '{"type":"message","source":"assistant"'*)
            while IFS= read -r call; do
                put '{type:"tool_start",call:$c.id,name:$c.name,input:$c.input}' --argjson c "$call"
                run_call "$call" >/dev/null & # workers say on fd 3; stdout is the next actor's
                running[$(jq -r .id <<<"$call")]=$!
            done < <(jq -c '.message.content[] | select(.type == "tool_use")' <<<"$line") ;;
        '{"type":"cancel"'*) [[ $line =~ $CALL && ${running[${BASH_REMATCH[1]}]-} ]] && kill_call "${BASH_REMATCH[1]}" ;;
        '{"type":"block"'*) [[ $line =~ $CALL ]] && unset "running[${BASH_REMATCH[1]}]" ;;
        '{"type":"exit"'*)
            for id in "${!running[@]}"; do kill_call "$id"; done
            exit ;;
    esac
done
wait # run alone: let the calls finish
