#!/bin/zsh
# Usage: gen.sh <name> "<fabric description>"
# Generates art/clothing/raw/<name>.png, a seamless square fabric swatch, with Codex's image tool.
# build.py tints and tiles these into the Shirt/Pants templates. Needs network (sandbox off).
set -e
here=${0:A:h}
name=$1
subject=$2
out=$here/raw/$name.png
[[ -f $out ]] && { echo "skip $name"; exit 0; }
codex exec --skip-git-repo-check -s workspace-write -C $here/raw -- \
"Use your image generation tool to create exactly ONE square image, then copy the generated PNG to ./$name.png in the current directory. Do nothing else.

SUBJECT: $subject

STYLE: a flat, top-down, evenly lit close-up photo scan of the fabric filling the whole frame edge to edge,
seamless and tileable, with no folds, no shadows, no vignette, no perspective, no objects, no text. Neutral
light grey, desaturated, mid-to-light value so it can be tinted later; the weave detail should be subtle and fine." \
	> $here/raw/$name.log 2>&1
[[ -f $out ]] && echo "ok $name" || echo "FAIL $name (see raw/$name.log)"
