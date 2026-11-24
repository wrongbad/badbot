# anthropic.jq: the Anthropic Messages format, for anthropic.sh and claudecode.sh
# (jq -L badbot 'include "anthropic"; …'). A request's messages in the API's
# terms, and a reply read from the API's stream events.

# The request's messages as the API takes them: a tool_result without the facts
# badbot keeps beside it (name, status, ran), a tool_use's input always an
# object, its name after $prefix (claudecode's MCP names), and no x- blocks or
# fields.
def api_messages($prefix):
  def plain: with_entries(select(.key | startswith("x-") | not));
  map(.content |= if type != "array" then . else map(
      if (.type // "" | startswith("x-")) then empty
      elif .type == "tool_result" then del(.name, .status, .ran) | plain
      elif .type == "tool_use" then plain | .name = $prefix + .name
          | .input |= if type == "object" then . else {} end
      else plain end) end);

# A reply, as its stream events come: start with fresh, then step each event.
# .emit holds the events to show for the last one; .done says message_stop came.
def fresh: {blocks: [], stop: null, usage: {}, done: false, error: null, emit: []};
def step($e):
  def at: [.blocks[].i] | rindex($e.index);
  .emit = []
  | if $e.type == "message_start" then .blocks = [] | .usage = ($e.message.usage // {})
    elif $e.type == "content_block_start" then
      ($e.content_block) as $b
      # a server-side fallback: what the first model said is not kept, but its text
      | if $b.type == "fallback" then .blocks |= map(if .start.type == "text" then . else .dropped = true end) else . end
      | .blocks += [{i: $e.index, start: $b, text: ($b.text // ""), thinking: ($b.thinking // ""),
                     signature: ($b.signature // ""), json: ""}]
    elif $e.type == "content_block_delta" then
      at as $i | ($e.delta) as $d
      | if $i == null then .
        elif $d.type == "text_delta" then .blocks[$i].text += $d.text | .emit = [{type: "text_delta", text: $d.text}]
        elif $d.type == "thinking_delta" then .blocks[$i].thinking += $d.thinking
        elif $d.type == "signature_delta" then .blocks[$i].signature += $d.signature
        elif $d.type == "input_json_delta" then .blocks[$i].json += $d.partial_json
        else . end
    elif $e.type == "message_delta" then
      .stop = ($e.delta.stop_reason // .stop)
      | .usage += (($e.usage // {}) | with_entries(select(.value != null)))
    elif $e.type == "message_stop" then .done = true
    elif $e.type == "error" then .error = $e.error
    else . end;

# The reply's stop, in badbot's terms.
def stop_name:
  if .stop == "tool_use" or .stop == "max_tokens" or .stop == "refusal" then .stop
  elif .stop == "model_context_window_exceeded" then "max_tokens"
  else "end_turn" end;

# The reply's content: complete text, signed thinking (replayed as is), and,
# unless $aborted, calls (only when it stopped to make them) and server blocks.
# A call's name loses $prefix.
def content($aborted; $prefix):
  (.stop == "tool_use" and ($aborted | not)) as $calls
  | [.blocks[] | select(.dropped | not)
     | .start.type as $t
     | if $t == "text" then select(.text != "") | {type: "text", text}
       elif $t == "thinking" then select(.signature != "") | {type: "thinking", thinking, signature}
       elif $t == "redacted_thinking" or $t == "fallback" then .start
       elif $t == "tool_use" then select($calls)
         | {type: "tool_use", id: .start.id, name: (.start.name | ltrimstr($prefix)),
            input: (if .json == "" then {} else .json | fromjson? // {} end | if type == "object" then . else {} end)}
       else select($aborted | not) | .start end];

def usage:
  .usage | {input: (.input_tokens // 0), output: (.output_tokens // 0),
            cache_read: (.cache_read_input_tokens // 0), cache_write: (.cache_creation_input_tokens // 0)};
