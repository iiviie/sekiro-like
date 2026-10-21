"""Menu chrome for LAST BLADE: the 9-slice panels, buttons, pills, brush strokes, seals,
rings and reveal pieces from research_notes/progression/ui/ui_style_guide.md (sections 5,
7, 8, 11 and 14). Grown from the guide's proto_textures.py prototypes.

Neutral (white / grey) art is tinted in game with ImageColor3; lacquer, washi and the
coloured seals are drawn in their final colours. Writes art/ui/png/ui_*.png.

Run with Pillow + numpy (generate.py's kanji brush is reused):
    python art/ui/chrome.py            # everything
    python art/ui/chrome.py pill shine # just these
"""

from pathlib import Path
import math
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate  # noqa: E402  (kanji brush, roughen, noise)

OUT = Path(__file__).resolve().parent / "png"
OUT.mkdir(exist_ok=True)
MINCHO = "/System/Library/Fonts/ヒラギノ明朝 ProN.ttc"

# Tokens (UI.Theme in src/client/UI.luau)
INK = (26, 23, 24)
LACQUER = (36, 30, 32)
LACQUER_HI = (52, 43, 45)
BONE = (237, 227, 207)
WASHI = (230, 218, 192)
GOLD = (212, 165, 74)
GOLD_HI = (232, 199, 122)
BRONZE = (107, 74, 34)
CRIMSON = (200, 16, 46)
LACQUER_RED = (122, 10, 26)
JADE = (62, 158, 132)
JADE_BTN = (35, 98, 79)


def save(img: Image.Image, name: str) -> Image.Image:
    img.save(OUT / f"ui_{name}.png", optimize=True)
    print(f"ui_{name}.png {img.size}")
    return img


def smooth_noise(w: int, h: int, cell: int, seed: int) -> Image.Image:
    """Value noise in L mode around 128, feature size ~cell px."""
    rnd = random.Random(seed)
    sw, sh = max(2, w // cell + 2), max(2, h // cell + 2)
    small = Image.new("L", (sw, sh))
    small.putdata([rnd.randint(0, 255) for _ in range(sw * sh)])
    return small.resize((w, h), Image.BICUBIC)


def chamfer_poly(x0, y0, x1, y1, c):
    return [(x0 + c, y0), (x1 - c, y0), (x1, y0 + c), (x1, y1 - c), (x1 - c, y1), (x0 + c, y1), (x0, y1 - c), (x0, y0 + c)]


def chamfer_mask(w, h, inset, c, ss=4):
    m = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(m).polygon(
        chamfer_poly(inset * ss, inset * ss, (w - inset) * ss - 1, (h - inset) * ss - 1, c * ss), fill=255
    )
    return m.resize((w, h), Image.LANCZOS)


def roughen(mask: Image.Image, amount: float, seed: int, cell: int = 6) -> Image.Image:
    """Dry-brush edge: blur the mask, push it around with noise, re-threshold softly."""
    w, h = mask.size
    blurred = mask.filter(ImageFilter.GaussianBlur(amount * 0.6))
    n = smooth_noise(w, h, cell, seed)
    random.seed(seed)
    fine = Image.effect_noise((w, h), 40).filter(ImageFilter.GaussianBlur(0.6))
    n = Image.blend(n, fine, 0.35)
    pushed = ImageChops.add(blurred, n, scale=1.0, offset=-128)
    return pushed.point(lambda v: 0 if v < 110 else 255 if v > 146 else int((v - 110) * 255 / 36))


def vgrad(w, h, top, bottom) -> Image.Image:
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def grain(img: Image.Image, strength: float, seed: int) -> Image.Image:
    random.seed(seed)
    n = Image.effect_noise(img.size, 60).convert("RGB")
    return Image.blend(img, ImageChops.overlay(img, n), strength)


def ss_draw(w: int, h: int, ss: int = 4):
    m = Image.new("L", (w * ss, h * ss), 0)
    return m, ImageDraw.Draw(m)


def down(m: Image.Image, w: int, h: int) -> Image.Image:
    return m.resize((w, h), Image.LANCZOS)


def solid(w: int, h: int, colour, alpha: Image.Image) -> Image.Image:
    img = Image.new("RGBA", (w, h), colour + (0,))
    img.putalpha(alpha)
    return img


# --- Panels -------------------------------------------------------------------------------


def panel_lacquer() -> None:
    """256x256, slice Rect(40,40,216,216). Dark lacquer, dry-brush ink rim, a gold hairline
    8 px in with brighter ticks on the chamfers."""
    W = 256
    body = grain(vgrad(W, W, LACQUER_HI, (22, 18, 19)), 0.08, 1).convert("RGBA")
    outer = roughen(chamfer_mask(W, W, 4, 22), 3, 11)
    rim = Image.new("RGBA", (W, W), INK + (255,))
    base = Image.composite(body, rim, chamfer_mask(W, W, 7, 20))
    d = ImageDraw.Draw(base)
    hl = chamfer_poly(11, 11, W - 12, W - 12, 17)
    d.line(hl + [hl[0]], fill=GOLD + (200,), width=2)
    for a, b in [(hl[7], hl[0]), (hl[1], hl[2]), (hl[3], hl[4]), (hl[5], hl[6])]:
        d.line([a, b], fill=GOLD_HI + (255,), width=4)
    base.putalpha(outer)
    save(base, "panel_lacquer")


def panel_plain() -> None:
    """256x256, slice Rect(40,40,216,216). The lacquer body and ink rim without the gold
    hairline: HUD plates, toasts, kill feed, rows that sit on their own."""
    W = 256
    body = grain(vgrad(W, W, LACQUER_HI, (22, 18, 19)), 0.08, 1).convert("RGBA")
    outer = roughen(chamfer_mask(W, W, 4, 22), 3, 13)
    rim = Image.new("RGBA", (W, W), INK + (255,))
    base = Image.composite(body, rim, chamfer_mask(W, W, 7, 20))
    d = ImageDraw.Draw(base)
    hl = chamfer_poly(10, 10, W - 11, W - 11, 18)
    d.line(hl + [hl[0]], fill=(120, 96, 70, 90), width=1)
    base.putalpha(outer)
    save(base, "panel_plain")


def panel_inset() -> None:
    """128x128, slice Rect(24,24,104,104). A neutral (grey) inset plate tinted in game: rows,
    stat chips, cards and tier cells inside a lacquer window. Small 10 px chamfer, a lighter
    rim line and an ink outline, so any tint keeps an edge."""
    W = 128
    body = grain(vgrad(W, W, (205, 205, 205), (150, 150, 150)), 0.05, 6).convert("RGBA")
    rim = Image.new("RGBA", (W, W), (40, 40, 40, 255))
    base = Image.composite(body, rim, chamfer_mask(W, W, 4, 11))
    d = ImageDraw.Draw(base)
    hl = chamfer_poly(6, 6, W - 7, W - 7, 9)
    d.line(hl + [hl[0]], fill=(255, 255, 255, 150), width=1)
    base.putalpha(roughen(chamfer_mask(W, W, 1, 13), 1.6, 17, cell=4))
    save(base, "panel_inset")


def panel_washi() -> None:
    """256x256, slice Rect(36,36,220,220). Bone paper, fibres, deckled edge, burnt rim."""
    W = 256
    img = grain(Image.new("RGB", (W, W), WASHI), 0.10, 2)
    d = ImageDraw.Draw(img)
    rnd = random.Random(3)
    for _ in range(160):
        x, y = rnd.uniform(0, W), rnd.uniform(0, W)
        L = rnd.uniform(6, 26)
        dx, dy = rnd.uniform(-1, 1), rnd.uniform(-0.4, 0.4)
        c = rnd.choice([(214, 200, 170), (244, 236, 220), (220, 206, 178)])
        d.line([(x, y), (x + dx * L, y + dy * L)], fill=c, width=1)
    rim = chamfer_mask(W, W, 14, 4).filter(ImageFilter.GaussianBlur(10))
    img = Image.composite(img, Image.new("RGB", (W, W), (196, 178, 140)), rim)
    img = img.convert("RGBA")
    img.putalpha(roughen(chamfer_mask(W, W, 5, 4), 4, 21, cell=5))
    save(img, "panel_washi")


def paper_grain() -> None:
    """256x256 tileable grain overlay (white; alpha = grain). ScaleType Tile."""
    W = 256
    random.seed(9)
    n = Image.effect_noise((W, W), 50).filter(ImageFilter.GaussianBlur(0.7))
    big = smooth_noise(W, W, 32, 9)
    a = ImageChops.add(n, big, scale=2.0, offset=0).point(lambda v: max(0, min(255, (v - 110) * 2)))
    a = Image.blend(a, a.transpose(Image.FLIP_LEFT_RIGHT), 0.5)
    a = Image.blend(a, a.transpose(Image.FLIP_TOP_BOTTOM), 0.5)
    save(solid(W, W, (255, 255, 255), a.point(lambda v: v // 3)), "paper_grain")


# --- Buttons, pills, rings ----------------------------------------------------------------


def button_base() -> None:
    """192x64, slice Rect(24,20,168,44). Neutral, tinted per variant: sheen band, ink rim,
    a pale inner hairline."""
    W, H = 192, 64
    body = vgrad(W, H, (255, 255, 255), (178, 178, 178))
    band = Image.new("L", (W, H), 0)
    ImageDraw.Draw(band).rectangle([0, 6, W, 22], fill=70)
    body = Image.composite(Image.new("RGB", (W, H), (255, 255, 255)), body, band.filter(ImageFilter.GaussianBlur(4)))
    body = grain(body, 0.05, 4).convert("RGBA")
    rim = Image.new("RGBA", (W, H), INK + (255,))
    btn = Image.composite(body, rim, chamfer_mask(W, H, 4, 9))
    d = ImageDraw.Draw(btn)
    hl = chamfer_poly(7, 7, W - 8, H - 8, 7)
    d.line(hl + [hl[0]], fill=(255, 255, 255, 110), width=1)
    btn.putalpha(roughen(chamfer_mask(W, H, 1, 11), 2, 31, cell=4))
    save(btn, "button_base")


def pill() -> None:
    """160x48, slice Rect(24,0,136,48). The koban currency capsule."""
    W, H, ss = 160, 48, 4
    m, d = ss_draw(W, H, ss)
    d.rounded_rectangle([2 * ss, 2 * ss, (W - 2) * ss, (H - 2) * ss], radius=(H / 2 - 2) * ss, fill=255)
    body = grain(vgrad(W, H, LACQUER_HI, (18, 15, 16)), 0.06, 5).convert("RGBA")
    inner, di = ss_draw(W, H, ss)
    di.rounded_rectangle([4 * ss, 4 * ss, (W - 4) * ss, (H - 4) * ss], radius=(H / 2 - 4) * ss, fill=255)
    img = Image.composite(body, Image.new("RGBA", (W, H), INK + (255,)), down(inner, W, H))
    ImageDraw.Draw(img).rounded_rectangle([6, 6, W - 7, H - 7], radius=H / 2 - 6, outline=GOLD + (170,), width=1)
    img.putalpha(down(m, W, H))
    save(img, "pill")


def select_ring() -> None:
    """128x128, slice Rect(32,32,96,96). A 2 px chamfer outline (white, tinted GoldHi) for
    gamepad focus and picked cards."""
    W, ss = 128, 4
    m, d = ss_draw(W, W, ss)
    poly = [(x * ss, y * ss) for x, y in chamfer_poly(3, 3, W - 4, W - 4, 14)]
    d.line(poly + [poly[0]], fill=255, width=3 * ss)
    glow = down(m, W, W).filter(ImageFilter.GaussianBlur(3)).point(lambda v: v // 2)
    save(solid(W, W, (255, 255, 255), ImageChops.lighter(down(m, W, W), glow)), "select_ring")


def ring(W: int, r_out: float, r_in: float, ss: int = 4) -> Image.Image:
    m, d = ss_draw(W, W, ss)
    c = W * ss / 2
    d.ellipse([c - r_out * ss, c - r_out * ss, c + r_out * ss, c + r_out * ss], fill=255)
    d.ellipse([c - r_in * ss, c - r_in * ss, c + r_in * ss, c + r_in * ss], fill=0)
    return down(m, W, W)


def touch_ring() -> None:
    """128x128: an ink rim with a gold hairline ring inside, laid over the touch discs so
    they read over dark ground."""
    W = 128
    img = solid(W, W, INK, roughen(ring(W, 63, 55), 1.2, 71, cell=4))
    gold = solid(W, W, GOLD, ring(W, 54, 51.5))
    save(Image.alpha_composite(img, gold), "touch_ring")


def disc_icon(W: int, glyph) -> Image.Image:
    """A small lacquer disc with a gold rim; `glyph(draw, ss)` paints on top."""
    ss = 4
    m, d = ss_draw(W, W, ss)
    c = W * ss / 2
    r = (W / 2 - 3) * ss
    d.ellipse([c - r, c - r, c + r, c + r], fill=255)
    alpha = roughen(down(m, W, W), 1.0, 81, cell=4)
    body = grain(vgrad(W, W, LACQUER_HI, (20, 16, 17)), 0.06, 8).convert("RGBA")
    rim = solid(W, W, INK, alpha)
    body.putalpha(ring(W, W / 2 - 7, 0))
    img = Image.alpha_composite(rim, body)
    img = Image.alpha_composite(img, solid(W, W, GOLD, ring(W, W / 2 - 7, W / 2 - 10)))
    g, gd = ss_draw(W, W, ss)
    glyph(gd, ss)
    g = roughen(down(g, W, W), 1.0, 83, cell=3)
    return Image.alpha_composite(img, solid(W, W, BONE, g))


def icon_close() -> None:
    """128x128: a brushed bone x on a small lacquer disc with a gold rim (the tsuba close)."""

    def cross(d, ss):
        W = 128 * ss
        a, b = W * 0.33, W * 0.67
        for (x0, y0, x1, y1) in [(a, a, b, b), (b, a, a, b)]:
            steps = 40
            for i in range(steps + 1):
                t = i / steps
                w = (10 - 4 * abs(t - 0.4)) * ss
                x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
                d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)

    save(disc_icon(128, cross), "icon_close")


def icon_plus() -> None:
    """128x128: a bone + on the same disc (gem top-up)."""

    def plus(d, ss):
        W = 128 * ss
        c, a, w = W / 2, W * 0.3, 11 * ss
        d.rounded_rectangle([a, c - w / 2, W - a, c + w / 2], radius=w / 2, fill=255)
        d.rounded_rectangle([c - w / 2, a, c + w / 2, W - a], radius=w / 2, fill=255)

    save(disc_icon(128, plus), "icon_plus")


def chevron(name: str, flip: bool) -> None:
    """128x128: a bone arrow on the disc (spectate previous / next, back)."""

    def arrow(d, ss):
        W = 128 * ss
        pts = [(0.58, 0.3), (0.38, 0.5), (0.58, 0.7)]
        if flip:
            pts = [(1 - x, y) for x, y in pts]
        d.line([(x * W, y * W) for x, y in pts], fill=255, width=12 * ss, joint="curve")

    save(disc_icon(128, arrow), name)


# --- Brush strokes, seals, shine ------------------------------------------------------------


def brush(w: int, h: int, thick: float, seed: int, name: str) -> None:
    """A white tapered dry-brush stroke (tinted): underline (tabs, links) and swipe (selected
    nav, PLAY backing)."""
    ss = 2
    m, d = ss_draw(w, h, ss)
    rnd = random.Random(seed)
    cy = h * ss / 2
    for i in range(w * ss):
        t = i / (w * ss)
        taper = min(1, t / 0.08) * min(1, (1 - t) / 0.25) ** 0.7
        half = thick * ss / 2 * taper * (0.9 + 0.1 * rnd.random())
        y = cy + (t - 0.5) * -h * ss * 0.12
        d.line([(i, y - half), (i, y + half)], fill=255)
    m = down(m, w, h)
    random.seed(seed)
    streak = Image.effect_noise((4, h), 90).resize((w, h), Image.BICUBIC)
    streak = streak.point(lambda v: 255 if v > 70 else int(v * 255 / 70))
    m = roughen(ImageChops.multiply(m, streak), 2, seed + 1, cell=3)
    save(solid(w, h, (255, 255, 255), m), name)


def hanko(char: str, name: str, colour) -> None:
    """64x64 seal with a knocked-out glyph."""
    W, ss = 64, 4
    m, d = ss_draw(W, W, ss)
    d.rounded_rectangle([4 * ss, 4 * ss, 60 * ss, 60 * ss], radius=8 * ss, fill=255)
    f = ImageFont.truetype(MINCHO, 42 * ss, index=1)
    bbox = d.textbbox((0, 0), char, font=f)
    d.text(
        ((W * ss - (bbox[2] - bbox[0])) / 2 - bbox[0], (W * ss - (bbox[3] - bbox[1])) / 2 - bbox[1]),
        char,
        font=f,
        fill=0,
    )
    save(solid(W, W, colour, roughen(down(m, W, W), 1, 41, cell=3)), name)


def hanko_check() -> None:
    """64x64 round jade seal with a knocked-out brush tick: done / equipped."""
    W, ss = 64, 4
    m, d = ss_draw(W, W, ss)
    d.ellipse([3 * ss, 3 * ss, 61 * ss, 61 * ss], fill=255)
    pts = [(18, 33), (28, 43), (47, 21)]
    d.line([(x * ss, y * ss) for x, y in pts], fill=0, width=8 * ss, joint="curve")
    save(solid(W, W, JADE, roughen(down(m, W, W), 1, 43, cell=3)), "hanko_check")


def shine() -> None:
    """128x512 diagonal light streak for legendary sweeps."""
    W, H = 128, 512
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).rectangle([W * 0.35, 0, W * 0.65, H], fill=255)
    img = solid(W, H, (255, 255, 255), m.filter(ImageFilter.GaussianBlur(14)))
    save(img.rotate(-20, resample=Image.BICUBIC, expand=False), "shine")


def life_pip() -> None:
    """48x48: a gold-rimmed crimson diamond (boss lives)."""
    W, ss = 48, 4
    out, d = ss_draw(W, W, ss)
    c = W * ss / 2

    def dia(r):
        return [(c, c - r), (c + r, c), (c, c + r), (c - r, c)]

    d.polygon(dia(22 * ss), fill=255)
    img = solid(W, W, INK, down(out, W, W))
    g, gd = ss_draw(W, W, ss)
    gd.polygon(dia(19 * ss), fill=255)
    img = Image.alpha_composite(img, solid(W, W, GOLD, down(g, W, W)))
    r, rd = ss_draw(W, W, ss)
    rd.polygon(dia(14 * ss), fill=255)
    red = vgrad(W, W, (226, 40, 60), LACQUER_RED).convert("RGBA")
    red.putalpha(down(r, W, W))
    img = Image.alpha_composite(img, red)
    h, hd = ss_draw(W, W, ss)
    hd.polygon([(c, c - 11 * ss), (c + 5 * ss, c - 6 * ss), (c, c - 1 * ss), (c - 5 * ss, c - 6 * ss)], fill=110)
    save(Image.alpha_composite(img, solid(W, W, (255, 255, 255), down(h, W, W))), "life_pip")


def tomoe_mask(W: int, ss: int, r_frac: float = 0.46) -> Image.Image:
    """A mitsudomoe (three comma swirl) mask, drawn from circles."""
    m, d = ss_draw(W, W, ss)
    c = W * ss / 2
    R = W * ss * r_frac
    for k in range(3):
        a = math.radians(90 + k * 120)
        # head: a disc at 0.45 R from centre; tail: a crescent sweeping round
        hx, hy = c + math.cos(a) * R * 0.42, c - math.sin(a) * R * 0.42
        hr = R * 0.36
        steps = 40
        for i in range(steps):
            t = i / steps
            ang = a + t * math.radians(150)
            rad = R * (0.42 + 0.5 * t)
            w = hr * (1 - t) ** 1.4
            x, y = c + math.cos(ang) * rad, c - math.sin(ang) * rad
            d.ellipse([x - w, y - w, x + w, y + w], fill=255)
        d.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=255)
    return down(m, W, W)


def tomoe() -> None:
    """64x64 gold mitsudomoe on an ink disc: boss difficulty stars."""
    W, ss = 64, 4
    img = solid(W, W, INK, ring(W, 31, 0))
    gold = vgrad(W, W, GOLD_HI, GOLD).convert("RGBA")
    gold.putalpha(ImageChops.multiply(tomoe_mask(W, ss, 0.4), ring(W, 27, 0)))
    img = Image.alpha_composite(img, gold)
    img = Image.alpha_composite(img, solid(W, W, GOLD, ring(W, 31, 29)))
    save(img, "tomoe")


def card_back() -> None:
    """256x340: ink card back with a gold hairline and a gold tomoe mon (x10 reveal flips)."""
    W, H = 256, 340
    body = grain(vgrad(W, H, (40, 33, 35), (16, 13, 14)), 0.08, 12).convert("RGBA")
    alpha = roughen(chamfer_mask(W, H, 3, 16), 2, 91)
    d = ImageDraw.Draw(body)
    hl = chamfer_poly(12, 12, W - 13, H - 13, 12)
    d.line(hl + [hl[0]], fill=GOLD + (220,), width=2)
    hl2 = chamfer_poly(20, 20, W - 21, H - 21, 8)
    d.line(hl2 + [hl2[0]], fill=GOLD + (90,), width=1)
    mon = 150
    gold = vgrad(mon, mon, GOLD_HI, BRONZE).convert("RGBA")
    gold.putalpha(tomoe_mask(mon, 4, 0.42))
    ringg = solid(mon, mon, GOLD, ring(mon, 74, 69))
    mon_img = Image.alpha_composite(ringg, gold)
    body.alpha_composite(mon_img, ((W - mon) // 2, (H - mon) // 2))
    body.putalpha(alpha)
    save(body, "card_back")


def reveal_slip() -> None:
    """512x160, slice Rect(48,40,464,120). A washi fortune slip with rolled ends."""
    W, H = 512, 160
    paper = grain(Image.new("RGB", (W, H), WASHI), 0.10, 14)
    d = ImageDraw.Draw(paper)
    rnd = random.Random(15)
    for _ in range(220):
        x, y = rnd.uniform(0, W), rnd.uniform(0, H)
        L = rnd.uniform(6, 24)
        c = rnd.choice([(214, 200, 170), (244, 236, 220)])
        d.line([(x, y), (x + rnd.uniform(-1, 1) * L, y + rnd.uniform(-0.3, 0.3) * L)], fill=c, width=1)
    img = paper.convert("RGBA")
    alpha = Image.new("L", (W, H), 0)
    ImageDraw.Draw(alpha).rectangle([20, 14, W - 21, H - 15], fill=255)
    alpha = roughen(alpha, 2.5, 17, cell=4)
    img.putalpha(alpha)
    # rolled ends: darker cylinders with a highlight
    for x0 in (4, W - 40):
        roll = Image.new("RGBA", (36, H), (0, 0, 0, 0))
        rd = ImageDraw.Draw(roll)
        for x in range(36):
            t = x / 35
            shade = 0.62 + 0.38 * math.sin(math.pi * t) ** 0.7
            col = tuple(int(c * shade) for c in (220, 204, 168))
            rd.line([(x, 4), (x, H - 5)], fill=col + (255,))
        roll.putalpha(roughen(_roll_mask(36, H), 1.5, 19, 3))
        img.alpha_composite(roll, (x0, 0))
    save(img, "reveal_slip")


def _roll_mask(w: int, h: int) -> Image.Image:
    m, d = ss_draw(w, h, 4)
    d.rounded_rectangle([1 * 4, 2 * 4, (w - 1) * 4, (h - 2) * 4], radius=8 * 4, fill=255)
    return down(m, w, h)


def reveal_stick() -> None:
    """64x256 bamboo fortune stick (natural colour) plus ui_reveal_tip.png: the white top
    third, tinted to the result's highest rarity in game."""
    W, H = 64, 256
    m, d = ss_draw(W, H, 4)
    d.rounded_rectangle([20 * 4, 6 * 4, 44 * 4, 250 * 4], radius=10 * 4, fill=255)
    alpha = down(m, W, H)
    wood = Image.new("RGB", (W, H))
    wd = ImageDraw.Draw(wood)
    for x in range(W):
        t = (x - 20) / 24
        shade = 0.7 + 0.3 * math.sin(math.pi * max(0, min(1, t)))
        wd.line([(x, 0), (x, H)], fill=tuple(int(c * shade) for c in (214, 180, 120)))
    for y in (96, 176):  # bamboo nodes
        wd.line([(18, y), (46, y)], fill=(120, 92, 54), width=3)
    wood = grain(wood, 0.06, 21).convert("RGBA")
    edge = solid(W, H, INK, alpha.filter(ImageFilter.MaxFilter(5)))
    wood.putalpha(alpha)
    save(Image.alpha_composite(edge, wood), "reveal_stick")
    tip, td = ss_draw(W, H, 4)
    td.rounded_rectangle([20 * 4, 6 * 4, 44 * 4, 80 * 4], radius=10 * 4, fill=255)
    td.rectangle([20 * 4, 40 * 4, 44 * 4, 80 * 4], fill=255)
    save(solid(W, H, (255, 255, 255), roughen(down(tip, W, H), 1, 23, 3)), "reveal_tip")


# --- Brush kanji ----------------------------------------------------------------------------


def kanji(text: str, name: str, size: int) -> None:
    generate.kanji(text, f"ui_{name}", size)


def kanji_vertical(text: str, name: str, size: int = 200) -> None:
    """Vertical brush kanji (the title seal 最後の刃): glyphs stacked top to bottom, same brush."""
    np = generate.np
    font = ImageFont.truetype(MINCHO, size, index=1)
    pad = 60
    boxes = [font.getbbox(ch) for ch in text]
    cell = int(size * 1.02)
    w = size + pad * 2
    h = cell * len(text) + pad * 2
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    for i, ch in enumerate(text):
        l, t, r, b = boxes[i]
        x = pad + (size - (r - l)) / 2 - l
        y = pad + i * cell + (cell - (b - t)) / 2 - t
        d.text((x, y), ch, font=font, fill=255)
    mask = mask.filter(ImageFilter.MaxFilter(5))
    mask = generate.roughen(mask, 3.5, 7)
    m = np.asarray(mask).astype(np.float32) / 255
    streak = np.repeat(generate.noise(1, h, scale=1.2), w, axis=1)
    m = m * (0.82 + 0.18 * np.clip((streak - 0.22) * 2.6, 0, 1))
    mask = Image.fromarray((np.clip(m, 0, 1) * 255).astype(np.uint8))
    shadow = generate.blur(mask, 12).point(lambda a: a * 0.8)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    img.putalpha(shadow)
    ink = solid(w, h, (255, 255, 255), mask)
    out = Image.alpha_composite(img, ink)
    out.save(OUT / f"ui_{name}.png", optimize=True)
    print(f"ui_{name}.png {out.size}")


RARITY_KANJI = [("並", "kanji_common"), ("良", "kanji_uncommon"), ("稀", "kanji_rare"), ("秀", "kanji_epic"), ("極", "kanji_legendary")]
BOSS_KANJI = [
    ("追憶の名も無き武人", "boss_Enemy01"),
    ("傀儡巫女", "boss_Enemy02"),
    ("大兎の式神", "boss_Enemy03"),
    ("荒くれの小鬼", "boss_Enemy04"),
    ("狭霧の護り人", "boss_Enemy05"),
    ("夜狐", "boss_Enemy06"),
    ("ねこ大将", "boss_Enemy07"),
    ("残映の影", "boss_Enemy08"),
    ("二天兎", "boss_Enemy09"),
]

JOBS = {
    "panel_lacquer": panel_lacquer,
    "panel_plain": panel_plain,
    "panel_inset": panel_inset,
    "panel_washi": panel_washi,
    "paper_grain": paper_grain,
    "button_base": button_base,
    "pill": pill,
    "select_ring": select_ring,
    "touch_ring": touch_ring,
    "icon_close": icon_close,
    "icon_plus": icon_plus,
    "icon_prev": lambda: chevron("icon_prev", False),
    "icon_next": lambda: chevron("icon_next", True),
    "brush_underline": lambda: brush(512, 48, 30, 51, "brush_underline"),
    "brush_swipe": lambda: brush(512, 128, 92, 61, "brush_swipe"),
    "hanko_new": lambda: hanko("新", "hanko_new", CRIMSON),
    "hanko_check": hanko_check,
    "shine": shine,
    "life_pip": life_pip,
    "tomoe": tomoe,
    "card_back": card_back,
    "reveal_slip": reveal_slip,
    "reveal_stick": reveal_stick,
    "kanji_rarity": lambda: [kanji(t, n, 300) for t, n in RARITY_KANJI],
    "kanji_bosses": lambda: [kanji(t, n, 92) for t, n in BOSS_KANJI],
    "kanji_title": lambda: kanji_vertical("最後の刃", "kanji_title"),
}

if __name__ == "__main__":
    for job in sys.argv[1:] or list(JOBS):
        JOBS[job]()
