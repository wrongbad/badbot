#!/usr/bin/env bash
# Chapter 1: someone to talk to. Each line you type goes into the session file
# as a user message; the whole file goes to a provider, whose text streams to
# the screen and whose result goes into the file as the next message.
#   docs/1-chat.sh [session.jsonl]     BADBOT_PROVIDER, BADBOT_MODEL: as for badbot
badbot=$(cd "$(dirname "$0")/../badbot" && pwd) # the providers
session=${1:-session.jsonl}
provider=$badbot/${BADBOT_PROVIDER:-openai}.sh

while IFS= read -r text; do
    jq -nc --arg t "$text" '{type:"message", message:{role:"user", content:[{type:"text", text:$t}]}}' >>"$session"
    while IFS= read -r line; do
        case $line in
            '{"type":"text_delta"'*) jq -j .text <<<"$line" ;;
            '{"type":"result"'*) jq -c '{type:"message", message}' <<<"$line" >>"$session" && echo ;;
        esac
    done < <(jq -sc --arg m "${BADBOT_MODEL-}" '{model:$m, messages:map(select(.type == "message").message)}' \
        "$session" | "$provider")
done
