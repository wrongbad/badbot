#!/usr/bin/env bash
# post: sends a provider's request, and sends it again while that is worth it.
#   post.sh [--hold REGEX] URL [CURL-OPTION...] <REQUEST
# REQUEST: header lines, an empty line, then the body: on stdin, so a key is
# never an argument. Out: the response as it comes, then a last line,
# "x-status: CODE" (000: no response at all).
# Held back until the stream says something: what comes before its first
# data: line, and the data: lines that match REGEX (events that say nothing
# yet). Until then, a failed connection, a 408, a 429, a 5xx, a first event
# that is an overloaded, rate-limit or server error, or an error about
# in-flight requests (credits held for them, not yet settled) is sent again:
# up to 5 times in all, 1, 2, 4 and 8 s apart. Past it, the stream is the
# stream: none of it comes twice.
# On SIGTERM it stops curl, or its wait, and ends.
set -u
hold=
[[ ${1-} == --hold ]] && { hold=$2; shift 2; }
url=$1
shift
headers=()
while IFS= read -r line && [[ $line ]]; do headers+=("$line"); done
IFS= read -rd '' body

pids=()
trap 'kill "${pids[@]}" 2>/dev/null; exit 143' TERM

error='^data: *\{ *"(error"|type": *"error")'
again='"type": *"(overloaded_error|rate_limit_error|api_error|server_error)"|in-flight'
for ((try = 1; ; try++)); do
    exec {r}< <(exec curl -sSN --connect-timeout 30 "$@" "$url" -H @<(printf '%s\n' "${headers[@]}") \
        --data-binary @<(printf '%s' "$body") -w '\nx-status: %{http_code}\n' 2>&1)
    pids=($!)
    held=() first=
    while IFS= read -r -u "$r" line; do
        held+=("$line")
        [[ $line == data:* ]] || continue
        [[ $hold && ${line#data:} =~ $hold ]] && continue
        first=$line
        break
    done
    if [[ $first && ! ($first =~ $error && $first =~ $again) ]]; then # the stream: on, as it comes
        printf '%s\n' "${held[@]}"
        cat <&"$r" &
        pids+=($!)
        wait $!
        exit 0
    fi
    [[ $first ]] && while IFS= read -r -u "$r" line; do held+=("$line"); done # an error, first: the rest of it
    exec {r}<&-
    status=${held[*]: -1} && status=${status#x-status: }
    if ((try < 5)) && [[ $first || $status == 000 || $status == 408 || $status == 429 || $status == 5[0-9][0-9] ||
        $(printf '%s\n' "${held[@]}") =~ $again ]]; then
        sleep $((1 << (try - 1))) &
        pids=($!)
        wait $!
        continue
    fi
    printf '%s\n' "${held[@]}"
    exit 0
done
