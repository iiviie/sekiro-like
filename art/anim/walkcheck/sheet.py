#!/usr/bin/env python3
"""Tile render_rec.py frames into a contact sheet: side row over back row, with a caption.
usage: sheet.py framesdir tag out.jpg "caption line 1" ["caption line 2"]"""
import sys, glob, os
from PIL import Image, ImageDraw, ImageFont

d, tag, out = sys.argv[1], sys.argv[2], sys.argv[3]
caps = sys.argv[4:]
side = sorted(glob.glob(os.path.join(d, f"{tag}_side_*.png")))
back = sorted(glob.glob(os.path.join(d, f"{tag}_back_*.png")))
w, h = Image.open(side[0]).size
scale = 0.7
tw, th = int(w * scale), int(h * scale)
n = len(side)
cap_h = 18 * len(caps) + 10
sheet = Image.new("RGB", (tw * n, th * 2 + cap_h), (250, 248, 242))
for i, (a, b) in enumerate(zip(side, back)):
    sheet.paste(Image.open(a).convert("RGB").resize((tw, th)), (i * tw, cap_h))
    sheet.paste(Image.open(b).convert("RGB").resize((tw, th)), (i * tw, cap_h + th))
dr = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 13)
except Exception:
    font = ImageFont.load_default()
for k, c in enumerate(caps):
    dr.text((8, 5 + 18 * k), c, fill=(20, 20, 20), font=font)
for i in range(1, n):
    dr.line((i * tw, cap_h, i * tw, cap_h + 2 * th), fill=(200, 195, 185))
sheet.save(out, quality=86)
print(out, sheet.size)
