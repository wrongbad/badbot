#!/usr/bin/env bash
# tools: runs every tool call an assistant message asks for, each in a worker.
# Kills one on cancel (the inbox decides which), and all at exit. Calls run in
# the kernel's process group, so Ctrl-C reaches them like everything else.
#   echo '{"type":"message","source":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"shell","input":{"command":"date"}}]}}' | badbot/tools.sh
. "$(dirname "$0")/lib.sh"

declare -A running=() # call id: its worker's pid
mkdir -p "$session.d/calls"

# A call's files: $c.out (stdout and stderr), $c.pid, $c.status, and $c.killed,
# which kill_call leaves in case the call has not started yet: whichever of the
# two comes second does the killing, with killtree (lib.sh).
kill_call() {
    local c
    c=$(calls "$1")
    [[ -e $c.status ]] && return # over already
    touch "$c.killed"
    [[ -s $c.pid ]] || return # not started: it kills itself
    killtree "$(<"$c.pid")" 2>/dev/null
}

# job_after SECONDS ID: says the call goes on as a job, if it still runs then,
# and has not gone on as one already ($c.job: a message sent it). The sleep
# runs in the foreground, as a background one would ignore Ctrl-C; its stderr
# is muted, as when the call ends and kills it, bash says "Terminated: 15".
job_after() {
    local c
    c=$(calls "$2")
    { { sleep "$1"; } 2>/dev/null; [[ -e $c.status || -e $c.job ]] || { : >"$c.job"; put '{type:"job",call:$id}' --arg id "$2"; }; } &
}

# Worker: one call, after its tool_start, to its block. Past its wait, a timer
# says it goes on as a job.
run_call() {
    local id name cmd wait c status timer limit=100000 media_limit=3000000 start=$SECONDS
    { read -r id; read -r name; read -r wait; } < <(jq -r '.id, .name, (.input.wait // "")' <<<"$1")
    cmd=$(jq -r '.input.command // ""' <<<"$1")
    c=$(calls "$id")
    : >"$c.out" # there even if the call is killed before it starts
    if [[ $name != shell ]]; then
        echo "no tool named $name" >"$c.out" && status="not run"
    elif [[ ! $cmd ]]; then
        echo "no command given" >"$c.out" && status="not run"
    else
        if [[ $wait ]]; then
            job_after "$wait" "$id"
            timer=$!
        fi
        {
            bare bash -c "$cmd" >"$c.out" 2>&1 </dev/null &
            echo $! >"$c.pid"
            [[ -e $c.killed ]] && kill_call "$id"
            wait $!
        } 2>/dev/null
        status=$?
        [[ -e $c.killed ]] && ((status > 128)) && status=killed || status="exit $status"
        echo "$status" >"$c.status"
        [[ ${timer-} ]] && pkill -P "$timer" sleep # the timer's sleep, never the timer: it may hold the lock
    fi
    local size media out head= tail= lines=0
    size=$(($(wc -c <"$c.out"))) # $((…)): wc pads
    media=$(media "$c.out")
    if [[ $media && $status == "exit 0" ]] && ((size <= media_limit)); then
        out=$(base64 <"$c.out" | tr -d '\n' | jq -Rsc --arg h "[$status; $media, $size bytes]" --arg m "$media" \
            '{content:[{type:"text", text:$h}, {type:"image", source:{type:"base64", media_type:$m, data:.}}]}')
    else # text up to the limit; past it, where it is, and a preview for the screen; not text, what it was
        local why= # an image not sent: why
        [[ $media && $status != "exit 0" ]] && why="the command failed, so its messages may be in it"
        [[ $media && $status == "exit 0" ]] && why="images over $media_limit bytes are not sent, so make it smaller (sips -Z 1568, magick -resize 1568x1568)"
        if ((size > limit)); then
            lines=$(($(wc -l <"$c.out")))
            [[ $(tail -c 1 "$c.out") ]] && ((lines++)) # a last line with no newline
            { head=$(head -c 4096 "$c.out" | head -n 5) tail=$(tail -c 4096 "$c.out" | tail -n 5); } 2>/dev/null # bash: "ignored null byte"
        fi
        out=$(head -c "$((size > limit ? 8192 : limit))" "$c.out" | jq -Rsc --arg st "$status" \
            --arg m "${media:-binary output}" --argjson size "$size" --argjson limit "$limit" --arg out "$c.out" --arg why "$why" \
            --argjson lines "$lines" --arg head "$head" --arg tail "$tail" '
            (.[:8192] | contains("\u0000") or ((explode | map(select(. == 65533)) | length) * 8 > length)) as $binary
            | if $binary or $m != "binary output" then
                  {content:"[\($st); \($size) bytes of \($m) not shown\(if $why != "" then ": " + $why + ";" else "," end) all of it in \($out)]"}
              elif $size > $limit then
                  {content:"[\($st); \($size) bytes, \($lines) lines: more than \($limit) bytes, so not shown. All of it is in \($out): read parts of it with head, tail, sed -n, grep or awk]",
                   preview:{lines:$lines, head:($head | split("\n") | map(if length > 200 then .[:200] + " …" else . end)),
                       tail:($tail | split("\n") | map(if length > 200 then "… " + .[-200:] else . end))}}
              else {content:"[\($st)]\n\(.)"} end
            | .content = [{type:"text", text:.content}]')
    fi
    say "$(jq -c --arg id "$id" --arg name "$name" --arg st "$status" --argjson ran $((SECONDS - start)) '{type:"block",
        call:$id, block:{type:"tool_result", tool_use_id:$id, is_error:false, content, name:$name, status:$st, ran:$ran}}
        + if .preview then {preview} else {} end' <<<"$out")" # stdin, not an argument: an image is megabytes
}

# media FILE: an image's media type, by its first bytes; nothing for anything else.
media() {
    case $(head -c 12 "$1" | od -An -tx1 | tr -d ' \n') in
        89504e470d0a1a0a*) echo image/png ;;
        ffd8ff*) echo image/jpeg ;;
        47494638[37]961*) echo image/gif ;;
        52494646????????57454250*) echo image/webp ;; # RIFF, its size, WEBP
    esac
}

while IFS= read -r line; do
    printf '%s\n' "$line" # pass it on
    case $line in
        '{"type":"message","source":"assistant"'*)
            while IFS= read -r call; do
                put '{type:"tool_start",call:$c.id,name:$c.name,input:$c.input}' --argjson c "$call"
                run_call "$call" >/dev/null & # workers say on fd 3; stdout is the next actor's
                running[$(jq -r .id <<<"$call")]=$!
            done < <(jq -c '.message.content[] | select(.type == "tool_use")' <<<"$line") ;;
        '{"type":"job"'*) [[ $line =~ $CALL ]] && : >"$(calls "${BASH_REMATCH[1]}").job" ;; # its timer need not say so too
        '{"type":"cancel"'*) [[ $line =~ $CALL && ${running[${BASH_REMATCH[1]}]-} ]] && kill_call "${BASH_REMATCH[1]}" ;;
        '{"type":"block"'*) [[ $line =~ $CALL ]] && unset 'running[${BASH_REMATCH[1]}]' ;;
        '{"type":"exit"'*)
            for id in "${!running[@]}"; do kill_call "$id"; done
            exit ;;
    esac
done
wait # run alone: let the calls finish
