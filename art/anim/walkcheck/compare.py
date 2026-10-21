import sys
from PIL import Image, ImageDraw, ImageFont
out, title, *ims = sys.argv[1:]
imgs = [Image.open(p).convert("RGB") for p in ims]
W = max(i.width for i in imgs); H = sum(i.height for i in imgs) + 34
sheet = Image.new("RGB", (W, H), (250, 248, 242))
d = ImageDraw.Draw(sheet)
font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 18)
d.text((10, 7), title, fill=(10, 10, 10), font=font)
y = 34
for i in imgs:
    sheet.paste(i, (0, y)); y += i.height
sheet.save(out, quality=84); print(out, sheet.size)
