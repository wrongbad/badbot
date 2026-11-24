#!/usr/bin/env bash
# inbox: the sequencer. Holds what waits to enter the conversation (sends, and
# jobs' late results) and the turn's tool results, and decides when they go
# in: all that is due as one user message, whenever the model is not talking.
# Every call is answered in the next message: one still running, by a note
# that it is now a job. A message never waits for a call: the calls still
# running go on as jobs.
# Opens and closes runs, and decides alone when the model talks (continue) and
# what an abort stops (preempt, cancel), so the other actors hear it in order.
# Says exit once stdin has ended and nothing is left.
#   printf '%s\n' '{"type":"send","content":"hi"}' '{"type":"eof"}' | badbot/inbox.sh
. "$(dirname "$0")/lib.sh"

open= busy= abort= stop= eof= settled=1 # busy: the model is talking
queue=() news=() calls=() # what was sent; jobs' results; the turn's calls, in order
declare -A pending=() results=() jobs=()
run=$(grep -c '^{"type":"run_start"' "$session" 2>/dev/null)

# cancel ID...: the tools kill these calls.
cancel() { for id; do put '{type:"cancel",call:$id}' --arg id "$id"; done; }

# What is due goes in as one user message, or the run ends. Runs after every
# event the inbox cares about.
deliver() {
    [[ $busy ]] && return # everything waits for the model's turn_end
    if ((${#pending[@]})); then
        ((${#queue[@]} + ${#news[@]})) && [[ ! $abort ]] || return # wait for the calls
        for id in "${!pending[@]}"; do # a message never waits for a call:
            jobs[$id]=1                # the calls still running go on as jobs
            put '{type:"job",call:$id}' --arg id "$id"
        done
        pending=()
    fi
    local content=() source=results
    for id in "${calls[@]}"; do # the answers first, in call order; a job's says where its output goes
        [[ ${results[$id]-} ]] || results[$id]=$(jq -nc --arg id "$id" --arg c "$(calls "$id")" '{type:"tool_result",
            tool_use_id:$id, content:[{type:"text", text:"[a job now: its result comes later, in a message of its own. Its output: \($c).out. To stop it: killtree $(<\($c).pid)]"}]}')
        content+=("${results[$id]}")
    done
    calls=() results=()
    if [[ ! $abort ]] && ((${#queue[@]} + ${#news[@]})); then
        ((${#content[@]})) && source=results+inbox || source=inbox
        content+=("${queue[@]}" "${news[@]}") queue=() news=()
    fi
    if ((${#content[@]})); then
        [[ $open ]] || { open=1 settled=; ((run++)); say "{\"type\":\"run_start\",\"run\":$run}"; }
        say "{\"type\":\"message\",\"source\":\"$source\",\"run\":$run,\"message\":{\"role\":\"user\",\"content\":[$(join "${content[@]}")]}}"
    fi
    if [[ $open && ! $abort ]] && ((${#content[@]})); then
        busy=1 stop= # the model answers it
        say '{"type":"continue"}'
        return
    fi
    if [[ $open ]]; then
        local reason=done
        [[ $stop == error ]] && reason=error
        [[ $abort ]] && reason=aborted
        say "{\"type\":\"run_end\",\"run\":$run,\"reason\":\"$reason\"}"
        open= abort= stop=
        ((${#queue[@]} + ${#news[@]})) && { deliver; return; } # due after an abort: a new run
    fi
    ((${#jobs[@]})) && return
    [[ $settled ]] || { settled=1; say '{"type":"settled"}'; }
    [[ $eof == 1 ]] && { eof=2; say '{"type":"exit"}'; }
}

while IFS= read -r line; do
    printf '%s\n' "$line" # pass it on
    case $line in
        '{"type":"send"'*) # content: a string, or blocks; anything else is not sent
            read -r when blocks < <(jq -r '(if .when == "now" then "now" else "turn" end) + " " +
                ([.content | if type == "string" then select(. != "") | {type:"text", text:.}
                  elif type == "array" then .[] | select(type == "object" and (.type | type) == "string")
                  else empty end | tojson] | join(","))' <<<"$line" 2>/dev/null)
            [[ ${blocks-} ]] || { put '{type:"error",where:"send",message:"nothing to send"}'; continue; }
            queue+=("$blocks")
            put '{type:"queued",when:$w,n:$n}' --arg w "$when" --argjson n "${#queue[@]}"
            [[ $when == now && $busy ]] && say '{"type":"preempt"}' ;;
        '{"type":"abort"'*)
            ((${#queue[@]})) && say "{\"type\":\"returned\",\"content\":[$(join "${queue[@]}")]}"
            queue=()
            cancel "${!pending[@]}"
            [[ $line == *'"jobs":true'* ]] && { cancel "${!jobs[@]}"; jobs=(); } # their results are not news
            [[ $busy ]] && say '{"type":"preempt"}'
            [[ $open ]] && abort=1 ;;
        '{"type":"message","source":"assistant"'*)
            while IFS= read -r id; do
                calls+=("$id") pending[$id]=1
                [[ $abort ]] && cancel "$id" # asked for before the provider was stopped
            done < <(jq -r '.message.content[] | select(.type == "tool_use") | .id' <<<"$line") ;;
        '{"type":"turn_end"'*)
            busy=
            [[ $line =~ \"stop\":\"([a-z_]+)\" ]] && stop=${BASH_REMATCH[1]} ;;
        '{"type":"job"'*)
            [[ $line =~ $CALL ]] && id=${BASH_REMATCH[1]} || continue
            [[ ${pending[$id]-} ]] && { unset 'pending[$id]'; jobs[$id]=1; } ;;
        '{"type":"block"'*)
            [[ $line =~ $CALL ]] && id=${BASH_REMATCH[1]} || continue
            if [[ ${pending[$id]-} ]]; then
                unset 'pending[$id]'; results[$id]=$(jq -c .block <<<"$line")
            elif [[ ${jobs[$id]-} ]]; then # its call was answered: its result is news, and wakes the model
                unset 'jobs[$id]'; news+=("$(jq -c '{type:"text", text:"[the job \(.call) has ended] \(.block.content[0].text)"}' <<<"$line")")
            fi ;;
        '{"type":"eof"'*) eof=1 ;;
        '{"type":"exit"'*) exit ;;
        *) continue ;;
    esac
    deliver
done
