#!/bin/zsh
# Fetches the open-licence (OFL) Google Fonts logo.py composes with into ./fonts (not committed).
here=${0:A:h}; mkdir -p $here/fonts; cd $here/fonts
B=https://raw.githubusercontent.com/google/fonts/main
for p in "ofl/cinzel/Cinzel%5Bwght%5D.ttf" ofl/yujiboku/YujiBoku-Regular.ttf ofl/yujimai/YujiMai-Regular.ttf \
         ofl/zenantique/ZenAntique-Regular.ttf ofl/shojumaru/Shojumaru-Regular.ttf; do
  n=$(basename $p | sed 's/%5B/[/;s/%5D/]/'); [[ -f $n ]] || curl -sfL -o "$n" "$B/$p" && echo "ok $n"
done
