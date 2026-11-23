#!/usr/bin/env bash
# model: asks the model. A turn starts when the inbox says continue, and runs
# the provider in a worker, so the actor keeps listening and can stop it on
# preempt. Keeps the context: every message it has seen.
#   printf '%s\n' '{"type":"message","source":"inbox","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' '{"type":"continue"}' | badbot/model.sh
. "$(dirname "$0")/lib.sh"

run=0 turn=0 pid= # pid: the provider of the turn in flight
ctx=$session.d/context.jsonl
system=$("$here/system-prompt.sh")
jq -Rc 'fromjson? | select(.type == "message") | .message' "$session" >"$ctx" 2>/dev/null # resuming: the file is the state

# Every tool_use is answered in the message after it. A session that ended
# while calls ran never answered them: they are answered here, as interrupted.
answered='
    def interrupted($ids): [$ids[] | {type:"tool_result", tool_use_id:.,
        content:[{type:"text", text:"[interrupted: the session ended before this call did]"}]}];
    def answered: reduce .[] as $m ({out:[], open:[]};
        .open as $open
        | ($m.content | if type == "string" then [{type:"text", text:.}] else . end) as $c
        | if $m.role == "user" then
              ([$c[] | select(.type == "tool_result") | .tool_use_id]) as $have
              | .out += [$m | .content = interrupted($open - $have) + $c] | .open = []
          else
              (if $open == [] then . else .out += [{role:"user", content:interrupted($open)}] end)
              | .out += [$m] | .open = [$c[] | select(.type == "tool_use") | .id]
          end)
        | .out + (if .open == [] then [] else [{role:"user", content:interrupted(.open)}] end);'

start_turn() {
    local from request=$session.d/request.json program=$here/$provider.sh
    ((turn++))
    put '{type:"turn_start",run:$r,turn:$t}' --argjson r "$run" --argjson t "$turn"
    if [[ ! -x $program ]]; then
        put '{type:"error",where:"provider",message:"no provider: badbot/\($p).sh"}' --arg p "$provider"
        put '{type:"turn_end",run:$r,turn:$t,stop:"error"}' --argjson r "$run" --argjson t "$turn"
        return
    fi
    jq -sc --arg model "$model" --arg session "$session" --arg system "$system" \
        --slurpfile tools "$here/tools.json" "$answered"'{model:$model, session:$session,
        system:$system, messages:answered,
        tools:($tools[0] | map(del(.program))), params:{}}' "$ctx" >"$request"
    exec {from}< <(bare "$program" <"$request")
    pid=$!
    relay <&"$from" >/dev/null & # workers say on fd 3; stdout is the next actor's
    exec {from}<&-
}

# SIGTERM asks the provider for a result with what it has so far; SIGKILL if not.
stop_provider() {
    [[ $pid ]] || return 0
    kill -TERM "$pid" 2>/dev/null
    { sleep 2 && kill -KILL "$pid"; } >/dev/null 2>&1 &
}

# Worker: the provider's lines onto the bus, then its result as the turn's
# assistant message and turn_end. Only a tool_use stop keeps its calls.
relay() {
    local line result=
    while IFS= read -r line; do
        case $line in
            '{"type":"result"'*) result=$line ;;
            '{'*) say "$line" ;;
        esac
    done
    if [[ ! $result ]]; then
        put '{type:"error",where:"provider",message:"provider exited without a result"}'
        result='{"stop":"error","message":{"content":[]}}'
    fi
    local out # the message and turn_end, said at once; a result that will not read is an error
    out=$(jq -c --argjson run "$run" --argjson turn "$turn" '
        if .stop != "tool_use" then .message.content |= map(select(.type != "tool_use")) else . end
        | (select(.message.content | length > 0)
           | {type:"message", source:"assistant", run:$run, turn:$turn, message}),
          {type:"turn_end", run:$run, turn:$turn, stop, usage}' <<<"$result" 2>/dev/null) || {
        put '{type:"error",where:"provider",message:"the provider'"'"'s result is not a result"}'
        out="{\"type\":\"turn_end\",\"run\":$run,\"turn\":$turn,\"stop\":\"error\"}"
    }
    say "$out"
}

while IFS= read -r line; do
    printf '%s\n' "$line" # pass it on
    case $line in
        '{"type":"run_start"'*)
            [[ $line =~ \"run\":([0-9]+) ]] && run=${BASH_REMATCH[1]} turn=0 ;;
        '{"type":"message"'*) jq -c .message <<<"$line" >>"$ctx" ;;
        '{"type":"continue"'*) start_turn ;;
        '{"type":"preempt"'*) stop_provider ;;
        '{"type":"turn_end"'*) pid= ;;
        '{"type":"exit"'*) stop_provider; exit ;;
    esac
done
wait # run alone: let the turn finish
