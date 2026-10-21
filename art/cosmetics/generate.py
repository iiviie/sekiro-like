"""Procedural textures for part C (cosmetics): finisher and blade-line particles, beam textures,
brush kanji stamps, banner patterns and nameplate frames. Everything is drawn white (or white with
a soft dark shadow) so the game tints it with ImageColor3 / ParticleEmitter.Color / Beam.Color.

Run with Pillow + numpy:  python art/cosmetics/generate.py  -> art/cosmetics/png/*.png
Then serve png/ on 127.0.0.1 and upload with Studio MCP upload_image; ids go in
src/shared/Assets.luau (Assets.Cosmetics).

The brush kanji reuse art/ui/generate.py's kanji() so they match the HUD's existing stamps.
"""

from __future__ import annotations

import importlib.util
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
OUT = HERE / "png"
OUT.mkdir(exist_ok=True)
RNG = np.random.default_rng(23)

_spec = importlib.util.spec_from_file_location("ui_generate", HERE.parent / "ui" / "generate.py")
ui = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ui)  # type: ignore[union-attr]
ui.OUT = OUT  # its save() writes here now


def save(img: Image.Image, name: str) -> None:
    img.save(OUT / f"{name}.png", optimize=True)
    print(f"{name}.png {img.size}")


def blur(img: Image.Image, r: float) -> Image.Image:
    return img.filter(ImageFilter.GaussianBlur(r))


def white(mask: Image.Image) -> Image.Image:
    img = Image.new("RGBA", mask.size, (255, 255, 255, 0))
    img.putalpha(mask)
    return img


def supersample(draw, size: int, s: int = 4) -> Image.Image:
    """Draws an L mask at s x size and scales it down (smooth edges)."""
    big = Image.new("L", (size * s, size * s), 0)
    draw(ImageDraw.Draw(big), size * s)
    return big.resize((size, size), Image.LANCZOS)


# --- Particles -------------------------------------------------------------------------


def petal() -> None:
    """A sakura petal, tip up: a broad rounded top with a notch, tapering to a narrow base.
    White at the tip shading a little darker toward the base (the tint deepens there)."""
    size = 128
    s = 4
    n = size * s
    y, x = np.mgrid[0:n, 0:n].astype(np.float32) / n
    # width at each height: 0 at the base (y=0.95), widest near y=0.32, rounded over the top
    t = np.clip((0.95 - y) / 0.88, 0, 1)  # 0 base .. 1 top
    half = 0.36 * np.sin(np.clip(t, 0, 1) * np.pi * 0.62) ** 0.9
    top = np.where(t > 0.62, np.sqrt(np.clip(1 - ((t - 0.62) / 0.38) ** 2, 0, 1)) * 0.36, half)
    width = np.where(t > 0.62, top, half)
    inside = (np.abs(x - 0.5) < width) & (t > 0) & (t < 1)
    # the notch at the tip
    notch = (y < 0.07 + (0.06 - np.abs(x - 0.5)) * 1.3) & (np.abs(x - 0.5) < 0.06)
    m = (inside & ~notch).astype(np.float32)
    m = np.asarray(Image.fromarray((m * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)).astype(np.float32) / 255
    yy = np.linspace(0, 1, size)[:, None] * np.ones((1, size))
    shade = 0.72 + 0.28 * (1 - yy)
    rgb = np.clip(255 * shade, 0, 255)
    img = np.dstack([rgb, rgb, rgb, m * 255]).astype(np.uint8)
    save(Image.fromarray(img, "RGBA"), "petal")


def feather() -> None:
    """A crow's flight feather, tip up: a curved quill, a narrow leading vane and a broad trailing
    one, barbs that part in two places, a pointed tip. Light grey barbs with brighter edges so a
    near-black tint keeps a sheen."""
    size = 256
    s = 4
    n = size * s
    big = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(big)

    def spine(t: float) -> tuple[float, float]:
        return (0.5 + 0.07 * math.sin(t * math.pi) - 0.035) * n, (0.97 - 0.92 * t) * n

    splits = (0.36, 0.61)
    for i in range(420):
        t = 0.1 + i / 420 * 0.88
        if any(abs(t - sp) < 0.01 for sp in splits):
            continue
        x, y = spine(t)
        prof = math.sin(min(t / 0.98, 1) * math.pi) ** 0.5 * (1 - max(0, t - 0.8) * 2.2)
        for side, wmax in ((-1, 0.075), (1, 0.15)):
            width = prof * wmax * n * (0.92 + 0.08 * math.sin(i * 1.7))
            d.line((x, y, x + side * width, y - width * 0.9), fill=170 + (i % 3) * 30, width=int(1.3 * s))
    d.line([spine(i / 80) for i in range(81)], fill=255, width=int(2.6 * s))
    mask = big.resize((size, size), Image.LANCZOS)
    mask = blur(mask, 0.4)
    save(white(mask), "feather")


def ink_splats() -> None:
    """2x2 flipbook of ink splats: a blot, droplets and flung streaks with ragged edges."""
    cell = 256
    sheet = Image.new("L", (cell * 2, cell * 2), 0)
    for k in range(4):
        m = Image.new("L", (cell, cell), 0)
        d = ImageDraw.Draw(m)
        c = cell / 2
        r = cell * RNG.uniform(0.17, 0.24)
        d.ellipse((c - r, c - r * 0.85, c + r, c + r * 0.85), fill=255)
        for _ in range(9):  # lobes
            ang = RNG.uniform(0, math.tau)
            rr = r * RNG.uniform(0.35, 0.6)
            ox, oy = c + math.cos(ang) * r * 0.8, c + math.sin(ang) * r * 0.8
            d.ellipse((ox - rr, oy - rr, ox + rr, oy + rr), fill=255)
        for _ in range(7):  # flung streaks
            ang = RNG.uniform(0, math.tau)
            length = cell * RNG.uniform(0.25, 0.45)
            w = RNG.uniform(4, 9)
            ex, ey = c + math.cos(ang) * length, c + math.sin(ang) * length
            d.line((c, c, ex, ey), fill=255, width=int(w))
            d.ellipse((ex - w, ey - w, ex + w, ey + w), fill=255)
        for _ in range(22):  # droplets
            ang = RNG.uniform(0, math.tau)
            dist = cell * RNG.uniform(0.22, 0.46)
            rr = RNG.uniform(1.5, 6)
            ox, oy = c + math.cos(ang) * dist, c + math.sin(ang) * dist
            d.ellipse((ox - rr, oy - rr, ox + rr, oy + rr), fill=255)
        m = ui.roughen(m, 2.2, 5)
        sheet.paste(m, ((k % 2) * cell, (k // 2) * cell))
    save(white(sheet), "ink_splats")


def crescent() -> None:
    """A thin crescent moon with a cold halo, horns pointing up-right."""
    size = 512
    s = 2
    n = size * s
    y, x = np.mgrid[0:n, 0:n].astype(np.float32) / n
    outer = np.hypot(x - 0.5, y - 0.5) < 0.36
    inner = np.hypot(x - 0.62, y - 0.42) < 0.32
    body = (outer & ~inner).astype(np.float32)
    body = np.asarray(
        Image.fromarray((body * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)
    ).astype(np.float32) / 255
    halo = np.asarray(blur(Image.fromarray((body * 255).astype(np.uint8)), 22)).astype(np.float32) / 255
    a = np.clip(body + halo * 0.9, 0, 1)
    save(white(Image.fromarray((a * 255).astype(np.uint8))), "crescent")


def bolt(name: str, seed: int) -> None:
    """A jagged lightning bolt running left to right across a strip, for a Beam's texture
    (TextureMode Stretch): a white-hot core, a glow, and two thin forks."""
    rng = np.random.default_rng(seed)
    w, h = 512, 128
    s = 2
    big = Image.new("L", (w * s, h * s), 0)
    d = ImageDraw.Draw(big)

    def path(x0, y0, x1, y1, depth, jag):
        pts = [(x0, y0), (x1, y1)]
        for _ in range(depth):
            out = [pts[0]]
            for a, b in zip(pts, pts[1:]):
                mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
                seg = math.hypot(b[0] - a[0], b[1] - a[1])
                my += rng.uniform(-1, 1) * seg * jag
                out += [(mx, my), b]
            pts = out
        return pts

    main = path(0, h * s / 2, w * s, h * s / 2, 6, 0.32)
    d.line(main, fill=255, width=int(3.2 * s))
    for _ in range(2):
        i = rng.integers(len(main) // 5, len(main) * 3 // 4)
        x0, y0 = main[i]
        fork = path(x0, y0, x0 + rng.uniform(60, 140) * s, y0 + rng.choice([-1, 1]) * rng.uniform(18, 40) * s, 4, 0.3)
        d.line(fork, fill=170, width=int(1.6 * s))
    core = big.resize((w, h), Image.LANCZOS)
    glow = blur(core, 7).point(lambda v: min(255, v * 2.2))
    a = np.maximum(np.asarray(core), np.asarray(glow) * 0.75)
    # fade both ends so a stretched beam doesn't end on a hard edge
    ramp = np.clip(np.minimum(np.linspace(0, 1, w), np.linspace(1, 0, w)) * 10, 0, 1)[None, :]
    save(white(Image.fromarray((a * ramp).astype(np.uint8))), name)


# --- Banner patterns (tileable, 256px) -----------------------------------------------


def tile(draw, size: int = 256, s: int = 4, width: float = 1.0) -> Image.Image:
    """Draws a pattern on a 3x3 canvas and crops the centre, so marks crossing an edge
    wrap around and the tile repeats seamlessly."""
    n = size * s
    big = Image.new("L", (n * 3, n * 3), 0)
    draw(ImageDraw.Draw(big), n, s)
    centre = big.crop((n, n, n * 2, n * 2))
    return centre.resize((size, size), Image.LANCZOS)


def pattern_seigaiha() -> None:
    def draw(d, n, s):
        r = n / 4
        for row in range(-1, 26):
            for col in range(-1, 8):
                cx = col * r * 2 + (r if row % 2 else 0)
                cy = row * r * 0.5
                for k in range(4, 0, -1):
                    rr = r * k / 4
                    d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=0, outline=255, width=int(2.2 * s))
                d.ellipse((cx - r * 0.12, cy - r * 0.12, cx + r * 0.12, cy + r * 0.12), fill=255)

    save(white(tile(draw)), "pat_seigaiha")


def pattern_asanoha() -> None:
    """Hemp-leaf star lattice."""

    def draw(d, n, s):
        a = n / 2  # hexagon lattice step
        hgt = a * math.sqrt(3) / 2
        lw = int(1.6 * s)
        for row in range(-2, 9):
            for col in range(-2, 9):
                cx = col * a + (a / 2 if row % 2 else 0)
                cy = row * hgt
                corners = [(cx + a / 2 * math.cos(math.radians(60 * k + 30)) * 1.155, cy + a / 2 * math.sin(math.radians(60 * k + 30)) * 1.155) for k in range(6)]
                for k in range(6):
                    p, q = corners[k], corners[(k + 1) % 6]
                    d.line((p, q), fill=255, width=lw)
                    d.line(((cx, cy), p), fill=255, width=lw)
                    mx, my = (p[0] + q[0]) / 2, (p[1] + q[1]) / 2
                    d.line(((mx, my), p), fill=255, width=lw)
                    # inner kite lines to the centre of each triangle
                    tx, ty = (cx + p[0] + q[0]) / 3, (cy + p[1] + q[1]) / 3
                    for v in ((cx, cy), p, q):
                        d.line(((tx, ty), v), fill=180, width=max(1, lw // 2))

    save(white(tile(draw)), "pat_asanoha")


def pattern_kikko() -> None:
    """Tortoise-shell hexagons, double-lined."""

    def draw(d, n, s):
        r = n / 6
        w = r * math.sqrt(3)
        for row in range(-1, 12):
            for col in range(-1, 12):
                cx = col * w + (w / 2 if row % 2 else 0)
                cy = row * r * 1.5
                for scale, lw in ((1.0, 2.4), (0.72, 1.2)):
                    pts = [(cx + r * scale * math.cos(math.radians(60 * k + 30)), cy + r * scale * math.sin(math.radians(60 * k + 30))) for k in range(6)]
                    d.polygon(pts, outline=255, width=int(lw * s))

    save(white(tile(draw)), "pat_kikko")


def pattern_bamboo() -> None:
    def draw(d, n, s):
        for k, x in enumerate((0.12, 0.42, 0.7, 0.9)):
            wdt = (0.07 if k % 2 == 0 else 0.05) * n
            cx = n + x * n
            d.rectangle((cx - wdt / 2, 0, cx + wdt / 2, n * 3), fill=200)
            for node in range(-2, 8):
                y = n + (node * 0.42 + k * 0.17) * n
                d.rectangle((cx - wdt * 0.62, y - 3 * s, cx + wdt * 0.62, y + 3 * s), fill=255)
                # a leaf off some nodes
                if (node + k) % 3 == 0:
                    side = 1 if k % 2 else -1
                    d.polygon([(cx, y), (cx + side * 0.2 * n, y - 0.05 * n), (cx + side * 0.05 * n, y + 0.015 * n)], fill=230)

    save(white(tile(draw)), "pat_bamboo")


def pattern_mountains() -> None:
    """Layered peaks, wrapping horizontally (a vertical gradient is applied in game)."""
    w, h = 512, 256
    a = np.zeros((h, w), np.float32)
    x = np.arange(w)
    for layer, (amp, base, freq, val) in enumerate(((60, 120, 2, 0.55), (45, 165, 3, 0.75), (30, 205, 5, 1.0))):
        phase = RNG.uniform(0, math.tau)
        ridge = base - amp * (0.6 * np.abs(np.sin(x / w * math.pi * freq + phase)) + 0.4 * np.abs(np.sin(x / w * math.pi * freq * 2.3 + phase * 2)))
        ys = np.arange(h)[:, None]
        a = np.where(ys > ridge[None, :], val, a)
    # snow caps on the back range
    img = Image.fromarray((a * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.8))
    save(white(img), "pat_mountains")


def pattern_uroko() -> None:
    """Scales (triangles), for the dragon."""

    def draw(d, n, s):
        t = n / 4
        h = n / 4  # 4 rows per tile keeps it seamless
        for row in range(-1, 14):
            for col in range(-1, 14):
                x0 = col * t + (t / 2 if row % 2 else 0)
                y0 = row * h
                d.polygon([(x0, y0 + h), (x0 + t / 2, y0), (x0 + t, y0 + h)], fill=255)

    save(white(tile(draw)), "pat_uroko")


def pattern_tora() -> None:
    """Tiger stripes: tapered wavy strokes."""
    w = h = 256
    s = 4
    big = Image.new("L", (w * s, h * s), 0)
    d = ImageDraw.Draw(big)
    for k in range(9):
        y0 = (k / 9 + RNG.uniform(-0.02, 0.02)) * h * s
        x_start = RNG.uniform(-0.2, 0.3) * w * s
        length = RNG.uniform(0.5, 0.9) * w * s
        for i in range(80):
            t = i / 80
            x = x_start + t * length
            y = y0 + math.sin(t * math.pi * 1.4 + k) * 10 * s
            thick = math.sin(t * math.pi) * 9 * s
            d.ellipse((x - thick, y - thick * 0.6, x + thick, y + thick * 0.6), fill=255)
    img = big.resize((w, h), Image.LANCZOS)
    img = ui.roughen(img, 1.5, 4)
    save(white(img), "pat_tora")


def pattern_hishi() -> None:
    """Small diamonds (a thousand of them)."""

    def draw(d, n, s):
        t = n / 8
        for row in range(-1, 50):
            for col in range(-1, 26):
                cx = col * t + (t / 2 if row % 2 else 0)
                cy = row * t / 2
                r = t * 0.32
                d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], fill=255)

    save(white(tile(draw)), "pat_hishi")


def pattern_cloth() -> None:
    """Plain linen weave: soft noise in both directions."""
    size = 256
    hn = np.repeat(ui.noise(1, size, scale=1.0), size, axis=1)
    vn = np.repeat(ui.noise(size, 1, scale=1.0), size, axis=0)
    a = np.clip((hn * 0.5 + vn * 0.5) * 1.2 - 0.25, 0, 1) * 0.6
    save(white(Image.fromarray((a * 255).astype(np.uint8))), "pat_cloth")


# --- Frames ------------------------------------------------------------------------------


def nameplate(name: str, ornate: bool) -> None:
    """A 512x128 nameplate frame for 9-slice (SliceCenter 64,40,448,88): a double hairline
    border with cut corners; `ornate` adds corner kamon (a mitsudomoe-like ring) and studs."""
    w, h = 512, 128
    s = 4
    big = Image.new("L", (w * s, h * s), 0)
    d = ImageDraw.Draw(big)
    cut = 18 * s

    def frame(inset: float, lw: float, val: int):
        i = inset * s
        pts = [(i + cut, i), (w * s - i - cut, i), (w * s - i, i + cut), (w * s - i, h * s - i - cut), (w * s - i - cut, h * s - i), (i + cut, h * s - i), (i, h * s - i - cut), (i, i + cut)]
        d.polygon(pts, outline=val, width=int(lw * s))

    frame(4, 4, 255)
    frame(12, 1.5, 200)
    if ornate:
        for cx, cy in ((24, 24), (w - 24, 24), (24, h - 24), (w - 24, h - 24)):
            cx, cy = cx * s, cy * s
            r = 13 * s
            d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=0, outline=255, width=int(3 * s))
            for k in range(3):
                ang = math.radians(120 * k)
                px, py = cx + math.cos(ang) * r * 0.42, cy + math.sin(ang) * r * 0.42
                rr = r * 0.32
                d.ellipse((px - rr, py - rr, px + rr, py + rr), fill=255)
        for cx in (w / 2 - 40, w / 2, w / 2 + 40):
            for cy in (4, h - 4):
                d.regular_polygon((cx * s, (cy + (6 if cy < h / 2 else -6)) * s, 5 * s), 4, fill=255)
    img = big.resize((w, h), Image.LANCZOS)
    save(white(img), name)


def banner_edge() -> None:
    """A vertical banner's frame (256x512, 9-slice 48,48,208,464): a heavy outer band, a hairline
    inside it, and a rod with finials at the top (nobori style)."""
    w, h = 256, 512
    s = 4
    big = Image.new("L", (w * s, h * s), 0)
    d = ImageDraw.Draw(big)
    d.rectangle((6 * s, 18 * s, (w - 6) * s, (h - 6) * s), outline=255, width=int(7 * s))
    d.rectangle((20 * s, 32 * s, (w - 20) * s, (h - 20) * s), outline=190, width=int(2 * s))
    d.rectangle((0, 6 * s, w * s, 14 * s), fill=255)  # rod
    for cx in (6, w - 6):
        d.ellipse(((cx - 7) * s, 3 * s, (cx + 7) * s, 17 * s), fill=255)
    img = big.resize((w, h), Image.LANCZOS)
    save(white(img), "banner_frame")


if __name__ == "__main__":
    petal()
    feather()
    ink_splats()
    crescent()
    bolt("bolt_a", 3)
    bolt("bolt_b", 11)
    pattern_seigaiha()
    pattern_asanoha()
    pattern_kikko()
    pattern_bamboo()
    pattern_mountains()
    pattern_uroko()
    pattern_tora()
    pattern_hishi()
    pattern_cloth()
    nameplate("plate_plain", False)
    nameplate("plate_ornate", True)
    banner_edge()
    for text, name in [
        # finishers
        ("墨", "k_ink"), ("桜", "k_sakura"), ("鴉", "k_crow"), ("雷", "k_thunder"), ("月", "k_moon"),
        # blade lines
        ("夜桜", "k_yozakura"), ("雷神", "k_raijin"), ("烏", "k_karasu"),
        # banners
        ("鶴", "k_crane"), ("波", "k_wave"), ("山", "k_mountain"), ("竹", "k_bamboo"), ("龍", "k_dragon"),
        ("虎", "k_tiger"), ("鬼", "k_oni"), ("千", "k_thousand"), ("金", "k_gold"), ("翠", "k_jade"),
        ("紅", "k_crimson"), ("将軍", "k_shogun"), ("道", "k_path"), ("浪人", "k_ronin"),
        # the VIP plate (Hatamoto; was Ronin, which is also a bot tier)
        ("旗本", "k_hatamoto"),
    ]:
        ui.kanji(text, name)
