"""LAST BLADE title logo: composes the wordmark candidates and the contact sheet.

Pillow-composed candidates use open-licence (OFL) Google Fonts, fetched by fetch_fonts.sh into
$FONTS (default: art/logo/fonts, not committed). Codex candidates (gen.sh -> raw/cx_*.png) are
cut out of their white background here. Every candidate is a transparent PNG in png/.

Run:  python art/logo/logo.py [compose] [cutout] [final] [sheet <desktop.jpg> [<phone.jpg>]]
  compose  the Pillow candidates (p_*.png)
  cutout   the Codex candidates raw/cx_*.png -> png/cx_*.png (the raw originals aren't committed;
           the committed png/cx_* are downsized to 1024 wide, so run cutout before final)
  final    the picks with the 最後の刃 hanko added (lb_*.png). The game uses lb_inkgold_seal,
           uploaded at 1024 wide as png/logo_1024.png (Assets.UI.Chrome.Logo)
  sheet    contact_sheet.jpg: every SHEET candidate at title size (1223x697) and phone size (844x390)

The pick, lb_inkgold_seal: Codex's sumi-brush wordmark (cx_inkgold: ink letters with gold leaf,
a crimson enso, a katana under the words) plus a Pillow hanko in Yuji Boku. Generated text was
checked letter by letter; cx_stacked is out because it spells "BADE".
"""

import math
import os
import random
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont
from scipy import ndimage

HERE = Path(__file__).resolve().parent
FONTS = Path(os.environ.get("FONTS", HERE / "fonts"))
OUT = HERE / "png"

BONE = (237, 227, 207)
BONE_HI = (250, 245, 232)
BONE_LO = (214, 198, 166)
INK = (20, 17, 18)
GOLD = (212, 165, 74)
GOLD_HI = (246, 214, 140)
GOLD_LO = (138, 98, 38)
CRIMSON = (200, 16, 46)
LACQUER = (122, 10, 26)
STEEL = (196, 205, 214)
STEEL_HI = (244, 248, 252)
STEEL_LO = (112, 122, 134)


def font(name: str, size: int, weight: int | None = None) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(str(FONTS / name), size)
    if weight is not None:
        f.set_variation_by_axes([weight])
    return f


def text_mask(text: str, f: ImageFont.FreeTypeFont, tracking: float = 0.0, kern: dict | None = None) -> Image.Image:
    """Alpha mask of `text` with extra tracking (fraction of the size) and per-pair kerning."""
    size = f.size
    advances = []
    x = 0.0
    for i, ch in enumerate(text):
        advances.append(x)
        x += f.getlength(ch) + tracking * size
        if kern and i + 1 < len(text):
            x += kern.get(text[i : i + 2], 0) * size
    width = int(x + size)
    height = int(size * 1.6)
    mask = Image.new("L", (width, height), 0)
    d = ImageDraw.Draw(mask)
    for ch, ax in zip(text, advances):
        d.text((ax + size * 0.2, size * 0.2), ch, font=f, fill=255)
    return mask.crop(mask.getbbox())


def pad(mask: Image.Image, n: int) -> Image.Image:
    out = Image.new(mask.mode, (mask.width + 2 * n, mask.height + 2 * n), 0)
    out.paste(mask, (n, n))
    return out


def grow(mask: Image.Image, r: int) -> Image.Image:
    """Round dilation of an alpha mask by r pixels (distance transform, so it stays round)."""
    a = np.asarray(mask) > 127
    dist = ndimage.distance_transform_edt(~a)
    soft = np.clip(r + 0.5 - dist, 0, 1)
    return Image.fromarray((soft * 255).astype(np.uint8), "L")


def shrink(mask: Image.Image, r: int) -> Image.Image:
    a = np.asarray(mask) > 127
    dist = ndimage.distance_transform_edt(a)
    soft = np.clip(dist - r + 0.5, 0, 1)
    return Image.fromarray((soft * 255).astype(np.uint8), "L")


def vgrad(size: tuple[int, int], stops: list[tuple[float, tuple[int, int, int]]]) -> Image.Image:
    w, h = size
    ys = np.linspace(0, 1, h)
    cols = np.zeros((h, 3))
    for c in range(3):
        cols[:, c] = np.interp(ys, [s for s, _ in stops], [col[c] for _, col in stops])
    arr = np.repeat(cols[:, None, :], w, axis=1)
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def fill(mask: Image.Image, color) -> Image.Image:
    layer = Image.new("RGBA", mask.size, color if len(color) == 4 else (*color, 255))
    layer.putalpha(ImageChops.multiply(layer.getchannel("A"), mask))
    return layer


def textured(mask: Image.Image, rgb: Image.Image) -> Image.Image:
    layer = rgb.convert("RGBA")
    layer.putalpha(mask)
    return layer


def grain(mask: Image.Image, amount: float, seed: int, scale: float = 1.0) -> Image.Image:
    """Eats into a mask with a dry-brush grain: horizontal streaks plus speckle."""
    rng = np.random.default_rng(seed)
    h, w = mask.size[1], mask.size[0]
    streak = rng.random((max(2, int(h / (3 * scale))), 1))
    streak = np.asarray(Image.fromarray((streak * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR)) / 255
    speck = rng.random((h, w))
    speck = ndimage.gaussian_filter(speck, 1.2 * scale)
    speck = (speck - speck.min()) / (np.ptp(speck) + 1e-6)
    noise = 0.55 * streak + 0.45 * speck
    a = np.asarray(mask).astype(np.float32) / 255
    # Only the outer edge band frays; the core stays solid.
    edge = np.asarray(shrink(mask, int(6 * scale))).astype(np.float32) / 255
    cut = np.where(noise > 1 - amount, 0, 1)
    a = np.where(edge > 0.5, a, a * cut)
    return Image.fromarray((a * 255).astype(np.uint8), "L")


def shadow(mask: Image.Image, offset: tuple[int, int], blur: float, alpha: float) -> Image.Image:
    s = Image.new("L", mask.size, 0)
    s.paste(mask, offset)
    s = s.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(v * alpha))
    return fill(s, INK)


def over(*layers: Image.Image) -> Image.Image:
    base = Image.new("RGBA", layers[0].size, (0, 0, 0, 0))
    for layer in layers:
        base = Image.alpha_composite(base, layer)
    return base


def trim(img: Image.Image, margin: int = 12) -> Image.Image:
    box = img.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    img = img.crop(box)
    return pad_rgba(img, margin)


def pad_rgba(img: Image.Image, n: int) -> Image.Image:
    out = Image.new("RGBA", (img.width + 2 * n, img.height + 2 * n), (0, 0, 0, 0))
    out.paste(img, (n, n))
    return out


# ------------------------------------------------------------------------------------
# Katana: drawn flat, edge down, tip to the right, with a slight sori (curve).


def katana(length: int, height: int, tip_right: bool = True) -> Image.Image:
    """A katana `length` px long (handle to tip), blade `height` px deep."""
    W, H = length, int(height * 4.2)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cy = H * 0.5
    handle = int(length * 0.25)
    tsuba_w = max(6, int(height * 0.5))
    blade_x0 = handle + tsuba_w + int(height * 0.5)
    sori = height * 0.9

    def curve(x: float) -> float:  # downward bow of the spine along the blade
        t = (x - blade_x0) / (W - blade_x0)
        return -sori * math.sin(math.pi * t * 0.85) * t

    # Blade outline polygon: spine on top, edge below; kissaki cut at the end.
    spine, edge = [], []
    tip_len = height * 2.2
    n = 64
    for i in range(n + 1):
        x = blade_x0 + (W - blade_x0 - tip_len - 2) * i / n
        y = cy + curve(x)
        spine.append((x, y - height * 0.5))
        edge.append((x, y + height * 0.5))
    xt = W - 2
    yt = cy + curve(xt) - height * 0.35
    xk = W - tip_len
    ykk = cy + curve(xk)
    poly = spine + [(xt, yt)] + [(xk + tip_len * 0.25, ykk + height * 0.5)] + edge[::-1]
    # Ink outline under everything.
    outline = Image.new("L", (W, H), 0)
    od = ImageDraw.Draw(outline)
    od.polygon(poly, fill=255)
    # Steel: dark spine band, bright edge band (the hamon), a white edge light.
    steel = Image.new("L", (W, H), 0)
    ImageDraw.Draw(steel).polygon(poly, fill=255)
    rgb = vgrad((W, H), [(0, STEEL_LO), (0.44, STEEL_LO), (0.5, STEEL), (0.56, STEEL_HI), (1, STEEL_HI)])
    # Re-centre the gradient on the curved blade per column.
    arr = np.zeros((H, W, 3), np.uint8)
    base = np.asarray(rgb)
    for x in range(W):
        off = int(curve(max(x, blade_x0)))
        arr[:, x] = np.roll(base[:, x], off, axis=0)
    blade = Image.fromarray(arr, "RGB").convert("RGBA")
    blade.putalpha(steel)
    # Hamon: a wavy line between the spine and edge bands.
    hd = ImageDraw.Draw(blade)
    pts = []
    for i in range(n * 2 + 1):
        x = blade_x0 + (W - blade_x0 - tip_len) * i / (n * 2)
        y = cy + curve(x) + height * (0.06 + 0.07 * math.sin(i * 0.9))
        pts.append((x, y))
    hd.line(pts, fill=(*STEEL_HI, 200), width=max(1, height // 9))
    # Edge glint line.
    glint = [(x, y - max(1, height // 10)) for x, y in edge]
    hd.line(glint, fill=(255, 255, 255, 255), width=max(1, height // 8))
    # Handle: ink wrap with gold diamonds (tsukamaki), gold cap.
    hgt = height * 1.15
    hc = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    hdc = ImageDraw.Draw(hc)
    hdc.rounded_rectangle((4, cy - hgt / 2, handle, cy + hgt / 2), radius=hgt * 0.35, fill=(*INK, 255))
    step = hgt * 0.95
    x = 4 + hgt * 0.6
    while x < handle - step * 0.6:
        hdc.polygon(
            [(x, cy), (x + step / 2, cy - hgt * 0.32), (x + step, cy), (x + step / 2, cy + hgt * 0.32)],
            fill=(*GOLD, 255),
        )
        x += step
    hdc.rounded_rectangle((2, cy - hgt * 0.56, 4 + hgt * 0.45, cy + hgt * 0.56), radius=hgt * 0.2, fill=(*GOLD, 255))
    # Tsuba (guard) and habaki (collar).
    tg = height * 2.1
    hdc.rounded_rectangle(
        (handle, cy - tg / 2, handle + tsuba_w, cy + tg / 2), radius=tsuba_w * 0.45, fill=(*GOLD_LO, 255)
    )
    hdc.rounded_rectangle(
        (handle + 2, cy - tg / 2 + 3, handle + tsuba_w - 2, cy + tg / 2 - 3), radius=tsuba_w * 0.4, fill=(*GOLD, 255)
    )
    hdc.rectangle((handle + tsuba_w, cy - height * 0.62, blade_x0 + 2, cy + height * 0.62), fill=(*GOLD_HI, 255))
    body = over(blade, hc)
    sil = body.getchannel("A")
    ink = fill(grow(sil, max(3, height // 4)), INK)
    out = over(ink, body)
    if not tip_right:
        out = out.transpose(Image.FLIP_LEFT_RIGHT)
    return out


# ------------------------------------------------------------------------------------
# Hanko seal: 最後の刃 in a 2x2 grid, carved white out of crimson, with worn edges.


def hanko(side: int, kanji_font: str, seed: int = 7, vertical: bool = True) -> Image.Image:
    rng = random.Random(seed)
    S = side
    pad_px = int(S * 0.08)
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, S - 1, S - 1), radius=int(S * 0.1), fill=255)
    m = grain(m, 0.18, seed, scale=S / 300)
    red = vgrad((S, S), [(0, (214, 30, 52)), (1, (170, 12, 36))]).convert("RGBA")
    red.putalpha(m)
    img = red
    # Characters: traditional right-to-left columns (最後 right, の刃 left).
    chars = "最後の刃"
    cell = (S - 2 * pad_px) / 2
    f = font(kanji_font, int(cell * 0.92))
    cut = Image.new("L", (S, S), 0)
    cd = ImageDraw.Draw(cut)
    order = [(1, 0), (1, 1), (0, 0), (0, 1)] if vertical else [(0, 0), (1, 0), (0, 1), (1, 1)]
    for ch, (col, row) in zip(chars, order):
        cx = pad_px + cell * col + cell / 2
        cy = pad_px + cell * row + cell / 2
        cd.text((cx, cy), ch, font=f, fill=255, anchor="mm")
    cut = grow(cut, max(1, S // 110))  # a little bolder than the font, so it survives small sizes
    cut = grain(cut, 0.12, seed + 1, scale=S / 400)
    a = ImageChops.subtract(img.getchannel("A"), cut)
    img.putalpha(a)
    # A thin carved border inside the rim.
    rim = Image.new("L", (S, S), 0)
    inset = int(S * 0.035)
    ImageDraw.Draw(rim).rounded_rectangle(
        (inset, inset, S - 1 - inset, S - 1 - inset), radius=int(S * 0.08), outline=255, width=max(2, S // 70)
    )
    img.putalpha(ImageChops.subtract(img.getchannel("A"), rim))
    return img.rotate(rng.uniform(-4, -2), resample=Image.BICUBIC, expand=True)


def brush_kanji(text: str, size: int, kanji_font: str, color=CRIMSON) -> Image.Image:
    """Small vertical brush kanji with an ink outline."""
    f = font(kanji_font, size)
    h = int(size * 1.05 * len(text) + size)
    m = Image.new("L", (int(size * 1.6), h), 0)
    d = ImageDraw.Draw(m)
    for i, ch in enumerate(text):
        d.text((m.width / 2, size * 0.5 + i * size * 1.02 + size / 2), ch, font=f, fill=255, anchor="mm")
    m = m.crop(m.getbbox())
    m = pad(m, 12)
    return over(fill(grow(m, max(3, size // 14)), INK), fill(m, color))


# ------------------------------------------------------------------------------------
# Wordmark treatments.


def lettering(mask: Image.Image, style: str, scale: float) -> Image.Image:
    """Bone letters, gold keyline, thick ink outline and a hard ink drop shadow."""
    ink_r = int(16 * scale)
    gold_r = int(5 * scale)
    m = pad(mask, ink_r + int(30 * scale))
    face_rgb = vgrad(m.size, [(0, BONE_HI), (0.55, BONE), (1, BONE_LO)])
    if style == "ink":
        face_rgb = vgrad(m.size, [(0, (44, 38, 40)), (1, INK)])
    face = textured(m, face_rgb)
    # Bevel: a light top edge and a darker bottom edge inside each letter.
    inner = shrink(m, int(4 * scale))
    top = ImageChops.subtract(m, ImageChops.offset(inner, 0, int(3 * scale)))
    bevel_hi = fill(top.point(lambda v: int(v * 0.8)), (255, 255, 255) if style != "ink" else (90, 82, 84))
    bot = ImageChops.subtract(m, ImageChops.offset(inner, 0, -int(3 * scale)))
    bevel_lo = fill(bot.point(lambda v: int(v * 0.6)), (150, 120, 80) if style != "ink" else (0, 0, 0))
    keyline = fill(grow(m, gold_r), GOLD if style != "ink" else BONE)
    keyline_hi = textured(
        grow(m, gold_r), vgrad(m.size, [(0, GOLD_HI), (0.5, GOLD), (1, GOLD_LO)]) if style != "ink" else Image.new("RGB", m.size, BONE)
    )
    outline = fill(grow(m, gold_r + ink_r), INK)
    drop = shadow(grow(m, gold_r + ink_r), (0, int(10 * scale)), 1.5 * scale, 0.9)
    soft = shadow(grow(m, gold_r + ink_r), (0, int(18 * scale)), 14 * scale, 0.45)
    return over(soft, drop, outline, keyline, keyline_hi, face, bevel_hi, bevel_lo)


def place(canvas: Image.Image, layer: Image.Image, xy: tuple[int, int]) -> Image.Image:
    tmp = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    tmp.paste(layer, xy)
    return Image.alpha_composite(canvas, tmp)


def slash_light(w: int, h: int, angle: float = -8) -> Image.Image:
    """A thin white sword-light streak, tapering at both ends."""
    img = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(img)
    cy = h / 2
    pts_top, pts_bot = [], []
    for i in range(101):
        t = i / 100
        x = t * w
        th = (h * 0.18) * math.sin(math.pi * t) ** 0.6
        pts_top.append((x, cy - th))
        pts_bot.append((x, cy + th * 0.4))
    d.polygon(pts_top + pts_bot[::-1], fill=255)
    img = img.filter(ImageFilter.GaussianBlur(1.2))
    glow = img.filter(ImageFilter.GaussianBlur(h * 0.12)).point(lambda v: int(v * 0.6))
    layer = over(fill(glow, GOLD_HI), fill(img, (255, 255, 255)))
    return layer.rotate(angle, resample=Image.BICUBIC, expand=True)


def compose_carved(kanji_font: str, name: str, seal: str = "hanko") -> Image.Image:
    """Carved Cinzel Black capitals over a katana underline, with a hanko seal."""
    scale = 1.0
    f = font("Cinzel[wght].ttf", 300, 900)
    mask = text_mask("LAST BLADE", f, tracking=-0.015, kern={"AS": -0.02, "LA": -0.03, "T ": -0.06, " B": 0.0})
    letters = lettering(mask, "bone", scale)
    W = letters.width + 260
    H = letters.height + 260
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    # Katana through the baseline, tip out past the E, handle out past the L.
    sword = katana(int(W * 0.94), 34)
    sword = sword.rotate(3, resample=Image.BICUBIC, expand=True)
    canvas = place(canvas, sword, ((W - sword.width) // 2 + 30, 130 + letters.height - sword.height // 2 - 92))
    canvas = place(canvas, letters, (130, 100))
    if seal == "hanko":
        s = hanko(190, kanji_font)
        canvas = place(canvas, s, (W - s.width - 30, 30))
    else:
        k = brush_kanji("最後の刃", 64, kanji_font)
        canvas = place(canvas, k, (W - k.width - 10, 40))
    return trim(canvas)


def compose_stack(kanji_font: str) -> Image.Image:
    """Stacked: LAST small and tracked above a big BLADE, the katana between, seal right."""
    f_small = font("Cinzel[wght].ttf", 150, 900)
    f_big = font("Cinzel[wght].ttf", 330, 900)
    last = lettering(text_mask("LAST", f_small, tracking=0.12), "bone", 0.7)
    blade = lettering(text_mask("BLADE", f_big, tracking=-0.02, kern={"LA": -0.03}), "bone", 1.0)
    W = blade.width + 300
    H = last.height + blade.height + 120
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sword = katana(int(blade.width * 1.05), 30)
    y_sword = last.height - 30
    canvas = place(canvas, sword, ((W - sword.width) // 2, y_sword - sword.height // 2 + 10))
    canvas = place(canvas, last, ((W - last.width) // 2, 0))
    canvas = place(canvas, blade, ((W - blade.width) // 2, last.height - 50))
    s = hanko(200, kanji_font, seed=3)
    canvas = place(canvas, s, (W - s.width - 10, H - s.height - 70))
    return trim(canvas)


def compose_shoju(kanji_font: str) -> Image.Image:
    """Shojumaru (Japanese-flavoured display) letters with a diagonal slash cut through them."""
    f = font("Shojumaru-Regular.ttf", 280)
    mask = text_mask("LAST BLADE", f, tracking=-0.04)
    mask = pad(mask, 40)
    # The slash: a thin wedge cut out of the letters, then a light streak laid along it.
    w, h = mask.size
    cut = Image.new("L", mask.size, 0)
    cd = ImageDraw.Draw(cut)
    y0, y1 = h * 0.78, h * 0.26
    cd.polygon([(0, y0 - 2), (w, y1 - 14), (w, y1 + 2), (0, y0 + 9)], fill=255)
    mask = ImageChops.subtract(mask, cut)
    letters = lettering(mask, "bone", 1.0)
    W, H = letters.width + 200, letters.height + 200
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    canvas = place(canvas, letters, (100, 120))
    streak = slash_light(int(W * 1.0), 70, angle=math.degrees(math.atan2(y0 - y1, w)) * 1.0)
    canvas = place(canvas, streak, ((W - streak.width) // 2, 120 + int((y0 + y1) / 2) - streak.height // 2 + 40))
    s = hanko(170, kanji_font, seed=11)
    canvas = place(canvas, s, (W - s.width - 20, 0))
    return trim(canvas)


def compose_brush_ink(kanji_font: str) -> Image.Image:
    """Bone Yuji-brush letters with crimson brush swash behind and a gold katana underline."""
    f = font("YujiMai-Regular.ttf", 300)
    mask = text_mask("LAST BLADE", f, tracking=-0.06)
    letters = lettering(mask, "bone", 1.0)
    W, H = letters.width + 240, letters.height + 260
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sword = katana(int(W * 0.9), 30)
    canvas = place(canvas, sword, ((W - sword.width) // 2, H - sword.height - 40))
    canvas = place(canvas, letters, (120, 80))
    k = brush_kanji("最後の刃", 70, kanji_font)
    canvas = place(canvas, k, (W - k.width, 20))
    return trim(canvas)


# ------------------------------------------------------------------------------------
# Codex candidates: cut the white background away.


def cutout(src: Path) -> Image.Image:
    rgb = np.asarray(Image.open(src).convert("RGB")).astype(np.float32)
    lo = rgb.min(axis=2)
    spread = rgb.max(axis=2) - lo
    whiteish = (lo > 238) & (spread < 14)
    labels, _ = ndimage.label(whiteish)
    border = set(np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))) - {0}
    bg = np.isin(labels, list(border))
    pure = (lo > 248) & (spread < 6)
    hl, hn = ndimage.label(pure)
    sizes = ndimage.sum(pure, hl, range(1, hn + 1))
    for i, s in enumerate(sizes, start=1):
        if s > pure.size * 0.0004:
            bg |= hl == i
    alpha = np.where(bg, 0.0, 1.0)
    edge = ndimage.binary_dilation(bg, iterations=2) & ~bg
    whiteness = np.clip((lo - 150) / (255 - 150), 0, 1)
    alpha[edge] = np.minimum(alpha[edge], 1 - whiteness[edge] * 0.9)
    img = Image.fromarray(np.dstack([rgb, alpha * 255]).astype(np.uint8), "RGBA")
    img.putalpha(img.getchannel("A").filter(ImageFilter.GaussianBlur(0.6)))
    return trim(img)


# ------------------------------------------------------------------------------------
# Contact sheet: each candidate over real game frames at title size and at phone size.


def sheet(names: list[str], backgrounds: list[Path], out: Path) -> None:
    title_w, phone_w = 465, 310  # logo widths in TitleScreen: 1223x697 desktop, 844x390 phone
    bg_d = Image.open(backgrounds[0]).convert("RGB").resize((1223, 697))
    src = Image.open(backgrounds[-1]).convert("RGB")
    ch = int(src.width * 390 / 844)
    bg_p = src.crop((0, (src.height - ch) // 2, src.width, (src.height - ch) // 2 + ch)).resize((844, 390))
    rows = []
    for n in names:
        logo = Image.open(OUT / f"{n}.png")
        row = Image.new("RGB", (1223 + 844 + 30, 697), (30, 30, 30))
        d = bg_d.copy().convert("RGBA")
        lg = logo.resize((title_w, int(logo.height * title_w / logo.width)), Image.LANCZOS)
        d.alpha_composite(lg, ((1223 - lg.width) // 2, int(697 * 0.3 - lg.height / 2)))
        p = bg_p.copy().convert("RGBA")
        lp = logo.resize((phone_w, int(logo.height * phone_w / logo.width)), Image.LANCZOS)
        p.alpha_composite(lp, ((844 - lp.width) // 2, int(max(390 * 0.3, lp.height / 2 + 20) - lp.height / 2)))
        row.paste(d.convert("RGB"), (0, 0))
        row.paste(p.convert("RGB"), (1223 + 30, 0))
        ImageDraw.Draw(row).text((1223 + 40, 420), n, fill=(255, 255, 255), font=ImageFont.load_default(36))
        rows.append(row)
    W = rows[0].width
    img = Image.new("RGB", (W, sum(r.height + 20 for r in rows)), (30, 30, 30))
    y = 0
    for r in rows:
        img.paste(r, (0, y))
        y += r.height + 20
    img.thumbnail((2100, 99999))
    img.save(out, quality=88)


# The contact sheet's candidates, the pick first (cx_stacked is out: it spells "BADE").
SHEET = ["lb_inkgold_seal", "lb_bone_seal", "cx_carved", "cx_slash", "cx_brush", "p_carved"]

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    args = sys.argv[1:] or ["compose", "cutout"]
    if "compose" in args:
        compose_carved("YujiBoku-Regular.ttf", "carved").save(OUT / "p_carved.png")
        compose_stack("YujiBoku-Regular.ttf").save(OUT / "p_stacked.png")
        compose_shoju("ZenAntique-Regular.ttf").save(OUT / "p_shoju.png")
        compose_brush_ink("YujiBoku-Regular.ttf").save(OUT / "p_brush.png")
    if "cutout" in args:
        for src in sorted((HERE / "raw").glob("cx_*.png")):
            cutout(src).save(OUT / src.name)
    if "sheet" in args:
        i = args.index("sheet")
        bgs = [Path(p) for p in args[i + 1 :]]
        names = SHEET
        sheet(names, bgs, HERE / "contact_sheet.jpg")


def with_seal(src: str, at: tuple[float, float], side_frac: float, seed: int = 5) -> Image.Image:
    """A Codex wordmark plus the 最後の刃 hanko, its centre at `at` (fractions of the image)."""
    base = Image.open(OUT / f"{src}.png").convert("RGBA")
    s = hanko(int(base.height * side_frac), "YujiBoku-Regular.ttf", seed=seed)
    margin = s.width
    canvas = pad_rgba(base, margin)
    x = int(margin + base.width * at[0] - s.width / 2)
    y = int(margin + base.height * at[1] - s.height / 2)
    # A thin bone keyline around the seal so it reads over the ink and the scene.
    ring = fill(grow(s.getchannel("A").point(lambda v: 255 if v > 60 else 0), 5), BONE)
    canvas = place(canvas, ring, (x, y))
    canvas = place(canvas, s, (x, y))
    return trim(canvas, 8)


if __name__ == "__main__" and "final" in sys.argv[1:]:
    with_seal("cx_inkgold", (0.93, 0.84), 0.16).save(OUT / "lb_inkgold_seal.png")
    with_seal("cx_enso_bone", (0.92, 0.86), 0.16, seed=9).save(OUT / "lb_bone_seal.png")
