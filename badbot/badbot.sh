#!/usr/bin/env bash
# badbot.sh: an agent kernel in bash. README.md tells the story of how it is built.
#
# The kernel is one pipeline. Every line goes through every actor, in order,
# and ends in the session file, and on stdout as a person reads it (show.jq). An actor passes every line on,
# and says its own on fd 3, the bus: a file, which input.sh, at the head of
# the pipeline, follows. Every line is one JSON object whose first key is
# "type", so a glob on the start of a line routes it. Lines: docs/lines.md.
#
# Set by the environment, not by options:
#   BADBOT_PROVIDER  NAME runs NAME.sh, here; openai if unset (echo: no key needed)
#   BADBOT_MODEL     the model the provider asks for
#   BADBOT_SESSION   the session file, resumed if it exists; a new one if unset
# Arguments are a first message.

export BADBOT_SESSION=${BADBOT_SESSION:-$(mktemp "${TMPDIR:-/tmp}/badbot-session-XXXXXX")}
. "$(dirname "$0")/lib.sh" # and with it, the bus's lock: fd 4
exec 3>"$session.d/bus"    # the bus: fd 3, empty, in every actor
trap : TERM HUP            # input.sh turns them into exit; wait for it

"$here/input.sh" "$@" | "$here/inbox.sh" | "$here/model.sh" | "$here/tools.sh" |
    deaf tee -a "$session" | deaf jq --unbuffered -rj -f "$here/show.jq"
