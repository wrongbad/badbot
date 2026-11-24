#!/usr/bin/env bash
# claudecode: a provider that asks Claude Code, through the claude CLI on PATH,
# on the user's Claude subscription. It never touches Claude Code's credentials.
#   BADBOT_PROVIDER=claudecode badbot/badbot.sh     BADBOT_MODEL: fable, opus, sonnet, haiku, or an id
# Without BADBOT_MODEL, claude picks. params.effort is --effort, and
# params.max_tokens CLAUDE_CODE_MAX_OUTPUT_TOKENS.
#
# One claude (claude -p, stream-json) per session, kept between turns: Claude
# Code continues a conversation's prompt cache only from its own previous
# request, so a new claude for every turn would write the whole history to the
# cache again each time. Each turn is the next step of that one conversation;
# when the request cannot be one (another model, a changed history, steering
# beside call results), a new claude starts and is given the history.
#
# Claude Code's own tools, settings, CLAUDE.md, memory, skills and other MCP
# servers are off. badbot's tools are an MCP server this script hosts over
# claude's stdin and stdout, named badbot: the model calls mcp__badbot__shell.
# When it calls, the turn ends with the calls (their prefix stripped), and
# claude waits; the next turn's tool results answer them.
#
# Its files are in S.d/claudecode: state.json (what claude holds), and for each
# claude a directory: its stdin (a fifo), stdout (out), stderr (err), pid, the
# lines of out read so far (lines), and the calls it asked for that wait for
# their results (held). claude ends with the kernel: a watcher checks once a
# second that the provider's parent, the model actor, is still there.
#
# On SIGTERM it stops claude, and gives back what it has said so far.
set -u
here=$(cd "$(dirname "$0")" && pwd)
prefix=mcp__badbot__
stopped= tail_pid=
trap 'stopped=1; [[ $tail_pid ]] && kill "$tail_pid" 2>/dev/null' TERM
IFS= read -r request

fail() { # MESSAGE: says it, and the result of a failed turn
    jq -nc --arg m "claudecode: $1" '{type:"error", where:"provider", message:$m},
        {type:"result", stop:"error", message:{role:"assistant", content:[]}}'
    exit 0
}
command -v claude >/dev/null || fail "claude is not on PATH"
session=$(jq -r '.session // empty' <<<"$request" 2>/dev/null) || fail "the request is not JSON"
[[ $session ]] || fail "the request names no session"
D=$session.d/claudecode
mkdir -p "$D" || fail "cannot make $D"
req=$D/request.json
printf '%s\n' "$request" >"$req"

# The claude now running, if any: its directory, from the last turn.
cdir=$(cat "$D/current" 2>/dev/null)
alive=false
[[ $cdir && -s $cdir/pid ]] && kill -0 "$(<"$cdir/pid")" 2>/dev/null && alive=true

stop_claude() {
    [[ $cdir ]] || return 0
    [[ -s $cdir/pid ]] && kill "$(<"$cdir/pid")" 2>/dev/null
    rm -rf -- "$cdir" "$D/current" "$D/state.json"
    cdir=
}

# The plan for this turn. calls: the request answers the calls claude waits
# on, and nothing else; feed: claude ended its turn, and the request goes on
# from it with new messages; start: a new claude, given the whole history.
# chunks: the stream-json lines to write; every user message but the last
# asks for no reply, and claude acknowledges each with a result line, so a
# chunk ends there and the next waits for it. settle: claude's result line
# that closes its last turn is still to come.
jq -n -L "$here" --arg p "$prefix" --argjson alive "$alive" --slurpfile req "$req" \
    --slurpfile st <(cat "$D/state.json" 2>/dev/null || echo null) 'include "anthropic";
    def chunks: . as $ms | (length - 1) as $last
        | reduce range(0; length) as $i ([""]; $ms[$i] as $m
            | if $m.role == "user" then
                .[-1] += ({type:"user"} + (if $i < $last then {shouldQuery:false} else {} end)
                          + {message:$m} | tojson) + "\n"
                | if $i < $last then . + [""] else . end
              else .[-1] += ({type:"assistant", message:$m} | tojson) + "\n" end)
        | map(select(. != ""));
    def carried: .content | if type == "string" then true
        else all(.type == "text" or (.type == "image" and .source.type == "base64")) end;
    $req[0] as $q | ($st[0] // {}) as $s
    | {model:($q.model // ""), system:($q.system // ""), tools:($q.tools // []),
       effort:($q.params.effort // null), max_tokens:($q.params.max_tokens // null)} as $setup
    | ($q.messages | api_messages($p)) as $r
    | ($s.fed // [] | length) as $n
    | (if $alive and $s.setup == $setup and ($r | length) > $n and $r[:$n] == $s.fed then $r[$n:] else null end) as $tail
    | if $tail and $s.phase == "calling" and ($tail | length) == 1 and $tail[0].role == "user"
         and ($tail[0].content | type) == "array"
         and ($tail[0].content | all(.type == "tool_result" and carried))
         and ([$tail[0].content[].tool_use_id] | sort) == ($s.calls | sort)
      then {mode:"calls", answers:$tail[0].content, chunks:[], settle:0}
      elif $tail and $s.phase == "ending"
         and ($tail[0].content | if type == "array" then .[0].type != "tool_result" else true end)
      then {mode:"feed", answers:[], chunks:($tail | chunks), settle:1}
      else {mode:"start", answers:[], chunks:($r | chunks), settle:0} end
    | . + {setup:$setup, last:($r[-1].role // ""),
           mcp:[$setup.tools[] | {name, description, inputSchema:.input_schema}],
           allowed:([$setup.tools[].name | $p + .] | join(","))}' >"$D/plan.json" 2>"$D/plan.err" ||
    fail "$(sed 's/^jq: error (at [^)]*): //' "$D/plan.err")"
{
    IFS= read -rd '' mode; IFS= read -rd '' settle; IFS= read -rd '' last; IFS= read -rd '' model
    IFS= read -rd '' system; IFS= read -rd '' effort; IFS= read -rd '' max_tokens; IFS= read -rd '' allowed
} < <(jq -j '[.mode, .settle, .last, .setup.model, .setup.system, .setup.effort, .setup.max_tokens, .allowed]
    | map((. // "" | tostring) + "\u0000") | add' "$D/plan.json")
mapfile -d '' chunks < <(jq -j '.chunks[] | . + "\u0000"' "$D/plan.json")
[[ $last == user ]] || fail "the conversation does not end with a user message"

# A new claude, in a directory of its own. Its wrapper waits for it, and
# writes its exit status to out as {"type":"x-exit"}; its watcher ends it when
# the kernel ends.
start_claude() {
    local args=(-p --input-format stream-json --output-format stream-json --verbose
        --include-partial-messages --no-session-persistence --tools "" --strict-mcp-config
        --setting-sources "" --disable-slash-commands --permission-mode dontAsk
        --mcp-config '{"mcpServers":{"badbot":{"type":"sdk","name":"badbot"}}}'
        --system-prompt "$system") kernel=$PPID
    [[ $allowed ]] && args+=(--allowedTools "$allowed")
    [[ $model ]] && args+=(--model "$model")
    [[ $effort ]] && args+=(--effort "$effort")
    cdir=$D/claude.$$
    rm -rf -- "$cdir" && mkdir -p "$cdir" && mkfifo "$cdir/in" && : >"$cdir/out" && echo 0 >"$cdir/lines" &&
        : >"$cdir/held" || fail "cannot make $cdir"
    (
        # a surrounding Claude Code session's variables are not this claude's
        for v in $(compgen -e); do
            case $v in
                CLAUDE_CONFIG_DIR | CLAUDE_CODE_OAUTH_TOKEN | CLAUDE_CODE_USE_BEDROCK | CLAUDE_CODE_USE_VERTEX | CLAUDE_CODE_USE_FOUNDRY) ;;
                CLAUDE*) unset "$v" ;;
            esac
        done
        export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
            CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 DISABLE_COMPACT=1 \
            MCP_TOOL_TIMEOUT=2147483647 MAX_MCP_OUTPUT_TOKENS=1000000000 # a call waits for badbot, which bounds its output
        [[ $max_tokens ]] && export CLAUDE_CODE_MAX_OUTPUT_TOKENS=$max_tokens
        claude "${args[@]}" <>"$cdir/in" >>"$cdir/out" 2>>"$cdir/err" &
        c=$!
        echo "$c" >"$cdir/pid"
        { while kill -0 "$kernel"; do sleep 1; done; kill "$c"; } 2>/dev/null &
        w=$!
        wait "$c"
        st=$?
        kill "$w" 2>/dev/null
        printf '{"type":"x-exit","status":%d}\n' "$st" >>"$cdir/out"
    ) </dev/null >/dev/null 2>&1 &
    for _ in {1..100}; do [[ -s $cdir/pid ]] && break; sleep 0.05; done
    [[ -s $cdir/pid ]] || fail "claude did not start"
    echo "$cdir" >"$D/current"
}

if [[ $mode == start ]]; then
    stop_claude
    start_claude
fi
exec {w}<>"$cdir/in" || fail "cannot open claude's stdin"
[[ $mode == start ]] &&
    printf '%s\n' '{"type":"control_request","request_id":"badbot-init","request":{"subtype":"initialize","sdkMcpServers":["badbot"]}}' >&"$w"

# What claude says, from where the last turn stopped reading, after the calls
# held from it, one line out for each line in (E at the end):
#   P EVENT  show it          W LINE  write it to claude     H LINE  a call to hold
#   R LINE   a result line    X LINE  claude exited          S STATE  the reply is done
#   -        nothing
held=$cdir/held lines=$(<"$cdir/lines")
nheld=$(wc -l <"$held")
exec {src}< <(cat "$held"; exec tail -n "+$((lines + 1))" -f "$cdir/out")
tail_pid=$!
[[ $stopped ]] && kill "$tail_pid" 2>/dev/null # SIGTERM came before there was a tail to stop
exec {r}< <(exec jq -nRr --unbuffered -L "$here" --slurpfile plan "$D/plan.json" <&"$src" 'include "anthropic";
    def reply($c; $result): {type:"control_response", response:{subtype:"success", request_id:$c.request_id,
        response:{mcp_response:{jsonrpc:"2.0", id:($c.request.message.id // 0), result:$result}}}};
    def call_result: {isError:(.is_error == true), content:[.content
        | if type == "string" then {type:"text", text:.}
          else .[] | if .type == "text" then {type:"text", text} else {type:"image", data:.source.data, mimeType:.source.media_type} end end]};
    $plan[0] as $plan
    | foreach (inputs, null) as $l (fresh;
        .out = "-"
        | if $l == null then .out = "E " + (del(.out, .emit) | tojson)
          else (($l | fromjson?) // {}) as $m
          | if $m.type == "control_request" and $m.request.subtype == "mcp_message" then
              $m.request.message as $msg
              | .out = if $msg.method == "initialize" then "W " + (reply($m; {protocolVersion:$msg.params.protocolVersion,
                    capabilities:{tools:{}}, serverInfo:{name:"badbot", version:"1"}}) | tojson)
                elif $msg.method == "tools/list" then "W " + (reply($m; {tools:$plan.mcp}) | tojson)
                elif $msg.method == "tools/call" then
                  [$plan.answers[] | select(.tool_use_id == $msg.params._meta["claudecode/toolUseId"])][0] as $a
                  | if $a then "W " + (reply($m; $a | call_result) | tojson) else "H " + $l end
                elif $msg.id == null or $msg.method == "ping" then "W " + (reply($m; {}) | tojson)
                else "W " + ({type:"control_response", response:{subtype:"success", request_id:$m.request_id,
                    response:{mcp_response:{jsonrpc:"2.0", id:$msg.id, error:{code:-32601, message:"Method not found"}}}}} | tojson) end
            elif $m.type == "control_request" then
              .out = "W " + ({type:"control_response", response:{subtype:"error", request_id:$m.request_id,
                  error:"badbot answers MCP messages only"}} | tojson)
            elif $m.type == "stream_event" and $m.parent_tool_use_id == null then
              step($m.event)
              | if .done then .out = "S " + (del(.out, .emit) | tojson)
                elif .emit != [] then .out = "P " + (.emit[0] | tojson) else . end
            elif $m.type == "result" then .out = "R " + $l
            elif $m.type == "x-exit" then .out = "X " + $l
            else . end
          end;
        .out)')
exec {src}<&-

# The turn: chunk k goes to claude once it has acknowledged k (and settled);
# a result line past those means it ended its turn without a reply.
seen=0 acks=0 next=0 end= failure= said=
expected=$((settle + (${#chunks[@]} > 0 ? ${#chunks[@]} - 1 : 0)))
: >"$held.new"
while :; do
    while ((next < ${#chunks[@]} && acks >= settle + next)); do
        printf '%s' "${chunks[next]}" >&"$w"
        ((next++))
    done
    if ((next < ${#chunks[@]} || acks < settle)); then
        IFS= read -r -t 60 -u "$r" line
    else
        IFS= read -r -u "$r" line
    fi
    rc=$?
    if ((rc != 0)); then
        [[ $stopped ]] && ((rc > 128)) && continue # the trap stopped the reading: E follows
        ((rc > 128)) && failure="claude did not take in the conversation" || failure="claude's output ended"
        break
    fi
    ((seen++ < nheld)) || ((lines++))
    case $line in
        P\ *) printf '%s\n' "${line#P }" ;;
        W\ *) printf '%s\n' "${line#W }" >&"$w" ;;
        H\ *) printf '%s\n' "${line#H }" >>"$held.new" ;;
        R\ *) ((++acks > expected)) && { said=${line#R }; break; } ;;
        X\ *) said=${line#X }; break ;;
        [SE]\ *) end=$line; break ;;
    esac
done
kill "$tail_pid" 2>/dev/null
tail_pid=
exec {r}<&- {w}>&-

if [[ $stopped ]]; then
    stop_claude
    jq -c -L "$here" --arg p "$prefix" 'include "anthropic"; (fresh + .) as $s
        | {type:"result", stop:"aborted", message:{role:"assistant", content:($s | content(true; $p))}, usage:($s | usage)}' \
        <<<"${end:2}"
    [[ $end ]] || jq -nc '{type:"result", stop:"aborted", message:{role:"assistant", content:[]}}'
    exit 0
fi
if [[ $end != S\ * ]]; then
    stop_claude
    [[ $said ]] || said='{}'
    msg=$(jq -r --arg f "$failure" 'if $f != "" then $f
        else .result // (.errors[0]? | strings) // if .type == "x-exit" then "claude exited with status \(.status) without a reply"
             else "claude ended its turn without a reply" end end' <<<"$said" 2>/dev/null)
    fail "${msg:-claude ended without a reply}"
fi

# The reply: its result, and what claude now holds. After calls, claude waits
# for their results; after end_turn, its turn closes with a result line still
# to come; after anything else (max_tokens: it would go on by itself), it ends.
end=${end:2}
out=$(jq -c -L "$here" --arg p "$prefix" 'include "anthropic";
    {type:"result", stop:stop_name, message:{role:"assistant", content:content(false; $p)}, usage:usage}' <<<"$end")
stop=$(jq -r .stop <<<"$out")
if [[ $stop == tool_use || $stop == end_turn ]]; then
    echo "$lines" >"$cdir/lines"
    mv "$held.new" "$held"
    jq -n -L "$here" --arg p "$prefix" --slurpfile req "$req" --slurpfile plan "$D/plan.json" \
        --slurpfile out <(printf '%s' "$out") \
        --arg cdir "$cdir" 'include "anthropic";
        $out[0] as $out | $out.message.content as $c
        | {dir:$cdir, setup:$plan[0].setup, phase:(if $out.stop == "tool_use" then "calling" else "ending" end),
           calls:[$c[] | select(.type == "tool_use") | .id],
           fed:($req[0].messages + (if $c == [] then [] else [$out.message] end) | api_messages($p))}' >"$D/state.json"
else
    stop_claude
fi
printf '%s\n' "$out"
