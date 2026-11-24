#!/usr/bin/env bash
# badbot.sh: an agent kernel in bash. README.md tells the story of how it is built.
#
# The kernel is one pipeline. Every event goes through every actor, in order,
# and ends in the session file, and on stdout as a person reads it (show.sh).
# An actor passes every event on, and says its own on fd 3, the bus: a file,
# which input.sh, at the head of the pipeline, follows. An event is a JSON
# object whose first key is "type"; they travel one per line, so a glob on the
# start of a line routes them. Events: docs/events.md.
#
#   badbot.sh [SESSION]   resumes SESSION if it exists; starts a new one if none
# Exits 1 if its last run ended in an error (the provider failed), so a parent
# can tell a sub-agent that gave up from one that is done.
# The environment says the rest:
#   BADBOT_PROVIDER  NAME runs NAME.sh, here; openai if unset (echo: no key needed)
#   BADBOT_MODEL     the model the provider asks for
#   BADBOT_EFFORT    how hard the model thinks: low, medium, high…; the provider's default if unset
# A session keeps what /provider, /model and /effort chose, over these.

exec 3>&- 4>&-             # fds 3 and 4 are the kernel's; anyone else's go
export BADBOT_SESSION=${1:-$(mktemp "${TMPDIR:-/tmp}/badbot-session-XXXXXX")}
mkdir -p "$BADBOT_SESSION.d" && exec 3>"$BADBOT_SESSION.d/bus" # the bus: fd 3, empty, in every actor
. "$(dirname "$(readlink -f "$0")")/lib.sh" # and with it, the bus's lock: fd 4 (-f: on PATH, $0 is a symlink)

start=$(($(wc -c <"$session" 2>/dev/null || echo 0))) # where this kernel's events begin

"$here/input.sh" | "$here/inbox.sh" | "$here/model.sh" | "$here/tools.sh" | tee -a "$session" | "$here/show.sh"
status=$?

# How this kernel's last run ended, not one before it, resumed.
last=$(tail -c +$((start + 1)) "$session" | grep '^{"type":"run_end"' | tail -n 1)
((status == 0)) && [[ $last == *'"reason":"error"'* ]] && status=1
exit "$status"
