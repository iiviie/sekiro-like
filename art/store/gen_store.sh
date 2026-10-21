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

Art direction: stylised, bold, high contrast, painterly cel-shading with ink-brush accents, crimson #C8102E, bone white, gold leaf, charcoal. Clean readable silhouettes. No logos, no watermarks, no Roblox logo.
No blood or gore of any kind (Roblox moderates uploads): no red splatter, drips, pools or stains, no wounds, no blade in a body,
no piles of bodies. Crimson only as cloth, lacquer, mist or dry ink; show impact with white slash light, gold sparks and petals." > $name.log 2>&1
  [[ -f $name.png ]] && echo "ok $name" || echo "FAIL $name"
}
run icon "GAME ICON, square 1:1. Extreme close-up of two Roblox samurai crossing katana blades in the centre, a huge white-gold spark burst where the blades meet (a perfect deflect), one fighter in a straw kasa in the foreground left with a determined face, crimson mist and sakura petals behind. Must read clearly at 150x150 pixels. No text at all." &
run thumb_deflect "THUMBNAIL, wide 16:9. Dynamic low-angle shot: a Roblox samurai deflects a falling overhead strike, giant spark burst, the attacker staggered backwards. Big bold brush-lettered title text on the left reading exactly: DEFLECT. Crimson and gold." &
run thumb_royale "THUMBNAIL, wide 16:9. Wide shot of six Roblox samurai fighting in a castle courtyard as a ring of red mist closes in, one fighter in the centre standing tall on a low stone plinth with a few knocked-off straw kasa hats scattered on the clean stone floor, gold sparks and sakura petals in the air. Big bold brush-lettered text at the top reading exactly: LAST BLADE STANDING." &
run thumb_execution "THUMBNAIL, wide 16:9. Cinematic finisher: a Roblox samurai stands tall calmly sheathing his katana, a huge white crescent slash of light and a burst of gold sparks hanging in the air behind him, his defeated opponent kneeling unhurt with head bowed and a broken sword on the ground before him, a huge black ink kanji 忍殺 brushed on a pale full moon behind them, dramatic storm sky. Big bold text bottom right reading exactly: EXECUTE." &
wait
