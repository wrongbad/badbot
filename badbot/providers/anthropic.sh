#!/usr/bin/env bash
# anthropic: a provider for Anthropic's Messages API. Streams the reply.
#   BADBOT_PROVIDER=anthropic badbot/badbot.sh     needs ANTHROPIC_API_KEY for api.anthropic.com
# The model is BADBOT_MODEL, else ANTHROPIC_MODEL, else claude-opus-5-5;
# ANTHROPIC_BASE_URL, if set, is where it goes. It asks for adaptive thinking
# (summarized), high effort, server-side fallbacks and prompt caching; the
# request's params go over those, and a param set to null leaves its field out
# ({"thinking":null,"output_config":null,"fallbacks":null} for an older model).
# The request's effort, if any, is output_config's, over high.
#   badbot/providers/anthropic.sh --list model|effort     the choices: the API's models; the efforts
# An overloaded or rate-limited API, a 5xx, a failed connection or an error
# about in-flight requests is tried again, up to 5 times in all, 1, 2, 4 and
# 8 s apart, before the stream says anything (post.sh).
# On SIGTERM it stops the request and gives back what it has said so far.
set -u
here=$(cd "$(dirname "$0")" && pwd)
stopped= child=
trap 'stopped=1; [[ $child ]] && kill "$child" 2>/dev/null' TERM
base=${ANTHROPIC_BASE_URL:-https://api.anthropic.com}
base=${base%/}

if [[ ${1-} == --list ]]; then # {"choices":[…],"default":"…"}, or why not on stderr
    case ${2-} in
        model)
            [[ $base == https://api.anthropic.com && ! ${ANTHROPIC_API_KEY-} ]] && { echo "ANTHROPIC_API_KEY is not set" >&2; exit 1; }
            out=$(curl -sS --max-time 30 "$base/v1/models?limit=1000" -H 'anthropic-version: 2026-10-21' \
                -H @<(printf 'x-api-key: %s\n' "${ANTHROPIC_API_KEY-}") 2>&1) || { echo "$out" >&2; exit 1; }
            jq -ce --arg d "${ANTHROPIC_MODEL:-claude-opus-5-5}" '{choices:[.data[].id], default:$d}' <<<"$out" 2>/dev/null ||
                { { jq -r '.error.message? // .error // "not a list of models" | tostring' <<<"$out" 2>/dev/null || echo "$out"; } >&2; exit 1; } ;;
        effort) jq -nc '{choices:["low", "medium", "high", "xhigh", "max"], default:"high"}' ;;
        *) echo "nothing to list for ${2-}" >&2; exit 1 ;;
    esac
    exit
fi

IFS= read -r request

fail() { # MESSAGE: says it, and the result of a failed turn
    jq -nc --arg m "anthropic: $1" '{type:"error", where:"provider", message:$m},
        {type:"result", stop:"error", message:{role:"assistant", content:[]}}'
    exit 0
}
[[ $base == https://api.anthropic.com && ! ${ANTHROPIC_API_KEY-} ]] && fail "ANTHROPIC_API_KEY is not set"

body=$(jq -c -L "$here" --arg fallback "${ANTHROPIC_MODEL:-claude-opus-5-5}" 'include "anthropic";
    .model = if .model != "" then .model else $fallback end
    | {model, max_tokens:64000, stream:true}
    + (if (.system // "") != "" then {system} else {} end)
    + {messages:(.messages | api_messages(""))}
    + (if (.tools // []) != [] then {tools:[.tools[] | {name, description, input_schema, eager_input_streaming:true}]} else {} end)
    + {thinking:{type:"adaptive", display:"summarized"}, output_config:{effort:"high"},
       fallbacks:"default", cache_control:{type:"ephemeral"}}
    + (if (.effort // "") != "" then {output_config:{effort:.effort}} else {} end)
    + (.params // {})
    | with_entries(select(.value != null))' <<<"$request" 2>&1) || fail "${body#jq: error (at *): }"
headers=('content-type: application/json' 'anthropic-version: 2026-10-21')
[[ $(jq 'has("fallbacks")' <<<"$body") == true ]] && headers+=('anthropic-beta: server-side-fallback-2026-07-01')

# The stream: thinking as a thinking block starts, a text_delta for each piece
# of text as it comes; then, apart, a line with what the stream left:
# {"type":"result","s":STATE}. post.sh sends it, and adds the HTTP status as a
# last line; the key and the body go to it on stdin, not as arguments. A
# message_start or a ping says nothing yet: an error after them is tried again.
exec {sse}< <(exec "$here/post.sh" --hold '^ ?\{"type": *"(message_start|ping)"' "$base/v1/messages" \
    --speed-limit 1 --speed-time 300 2>&1 \
    < <(printf '%s\n' "${headers[@]}" "x-api-key: ${ANTHROPIC_API_KEY-}" '' "$body"))
child=$!
[[ $stopped ]] && kill "$child" 2>/dev/null # SIGTERM came before there was a child to stop
result=
while IFS= read -r line; do
    case $line in
        '{"type":"result"'*) result=$line ;;
        *) printf '%s\n' "$line" ;;
    esac
done < <(jq -nRc --unbuffered -L "$here" <&"$sse" 'include "anthropic";
    foreach ((inputs | rtrimstr("\r")), null) as $l (fresh + {status:0, body:""};
        if $l == null then .emit = [{type:"result", s:del(.emit)}]
        elif $l | startswith("data:") then (($l[5:] | fromjson?) // null) as $e
            | if $e then step($e) else .emit = [] end
        elif $l | startswith("x-status: ") then .status = ($l[10:] | tonumber? // 0) | .emit = []
        elif $l == "" or ($l | test("^(:|event:|id:|retry:)")) then .emit = []
        else .body += $l + "\n" | .emit = [] end; # not the stream: an error body, or curl
        .emit[])')

# The turn's end, from what the stream left.
jq -c -L "$here" --arg stopped "$stopped" 'include "anthropic";
    (fresh + {status:0, body:""} + (.s // {})) as $s
    | (if $s.done then $s | stop_name elif $stopped != "" then "aborted" else "error" end) as $stop
    | ($s.error // ($s.body | fromjson? | .error?) // null) as $e
    | if $stop == "error" then {type:"error", where:"provider", message:("anthropic: "
        + ($e.message // ($s.body | rtrimstr("\n") | select(. != ""))
           // if $s.status >= 400 then "HTTP \($s.status)" else "the stream ended without a reply" end))}
      else empty end,
      {type:"result", stop:$stop, message:{role:"assistant",
        content:(if $stop == "error" then [] else $s | content($stop == "aborted"; "") end)},
       usage:($s | usage)}' <<<"${result:-"{}"}"
