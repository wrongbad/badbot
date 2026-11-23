#!/usr/bin/env bash
# echo: a provider with no model behind it, to try the kernel without a key.
# It answers the last user message:
#   hi                      streams "echo: hi", a word at a time
#   !ls; date               asks for two shell calls
#   !@shell {"command":"sleep 5; echo up","wait":0}   one call, its input as given
#   (a tool result)         "The tool said: <its first line>"
# On SIGTERM it stops and gives back what it has said so far.
set -f
result() { # STOP CONTENT
    jq -nc --arg stop "$1" --argjson content "$2" '{type:"result", stop:$stop,
        message:{role:"assistant", content:$content},
        usage:{input:0, output:0, cache_read:0, cache_write:0}}'
    exit 0
}
said=
text_so_far() { jq -nc --arg t "$said" 'if $t == "" then [] else [{type:"text", text:$t}] end'; }
trap 'result aborted "$(text_so_far)"' TERM

IFS= read -r request
last=$(jq -c '.messages[-1].content' <<<"$request")
text=$(jq -r 'map(select(.type == "text").text) | last // ""' <<<"$last")
tool=$(jq -r '[.[] | select(.type == "tool_result") | .content[0].text | split("\n")[0]] | first // ""' <<<"$last")

if [[ $text == '!'* ]]; then
    result tool_use "$(jq -nc --arg t "${text#!}" --arg p $$ '
        [if $t | startswith("@") then $t else $t | split(";")[] | ltrimstr(" ") end] | to_entries | map({type:"tool_use", id:"tu_\($p)_\(.key + 1)"} +
          if .value | startswith("@")
          then .value[1:] | capture("^(?<name>\\S+)\\s*(?<input>.*)$")
               | {name, input:(if .input == "" then {} else .input | fromjson end)}
          else {name:"shell", input:{command:.value}} end)')"
fi

reply="echo: $text"
[[ $tool ]] && reply="The tool said: $tool"
for word in $reply; do
    jq -nc --arg t "$word " '{type:"text_delta", text:$t}'
    said+="$word "
    sleep 0.15 & wait $!
done
result end_turn "$(text_so_far)"
