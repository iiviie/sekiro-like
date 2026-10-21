"""Rarity frames for item cards: 512x512 PNGs with a transparent centre, drawn in code
so the five tiers line up exactly (same border width, same opening) and only colour and
ornament escalate.

Style follows STYLE.md: a thick charcoal ink outline with dry-brush edges, a two-tone cel
band with one crisp highlight, washi grain in the fill. Ornaments stay inside the outer
96 px, so the frames 9-slice cleanly with SliceCenter Rect(96, 96, 416, 416).

Run: python art/icons/frames.py   (writes art/icons/png/frame_<rarity>.png)
"""

from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

HERE = Path(__file__).resolve().parent
SIZE = 512
SS = 2  # supersample
N = SIZE * SS

INK = (26, 23, 24)
BONE = (237, 227, 207)
GOLD = (212, 165, 74)
BRONZE = (107, 74, 34)
CRIMSON = (200, 16, 46)
LACQUER = (122, 10, 26)

# name: (light tone, dark tone, accent, ornament level)
TIERS = {
    "common": ((184, 194, 204), (120, 128, 138), BONE, 0),
    "rare": ((74, 132, 196), (38, 76, 128), BONE, 1),
    "epic": ((150, 92, 196), (88, 48, 128), BONE, 2),
    "legendary": (GOLD, BRONZE, BONE, 3),
    "mythic": (CRIMSON, LACQUER, GOLD, 4),
    # Appended (not inserted) so the other tiers keep their noise seeds. Level 0.5: plain
    # band plus small bone corner pips (rare has diamonds).
    "uncommon": ((108, 196, 164), (46, 110, 92), BONE, 0.5),
}

yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)


def noise(scale: float, seed: int) -> np.ndarray:
    r = np.random.default_rng(seed)
    small = r.random((int(N / scale) + 2, int(N / scale) + 2)).astype(np.float32)
    big = ndimage.zoom(small, scale, order=3)[:N, :N]
    return (big - big.mean()) / (big.std() + 1e-6)


def rrect_sdf(inset: float, radius: float) -> np.ndarray:
    """Signed distance to a rounded square inset from the canvas edge (negative inside)."""
    c = N / 2
    half = c - inset - radius
    qx = np.abs(xx - c) - half
    qy = np.abs(yy - c) - half
    outside = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    inside = np.minimum(np.maximum(qx, qy), 0)
    return outside + inside - radius


def rough(mask_sdf: np.ndarray, amount: float, seed: int) -> np.ndarray:
    """Dry-brush edge: wobble the boundary with noise, then soft-threshold."""
    n = noise(24, seed) * 0.7 + noise(6, seed + 1) * 0.3
    d = mask_sdf + n * amount
    return np.clip(0.5 - d / (1.2 * SS), 0, 1)


def band(outer_inset: float, inner_inset: float, radius: float, amount: float, seed: int) -> np.ndarray:
    outer = rough(rrect_sdf(outer_inset, radius), amount, seed)
    inner = rough(rrect_sdf(inner_inset, max(radius - (inner_inset - outer_inset), 6 * SS)), amount, seed + 9)
    return np.clip(outer - inner, 0, 1)


def diamond(cx: float, cy: float, r: float) -> np.ndarray:
    return np.clip(0.5 - (np.abs(xx - cx) + np.abs(yy - cy) - r) / (1.2 * SS), 0, 1)


def disc(cx: float, cy: float, r: float) -> np.ndarray:
    return np.clip(0.5 - (np.hypot(xx - cx, yy - cy) - r) / (1.2 * SS), 0, 1)


def corners(fn, off: float, *args) -> np.ndarray:
    m = np.zeros((N, N), np.float32)
    for cx in (off, N - off):
        for cy in (off, N - off):
            m = np.maximum(m, fn(cx, cy, *args))
    return m


def bracket(off: float, length: float, width: float) -> np.ndarray:
    """L-shaped corner brackets pointing into each corner."""
    m = np.zeros((N, N), np.float32)
    for sx in (1, -1):
        for sy in (1, -1):
            x0 = off if sx > 0 else N - off
            y0 = off if sy > 0 else N - off
            px = (xx - x0) * sx
            py = (yy - y0) * sy
            arm1 = (px >= 0) & (px <= length) & (py >= 0) & (py <= width)
            arm2 = (py >= 0) & (py <= length) & (px >= 0) & (px <= width)
            m = np.maximum(m, (arm1 | arm2).astype(np.float32))
    return ndimage.gaussian_filter(m, 0.8 * SS)


def flames(seed: int) -> np.ndarray:
    """Flame tongues licking off the outer edge (mythic only): the outline pushed outward
    by a spiky wave around the frame."""
    ang = np.arctan2(yy - N / 2, xx - N / 2)
    wave = (np.sin(ang * 24 + noise(60, seed) * 0.4) * 0.5 + 0.5) ** 4
    reach = (2 + 13 * wave + noise(16, seed + 2) * 0.8) * SS
    return np.clip(0.5 - (rrect_sdf(17 * SS, 52 * SS) - reach) / (1.2 * SS), 0, 1)


def compose(name: str) -> Image.Image:
    light, dark, accent, level = TIERS[name]
    seed = 100 * list(TIERS).index(name) + 11
    rgb = np.zeros((N, N, 3), np.float32)
    alpha = np.zeros((N, N), np.float32)

    def paint(mask: np.ndarray, colour) -> None:
        nonlocal alpha
        m = mask[..., None]
        rgb[:] = rgb * (1 - m) + np.array(colour, np.float32) * m
        alpha = np.maximum(alpha, mask)

    radius = 44 * SS
    o, i = 26 * SS, 66 * SS  # band runs from 26 px to 66 px in from the edge (512 scale)

    if level >= 4:
        f = flames(seed) * (rrect_sdf(o, radius) > -30 * SS)
        paint(ndimage.grey_dilation(f, size=(5 * SS, 5 * SS)), INK)
        paint(f, GOLD)

    # Ink outline (outer + inner) as one thick band, then the coloured band on top of it.
    paint(band(o - 9 * SS, i + 8 * SS, radius + 8 * SS, 1.8 * SS, seed), INK)
    fill = band(o, i, radius, 1.6 * SS, seed + 3)
    # Two-tone cel: light top-left, dark bottom-right.
    split = ((xx + yy) / N > 1.0 + noise(30, seed + 4) * 0.03).astype(np.float32)
    split = ndimage.gaussian_filter(split, 0.8 * SS)
    tone = np.array(light, np.float32) * (1 - split[..., None]) + np.array(dark, np.float32) * split[..., None]
    grain = 1 + noise(1.5, seed + 5)[..., None] * 0.035
    m = fill[..., None]
    rgb[:] = rgb * (1 - m) + np.clip(tone * grain, 0, 255) * m

    # Crisp highlight: thin bone stroke along the inner top-left of the band.
    hl = band(o + 7 * SS, o + 12 * SS, radius - 7 * SS, 0.8 * SS, seed + 6)
    hl *= np.clip(1.15 - (xx + yy) / N, 0, 1) ** 1.5
    paint(hl * 0.85, BONE)

    if level >= 3:
        # Inner second line in the accent colour.
        paint(band(i + 12 * SS, i + 17 * SS, radius - 36 * SS, 1.0 * SS, seed + 7), INK)
        paint(band(i + 13 * SS, i + 16 * SS, radius - 36 * SS, 0.6 * SS, seed + 8), accent if level == 4 else GOLD)

    if level >= 2:
        orn_c = GOLD if level >= 3 else accent
        b = bracket(14 * SS, 92 * SS, 16 * SS)
        paint(ndimage.grey_dilation(b, size=(7 * SS, 7 * SS)), INK)
        paint(b, orn_c)

    if level >= 1:
        off = 46 * SS
        r = (17 if level < 3 else 22) * SS
        shape = diamond if level < 3 else disc
        paint(corners(shape, off, r + 6 * SS), INK)
        paint(corners(shape, off, r), GOLD if level >= 3 else accent)
        if level >= 3:
            paint(corners(disc, off, r * 0.5 + 2 * SS), INK)
            paint(corners(disc, off, r * 0.5 - 1 * SS), CRIMSON if level == 3 else BONE)
        else:
            paint(corners(diamond, off, r * 0.45), dark)

    if level == 0.5:
        off = 46 * SS
        paint(corners(disc, off, 11 * SS), INK)
        paint(corners(disc, off, 7 * SS), BONE)

    if level >= 2:
        # Mid-edge studs.
        mids = np.zeros((N, N), np.float32)
        c = N / 2
        e = (o + i) / 2
        for cx, cy in ((c, e), (c, N - e), (e, c), (N - e, c)):
            mids = np.maximum(mids, diamond(cx, cy, 13 * SS))
        paint(ndimage.grey_dilation(mids, size=(9 * SS, 9 * SS)), INK)
        paint(mids, GOLD if level >= 3 else accent)

    img = Image.fromarray(np.dstack([np.clip(rgb, 0, 255), alpha * 255]).astype(np.uint8), "RGBA")
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    import sys

    for name in sys.argv[1:] or TIERS:
        compose(name).save(HERE / "png" / f"frame_{name}.png", optimize=True)
        print(f"frame_{name}")


if __name__ == "__main__":
    main()
