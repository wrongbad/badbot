#!/usr/bin/env bash
# show: the events as a person reads them, stdin to stdout: the kernel's last
# stage, after the session file. show.jq says how; in color only on a terminal.
#   … | tee -a "$session" | badbot/show.sh
[[ -t 1 && ! ${NO_COLOR-} ]] && tty=true || tty=false
exec jq --unbuffered -nRrj --argjson tty $tty -f "$(dirname "$0")/show.jq"
