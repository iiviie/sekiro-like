#!/bin/zsh
# Usage: gen.sh <name> "<design description>"
# Generates art/logo/raw/<name>.png (a wide game-title wordmark on flat white) with Codex's
# image tool. Cut out with logo.py. Spelling is checked by eye: generated text can misspell.
set -e
here=${0:A:h}
name=$1; shift
design=$1; shift
out=$here/raw/$name.png
[[ -f $out ]] && { echo "skip $name"; exit 0; }
codex exec --skip-git-repo-check -s workspace-write -C $here/raw "$@" -- \
"Use your image generation tool to create exactly ONE wide landscape image (3:2, 1536x1024), then copy the generated PNG to ./$name.png in the current directory. Do nothing else.

SUBJECT: the title logo (wordmark) of a samurai sword-fighting video game called LAST BLADE. The logo text is exactly the two English words \"LAST BLADE\" in capital letters, spelled L-A-S-T then B-L-A-D-E, with no other words, no subtitle, no tagline, no Japanese characters, no numbers.
DESIGN: $design
QUALITY: a polished, professional AAA game logo lockup, centred, filling about 85% of the width, crisp, high contrast, readable when shrunk to a phone screen. Tight letter spacing, letters with real weight and character.
PALETTE (hex): bone white #EDE3CF, ink black #141112, gold leaf #D4A54A, crimson lacquer #C8102E, steel #B8C2CC.
BACKGROUND: perfectly flat pure white (#FFFFFF) edge to edge, no texture, no shadow, no vignette, no scenery, nothing behind the logo.
NO BLOOD OR GORE: no blood, no red liquid, no red splatter, drips or droplets. Crimson only as flat lacquer or a dry brush accent. Energy is shown with ink brush arcs, white slash light and gold." > $here/raw/$name.log 2>&1 </dev/null
[[ -f $out ]] && echo "ok $name" || echo "FAIL $name (see raw/$name.log)"
