#!/bin/zsh
# Usage: gen_board.sh <name> "<scene description>"
# Generates art/icons/raw/<name>.png: a wide painted lobby-board image (no text) in the
# icon set's palette. cutout.py --board crops it to 1024x512 in art/icons/png/.
set -e
here=${0:A:h}
name=$1; shift
scene=$1; shift
out=$here/raw/$name.png
[[ -f $out ]] && { echo "skip $name"; exit 0; }
codex exec --skip-git-repo-check -s workspace-write -C $here/raw "$@" -- \
"Use your image generation tool to create exactly ONE wide landscape image (3:2, 1536x1024), then copy the generated PNG to ./$name.png in the current directory. Do nothing else.

SCENE: $scene

STYLE: painted key art for a samurai game's in-world notice board. Japanese ink-brush (sumi-e) meets clean
cel-shaded illustration: bold black brush outlines with dry-brush edges, flat cel shading with two tones per
material and crisp highlights, subtle washi-paper grain, painterly ink-wash sky. Composition reads from across
a room: one clear focal point in the centre band, the top and bottom sixth of the frame quiet (it gets cropped to 2:1).
PALETTE (hex): crimson #C8102E, deep lacquer red #7A0A1A, bone white #EDE3CF, gold leaf #D4A54A,
dark bronze #6B4A22, charcoal #1A1718, jade #3E9E84, steel #B8C2CC.
NEVER: text, letters, numbers, signage writing, watermarks, logos, UI, borders, photorealism, people's faces." > $here/raw/$name.log 2>&1
[[ -f $out ]] && echo "ok $name" || echo "FAIL $name (see raw/$name.log)"
