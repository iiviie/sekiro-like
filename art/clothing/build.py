"""Builds LAST BLADE's classic Shirt (gi) and Pants (hakama) templates, one pair per colourway.

Paints onto Roblox's 585x559 classic clothing layout: fabric swatches from raw/ (made by gen.sh with
Codex) are tinted per colourway and tiled into each panel, then lapels, folds, seams, the obi and the
hakama pleats, ties and hem are painted on top with soft shading so the blocky R15 parts read as cloth.
raw/ keeps 600px greyscale copies of the 1254px generations (only luminance is used). out/ holds the
exact PNGs that were uploaded (built from the full-size swatches; a rebuild differs by <0.1/255).

R15 maps each 128px-tall panel onto several parts (rows measured in Studio with a banded test
template): the torso panel's bottom ~26 rows land on the LowerTorso, the arm panel's bottom ~16 rows on
the Hand, the leg panel's bottom ~14 rows on the Foot, and the top ~20 rows of a leg panel hide inside
the LowerTorso. The waist (obi and hakama ties) is painted identically in both templates so it reads
whichever one Roblox composites on top. The hands are left transparent: the arm's body colour (skin)
shows through.

Gotcha: never use the same image id as both a Shirt and a Pants; Roblox caches the composite by id.

Run: python art/clothing/build.py   (needs Pillow + numpy) -> art/clothing/out/<colourway>_{shirt,pants}.png
     plus out/preview.png (a front-view doll per colourway).
Then upload out/*.png (Studio MCP upload_image over a localhost http server), record the ids in
ids.json and run `python art/clothing/build.py --luau` to print the Sets table for
src/shared/Clothing.luau.
"""

from __future__ import annotations

import math
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
RAW = HERE / "raw"
OUT = HERE / "out"
W, H = 585, 559

# Classic template panels: (x, y, w, h).
TORSO = {
    "U": (231, 8, 128, 64),
    "R": (165, 74, 64, 128),
    "F": (231, 74, 128, 128),
    "L": (361, 74, 64, 128),
    "B": (427, 74, 128, 128),
    "D": (231, 204, 128, 64),
}
# Right limb row then left limb row. Order around the limb (see the classic template).
RIGHT = {
    "U": (217, 289, 64, 64),
    "R": (19, 355, 64, 128),
    "B": (85, 355, 64, 128),
    "L": (151, 355, 64, 128),
    "F": (217, 355, 64, 128),
    "D": (217, 485, 64, 64),
}
LEFT = {
    "U": (308, 289, 64, 64),
    "F": (308, 355, 64, 128),
    "L": (374, 355, 64, 128),
    "B": (440, 355, 64, 128),
    "R": (506, 355, 64, 128),
    "D": (308, 485, 64, 64),
}

# R15 rows inside a 128px panel (measured, see the docstring).
TORSO_SPLIT = 100  # UpperTorso above (the gi), LowerTorso below (the obi)
ARM_SPLITS = (58, 108)  # elbow row, wrist row (cuff ends; hand and wrist below are skin)
LEG_SPLITS = (58, 114)  # knee row, ankle row (hakama hem ends; tabi below)

# name: gi, collar (eri), inner collar (juban), obi, hakama, ties (himo), gi fabric
COLOURWAYS: dict[str, dict] = {
    # bots
    "indigo": dict(gi=(62, 76, 128), eri=(40, 46, 74), juban=(226, 220, 204), obi=(168, 44, 44), hakama=(80, 86, 108), himo=(196, 186, 164), fabric="sashiko"),
    "slate": dict(gi=(92, 112, 138), eri=(58, 70, 90), juban=(232, 226, 212), obi=(150, 52, 46), hakama=(92, 98, 112), himo=(206, 196, 172), fabric="gi_cotton"),
    "moss": dict(gi=(96, 112, 74), eri=(60, 70, 48), juban=(228, 220, 196), obi=(176, 128, 58), hakama=(104, 96, 82), himo=(214, 200, 168), fabric="gi_cotton"),
    "ash": dict(gi=(132, 112, 92), eri=(84, 68, 56), juban=(234, 226, 208), obi=(64, 84, 104), hakama=(106, 100, 96), himo=(200, 188, 166), fabric="gi_cotton"),
    "oxblood": dict(gi=(124, 52, 50), eri=(78, 34, 34), juban=(230, 222, 204), obi=(196, 160, 86), hakama=(98, 90, 96), himo=(210, 196, 170), fabric="gi_cotton"),
    "dove": dict(gi=(168, 168, 166), eri=(96, 98, 104), juban=(244, 240, 232), obi=(132, 46, 46), hakama=(96, 106, 128), himo=(220, 214, 200), fabric="sashiko"),
    # bosses (Clothing.Boss maps ids onto these)
    "nameless": dict(gi=(74, 84, 118), eri=(46, 52, 74), juban=(226, 220, 206), obi=(214, 206, 190), hakama=(82, 86, 102), himo=(214, 206, 190), fabric="sashiko"),
    "miko": dict(gi=(236, 232, 226), eri=(220, 214, 206), juban=(178, 36, 40), obi=(178, 36, 40), hakama=(176, 38, 42), himo=(236, 232, 226), fabric="gi_cotton"),
    "shikigami": dict(gi=(238, 234, 224), eri=(196, 50, 44), juban=(246, 244, 238), obi=(190, 44, 40), hakama=(206, 196, 178), himo=(190, 44, 40), fabric="gi_cotton"),
    "demon": dict(gi=(132, 64, 46), eri=(84, 40, 32), juban=(214, 176, 90), obi=(74, 62, 60), hakama=(190, 150, 70), himo=(84, 40, 32), fabric="gi_cotton"),
    "mist": dict(gi=(156, 168, 178), eri=(96, 108, 124), juban=(236, 240, 244), obi=(226, 230, 236), hakama=(92, 102, 118), himo=(226, 230, 236), fabric="sashiko"),
    "fox": dict(gi=(96, 72, 118), eri=(62, 46, 80), juban=(222, 176, 92), obi=(210, 160, 70), hakama=(84, 70, 104), himo=(210, 160, 70), fabric="gi_cotton"),
    "cat": dict(gi=(164, 98, 52), eri=(96, 60, 36), juban=(236, 222, 190), obi=(214, 170, 60), hakama=(100, 74, 56), himo=(214, 170, 60), fabric="gi_cotton"),
    "shadow": dict(gi=(112, 40, 44), eri=(70, 62, 66), juban=(196, 40, 44), obi=(186, 30, 36), hakama=(88, 80, 88), himo=(186, 30, 36), fabric="sashiko"),
    "niten": dict(gi=(232, 232, 238), eri=(66, 82, 128), juban=(246, 246, 250), obi=(66, 82, 128), hakama=(70, 86, 134), himo=(232, 232, 238), fabric="gi_cotton"),
    # player coin colourways (part C; Catalog outfit.rust / .pine / .ink)
    "rust": dict(gi=(150, 78, 44), eri=(92, 46, 26), juban=(232, 222, 200), obi=(222, 200, 150), hakama=(72, 68, 66), himo=(222, 200, 150), fabric="sashiko"),
    "pine": dict(gi=(46, 82, 64), eri=(28, 50, 40), juban=(228, 224, 206), obi=(204, 164, 82), hakama=(84, 90, 96), himo=(204, 164, 82), fabric="gi_cotton"),
    "ink": dict(gi=(34, 34, 42), eri=(18, 18, 22), juban=(236, 232, 224), obi=(150, 34, 46), hakama=(44, 44, 52), himo=(206, 200, 190), fabric="sashiko"),
}

SWATCH_PX = 300  # each 1254px swatch is scaled so its weave reads at template scale

_swatches: dict[str, np.ndarray] = {}


def swatch(name: str) -> np.ndarray:
    """Luminance detail of a swatch, normalised around 1.0."""
    if name not in _swatches:
        im = Image.open(RAW / f"{name}.png").convert("L").resize((SWATCH_PX, SWATCH_PX), Image.LANCZOS)
        a = np.asarray(im, dtype=np.float32)
        _swatches[name] = a / a.mean()
    return _swatches[name]


def cloth(name: str, w: int, h: int, colour, strength: float, seed: int) -> np.ndarray:
    """A w x h tile of tinted fabric (float RGB 0..255)."""
    det = swatch(name)
    rng = random.Random(seed)
    ox, oy = rng.randrange(SWATCH_PX), rng.randrange(SWATCH_PX)
    reps = (math.ceil((h + oy) / SWATCH_PX) + 1, math.ceil((w + ox) / SWATCH_PX) + 1)
    tile = np.tile(det, reps)[oy : oy + h, ox : ox + w]
    k = 1 + strength * (tile - 1)
    return np.clip(np.asarray(colour, dtype=np.float32)[None, None, :] * k[:, :, None], 0, 255)


def shade(a: np.ndarray, factor) -> np.ndarray:
    return np.clip(a * np.asarray(factor, dtype=np.float32)[..., None], 0, 255)


def edge_ao(w: int, h: int, sides=(0.12, 0.12, 0.08, 0.10), width=10) -> np.ndarray:
    """Darkening toward panel edges (left, right, top, bottom) so seams read as creases."""
    xs = np.arange(w, dtype=np.float32)
    ys = np.arange(h, dtype=np.float32)
    f = np.ones((h, w), np.float32)
    l, r, t, b = sides
    f -= l * np.clip(1 - xs / width, 0, 1)[None, :]
    f -= r * np.clip(1 - (w - 1 - xs) / width, 0, 1)[None, :]
    f -= t * np.clip(1 - ys / width, 0, 1)[:, None]
    f -= b * np.clip(1 - (h - 1 - ys) / width, 0, 1)[:, None]
    return f


def mix(a, b, t: float):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def darker(c, f: float):
    return tuple(int(v * f) for v in c)


class Canvas:
    def __init__(self):
        self.rgb = np.zeros((H, W, 3), np.float32)
        self.alpha = np.zeros((H, W), np.float32)

    def put(self, x: int, y: int, block: np.ndarray, alpha: np.ndarray | None = None):
        h, w = block.shape[:2]
        a = np.ones((h, w), np.float32) if alpha is None else alpha
        cur = self.rgb[y : y + h, x : x + w]
        self.rgb[y : y + h, x : x + w] = cur * (1 - a[..., None]) + block * a[..., None]
        self.alpha[y : y + h, x : x + w] = np.maximum(self.alpha[y : y + h, x : x + w], a)

    def overlay(self, x: int, y: int, w: int, h: int, draw_fn, colour_fn=None):
        """Paint strokes in panel-local coords: draw_fn(draw) on an L mask; colour from colour_fn(mask)."""
        mask = Image.new("L", (w, h), 0)
        draw_fn(ImageDraw.Draw(mask))
        return np.asarray(mask, dtype=np.float32) / 255

    def clear(self, x: int, y: int, w: int, h: int):
        self.alpha[y : y + h, x : x + w] = 0
        self.rgb[y : y + h, x : x + w] = 0

    def image(self) -> Image.Image:
        rgba = np.dstack([self.rgb, self.alpha * 255]).round().clip(0, 255).astype(np.uint8)
        return Image.fromarray(rgba, "RGBA")


def mask_of(w: int, h: int, draw_fn, blur: float = 0) -> np.ndarray:
    m = Image.new("L", (w, h), 0)
    draw_fn(ImageDraw.Draw(m))
    if blur:
        m = m.filter(ImageFilter.GaussianBlur(blur))
    return np.asarray(m, dtype=np.float32) / 255


def blend(base: np.ndarray, colour_block: np.ndarray, m: np.ndarray) -> np.ndarray:
    return base * (1 - m[..., None]) + colour_block * m[..., None]


def darken_by(base: np.ndarray, m: np.ndarray, amount: float) -> np.ndarray:
    return base * (1 - amount * m[..., None])


def lighten_by(base: np.ndarray, m: np.ndarray, amount: float) -> np.ndarray:
    return base + (255 - base) * (amount * m[..., None])


# --------------------------------------------------------------------------------------- shirt


def torso_panel(cw: dict, face: str, w: int, h: int, seed: int) -> np.ndarray:
    gi = cloth(cw["fabric"], w, h, cw["gi"], 0.55, seed)
    gi = shade(gi, edge_ao(w, h, sides=(0.16, 0.16, 0.06, 0.0), width=14))
    # A soft top light: shoulders catch more light than the belly.
    ys = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    gi = shade(gi, np.broadcast_to(1.06 - 0.12 * ys, (h, w)))
    if face == "F":
        gi = paint_lapels(cw, gi, w, h, seed)
    elif face == "B":
        # A centre-back seam, two shoulder-blade drapes and a soft fold above the obi.
        seam = mask_of(w, h, lambda d: d.line([(w / 2, 0), (w / 2, h)], fill=255, width=2), 0.6)
        gi = darken_by(gi, seam, 0.35)
        folds = mask_of(
            w,
            h,
            lambda d: [
                d.line([(18, 30), (40, TORSO_SPLIT - 6)], fill=255, width=4),
                d.line([(w - 18, 30), (w - 40, TORSO_SPLIT - 6)], fill=255, width=4),
                d.line([(30, TORSO_SPLIT - 12), (w - 30, TORSO_SPLIT - 14)], fill=200, width=3),
            ],
            3,
        )
        gi = darken_by(gi, folds, 0.25)
        # A small family crest (mon) between the shoulders, in the collar colour.
        cx, cy, r = w / 2, 26, 9
        mon = mask_of(
            w,
            h,
            lambda d: [
                d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=255, width=2),
                d.rectangle([cx - 6, cy - 4, cx + 6, cy - 2], fill=255),
                d.rectangle([cx - 6, cy + 2, cx + 6, cy + 4], fill=255),
            ],
            0.5,
        )
        gi = blend(gi, cloth(cw["fabric"], w, h, cw["juban"], 0.3, seed + 7), mon * 0.8)
    else:  # sides: a side seam and an armpit fold
        seam = mask_of(w, h, lambda d: d.line([(w / 2, 0), (w / 2, h)], fill=255, width=2), 0.6)
        gi = darken_by(gi, seam, 0.3)
        fold = mask_of(w, h, lambda d: d.line([(w / 2 - 10, 4), (w / 2 + 4, 40)], fill=255, width=4), 3)
        gi = darken_by(gi, fold, 0.25)
    return gi


def paint_lapels(cw: dict, gi: np.ndarray, w: int, h: int, seed: int) -> np.ndarray:
    """Crossed lapels: the wearer's left panel over the right, a wide eri band along each edge and the
    light under-collar (juban) showing in the neck of the V."""
    bottom = TORSO_SPLIT  # the V closes at the obi
    cx = w / 2
    neck_half = 22  # half-width of the neck opening at the top edge
    band = 13  # eri width
    # Under-collar: a narrower V of juban just inside the gi's V.
    juban = cloth("gi_cotton", w, h, cw["juban"], 0.25, seed + 3)
    jv = mask_of(
        w,
        h,
        lambda d: d.polygon([(cx - neck_half + 2, 0), (cx + neck_half - 2, 0), (cx + 4, bottom * 0.55), (cx - 4, bottom * 0.55)], fill=255),
        0.7,
    )
    # Skin-dark neck shadow at the very top of the V reads as depth.
    out = blend(gi, juban, jv)
    out = darken_by(out, mask_of(w, h, lambda d: d.polygon([(cx - neck_half, 0), (cx + neck_half, 0), (cx, 22)], fill=255), 5), 0.35)
    # The juban's own collar edge: a thin line just inside each gi lapel.
    # Under lapel (wearer's right = viewer's left), from the viewer's left neck down to the right hip.
    eri = cloth(cw["fabric"], w, h, cw["eri"], 0.45, seed + 5)
    under = mask_of(
        w,
        h,
        lambda d: d.polygon(
            [(cx - neck_half - band, 0), (cx - neck_half, 0), (w - 16, bottom), (w - 16 - band * 1.4, bottom)], fill=255
        ),
        0.7,
    )
    # Over lapel (wearer's left = viewer's right), from the viewer's right neck down to the left hip.
    over_edge = [(cx + neck_half, 0), (cx + neck_half + band, 0), (16 + band * 1.4, bottom), (16, bottom)]
    over = mask_of(w, h, lambda d: d.polygon(over_edge, fill=255), 0.7)
    # The over panel covers everything left of its edge below the V: repaint gi there so the under lapel
    # disappears beneath it.
    over_body = mask_of(
        w,
        h,
        lambda d: d.polygon([(cx + neck_half, 0), (w, 0), (w, bottom), (16, bottom)], fill=255),
        0.0,
    )
    under_body = mask_of(
        w,
        h,
        lambda d: d.polygon([(0, 0), (cx - neck_half, 0), (w - 16, bottom), (0, bottom)], fill=255),
        0.0,
    )
    gi_clean = gi
    out = blend(out, gi_clean, under_body)
    out = blend(out, eri, under)
    # The over panel casts a soft shadow onto the under lapel along its edge.
    shadow = mask_of(w, h, lambda d: d.line([(cx + neck_half + band + 2, 0), (16 + band * 1.4 + 3, bottom)], fill=255, width=5), 3)
    out = darken_by(out, shadow * (1 - over_body), 0.3)
    out = blend(out, gi_clean, over_body)
    out = blend(out, eri, over)
    # Stitch line down the middle of each eri band and a crisp outer edge.
    for poly, visible, light in ((under, 1 - over_body, 0.12), (over, 1.0, 0.16)):
        eroded = Image.fromarray((poly * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(3))
        edge = np.clip(poly - np.asarray(eroded, dtype=np.float32) / 255, 0, 1)
        out = lighten_by(out, edge * visible, light)
    # Diagonal drape folds radiating from the armpits toward the crossing.
    folds = mask_of(
        w,
        h,
        lambda d: [
            d.line([(4, 22), (34, 58)], fill=255, width=4),
            d.line([(w - 4, 22), (w - 34, 58)], fill=255, width=4),
            d.line([(8, 64), (40, bottom - 8)], fill=180, width=3),
            d.line([(w - 6, 50), (w - 30, bottom - 10)], fill=180, width=3),
        ],
        3,
    )
    out = darken_by(out, folds, 0.22)
    hi = mask_of(w, h, lambda d: [d.line([(10, 24), (38, 56)], fill=255, width=2), d.line([(w - 10, 24), (w - 38, 56)], fill=255, width=2)], 2)
    out = lighten_by(out, hi, 0.08)
    return out


def sleeve_panel(cw: dict, face: str, w: int, h: int, seed: int, outer: bool) -> tuple[np.ndarray, np.ndarray]:
    """Gi sleeve on the upper and lower arm, a turned-back cuff, the hand left transparent."""
    a0, a1 = ARM_SPLITS
    gi = cloth(cw["fabric"], w, h, cw["gi"], 0.55, seed)
    gi = shade(gi, edge_ao(w, h, sides=(0.14, 0.14, 0.04, 0.0), width=10))
    ys = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    gi = shade(gi, np.broadcast_to(1.05 - 0.1 * ys, (h, w)))
    rng = random.Random(seed)
    # Elbow and forearm wrinkles: short shallow arcs.
    for _ in range(5):
        y = rng.uniform(a0 - 10, a1 - 18)
        x0 = rng.uniform(-6, w * 0.3)
        x1 = rng.uniform(w * 0.6, w + 6)
        sag = rng.uniform(3, 7)
        m = mask_of(w, h, lambda d: d.arc([x0, y - sag, x1, y + sag], 10, 170, fill=255, width=3), 1.6)
        gi = darken_by(gi, m, rng.uniform(0.18, 0.3))
        gi = lighten_by(gi, np.roll(m, -2, axis=0), 0.06)
    if outer:
        # A shoulder seam where the sleeve meets the body.
        m = mask_of(w, h, lambda d: d.line([(0, 6), (w, 6)], fill=255, width=2), 0.8)
        gi = darken_by(gi, m, 0.3)
    # Cuff: a wide turned-back band in the collar colour, darker on its lower edge.
    cuff_top = a1 - 12
    cuff = cloth(cw["fabric"], w, h, cw["eri"], 0.45, seed + 2)
    cm = np.zeros((h, w), np.float32)
    cm[cuff_top:a1, :] = 1
    gi = blend(gi, cuff, cm)
    gi = darken_by(gi, mask_of(w, h, lambda d: d.line([(0, a1 - 1), (w, a1 - 1)], fill=255, width=2), 0.6), 0.4)
    gi = lighten_by(gi, mask_of(w, h, lambda d: d.line([(0, cuff_top), (w, cuff_top)], fill=255, width=1), 0.4), 0.15)
    alpha = np.ones((h, w), np.float32)
    alpha[a1:, :] = 0
    return gi, alpha


def waist(cw: dict, face: str, block: np.ndarray, seed: int) -> np.ndarray:
    """The LowerTorso rows: the obi, the hakama's himo ties over it and the hakama's top edge, the
    knot in front and the stiff koshi-ita at the back. Painted the same in both templates."""
    h, w = block.shape[:2]
    top = TORSO_SPLIT
    obi_bot = top + 15
    himo_y = obi_bot + 3
    out = block.copy()
    # Hakama top below the obi.
    hk = pleats(cw, w, h, seed + 1, 6 if w > 64 else 3, top, h, 0.0)
    out[top:] = hk[top:]
    # Obi: a woven band with a light top edge, a centre crease and a shadow under it.
    obi = cloth("obi_weave", w, h, cw["obi"], 0.6, seed + 2)
    out[top:obi_bot] = obi[top:obi_bot]
    out = lighten_by(out, mask_of(w, h, lambda d: d.line([(0, top + 1), (w, top + 1)], fill=255, width=1), 0.4), 0.22)
    out = darken_by(out, mask_of(w, h, lambda d: d.line([(0, top + 8), (w, top + 8)], fill=255, width=1), 0.5), 0.18)
    out = darken_by(out, mask_of(w, h, lambda d: d.line([(0, top), (w, top)], fill=255, width=2), 0.8), 0.35)
    out = darken_by(out, mask_of(w, h, lambda d: d.line([(0, obi_bot + 1), (w, obi_bot + 1)], fill=255, width=2), 0.8), 0.4)
    # Himo: a cord wrapped round the waist, crossing into a knot at the front.
    if face == "F":
        def draw(d):
            d.line([(0, himo_y), (w, himo_y)], fill=255, width=4)
            d.line([(w / 2 - 16, obi_bot - 4), (w / 2 + 16, himo_y + 4)], fill=255, width=4)
            d.line([(w / 2 + 16, obi_bot - 4), (w / 2 - 16, himo_y + 4)], fill=255, width=4)
            d.rounded_rectangle([w / 2 - 8, himo_y - 5, w / 2 + 8, himo_y + 5], 3, fill=255)
            d.line([(w / 2 - 4, himo_y + 4), (w / 2 - 10, h)], fill=255, width=3)
            d.line([(w / 2 + 4, himo_y + 4), (w / 2 + 9, h)], fill=255, width=3)
    elif face == "B":
        def draw(d):
            d.line([(0, himo_y), (w, himo_y)], fill=255, width=4)
            # The koshi-ita sits over the cords: drawn below as fabric.
    else:
        def draw(d):
            d.line([(0, himo_y), (w, himo_y)], fill=255, width=4)
    cord = mask_of(w, h, draw, 0.6)
    out = darken_by(out, np.roll(cord, 2, axis=0) * (1 - cord), 0.4)
    out = blend(out, cloth("gi_cotton", w, h, cw["himo"], 0.35, seed + 3), cord)
    out = lighten_by(out, np.clip(cord - np.roll(cord, 1, axis=0), 0, 1), 0.2)
    if face == "B":
        ko = mask_of(w, h, lambda d: d.polygon([(w / 2 - 26, top + 4), (w / 2 + 26, top + 4), (w / 2 + 20, h), (w / 2 - 20, h)], fill=255), 0.6)
        board = cloth("hakama_twill", w, h, darker(cw["hakama"], 0.92), 0.4, seed + 4)
        out = darken_by(out, np.roll(np.roll(ko, 2, axis=0), 2, axis=1) * (1 - ko), 0.45)
        out = blend(out, board, ko)
        out = lighten_by(out, mask_of(w, h, lambda d: d.line([(w / 2 - 26, top + 5), (w / 2 + 26, top + 5)], fill=255, width=1), 0.4), 0.25)
    return out


def build_shirt(cw: dict) -> Image.Image:
    c = Canvas()
    for i, (face, (x, y, w, h)) in enumerate(TORSO.items()):
        if face in ("U", "D"):
            fill = cw["gi"] if face == "U" else cw["hakama"]
            block = cloth(cw["fabric"], w, h, fill, 0.5, 100 + i)
            block = shade(block, edge_ao(w, h, width=10))
            if face == "U":
                # The collar seen from above: the eri wraps the neck.
                m = mask_of(w, h, lambda d: d.ellipse([w / 2 - 22, h / 2 - 16, w / 2 + 22, h / 2 + 16], outline=255, width=8), 0.8)
                block = blend(block, cloth(cw["fabric"], w, h, cw["eri"], 0.4, 9), m)
            c.put(x, y, block)
            continue
        block = torso_panel(cw, face, w, h, 200 + i)
        c.put(x, y, waist(cw, face, block, 250 + i))
    for limb, panels in (("R", RIGHT), ("L", LEFT)):
        for i, (face, (x, y, w, h)) in enumerate(panels.items()):
            seed = 300 + i + (0 if limb == "R" else 50)
            if face == "U":
                block = cloth(cw["fabric"], w, h, cw["gi"], 0.5, seed)
                c.put(x, y, shade(block, edge_ao(w, h, width=10)))
            elif face == "D":
                continue  # the palm: skin
            else:
                outer = (limb == "R" and face == "R") or (limb == "L" and face == "L")
                block, alpha = sleeve_panel(cw, face, w, h, seed, outer)
                c.put(x, y, block, alpha)
    return c.image()


# --------------------------------------------------------------------------------------- pants


def pleats(cw: dict, w: int, h: int, seed: int, count: int, top: int, bottom: int, flare: float) -> np.ndarray:
    """Hakama pleats: vertical folds, dark in the grooves, a lit ridge beside each, slightly flaring."""
    base = cloth("hakama_twill", w, h, cw["hakama"], 0.5, seed)
    ys = np.arange(h, dtype=np.float32)[:, None]
    xs = np.arange(w, dtype=np.float32)[None, :]
    t = np.clip((ys - top) / max(1, bottom - top), 0, 1)
    # Pleat phase: columns spread a little toward the hem.
    cx = w / 2
    u = (xs - cx) / (1 + flare * t) + cx
    phase = (u / w) * count
    frac = phase - np.floor(phase)
    groove = np.exp(-((frac - 0.15) ** 2) / 0.004)  # sharp dark fold line
    ridge = np.exp(-((frac - 0.32) ** 2) / 0.02)  # lit side of the pleat
    body = 0.5 + 0.5 * np.cos(frac * 2 * math.pi)  # rounded pleat shading
    f = 1.0 - 0.28 * groove - 0.08 * (1 - body) + 0.1 * ridge
    return shade(base, f)


def build_pants(cw: dict) -> Image.Image:
    c = Canvas()
    l0, l1 = LEG_SPLITS
    hakama = cw["hakama"]
    hem = darker(hakama, 0.62)
    for i, (face, (x, y, w, h)) in enumerate(TORSO.items()):
        if face in ("U", "D"):
            block = cloth("hakama_twill", w, h, hakama, 0.45, 400 + i)
            c.put(x, y, shade(block, edge_ao(w, h, width=10)))
            continue
        # The UpperTorso rows sit under the shirt; the waist matches the shirt's exactly.
        block = torso_panel(cw, face, w, h, 200 + i)
        c.put(x, y, waist(cw, face, block, 250 + i))
    for limb, panels in (("R", RIGHT), ("L", LEFT)):
        for i, (face, (x, y, w, h)) in enumerate(panels.items()):
            seed = 500 + i + (0 if limb == "R" else 50)
            if face == "U":
                block = cloth("hakama_twill", w, h, hakama, 0.45, seed)
                c.put(x, y, shade(block, edge_ao(w, h, width=10)))
                continue
            if face == "D":
                # The sole: straw waraji under a pale tabi.
                block = cloth("obi_weave", w, h, (176, 150, 104), 0.7, seed)
                c.put(x, y, shade(block, edge_ao(w, h, sides=(0.3, 0.3, 0.3, 0.3), width=12)))
                continue
            block = pleats(cw, w, h, seed, 3, 0, l1, 0.25)
            # Darker hem band at the bottom of the LowerLeg, with a stitched edge.
            hem_top = l1 - 12
            band = pleats({**cw, "hakama": hem}, w, h, seed + 1, 3, 0, l1, 0.25)
            m = np.zeros((h, w), np.float32)
            m[hem_top:l1, :] = 1
            block = blend(block, band, m)
            block = lighten_by(block, mask_of(w, h, lambda d: d.line([(0, hem_top), (w, hem_top)], fill=255, width=1), 0.3), 0.15)
            # Foot: off-white tabi with a strap of the sandal.
            tabi = cloth("gi_cotton", w, h, (226, 220, 206), 0.3, seed + 2)
            fm = np.zeros((h, w), np.float32)
            fm[l1:, :] = 1
            block = blend(block, tabi, fm)
            block = darken_by(block, mask_of(w, h, lambda d: d.line([(0, l1 + 1), (w, l1 + 1)], fill=255, width=3), 1.5), 0.45)
            strap = mask_of(w, h, lambda d: d.line([(0, h - 6), (w, h - 6)], fill=255, width=3), 0.5)
            block = blend(block, cloth("obi_weave", w, h, (150, 120, 84), 0.5, seed + 3), strap)
            block = shade(block, edge_ao(w, h, sides=(0.12, 0.12, 0.0, 0.0), width=8))
            c.put(x, y, block)
    return c.image()




def preview(path: Path):
    """A front-view paper doll of every colourway (shirt over pants, skin hands, tan head)."""
    names = list(COLOURWAYS)
    cell_w, cell_h = 140, 300
    sheet = Image.new("RGBA", (cell_w * len(names), cell_h), (54, 58, 64, 255))
    for n, name in enumerate(names):
        shirt = Image.open(OUT / f"{name}_shirt.png")
        pants = Image.open(OUT / f"{name}_pants.png")
        body = Image.new("RGBA", (W, H), (226, 178, 140, 255))
        body.alpha_composite(pants)
        body.alpha_composite(shirt)
        legs = Image.new("RGBA", (W, H), (226, 178, 140, 255))
        legs.alpha_composite(pants)
        doll = Image.new("RGBA", (cell_w, cell_h), (0, 0, 0, 0))
        s = 0.5  # px per template px
        def part(region, box, src=body):
            x, y, w, h = region
            doll.alpha_composite(src.crop((x, y, x + w, y + h)).resize((int(w * s), int(h * s))), box)
        ox = (cell_w - 128 * s - 128 * s) // 2
        head = Image.new("RGBA", (int(64 * s * 1.2), int(64 * s * 1.2)), (226, 178, 140, 255))
        doll.alpha_composite(head, (int(ox + 64 * s - head.width / 2 + 32 * s), 10))
        top = 10 + head.height
        part(RIGHT["F"], (int(ox), top))
        part(TORSO["F"], (int(ox + 64 * s), top))
        part(LEFT["F"], (int(ox + 192 * s), top))
        part(RIGHT["F"], (int(ox + 64 * s), int(top + 128 * s)), legs)
        part(LEFT["F"], (int(ox + 128 * s), int(top + 128 * s)), legs)
        sheet.alpha_composite(doll, (n * cell_w, 0))
        ImageDraw.Draw(sheet).text((n * cell_w + 6, cell_h - 16), name, fill=(230, 230, 230, 255))
    sheet.save(path)


def luau() -> str:
    """The Clothing.Sets entries from ids.json and the colourways above."""
    import json

    ids = json.loads((HERE / "ids.json").read_text())

    def c(rgb):
        return f"rgb({rgb[0]}, {rgb[1]}, {rgb[2]})"

    lines = []
    for name, cw in COLOURWAYS.items():
        i = ids[name]
        lines.append(f"\t{name} = set({i['shirt']}, {i['pants']}, {c(cw['gi'])}, {c(cw['hakama'])}, {c(cw['obi'])}),")
    return "\n".join(lines)


def main():
    import sys

    if "--luau" in sys.argv:
        print(luau())
        return
    OUT.mkdir(exist_ok=True)
    only = None
    if "--only" in sys.argv:  # e.g. --only rust,pine,ink: build just these (the rest stay as uploaded)
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    for name, cw in COLOURWAYS.items():
        if only and name not in only:
            continue
        build_shirt(cw).save(OUT / f"{name}_shirt.png")
        build_pants(cw).save(OUT / f"{name}_pants.png")
        print("built", name)
    preview(OUT / "preview.png")


if __name__ == "__main__":
    main()
