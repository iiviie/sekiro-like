#!/bin/zsh
# Usage: gen.sh <name> "<subject description>" [extra codex args...]
# Generates art/icons/raw/<name>.png with Codex's image tool using STYLE.md.
set -e
here=${0:A:h}
name=$1; shift
subject=$1; shift
style=$(cat $here/STYLE.md | sed -n '/^STYLE:/,$p')
out=$here/raw/$name.png
[[ -f $out ]] && { echo "skip $name"; exit 0; }
codex exec --skip-git-repo-check -s workspace-write -C $here/raw "$@" \
"Use your image generation tool to create exactly ONE square image, then copy the generated PNG to ./$name.png in the current directory. Do nothing else.

SUBJECT: $subject

$style" > $here/raw/$name.log 2>&1
[[ -f $out ]] && echo "ok $name" || echo "FAIL $name (see raw/$name.log)"
