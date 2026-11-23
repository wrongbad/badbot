#!/usr/bin/env bash
# openai: a provider for OpenAI's Chat Completions API, or any server that
# speaks it (OPENAI_BASE_URL: Ollama, vLLM, OpenRouter, …). Streams the reply.
#   BADBOT_PROVIDER=openai BADBOT_MODEL=gpt-5 badbot/badbot.sh     needs OPENAI_API_KEY for api.openai.com
# The model is BADBOT_MODEL, else OPENAI_MODEL.
# On SIGTERM it stops the request and gives back what it has said so far.
set -u
stopped= curl=
trap 'stopped=1; [[ $curl ]] && kill "$curl" 2>/dev/null' TERM
IFS= read -r request
base=${OPENAI_BASE_URL:-https://api.openai.com/v1}

fail() { # MESSAGE: says it, and the result of a failed turn
    jq -nc --arg m "openai: $1" '{type:"error", where:"provider", message:$m},
        {type:"result", stop:"error", message:{role:"assistant", content:[]}}'
    exit 0
}
[[ $base == https://api.openai.com/* && ! ${OPENAI_API_KEY-} ]] && fail "OPENAI_API_KEY is not set"

# The request, in Chat Completions' terms: a user message's tool results become
# "tool" messages, its text one "user" message.
body=$(jq -c --arg fallback "${OPENAI_MODEL-}" '
    def text: map(select(.type == "text").text) | join("\n");
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
                 ($c[] | select(.type == "tool_result") | {role:"tool", tool_call_id:.tool_use_id, content:(.content | text)}),
                 ($c | text | select(. != "") | {role:"user", content:.})
             end])}
    + if .tools then {tools:[.tools[] | {type:"function", function:{name, description, parameters:.input_schema}}]} else {} end
    + .params' <<<"$request" 2>&1) || fail "${body#jq: error (at *): }"
[[ $stopped ]] && { jq -nc '{type:"result", stop:"aborted", message:{role:"assistant", content:[]}}'; exit 0; }

# The stream, as it comes: a text_delta for each piece of text; at its end, the
# result. The key and the body go to curl by file descriptor, not argument.
exec {sse}< <(exec curl -sSN "$base/chat/completions" -H 'Content-Type: application/json' \
    -H @<(printf 'Authorization: Bearer %s\n' "${OPENAI_API_KEY-}") --data-binary @<(printf '%s' "$body") 2>&1)
curl=$!
result=
while IFS= read -r line; do
    case $line in
        '{"type":"result"'*) result=$line ;;
        *) printf '%s\n' "$line" ;;
    esac
done < <(jq -nRc --unbuffered <&"$sse" '
    def stop: {stop:"end_turn", tool_calls:"tool_use", function_call:"tool_use",
               length:"max_tokens", content_filter:"refusal"}[.] // .;
    foreach ((inputs | rtrimstr("\r")), null) as $l ({text:"", calls:[], stop:null, usage:null, err:""};
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
                | if $t != "" then .text += $t | .emit += [{type:"text_delta", text:$t}] else . end
                | reduce ($ch.delta.tool_calls // [])[] as $tc (.; # by index; without one, by id, or the last
                    ($tc.index // (if $tc.id then [.calls[] | .id?] | index($tc.id) // length else null end)
                        // ([(.calls | length) - 1, 0] | max)) as $i
                    | .calls[$i] |= ((. // {id:"", name:"", arguments:""})
                        | .id = ($tc.id // .id) | .name = ($tc.function.name // .name)
                        | .arguments += ($tc.function.arguments // "")))
                | if $ch.finish_reason then .stop = ($ch.finish_reason | stop) else . end
                | if $c.usage then .usage = $c.usage else . end
              end
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
