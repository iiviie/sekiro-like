#!/bin/zsh
# Store-page art: game icon (1:1) and three thumbnails (16:9), from real screenshots in ref/.
here=${0:A:h}
cd $here
run() {
  local name=$1 prompt=$2
  [[ -f $name.png ]] && { echo "skip $name"; return; }
  codex exec --skip-git-repo-check -s workspace-write -C $here -i ref/clash.jpg -i ref/arena.jpg -- \
    "Use your image generation tool to create exactly ONE image, then copy the generated PNG to ./$name.png. Do nothing else.

The two attached screenshots are from my Roblox game LAST BLADE (a samurai posture-and-deflect sword royale). Keep the characters recognisably Roblox (blocky R15 bodies, simple faces, woven straw kasa hats, dark gi with a crimson sash) and the world (castle courtyard, red shrine hall, pagoda, golden-hour storm sky, red mist pillars).

$prompt

Art direction: stylised, bold, high contrast, painterly cel-shading with ink-brush accents, crimson #C8102E, bone white, gold leaf, charcoal. Clean readable silhouettes. No logos, no watermarks, no Roblox logo." > $name.log 2>&1
  [[ -f $name.png ]] && echo "ok $name" || echo "FAIL $name"
}
run icon "GAME ICON, square 1:1. Extreme close-up of two Roblox samurai crossing katana blades in the centre, a huge white-gold spark burst where the blades meet (a perfect deflect), one fighter in a straw kasa in the foreground left with a determined face, crimson mist and sakura petals behind. Must read clearly at 150x150 pixels. No text at all." &
run thumb_deflect "THUMBNAIL, wide 16:9. Dynamic low-angle shot: a Roblox samurai deflects a falling overhead strike, giant spark burst, the attacker staggered backwards. Big bold brush-lettered title text on the left reading exactly: DEFLECT. Crimson and gold." &
run thumb_royale "THUMBNAIL, wide 16:9. Wide shot of six Roblox samurai fighting in a castle courtyard as a ring of red mist closes in, one fighter in the centre standing on a pile of fallen straw hats. Big bold brush-lettered text at the top reading exactly: LAST BLADE STANDING." &
run thumb_execution "THUMBNAIL, wide 16:9. Cinematic deathblow: a Roblox samurai drives a katana into a kneeling broken opponent, a huge red kanji 忍殺 painted in ink behind them, dramatic red-black sky. Big bold text bottom right reading exactly: EXECUTE." &
wait
