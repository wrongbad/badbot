# show.jq: the event stream as a person reads it: badbot.sh's stdout. The raw
# lines are in the session file.
if .type == "text_delta" then .text
elif .type == "tool_start" then "$ \(.input.command // .name)\n"
elif .type == "block" then "  \(.block.content[0].text | split("\n")[0])\n"
elif .type == "job" then "  … \(.call) goes on as a job\n"
elif .type == "turn_end" then (if .stop == "aborted" then " ⏹\n" elif .stop == "tool_use" then "" else "\n" end)
elif .type == "run_end" then "\n· \(.reason)\n"
elif .type == "error" then "! \(.message)\n"
else empty end
