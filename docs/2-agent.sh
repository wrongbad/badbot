#!/usr/bin/env bash
# Chapter 2: an agent. When an answer stops for tool_use, run each call, put
# the results in one user message, and ask again, until it stops for anything
# else. One thing at a time: while it works, nobody else can.
#   docs/2-agent.sh [session.jsonl]     BADBOT_PROVIDER, BADBOT_MODEL: as for badbot
badbot=$(cd "$(dirname "$0")/../badbot" && pwd) # the providers, and tools.json
session=${1:-session.jsonl}
provider=$badbot/${BADBOT_PROVIDER:-openai}.sh

# The session to the provider; its text to the screen, its message to the file.
ask() {
    local line
    while IFS= read -r line; do
        case $line in
            '{"type":"text_delta"'*) jq -j .text <<<"$line" ;;
            '{"type":"result"'*)
                jq -c '{type:"message", message}' <<<"$line" >>"$session"
                stop=$(jq -r .stop <<<"$line") ;;
        esac
    done < <(jq -sc --arg m "${BADBOT_MODEL-}" --slurpfile t "$badbot/tools.json" '{model:$m,
        messages:map(select(.type == "message").message), tools:($t[0] | map(del(.program)))}' \
        "$session" | "$provider")
    echo
}

# Every call in the last message, one after another, answered in one message.
run_tools() {
    local call cmd out status
    tail -n1 "$session" | jq -c '.message.content[] | select(.type == "tool_use")' |
        while IFS= read -r call; do
            cmd=$(jq -r .input.command <<<"$call")
            echo "\$ $cmd" >&2
            out=$(bash -c "$cmd" 2>&1 </dev/null)
            status=$?
            jq -nc --argjson c "$call" --arg t "[exit $status]"$'\n'"$out" \
                '{type:"tool_result", tool_use_id:$c.id, is_error:false, content:[{type:"text", text:$t}]}'
        done | jq -sc '{type:"message", message:{role:"user", content:.}}' >>"$session"
}

while IFS= read -r text; do
    jq -nc --arg t "$text" '{type:"message", message:{role:"user", content:[{type:"text", text:$t}]}}' >>"$session"
    ask
    while [[ $stop == tool_use ]]; do run_tools && ask; done
done
