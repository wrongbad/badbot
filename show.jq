# show.jq: the event stream as a person reads it.
#   ./akern | jq --unbuffered -rj -f show.jq
if .type == "text_delta" then .text
elif .type == "tool_start" then "\n$ \(.input.command // .name)\n"
elif .type == "block" then "  \(.block.content[0].text | split("\n")[0])\n"
elif .type == "job" then "  … \(.call) goes on as a job\n"
elif .type == "turn_end" then (if .stop == "aborted" then " ⏹\n" else "\n" end)
elif .type == "run_end" then "\n· \(.reason)\n"
elif .type == "error" then "! \(.message)\n"
else empty end
