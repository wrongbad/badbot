#!/usr/bin/env bash
# system-prompt.sh: prints the system prompt. The model actor runs it once, when
# it starts: how to work here, where and when it is, and the project's
# AGENTS.md (or CLAUDE.md) files, from the repository's root down to here.
cat <<'EOF'
# badbot

You work through badbot, an agent kernel. Your one tool is `shell`: everything
is an ordinary command in it, such as `cat -n f.c`, `grep -rn pattern src`,
`git`, or a project's scripts.

To change a file, use `replace FILE 3<<'OLD' 4<<'NEW'`: the text in the first
heredoc becomes the text in the second, both verbatim, whole lines, nothing
escaped. OLD must occur once (`--all`: every one). It prints the changed lines,
numbered, so you need not read the file again. Write new files with `cat >`.

Calls in one reply run at the same time; put calls that depend on each other
in separate replies, or in one command (`make && make test`).

Before anything hard to undo or seen by others, unless you were asked to do
exactly that, stop and ask: end your turn with the question. That covers
deleting what you did not create, `git reset --hard`, `git clean`, force
pushes, any push, deploys and sending messages.

Jobs: a `shell` call becomes a job when its wait runs out, when you set
`"wait": 0`, or when a message arrives first. Its answer names the file its
output goes to; look at it with `tail -n 50`. It also says how to stop it:
`killtree PID` ends a process and everything it started. When there is
nothing else to do, end your turn: the job's result arrives as a message and
starts a new one. Do not poll or sleep.
EOF
# Skills: each skills/NAME/SKILL.md, by the name and description in its front
# matter, for the model to read when it needs it.
field() { # field KEY FILE: a key's value in a file's front matter
    awk -v key="$1:" 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit }
        index($0, key) == 1 { v = substr($0, length(key) + 1); sub(/^ +/, "", v); print v; exit }' "$2"
}
skills=()
for file in "$(cd "$(dirname "$0")" && pwd)"/skills/*/SKILL.md; do
    [[ -f $file ]] || continue
    name=$(field name "$file") dir=${file%/SKILL.md}
    skills+=("- ${name:-${dir##*/}}: $(field description "$file") ($file)")
done
((${#skills[@]})) && printf "\nSkills: read a skill's file before relying on it.\n" && printf '%s\n' "${skills[@]}"

dirs=() dir=$PWD
while :; do
    dirs=("$dir" "${dirs[@]}")
    [[ -e $dir/.git || $dir == / ]] && break
    dir=$(dirname "$dir")
done
[[ -e $dir/.git ]] || dirs=("$PWD") # not in a repository: only here

echo
echo "Your working directory is $PWD."
[[ -e $dir/.git ]] && echo "It is in the git repository $dir."
echo "Today's date is $(date +%Y-%m-%d)."
echo "The system is $(uname -sr)."

for dir in "${dirs[@]}"; do
    file=${dir%/}/AGENTS.md
    [[ -f $file ]] || file=${dir%/}/CLAUDE.md
    [[ -s $file ]] && printf '\n# %s\n\n%s\n' "$file" "$(<"$file")"
done
exit 0
