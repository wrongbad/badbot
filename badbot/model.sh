#!/usr/bin/env bash
# model: asks the model. A turn starts when the inbox says continue, and runs
# the provider in a worker, so the actor keeps listening and can stop it on
# preempt. Keeps the context: every message it has seen. Keeps the settings
# too, which provider it runs and what the request asks of it, and changes
# them on set; on list, it says the choices for one of them.
#   printf '%s\n' '{"type":"message","source":"inbox","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' '{"type":"continue"}' | badbot/model.sh
. "$(dirname "$0")/lib.sh"

run=0 turn=0 pid= # pid: the provider of the turn in flight
ctx=$session.d/context.jsonl
system=$("$here/system-prompt.sh")
jq -Rc 'fromjson? | select(.type == "message") | .message' "$session" >"$ctx" 2>/dev/null # resuming: the file is the state

# The settings: the provider, and what the request asks of it. They start as
# the environment says, or as the session last left them; a set changes them,
# and says the new ones as settings, which the session keeps.
settings=$(jq -nc --arg p "$provider" --arg m "$model" --arg e "$effort" '{provider:$p, model:$m, effort:$e}')
last=$(grep '^{"type":"settings"' "$session" 2>/dev/null | tail -n 1)
[[ $last ]] && new=$(jq -c --argjson s "$settings" '$s + (del(.type)
    | with_entries(select((.key as $k | $s | has($k)) and (.value | type) == "string")))' <<<"$last" 2>/dev/null) &&
    settings=$new
provider=$(jq -r .provider <<<"$settings")

# is_provider NAME: NAME.sh, here, says on its second line that it is one: "# NAME: a provider …".
is_provider() {
    [[ $1 =~ ^[A-Za-z0-9_-]+$ && -x $here/$1.sh && $(sed -n 2p "$here/$1.sh") == "# $1: a provider"* ]]
}

# set_ EVENT: the settings it names change, if they may. A new provider starts
# with its own defaults, for what the set does not name. A choice its provider
# lists (not a provider, nor a model: those are checked when used) must be one.
set_() {
    local new p key keys value choices
    new=$(jq -rc --argjson s "$settings" '
        (del(.type) | with_entries(select((.key as $k | $s | has($k)) and (.value | type) == "string"))
            | if .provider == "" then .provider = "openai" else . end) as $n # the default provider
        | if $n == {} then error("nothing to set: the settings are \($s | keys_unsorted | join(", "))") else . end
        | $s + (if ($n.provider // $s.provider) != $s.provider then {model:"", effort:""} else {} end) + $n
        | ., ($n | keys_unsorted[] | select(. != "provider" and . != "model"))' <<<"$1" 2>&1) || {
        put '{type:"error",where:"set",message:$m}' --arg m "${new#jq: error (at *): }"
        return
    }
    { IFS= read -r new; mapfile -t keys; } <<<"$new"
    p=$(jq -r .provider <<<"$new")
    is_provider "$p" || { put '{type:"error",where:"set",message:"no provider \($p): /provider lists them"}' --arg p "$p"; return; }
    for key in "${keys[@]}"; do
        value=$(jq -r --arg k "$key" '.[$k]' <<<"$new")
        [[ $value ]] || continue
        choices=$(bare "$here/$p.sh" --list "$key" </dev/null 2>/dev/null | jq -c '.choices // []' 2>/dev/null)
        jq -e --arg v "$value" 'length > 0 and (any(.[]; . == $v) | not)' <<<"${choices:-[]}" >/dev/null || continue
        put '{type:"error",where:"set",message:"\($p) has no \($k) \($v): \($c | join(", "))"}' \
            --arg p "$p" --arg k "$key" --arg v "$value" --argjson c "$choices"
        return
    done
    settings=$new provider=$p
    put '{type:"settings"} + $s' --argjson s "$settings"
}

# Worker: list KEY: the choices for a setting, as options. The providers are
# the scripts here that say they are one; the rest, the provider lists (it may
# ask its server): NAME.sh --list KEY prints {"choices":[…],"default":"…"}.
list() {
    local key=$1 out f n
    if ! jq -e --arg k "$key" 'has($k)' <<<"$settings" >/dev/null; then
        put '{type:"error",where:"list",message:"no setting \($k): the settings are \($s | keys_unsorted | join(", "))"}' \
            --arg k "$key" --argjson s "$settings"
        return
    fi
    if [[ $key == provider ]]; then
        out=$(for f in "$here"/*.sh; do
            n=${f##*/} && n=${n%.sh} && is_provider "$n" && echo "$n"
        done | jq -Rnc '{choices:[inputs], default:"openai"}')
    elif ! out=$(bare "$here/$provider.sh" --list "$key" </dev/null 2>&1) ||
        ! jq -e '(.choices | type) == "array"' <<<"$out" >/dev/null 2>&1; then
        put '{type:"error",where:"list",message:"\($p) cannot list \($k)\(if $o == "" then "" else ": " + $o end)"}' \
            --arg p "$provider" --arg k "$key" --arg o "$out"
        return
    fi
    put '{type:"options", key:$k, provider:$s.provider, current:$s[$k]} + ($o | {choices, default:(.default // "")})' \
        --arg k "$key" --argjson s "$settings" --argjson o "$out"
}

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
    jq -sc --argjson settings "$settings" --arg session "$session" --arg system "$system" \
        --slurpfile tools "$here/tools.json" "$answered"'($settings | del(.provider)) + {session:$session,
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
        '{"type":"set"'*) set_ "$line" ;;
        '{"type":"list"'*) list "$(jq -r '.key // "" | tostring' <<<"$line")" >/dev/null & ;;
        '{"type":"turn_end"'*) pid= ;;
        '{"type":"exit"'*) stop_provider; exit ;;
    esac
done
wait # run alone: let the turn finish
