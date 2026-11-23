#!/usr/bin/env bash
# tests/test.sh: badbot's tests, all at once, in parallel. No network, no key:
# the echo provider, and for openai.sh a mock server (tests/mock.py, python3).
#   tests/test.sh [-v] [-l] [NAME...]
#     NAME   run only these tests (NAME, or NAME_*: "openai" runs every openai_ test)
#     -v     verbose (or TEST_VERBOSE=1): on failure, show the test's log and
#            session, and keep the temp dir
#     -l     list the tests
# Each test runs in a background job, in its own temp dir (its TMPDIR too), and
# every kernel it starts runs in a process group of its own, as in a terminal;
# a test ends by killing its own groups, and nothing else.
((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 404)) || { echo "tests: need bash 4.4 or later" >&2; exit 2; }
set -u
TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$TESTS")
BADBOT=$REPO/badbot
exec 3>&- 4>&- # a kernel's fds, if this runs in one
unset BADBOT_SESSION BADBOT_MODEL OPENAI_API_KEY OPENAI_BASE_URL OPENAI_MODEL
export BADBOT_PROVIDER=echo NO_COLOR=1
TIMEOUT=${TEST_TIMEOUT:-60} # seconds, for any one test
VERBOSE=
[[ ${TEST_VERBOSE:-0} != 0 ]] && VERBOSE=1
INT_IGNORED=$(trap -p INT) # inherited, before this script sets its own

# ---------------------------------------------------------------- helpers
# These run inside a test: T is its directory, and the current directory.

fail() { printf '%s\n' "$*" >"$T/fail"; exit 1; }
skip() { printf '%s\n' "$*" >"$T/skip"; exit 0; }

# now: NOW, in milliseconds (bash 5: exact; 4.4: to the second, so SLACK).
SLACK=0
[[ ${EPOCHREALTIME-} ]] || SLACK=1000
now() {
    if [[ ${EPOCHREALTIME-} ]]; then
        local t=${EPOCHREALTIME/[.,]/}
        NOW=$((10#$t / 1000))
    else
        NOW=$((SECONDS * 1000))
    fi
}
# nap: a tenth of a second, without a fork: a read that times out on a fifo
# no one writes (NAP, opened by run_test).
nap() { read -r -t 0.1 -u "$NAP" _ 2>/dev/null; :; }

# until_ SECONDS CMD...: polls CMD until it succeeds; false at the deadline.
until_() {
    local end
    now
    end=$((NOW + $1 * 1000))
    shift
    until "$@"; do
        now
        ((NOW < end)) || return 1
        nap
    done
}

# check FILE EXPR [MESSAGE]: EXPR, a jq expression over $e (FILE's events, the
# lines that read as JSON objects), must be true. Helpers: of(TYPE), the events
# of a type; text, a tool_result's or a message's text.
JQDEFS='def of($t): [$e[] | select(.type == $t)];
    def text: if type == "array" then map(text) | join("") elif type == "object" then
        (if .type == "text" then .text elif .content then .content | text else "" end) else tostring end;'
check() {
    jq -Rne "[inputs | fromjson? | objects] as \$e | $JQDEFS $2" "$1" >/dev/null 2>&1 ||
        fail "${3:-$2}"
}
# has FILE EXPR: some event in FILE satisfies EXPR (a jq condition on the event).
has() { jq -Rne "[inputs | fromjson? | objects | select($2)] | length > 0" "$1" >/dev/null 2>&1; }
# count FILE EXPR
count() { jq -Rn "[inputs | fromjson? | objects | select($2)] | length" "$1" 2>/dev/null; }
# get FILE JQ: JQ over $e, raw
get() { jq -Rnr "[inputs | fromjson? | objects] as \$e | $JQDEFS $2" "$1" 2>/dev/null; }

# valid FILE: every line is a JSON object whose first key is type.
valid() {
    local bad
    bad=$(jq -Rnr '[inputs | try (fromjson | type == "object" and (keys_unsorted[0] == "type")) catch false]
        | if length == 0 then "empty" else (index(false) // empty) + 1 end' "$1" 2>&1)
    [[ ! $bad ]] || fail "${1##*/}: line $bad is not a JSON event (or the file is empty)"
}

# procs PGID: the processes of a group, on one line (for a failure's message;
# ps is slow on macOS, so the polls use kill -0).
procs() { ps -A -o pid=,pgid=,command= | awk -v g="$1" '$2 == g { $2 = ""; printf "%s; ", $0 }'; }
gone() { ! kill -0 "$1" 2>/dev/null; }
# empty PGID: no process left in the group.
empty() { ! kill -0 -- "-$1" 2>/dev/null; }
# pids_gone FILE: every pid in FILE has ended.
pids_gone() { local p; for p in $(<"$1"); do gone "$p" || return 1; done; }
# lines N FILE: FILE has N lines
lines() { [[ -f $2 && $(wc -l <"$2") -eq $1 ]]; }

# kernel NAME: starts badbot.sh $T/NAME in a process group of its own (PG),
# stdin a fifo this test holds open on fd IN.
kernel() {
    local s=$T/$1
    rm -f "$s.in" && mkfifo "$s.in" || fail "mkfifo"
    set -m
    "$BADBOT/badbot.sh" "$s" <"$s.in" >"$s.stdout" 2>"$s.stderr" &
    PG=$!
    set +m
    echo "$PG" >>"$T/pgids"
    exec {IN}>"$s.in"
}
type_() { printf '%s\n' "$@" >&"$IN"; }
alive() { kill -0 "$PG" 2>/dev/null; }
dead() { ! alive; }

# wait_for S EXPR [SECONDS]: until an event of S satisfies EXPR; fails at the
# deadline, or at once if the kernel has gone.
wait_for() {
    local end
    now
    end=$((NOW + ${3:-20} * 1000))
    until has "$1" "$2"; do
        now
        ((NOW < end)) || fail "no event ($2) in ${3:-20}s"
        if [[ ${PG-} ]] && dead && ! has "$1" "$2"; then fail "kernel gone, and no event ($2)"; fi
        nap
    done
}

# finish [SECONDS]: ends stdin, and the kernel must exit, with status 0, and
# leave nothing running in its group.
finish() {
    exec {IN}>&-
    until_ "${1:-10}" dead || fail "the kernel did not exit within ${1:-10}s of eof"
    wait "$PG"
    local rc=$?
    ((rc == 0)) || fail "the kernel exited $rc"
    until_ 4 empty "$PG" || fail "left running: $(procs "$PG")"
}

# a tool_use line for the echo provider: one call with this input
call() { printf '!@shell %s' "$(jq -nc "$@")"; }

# ---------------------------------------------------------------- tests
TESTS_ALL=(chat tools status job barge abort abort_tree abort_jobs bad_send resume
    sigint sighup sigterm big actors nobus ids subagent
    openai_text openai_tools openai_noindex openai_stopcalls openai_401 openai_strerror
    openai_nospace openai_crlf openai_sigterm openai_request openai_kernel)

t_chat() {
    kernel s
    type_ hi
    wait_for s '.type == "run_end" and .reason == "done"'
    finish
    valid s
    check s '(of("message") | map(select(.source == "assistant")) | .[0].message.content | text) == "echo: hi "' \
        "no 'echo: hi' from the assistant"
    check s '$e[-1].type == "exit"' "the last event is not exit"
    check s '(of("hello") | length) == 1 and $e[0].type == "hello" and $e[0].session == "'"$T/s"'"' "no hello naming the session"
    check s '[$e[].type] | (index("run_start") < index("run_end")) and (index("run_end") < index("settled")) and (index("settled") < index("exit"))' \
        "run_start, run_end, settled, exit: not in that order"
}

t_tools() {
    kernel s
    type_ '!sleep 0.3 && echo a; echo b'
    wait_for s '.type == "run_end"'
    finish
    valid s
    check s '(of("block") | length) == 2 and all(of("block")[]; .block.status == "exit 0")' "not two blocks with exit 0"
    check s '(of("message") | map(select(.source == "assistant"))[0].message.content | map(select(.type == "tool_use").id)) as $ids
        | (of("message") | map(select(.source == "results")) | length == 1 and
            (.[0].message.content | map(.tool_use_id) == $ids and map(.content | text) == ["[exit 0]\na\n", "[exit 0]\nb\n"]))' \
        "the results message does not hold both results, in call order"
    check s 'of("run_end")[0].reason == "done"' "run_end is not done"
    check s '(of("turn_end") | map(.stop)) == ["tool_use", "end_turn"]' "turns: not tool_use then end_turn"
}

t_status() {
    kernel s
    type_ '!exit 255;' # two calls: "exit 255", and an empty one
    wait_for s '.type == "run_end"'
    type_ '!@nosuch {}'
    wait_for s '.type == "run_end" and .run == 2'
    finish
    # the blocks, in call order
    local by_call='(of("block") | map({(.call): .block}) | add) as $b | [of("tool_start")[] | $b[.call]]'
    check s "$by_call"' | map(.status) == ["exit 255", "not run", "not run"]' \
        "statuses are not exit 255, not run, not run: $(get s "$by_call"' | map(.status) | tojson')"
    check s "$by_call"' | (.[1].content | text | startswith("[not run]\nno command given"))
        and (.[2].content | text | startswith("[not run]\nno tool named nosuch"))' "no 'no command given', or no 'no tool named nosuch'"
}

t_job() {
    kernel s
    type_ "$(call '{command:"sleep 4; echo job-out", wait:0}')" # longer than the run it starts
    exec {IN}>&- # eof at once: the kernel waits for the job
    wait_for s '.type == "exit"' 25
    finish
    valid s
    local id
    id=$(get s 'of("job")[0].call')
    [[ $id ]] || fail "no job event"
    check s 'of("message") | map(select(.source == "results"))[0].message.content[0]
        | .tool_use_id == "'"$id"'" and (.content | text | startswith("[a job now") and contains("'"$T/s.d/calls/$id.out"'"))' \
        "no placeholder answer naming $T/s.d/calls/$id.out"
    check s '[$e[] | select(.type == "message" and .source != "assistant") | .message.content | text
        | select(contains("[the job '"$id"' has ended] [exit 0]\njob-out"))] | length == 1' "no '[the job $id has ended]' message"
    check s '([$e[] | .type == "message" and .source != "assistant" and (.message.content | text | contains("[the job"))] | index(true)) as $r
        | ([$e[].type] | index("exit")) as $x | $r != null and $x != null and $r < $x' "exit came before the job's result"
    check s 'of("run_end") | length > 0 and all(.[]; .reason == "done")' "a run did not end done"
    [[ $(<"s.d/calls/$id.out") == job-out && $(<"s.d/calls/$id.status") == "exit 0" ]] || fail "the job's files are wrong"
}

t_barge() { # a message never waits for a call: the slow one goes on as a job at once
    kernel s
    type_ '!sleep 5; echo fast'
    wait_for s '.type == "block" and .block.status == "exit 0"' # fast
    local t0
    now
    t0=$NOW
    type_ next
    wait_for s '.type == "job"' 10
    now
    ((NOW - t0 <= 1500 + SLACK)) || fail "the job came $((NOW - t0))ms after the message, not at once"
    wait_for s '.type == "message" and (.message.content | tostring | contains("[the job"))' 
    finish
    valid s
    local slow fast
    slow=$(get s 'of("tool_start")[0].call') fast=$(get s 'of("tool_start")[1].call')
    check s 'of("job") | length == 1 and .[0].call == "'"$slow"'"' "the job is not the slow call"
    check s 'of("message") | map(select(.source == "results+inbox"))[0].message.content
        | length == 3 and .[0].tool_use_id == "'"$slow"'" and (.[0] | text | startswith("[a job now"))
        and .[1].tool_use_id == "'"$fast"'" and (.[1] | text) == "[exit 0]\nfast\n" and .[2].text == "next"' \
        "the message is not [slow: a job, fast: its result, next]"
}

t_abort() {
    kernel s
    type_ '!sleep 30'
    wait_for s '.type == "tool_start"'
    local id
    id=$(get s 'of("tool_start")[0].call')
    until_ 10 test -s "s.d/calls/$id.pid" || fail "the call did not start"
    type_ '{"type":"abort"}'
    wait_for s '.type == "run_end"'
    check s 'of("cancel") | length == 1 and .[0].call == "'"$id"'"' "no cancel for $id"
    check s 'of("block")[0] | .block.status == "killed" and (.block.content | text | startswith("[killed]"))' "the block is not killed"
    check s 'of("run_end")[0].reason == "aborted"' "run_end is not aborted"
    until_ 4 pids_gone "s.d/calls/$id.pid" || fail "sleep 30 still runs"
    type_ hi # and the kernel carries on
    wait_for s '.type == "run_end" and .run == 2'
    finish
    check s 'of("run_end")[1].reason == "done"' "the next run is not done"
}

t_abort_tree() {
    kernel s
    # a child; a child that ignores TERM, and its child; and the call's own
    # sleep: their pids in a file
    local p inner
    printf -v p %q "$T/pids"
    inner="trap '' TERM; sleep 32 & echo \$! >>$p; wait"
    type_ "$(call --arg c "sleep 31 & echo \$! >>$p; bash -c $(printf %q "$inner") & echo \$! >>$p; sleep 33 & echo \$! >>$p; wait" '{command:$c}')"
    until_ 15 lines 4 pids || fail "the call's processes did not start"
    type_ '{"type":"abort"}'
    wait_for s '.type == "run_end"'
    check s 'of("block")[0].block.status == "killed" and of("run_end")[0].reason == "aborted"' "not killed, aborted"
    until_ 5 pids_gone pids || fail "left running after abort: $(for p in $(<pids); do gone "$p" || ps -o pid=,command= -p "$p"; done)"
    finish
}

t_abort_jobs() {
    kernel s
    type_ "$(call --arg p "$T/pids" '{command:"sleep 35 & echo $! >>\($p | @sh); wait; echo late", wait:0}')"
    wait_for s '.type == "run_end"'
    check s 'of("job") | length == 1' "no job"
    local id
    id=$(get s 'of("job")[0].call')
    type_ '{"type":"abort","jobs":true}'
    wait_for s '.type == "block"'
    check s 'of("cancel") | length == 1 and .[0].call == "'"$id"'"' "no cancel for the job"
    check s 'of("block")[0].block.status == "killed"' "the job was not killed"
    until_ 4 pids_gone pids || fail "the job's sleep still runs"
    finish
    check s '(of("run_start") | length) == 1' "a new run started from the killed job's result"
    check s '[of("message")[] | .message.content | text | select(contains("[the job"))] | length == 0' "the killed job's result was delivered"
}

t_bad_send() {
    kernel s
    type_ '{"type":"send","content":[]}' '{"type":"send"}' '{"type":"send","content":[1,"x",{"no":"type"}]}' '{not json' hi
    wait_for s '.type == "run_end"'
    finish
    valid s
    check s 'of("error") | map(select(.where == "send")) | length == 3' "not 3 send errors: $(get s 'of("error") | tojson')"
    check s 'of("error") | map(select(.where == "command")) | length == 1' "no error for the bad command"
    check s '(of("run_start") | length) == 1 and of("run_end")[0].reason == "done"' "hi did not run to done"
    check s 'of("message")[0].message.content == [{type:"text", text:"hi"}]' "the first message is not just hi"
}

t_resume() {
    kernel s
    type_ hi
    finish
    kernel s
    type_ again
    finish
    valid s
    check s '(of("run_start") | map(.run)) == [1, 2] and (of("run_end") | map(.run)) == [1, 2]' "runs are not 1, 2"
    check s '(of("hello") | length) == 2' "not two hellos"
    check s 'of("turn_start") | map([.run, .turn]) == [[1, 1], [2, 1]]' "turns are not numbered per run"
    jq -e "[] as \$e | $JQDEFS"'.messages | map(.content | text) == ["hi", "echo: hi ", "again"]' s.d/request.json >/dev/null ||
        fail "request.json does not hold run one's context: $(jq -c '.messages' s.d/request.json)"
    check s 'of("message") | map(select(.source == "assistant"))[-1].message.content | text == "echo: again "' "no 'echo: again'"
}

# Ctrl-C, SIGHUP, SIGTERM: the kernel's process group, with a call and a long timer running.
signal_test() {
    kernel s
    type_ "$(call '{command:"sleep 36", wait:600}')"
    wait_for s '.type == "tool_start"'
    local id t0
    id=$(get s 'of("tool_start")[0].call')
    until_ 10 test -s "s.d/calls/$id.pid" || fail "the call did not start" # and its timer, before it
    now
    t0=$NOW
    kill "-$1" -- "-$PG"
    until_ 5 empty "$PG" || fail "left running 5s after SIG$1: $(procs "$PG")"
    now
    ((NOW - t0 < 2000 + SLACK)) || fail "SIG$1: took $((NOW - t0))ms to end"
    exec {IN}>&-
}

t_sigint() {
    # a shell started in the background, by one without job control, ignores
    # SIGINT, and so does all it starts: a kernel too, and no bash can undo it
    [[ $INT_IGNORED ]] && skip "SIGINT is ignored here (the suite was started in the background?)"
    signal_test INT
    local id
    id=$(get s 'of("tool_start")[0].call')
    kernel s # resumed: the unfinished call is answered
    type_ hi
    finish
    jq -e --arg id "$id" '[.messages[] | select(.role == "user") | .content[] | select(.type == "tool_result" and .tool_use_id == $id)
        | .content[0].text | select(startswith("[interrupted"))] | length == 1' s.d/request.json >/dev/null ||
        fail "request.json does not answer $id with [interrupted"
    jq -e --arg id "$id" '.messages | map(.role) == ["user", "assistant", "user"]
        and (.[1].content[] | select(.type == "tool_use") | .id) == $id
        and (.[2].content | map(.type) == ["tool_result", "text"])' s.d/request.json >/dev/null ||
        fail "request.json's messages are not [user, assistant with the call, user with its answer and hi]"
    check s '(of("run_start") | map(.run)) == [1, 2]' "the resumed run is not run 2"
}
t_sighup() { signal_test HUP; }
t_sigterm() { signal_test TERM; }

t_big() {
    kernel s
    local c='head -c 90000 /dev/zero | tr "\0" x'
    type_ "!$c; $c; $c; $c; $c; $c"
    wait_for s '.type == "run_end"' 45
    finish
    valid s
    check s 'of("block") | length == 6 and all(.[]; .block.status == "exit 0"
        and (.block.content | text) == "[exit 0]\n" + ("x" * 90000))' "not six whole 90000-byte results"
    check s 'of("message") | map(select(.source == "results"))[0].message.content | length == 6' "the results message does not have 6 results"
    check s 'of("run_end")[0].reason == "done"' "the run is not done"
    jq -e '.messages | length == 3' s.d/request.json >/dev/null || fail "request.json is not valid, or not 3 messages"
}

t_actors() {
    local out
    out=$(echo hi | "$BADBOT/input.sh")
    [[ $out == $'{"type":"send","content":"hi"}\n{"type":"eof"}' ]] || fail "input.sh alone: $out"
    printf '%s\n' '{"type":"send","content":"hi"}' '{"type":"eof"}' | "$BADBOT/inbox.sh" | "$BADBOT/model.sh" >out.jsonl
    valid out.jsonl
    check out.jsonl 'of("turn_end") | length == 1 and .[0].stop == "end_turn"' "inbox | model: no turn ended"
    check out.jsonl 'of("message") | map(select(.source == "assistant"))[0].message.content | text == "echo: hi "' "inbox | model: no 'echo: hi'"
    echo '{"type":"message","source":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"shell","input":{"command":"echo out"}}]}}' |
        "$BADBOT/tools.sh" >tools.jsonl
    check tools.jsonl 'of("block") | length == 1 and (.[0].block.content | text) == "[exit 0]\nout\n"' "tools.sh alone: no block"
    local left
    left=$(ls -A "$TMPDIR")
    [[ ! $left ]] || fail "left in TMPDIR: $left"
}

t_nobus() {
    local a err rc
    for a in input inbox model tools; do
        err=$(BADBOT_SESSION=$T/s "$BADBOT/$a.sh" 2>&1 3>&- >/dev/null </dev/null)
        rc=$?
        ((rc != 0)) || fail "$a.sh exited 0 with no bus"
        [[ $err == *"has no bus"* ]] || fail "$a.sh did not say it has no bus: $err"
    done
}

t_ids() {
    # tool ids from a model: as a file name, they are made safe; as data, kept
    local evil1='$(touch pwned1)' evil2='`touch pwned2`' evil3='$(touch pwned3)' up=../x
    jq -nc --arg a "$evil1" --arg b "$up" --arg c "$evil2" '{type:"message", source:"assistant",
        message:{role:"assistant", content:[{type:"tool_use", id:$a, name:"shell", input:{command:"echo one"}},
            {type:"tool_use", id:$b, name:"shell", input:{command:"echo two"}},
            {type:"tool_use", id:$c, name:"shell", input:{command:"sleep 39"}}]}}' >msg.json
    {
        cat msg.json
        until_ 5 test -s "s.d/calls/_touch_pwned2_.pid"
        jq -nc --arg c "$evil2" '{type:"cancel", call:$c}'
        jq -nc --arg c "$evil3" '{type:"cancel", call:$c}'
        jq -nc --arg c "$evil3" '{type:"block", call:$c, block:{type:"tool_result", tool_use_id:$c, content:[]}}'
    } | BADBOT_SESSION=$T/s "$BADBOT/tools.sh" 3>bus >/dev/null
    valid bus
    check bus 'of("block") | map({(.call): .block.status}) | add == {"'"$evil1"'": "exit 0", "../x": "exit 0", "'"$evil2"'": "killed"}' \
        "tools: blocks are not (one, two: exit 0, sleep: killed): $(get bus 'of("block") | map([.call, .block.status]) | tojson')"
    [[ -e s.d/calls/___x.out && ! -e s.d/x.out && ! -e x.out ]] || fail "../x went outside calls/"
    [[ ! $(find . -name '*.out' ! -path './s.d/calls/*') ]] || fail "a call's file outside calls/: $(find . -name '*.out')"
    # the inbox: calls with these ids, their results, a job, a cancel
    {
        cat msg.json
        jq -nc --arg c "$evil1" '{type:"job", call:$c}'
        for id in "$evil1" "$up" "$evil2" "$evil3"; do
            jq -nc --arg c "$id" '{type:"block", call:$c, block:{type:"tool_result", tool_use_id:$c, content:[{type:"text", text:"[exit 0]\n"}]}}'
        done
        echo '{"type":"abort","jobs":true}'
        echo '{"type":"eof"}'
    } | BADBOT_SESSION=$T/s2 "$BADBOT/inbox.sh" 3>bus2 >/dev/null
    valid bus2
    check bus2 'of("message")[0].message.content | map(.tool_use_id // empty) == ["'"$evil1"'", "../x", "'"$evil2"'"]' \
        "inbox: the results message does not keep the ids: $(get bus2 'of("message") | tojson')"
    [[ ! $(find . "$REPO" -name 'pwned*' 2>/dev/null) ]] || fail "an id ran as a command: $(find . "$REPO" -name 'pwned*')"
}

t_subagent() {
    kernel s
    local q
    printf -v q %q "$BADBOT/badbot.sh"
    type_ "$(call --arg c "echo \"say hi\" | BADBOT_PROVIDER=echo $q" '{command:$c, wait:0}')"
    wait_for s '.type == "message" and (.message.content | tostring | contains("[the job"))' 30
    finish
    local inner=("$TMPDIR"/badbot-session-??????)
    ((${#inner[@]} == 1)) && [[ -f ${inner[0]} ]] || fail "no session of its own for the subagent: ${inner[*]}"
    check "${inner[0]}" '$e[0].type == "hello" and $e[0].session == "'"${inner[0]}"'" and $e[-1].type == "exit"
        and of("run_end")[0].reason == "done"' "the subagent's session did not run to done"
    check s '[of("message")[] | select(.source != "assistant") | .message.content | text
        | select(contains("[the job") and contains("[exit 0]") and contains("echo: say hi"))] | length == 1' \
        "the subagent's answer is not the job's result"
}

# openai.sh, alone, against the mock: REQ in, its events in out.jsonl.
REQ='{"model":"test-model","session":"s","system":"be brief","messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}],"tools":[],"params":{}}'
openai() { # SCENARIO [REQUEST]
    printf '%s\n' "${2:-$REQ}" | OPENAI_BASE_URL=http://127.0.0.1:$MOCK_PORT/$1 OPENAI_API_KEY=sk-test \
        "$BADBOT/openai.sh" >out.jsonl 2>err || fail "openai.sh exited $?"
    valid out.jsonl
    check out.jsonl '(of("result") | length) == 1 and $e[-1].type == "result"' "the last event is not its one result"
}
text_ok() {
    check out.jsonl '[of("text_delta")[].text] == ["Hel", "lo"]' "deltas are not Hel, lo"
    check out.jsonl 'of("result")[0] | .stop == "end_turn" and .message == {role:"assistant", content:[{type:"text", text:"Hello"}]}
        and .usage == {input:6, output:2, cache_read:4, cache_write:0}' "not the result: $(tail -n1 out.jsonl)"
}
t_openai_text() {
    openai text
    text_ok
    jq -e '.model == "test-model" and .stream == true and .messages == [{role:"system", content:"be brief"}, {role:"user", content:"hi"}]' \
        "$MOCK_DIR/request-text.json" >/dev/null || fail "the request body is wrong: $(cat "$MOCK_DIR/request-text.json")"
    [[ $(<"$MOCK_DIR/auth-text") == "Bearer sk-test" ]] || fail "no Authorization: Bearer sk-test"
}
t_openai_nospace() { openai nospace; text_ok; }
t_openai_crlf() { openai crlf; text_ok; }
t_openai_tools() {
    openai tools
    check out.jsonl 'of("result")[0] | .stop == "tool_use" and .message.content == [{type:"text", text:"Let me look."},
        {type:"tool_use", id:"call_1", name:"shell", input:{command:"ls"}},
        {type:"tool_use", id:"call_2", name:"shell", input:{command:"date", wait:0}}]' "not the calls: $(tail -n1 out.jsonl)"
}
t_openai_noindex() {
    openai noindex
    check out.jsonl 'of("result")[0] | .stop == "tool_use" and .message.content == [
        {type:"tool_use", id:"a", name:"shell", input:{command:"pwd"}},
        {type:"tool_use", id:"b", name:"shell", input:{command:"date"}}]' "not the calls: $(tail -n1 out.jsonl)"
}
t_openai_stopcalls() {
    openai stopcalls
    check out.jsonl 'of("result")[0] | .stop == "tool_use" and (.message.content | length) == 1' "stop with calls is not tool_use: $(tail -n1 out.jsonl)"
}
t_openai_401() {
    openai unauthorized
    check out.jsonl 'of("error") | length == 1 and (.[0].message | startswith("openai: Incorrect API key"))' "no error naming the 401: $(head -n1 out.jsonl)"
    check out.jsonl 'of("result")[0] | .stop == "error" and .message.content == []' "the result is not an error"
}
t_openai_strerror() {
    openai strerror
    check out.jsonl 'of("error") | length == 1 and .[0].message == "openai: model not found"' "no error 'model not found': $(head -n1 out.jsonl)"
    check out.jsonl 'of("result")[0].stop == "error"' "the result is not an error"
}
deltas() { [[ $(count out.jsonl '.type == "text_delta"') == "$1" ]]; }
t_openai_sigterm() {
    set -m # its own group: openai.sh, curl, jq
    OPENAI_BASE_URL=http://127.0.0.1:$MOCK_PORT/slow OPENAI_API_KEY=sk-test \
        "$BADBOT/openai.sh" <<<"$REQ" >out.jsonl 2>err &
    local pid=$!
    set +m
    echo "$pid" >>pgids
    until_ 10 deltas 2 || fail "no partial text"
    kill -TERM "$pid"
    until_ 3 gone "$pid" || fail "openai.sh still runs 3s after SIGTERM"
    valid out.jsonl
    check out.jsonl '$e[-1] | .type == "result" and .stop == "aborted" and .message.content == [{type:"text", text:"partial text"}]' \
        "not aborted with the partial text: $(tail -n1 out.jsonl)"
    until_ 3 empty "$pid" || fail "still running: $(procs "$pid")"
}
t_openai_request() {
    local req
    req=$(jq -c '.messages += [{role:"assistant", content:[{type:"text", text:"ok"},
            {type:"tool_use", id:"t1", name:"shell", input:{command:"ls"}}]},
        {role:"user", content:[{type:"tool_result", tool_use_id:"t1", content:[{type:"text", text:"[exit 0]\nfile"}]},
            {type:"text", text:"thanks"}]}]' <<<"$REQ" | jq -c --slurpfile t "$BADBOT/tools.json" '.tools = ($t[0] | map(del(.program)))')
    openai request "$req" # the text stream, its request kept apart
    jq -e '.messages[1:] == [{role:"user", content:"hi"},
        {role:"assistant", content:"ok", tool_calls:[{id:"t1", type:"function", function:{name:"shell", arguments:"{\"command\":\"ls\"}"}}]},
        {role:"tool", tool_call_id:"t1", content:"[exit 0]\nfile"}, {role:"user", content:"thanks"}]
        and (.tools | length == 1 and .[0].type == "function" and .[0].function.name == "shell"
            and .[0].function.parameters.required == ["command"])' "$MOCK_DIR/request-request.json" >/dev/null ||
        fail "the request is not in Chat Completions' terms: $(cat "$MOCK_DIR/request-request.json")"
}
t_openai_kernel() {
    BADBOT_PROVIDER=openai BADBOT_MODEL=test-model OPENAI_API_KEY=sk-test \
        OPENAI_BASE_URL=http://127.0.0.1:$MOCK_PORT/text kernel s
    type_ hi
    wait_for s '.type == "run_end"'
    finish
    valid s
    check s 'of("run_end")[0].reason == "done" and (of("message") | map(select(.source == "assistant"))[0].message.content | text) == "Hello"' \
        "the openai kernel did not answer Hello"
}

# ---------------------------------------------------------------- runner

usage() { sed -n '2,12s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }
selected=()
for arg; do
    case $arg in
        -v) VERBOSE=1 ;;
        -l) printf '%s\n' "${TESTS_ALL[@]}"; exit 0 ;;
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *)
            n=${#selected[@]}
            for t in "${TESTS_ALL[@]}"; do
                [[ $t == $arg || $t == ${arg}_* ]] && selected+=("$t")
            done
            ((${#selected[@]} > n)) || { echo "tests: no test named $arg (-l lists them)" >&2; exit 2; }
            ;;
    esac
done
((${#selected[@]})) || selected=("${TESTS_ALL[@]}")
for need in jq ps awk mkfifo; do
    command -v "$need" >/dev/null || { echo "tests: needs $need" >&2; exit 2; }
done

tmp=${TMPDIR:-/tmp}
ROOT=$(mktemp -d "${tmp%/}/badbot-tests.XXXXXX") || exit 2
declare -A job=() started=()
MOCK_PG=

# Kills every process group this run started: tests, their kernels, the mock.
killall_groups() {
    local pg name
    for name in "${!job[@]}"; do
        kill -KILL -- "-${job[$name]}" 2>/dev/null
        [[ -f $ROOT/$name/pgids ]] && while read -r pg; do kill -KILL -- "-$pg" 2>/dev/null; done <"$ROOT/$name/pgids"
    done
    [[ $MOCK_PG ]] && kill -KILL -- "-$MOCK_PG" 2>/dev/null
    job=()
}
failed=0
at_exit() {
    killall_groups
    if [[ $VERBOSE && $failed != 0 ]]; then
        echo "kept: $ROOT"
    else
        rm -rf -- "$ROOT"
    fi
}
trap at_exit EXIT
trap 'trap - INT TERM HUP; echo "tests: interrupted" >&2; exit 130' INT TERM HUP

# run_test NAME: in a background job of its own.
run_test() {
    T=$ROOT/$1
    export TMPDIR=$T/tmp
    trap 'pgs=$(cat "$T/pgids" 2>/dev/null); for pg in $pgs; do kill -KILL -- "-$pg" 2>/dev/null; done' EXIT
    cd "$T" || exit 1
    mkfifo nap && exec {NAP}<>nap && rm nap || exit 1
    "t_$1"
    exit 0
}

openai_needed=
for name in "${selected[@]}"; do [[ $name == openai_* ]] && openai_needed=1; done
MOCK_DIR=$ROOT/mock MOCK_PORT= mock_error=
if [[ $openai_needed ]]; then
    if ! command -v python3 >/dev/null; then
        mock_error="SKIP: python3 not found"
    else
        mkdir -p "$MOCK_DIR"
        set -m
        python3 "$TESTS/mock.py" "$MOCK_DIR" </dev/null >"$MOCK_DIR/log" 2>&1 &
        MOCK_PG=$!
        set +m
        disown "$MOCK_PG"
        for _ in {1..100}; do [[ -s $MOCK_DIR/port ]] && break; kill -0 "$MOCK_PG" 2>/dev/null || break; sleep 0.05; done
        MOCK_PORT=$(cat "$MOCK_DIR/port" 2>/dev/null)
        [[ $MOCK_PORT ]] || mock_error="FAIL: the mock server did not start: $(tail -n 3 "$MOCK_DIR/log")"
    fi
fi

start=$SECONDS
passed=0 skipped=0
report() { # NAME STATUS [REASON]
    case $2 in
        PASS) echo "PASS $1${VERBOSE:+ ($((SECONDS - started[$1]))s)}"; ((passed++)) ;;
        SKIP) echo "SKIP $1: $3"; ((skipped++)) ;;
        *)
            echo "FAIL $1: $3${VERBOSE:+ ($((SECONDS - ${started[$1]:-$SECONDS}))s)}"
            ((failed++))
            if [[ $VERBOSE ]]; then
                local f
                sed 's/^/    | /' "$ROOT/$1/log" 2>/dev/null | tail -n 30
                for f in "$ROOT/$1"/*; do
                    [[ -f $f && $f != */log && $f != */fail && $f != */pgids && ! -p $f ]] || continue
                    echo "    -- ${f##*/}"
                    tail -n 25 "$f" | cut -c1-240 | sed 's/^/    | /'
                done
            fi
            ;;
    esac
}

for name in "${selected[@]}"; do
    if [[ $name == openai_* && $mock_error ]]; then
        report "$name" "${mock_error%%:*}" "${mock_error#*: }"
        continue
    fi
    mkdir -p "$ROOT/$name/tmp"
    set -m
    (run_test "$name") </dev/null >"$ROOT/$name/log" 2>&1 &
    job[$name]=$!
    set +m
    started[$name]=$SECONDS
done

while ((${#job[@]})); do
    for name in "${!job[@]}"; do
        pid=${job[$name]}
        if kill -0 "$pid" 2>/dev/null; then
            ((SECONDS - started[$name] <= TIMEOUT)) && continue
            kill -KILL -- "-$pid" 2>/dev/null
            [[ -f $ROOT/$name/pgids ]] && while read -r pg; do kill -KILL -- "-$pg" 2>/dev/null; done <"$ROOT/$name/pgids"
            wait "$pid" 2>/dev/null
            unset 'job[$name]'
            report "$name" FAIL "timed out after ${TIMEOUT}s"
            continue
        fi
        wait "$pid"
        rc=$?
        unset 'job[$name]'
        empty "$pid" || kill -KILL -- "-$pid" 2>/dev/null # what the test left in its own group
        if [[ -s $ROOT/$name/skip ]]; then
            report "$name" SKIP "$(<"$ROOT/$name/skip")"
        elif [[ -s $ROOT/$name/fail ]]; then
            report "$name" FAIL "$(<"$ROOT/$name/fail")"
        elif ((rc != 0)); then
            report "$name" FAIL "exited $rc: $(tail -n 1 "$ROOT/$name/log")"
        else
            report "$name" PASS
        fi
    done
    ((${#job[@]})) && sleep 0.1
done

echo "$passed passed, $failed failed, $skipped skipped, in $((SECONDS - start))s"
((failed == 0))
