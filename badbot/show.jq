# show.jq: the event stream as a person reads it: badbot.sh's stdout. The raw
# events are in the session file. Run with -nR and $tty (true: color): it
# remembers each call's command, to name it again when its result comes, and
# whether the agent is mid-line, to end that line before anything else. A line
# that is not JSON is skipped, not fatal.
def tag($s; $color): (if $tty then "\u001b[1;\($color)m\($s)\u001b[0m" else $s end) + " ";
def blue($s): tag($s; 34);
def green($s): tag($s; 32);
def red($s): tag($s; 31);
def yellow($s): tag($s; 33);

# a result's output: its text after the [exit N] line, at most 10 lines
def output:
  (split("\n")[1:] | if last == "" then .[:-1] else . end) as $l
  | ([$l[:10] | to_entries[] | (if .key == 0 then green("output") else "       " end) + .value + "\n"] | add // "")
    + (if ($l | length) > 10 then "       … \(($l | length) - 10) more lines\n" else "" end);

def command: .input.command // "\(.name) \(.input | tojson)";
def tool: if .input.command then "bash" else .name end;

foreach (inputs | fromjson? // empty) as $e ({calls: {}, open: false, bol: true, out: ""};
  .out = ""
  | if $e.type == "text_delta" then
      .out = (if .open then "" else blue("agent:") end) + $e.text
      | .open = true
      | .bol = ($e.text | endswith("\n"))
    else
      (if $e.type == "hello" then .out = yellow("session") + $e.session + "\n"
       elif $e.type == "tool_start" then
         .calls[$e.call] = ($e | command)
         | .out = green($e | tool) + ($e | command) + "\n"
       elif $e.type == "job" then
         .out = green("background") + (.calls[$e.call] // $e.call) + "\n"
       elif $e.type == "block" then
         ($e.block.status // "done") as $s
         | .out = (if $s == "exit 0" then green($s) else red($s) end)
                  + (.calls[$e.call] // $e.block.name) + "\n"
                  + ($e.block.content[0].text | output)
       elif $e.type == "turn_end" and $e.stop == "aborted" then .out = yellow("stopped") + "\n"
       elif $e.type == "run_end" and $e.reason != "done" then .out = yellow($e.reason) + "\n"
       elif $e.type == "error" then .out = red("error") + $e.message + "\n"
       else . end)
      # the agent's line ends before anything else is shown, and with its turn
      | if .open and (.out != "" or $e.type == "turn_end") then
          .out = (if .bol then "" else "\n" end) + .out | .open = false | .bol = true
        else . end
    end;
  .out)
