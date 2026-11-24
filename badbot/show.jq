# show.jq: the event stream as a person reads it: badbot.sh's stdout, by show.sh.
# The raw events are in the session file. Run with -nR and $tty (true: color).
# It remembers whether a person types at a terminal (hello says), each call's
# command, to name it again when its result comes, and whether the agent is
# mid-line, or a prompt is waiting, to end that line before anything else. A
# line that is not JSON is skipped, not fatal.
#
# What a person types, the terminal shows as they type it, so it gets a prompt,
# when a run ends, rather than a label: typed mid-run, it has neither. What is
# piped in, nothing shows, so each send is shown here.
def tag($s; $color): (if $tty then "\u001b[1;\($color)m\($s)\u001b[0m" else $s end) + " ";
def cyan($s): tag($s; 36);
def blue($s): tag($s; 34);
def green($s): tag($s; 32);
def red($s): tag($s; 31);
def yellow($s): tag($s; 33);

# a result's output: its first 5 lines and last 5, of at most 200 characters,
# then what its header says was not shown (an image: its type). The lines are
# the text after the [exit N] line; output too long for the model has none, so
# they are the block event's preview.
def output($preview):
  (map(select(.type == "text").text) | join("\n")) as $t
  | (if $preview then $preview
     else $t | split("\n")[1:] | if last == "" then .[:-1] else . end
       | {lines:length, head:(if length > 10 then .[:5] else . end), tail:(if length > 10 then .[-5:] else [] end)}
       | .head |= map(if length > 200 then .[:200] + " …" else . end)
       | .tail |= map(if length > 200 then .[:200] + " …" else . end) end) as $p
  | ($p.lines - ($p.head | length) - ($p.tail | length)) as $more
  | ($p.head + (if $more > 0 then ["… \($more) more line\(if $more == 1 then "" else "s" end)"] else [] end) + $p.tail
     + [$t | capture("^\\[[^;\\]\n]*; (?<n>[^\n]*)\\]") | "[\(.n)]"])
  | to_entries | map((if .key == 0 then green("output") else "       " end) + .value + "\n") | add // "";

def command: .input.command // "\(.name) \(.input | tojson)";
def tool: if .input.command then "bash" else .name end;

def prompt: blue("you");

# a send's content as text: a string, or its text blocks, with [type] for others
def said:
  if type == "string" then .
  elif type == "array" then
    map(if type != "object" then empty elif .type == "text" then .text | tostring
        elif .type then "[\(.type)]" else empty end) | join(" ")
  else "" end;

foreach (inputs | fromjson? // empty) as $e ({calls: {}, early: {}, open: false, bol: true, prompt: false, typing: false, out: ""};
  .out = ""
  | if $e.type == "text_delta" then
      .out = (if .open then "" else cyan("agent") end) + $e.text
      | .open = true
      | .bol = ($e.text | endswith("\n"))
    else
      (if $e.type == "hello" then .out = green("session") + $e.session + "\n" | .typing = ($e.typing == true)
       elif $e.type == "send" then
         if .typing then .prompt = false # the terminal ended the line, with Enter
         else ($e.content | said) as $s | if $s == "" then . else .out = blue("you") + $s + "\n" end end
       elif $e.type == "tool_start" then
         .calls[$e.call] = ($e | command)
         | .out = green($e | tool) + ($e | command) + "\n"
                  + (if .early[$e.call] then green("background") + ($e | command) + "\n" else "" end)
         | del(.early[$e.call])
       elif $e.type == "job" then # the inbox can say it before the tools say tool_start: then it waits
         if .calls[$e.call] then .out = green("background") + .calls[$e.call] + "\n"
         else .early[$e.call] = true end
       elif $e.type == "block" then
         ($e.block.status // "done") as $s
         | .out = (if $s == "exit 0" then green($s) else red($s) end)
                  + (.calls[$e.call] // $e.block.name) + "\n"
                  + ($e.block.content | if type == "array" then output($e.preview) else "" end)
       elif $e.type == "turn_end" and $e.stop == "aborted" then .out = yellow("stopped") + "\n"
       elif $e.type == "run_end" and $e.reason != "done" then .out = yellow($e.reason) + "\n"
       elif $e.type == "error" then .out = red("error") + $e.message + "\n"
       else . end)
      # the agent's line ends before anything else is shown, and with its turn
      | if .open and (.out != "" or $e.type == "turn_end") then
          .out = (if .bol then "" else "\n" end) + .out | .open = false | .bol = true
        else . end
    end
  # a waiting prompt's line ends before anything else is shown, or at exit
  | if .prompt and (.out != "" or $e.type == "exit") then .out = "\n" + .out | .prompt = false else . end
  # and a new one waits when the kernel starts, and when a run ends
  | if ($e.type == "hello" or $e.type == "run_end") and .typing then .out += prompt | .prompt = true else . end;
  .out)
