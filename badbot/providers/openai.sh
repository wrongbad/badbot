#!/usr/bin/env bash
# openai: a provider for OpenAI's Chat Completions API, or any server that
# speaks it (OPENAI_BASE_URL: Ollama, vLLM, OpenRouter, …). Streams the reply.
#   BADBOT_PROVIDER=openai BADBOT_MODEL=gpt-5 badbot/badbot.sh     needs OPENAI_API_KEY for api.openai.com
# The model is BADBOT_MODEL, else OPENAI_MODEL; the request's effort is its
# reasoning_effort.
#   badbot/providers/openai.sh --list model|effort     the choices: the server's models; the efforts
# A failed connection, a 429, a 5xx, an overloaded server or an error about
# in-flight requests is tried again, before the stream says anything (post.sh).
# On SIGTERM it stops the request and gives back what it has said so far.
set -u
here=$(cd "$(dirname "$0")" && pwd)
base=${OPENAI_BASE_URL:-https://api.openai.com/v1}

if [[ ${1-} == --list ]]; then # {"choices":[…],"default":"…"}, or why not on stderr
    case ${2-} in
        model)
            [[ $base == https://api.openai.com/* && ! ${OPENAI_API_KEY-} ]] && { echo "OPENAI_API_KEY is not set" >&2; exit 1; }
            out=$(curl -sS --max-time 30 "$base/models" -H @<(printf 'Authorization: Bearer %s\n' "${OPENAI_API_KEY-}") 2>&1) ||
                { echo "$out" >&2; exit 1; }
            jq -ce --arg d "${OPENAI_MODEL-}" '{choices:([.data[].id] | sort), default:$d}' <<<"$out" 2>/dev/null ||
                { { jq -r '.error.message? // .error // "not a list of models" | tostring' <<<"$out" 2>/dev/null || echo "$out"; } >&2; exit 1; } ;;
        effort) jq -nc '{choices:["none", "minimal", "low", "medium", "high", "xhigh"], default:""}' ;;
        *) echo "nothing to list for ${2-}" >&2; exit 1 ;;
    esac
    exit
fi

stopped= child=
trap 'stopped=1; [[ $child ]] && kill "$child" 2>/dev/null' TERM
IFS= read -r request

fail() { # MESSAGE: says it, and the result of a failed turn
    jq -nc --arg m "openai: $1" '{type:"error", where:"provider", message:$m},
        {type:"result", stop:"error", message:{role:"assistant", content:[]}}'
    exit 0
}
[[ $base == https://api.openai.com/* && ! ${OPENAI_API_KEY-} ]] && fail "OPENAI_API_KEY is not set"

# The request, in Chat Completions' terms: a user message's tool results become
# "tool" messages, its text one "user" message. A tool message holds only text,
# so the images in tool results go in that user message, before its text.
body=$(jq -c --arg fallback "${OPENAI_MODEL-}" '
    def text: map(select(.type == "text").text) | join("\n");
    def images: [.[] | select(.type == "image" and .source.type == "base64")
        | {type:"image_url", image_url:{url:"data:\(.source.media_type);base64,\(.source.data)"}}];
    .model = if .model != "" then .model else $fallback end
    | if .model == "" then error("no model: set BADBOT_MODEL or OPENAI_MODEL") else . end
    | {model, stream:true, stream_options:{include_usage:true},
       messages:([.system // empty | {role:"system", content:.}] + [.messages[] | .content as $c
           | if .role == "assistant" then
                 [$c[] | select(.type == "tool_use")] as $calls
                 | {role:"assistant", content:($c | text | if . == "" then null else . end)}
                   + if $calls == [] then {} else {tool_calls:[$calls[]
                       | {id, type:"function", function:{name, arguments:(.input | tojson)}}]} end
             else
                 ($c[] | select(.type == "tool_result") | {role:"tool", tool_call_id:.tool_use_id, content:(.content
                     | text + if images != [] then "\n(its image is in the next user message)" else "" end)}),
                 ([$c[] | select(.type == "tool_result") | .content[]] + $c | images) as $images
                 | ($c | text) as $text
                 | if $images != [] then {role:"user", content:($images + [$text | select(. != "") | {type:"text", text:.}])}
                   elif $text != "" then {role:"user", content:$text} else empty end
             end])}
    + if .tools then {tools:[.tools[] | {type:"function", function:{name, description, parameters:.input_schema}}]} else {} end
    + if (.effort // "") != "" then {reasoning_effort:.effort} else {} end
    + .params' <<<"$request" 2>&1) || fail "${body#jq: error (at *): }"
[[ $stopped ]] && { jq -nc '{type:"result", stop:"aborted", message:{role:"assistant", content:[]}}'; exit 0; }

# The stream, as it comes: thinking when reasoning starts (a delta's
# reasoning_content or reasoning), a text_delta for each piece of text; at its end, the
# result. post.sh sends it; the key and the body go to it on stdin, not as arguments.
exec {sse}< <(exec "$here/post.sh" "$base/chat/completions" 2>&1 \
    < <(printf '%s\n' 'Content-Type: application/json' "Authorization: Bearer ${OPENAI_API_KEY-}" '' "$body"))
child=$!
[[ $stopped ]] && kill "$child" 2>/dev/null # SIGTERM came before there was a child to stop
result=
while IFS= read -r line; do
    case $line in
        '{"type":"result"'*) result=$line ;;
        *) printf '%s\n' "$line" ;;
    esac
done < <(jq -nRc --unbuffered <&"$sse" '
    def stop: {stop:"end_turn", tool_calls:"tool_use", function_call:"tool_use",
               length:"max_tokens", content_filter:"refusal"}[.] // .;
    foreach ((inputs | rtrimstr("\r")), null) as $l ({text:"", calls:[], stop:null, usage:null, err:"", thinking:false};
        .emit = []
        | if $l == null then
            ([.calls[] | select(. != null)] | length > 0) as $calls # some servers say "stop" with calls
            | .emit = [{type:"result", stop:(if .stop == "end_turn" and $calls then "tool_use" else .stop end),
                error:((.err | fromjson? | .error | if type == "object" then .message else . end) // (.err | rtrimstr("\n"))),
                message:{role:"assistant", content:(
                    [if .text != "" then {type:"text", text:.text} else empty end]
                    + [.calls[] | select(. != null) | {type:"tool_use", id, name,
                        input:(.arguments | if . == "" then {} else (fromjson? // {}) end)}])},
                usage:(.usage | {input:((.prompt_tokens // 0) - (.prompt_tokens_details.cached_tokens // 0)),
                    output:(.completion_tokens // 0), cache_read:(.prompt_tokens_details.cached_tokens // 0),
                    cache_write:0})}]
          elif $l | test("^data: ?\\{") then
            (($l | sub("^data: ?"; "") | fromjson?) // {}) as $c
            | if $c.error then .err += ($c.error | if type == "object" then .message // tojson else tostring end)
              else
                ($c.choices[0]? // {}) as $ch
                | ($ch.delta.content // "") as $t
                | if ($ch.delta.reasoning_content // $ch.delta.reasoning // "") != "" and (.thinking | not)
                  then .thinking = true | .emit += [{type:"thinking"}] else . end
                | if $t != "" then .text += $t | .thinking = false | .emit += [{type:"text_delta", text:$t}] else . end
                | reduce ($ch.delta.tool_calls // [])[] as $tc (.; # by index; without one, by id, or the last
                    ($tc.index // (if $tc.id then [.calls[] | .id?] | index($tc.id) // length else null end)
                        // ([(.calls | length) - 1, 0] | max)) as $i
                    | .calls[$i] |= ((. // {id:"", name:"", arguments:""})
                        | .id = ($tc.id // .id) | .name = ($tc.function.name // .name)
                        | .arguments += ($tc.function.arguments // "")))
                | if $ch.finish_reason then .stop = ($ch.finish_reason | stop) else . end
                | if $c.usage then .usage = $c.usage else . end
              end
          elif $l | startswith("x-status: ") then # from post.sh: an error with no body says it
            if .err == "" and ($l[10:] | tonumber? // 0) >= 400 then .err = "HTTP \($l[10:])" else . end
          elif $l == "" or ($l | test("^(:|data:|event:|id:|retry:)")) then .
          else .err += $l + "\n" end; # not the stream: an error body, or curl
        .emit[])')

# A stream that ended without a stop was stopped, or failed.
[[ $result ]] || result='{"type":"result","message":{"role":"assistant","content":[]}}'
jq -c --arg stopped "$stopped" '
    (.stop // if $stopped != "" then "aborted" else "error" end) as $stop
    | if $stop == "error" then {type:"error", where:"provider", message:("openai: "
        + if (.error // "") != "" then .error else "the stream ended without a reply" end)} else empty end,
      (del(.error) | .stop = $stop)' <<<"$result"
