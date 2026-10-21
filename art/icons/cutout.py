"""Cuts generated icons out of their flat white background.

Removes near-white regions connected to the border, plus enclosed pure-white holes (a
coin's square hole), then feathers the edge so the ink outline anti-aliases cleanly.
Writes art/icons/png/<name>.png at 512x512 (board_* names: a 1024x512 crop, no cutout).

Run: python art/icons/cutout.py [names...]
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

HERE = Path(__file__).resolve().parent
SIZE = 512


def cut(src: Path) -> Image.Image:
    rgb = np.asarray(Image.open(src).convert("RGB")).astype(np.float32)
    lo = rgb.min(axis=2)
    spread = rgb.max(axis=2) - lo
    whiteish = (lo > 232) & (spread < 18)
    labels, n = ndimage.label(whiteish)
    border = set(np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))) - {0}
    background = np.isin(labels, list(border))
    # Enclosed holes: very white and big enough not to be a highlight.
    pure = (lo > 246) & (spread < 8)
    hl, hn = ndimage.label(pure)
    sizes = ndimage.sum(pure, hl, range(1, hn + 1))
    area = pure.size
    for i, s in enumerate(sizes, start=1):
        if s > area * 0.002:
            background |= hl == i
    # Soft alpha: distance-to-white inside a thin band around the cut.
    alpha = np.where(background, 0.0, 1.0)
    edge = ndimage.binary_dilation(background, iterations=2) & ~background
    whiteness = np.clip((lo - 150) / (255 - 150), 0, 1)
    alpha[edge] = np.minimum(alpha[edge], 1 - whiteness[edge] * 0.85)
    img = Image.fromarray(np.dstack([rgb, alpha * 255]).astype(np.uint8), "RGBA")
    a = img.getchannel("A").filter(ImageFilter.GaussianBlur(0.6))
    img.putalpha(a)
    bbox = img.getchannel("A").point(lambda v: 255 if v > 20 else 0).getbbox()
    img = img.crop(bbox)
    side = int(max(img.size) * 1.06)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def board(src: Path) -> Image.Image:
    """Lobby-board art (gen_board.sh): no cutout, centre-cropped to 2:1 at 1024x512."""
    img = Image.open(src).convert("RGB")
    h = min(img.height, img.width // 2)
    w = h * 2
    left, top = (img.width - w) // 2, (img.height - h) // 2
    return img.crop((left, top, left + w, top + h)).resize((1024, 512), Image.LANCZOS)


def main() -> None:
    names = sys.argv[1:] or [p.stem for p in sorted((HERE / "raw").glob("*.png"))]
    (HERE / "png").mkdir(exist_ok=True)
    for name in names:
        process = board if name.startswith("board_") else cut
        process(HERE / "raw" / f"{name}.png").save(HERE / "png" / f"{name}.png", optimize=True)
        print(name)


if __name__ == "__main__":
    main()
