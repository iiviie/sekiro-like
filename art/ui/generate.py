"""Renders the HUD's UI art: soft framed bars, glows, the posture ornament, the
deathblow dot, brush-stroke kanji and an ink band. Outputs PNGs next to this file.

Everything is drawn white or neutral where the game tints it (ImageColor3
multiplies), so one texture serves several colours.

Run with Pillow + numpy:  python art/ui/generate.py
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

OUT = Path(__file__).resolve().parent / "png"
OUT.mkdir(exist_ok=True)
MINCHO = "/System/Library/Fonts/ヒラギノ明朝 ProN.ttc"
RNG = np.random.default_rng(7)


def save(img: Image.Image, name: str) -> None:
    img.save(OUT / f"{name}.png", optimize=True)
    print(f"{name}.png {img.size}")


def blur(img: Image.Image, radius: float) -> Image.Image:
    return img.filter(ImageFilter.GaussianBlur(radius))


def noise(w: int, h: int, scale: float = 1.0) -> np.ndarray:
    """Smooth-ish value noise in 0..1."""
    base = RNG.random((max(2, int(h / scale)), max(2, int(w / scale))))
    img = Image.fromarray((base * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
    return np.asarray(img).astype(np.float32) / 255


# --- Bars ----------------------------------------------------------------------------

def bar_frame() -> None:
    """9-slice track: soft drop shadow, dark lacquer track, thin bronze hairline."""
    w, h, pad = 256, 40, 10
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    shadow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((pad - 3, pad - 2, w - pad + 3, h - pad + 4), radius=4, fill=170)
    img.putalpha(blur(shadow, 4))
    img = Image.composite(Image.new("RGBA", (w, h), (0, 0, 0, 255)), img, blur(shadow, 4))

    track = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(track)
    for y in range(pad, h - pad):
        t = (y - pad) / (h - 2 * pad)
        c = int(22 - 10 * t)
        d.line((pad, y, w - pad - 1, y), fill=(c + 4, c, c - 2, 235))
    img = Image.alpha_composite(img, track)

    rim = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rectangle((pad, pad, w - pad - 1, h - pad - 1), outline=(176, 146, 98, 210), width=1)
    glow = blur(rim, 1.2)
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, rim)
    save(img, "bar_frame")


def bar_fill() -> None:
    """White fill with a bright top edge, a darker base and faint brushed streaks."""
    w, h = 512, 16
    y = np.linspace(0, 1, h)[:, None]
    shade = 0.78 + 0.22 * (1 - y) - 0.18 * y**2
    shade[1] += 0.12  # specular line near the top
    streaks = noise(w, h, scale=6.0) * 0.08 + noise(w, h, scale=1.5) * 0.05
    v = np.clip(shade - streaks, 0, 1)
    rgb = (np.dstack([v, v, v]) * 255).astype(np.uint8)
    alpha = np.full((h, w), 255, np.uint8)
    save(Image.fromarray(np.dstack([rgb, alpha]), "RGBA"), "bar_fill")


def bar_glow() -> None:
    """Soft horizontal bloom used under the posture bar when it runs hot."""
    w, h = 512, 96
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle((40, 38, w - 40, h - 38), radius=10, fill=255)
    m = blur(m, 14)
    img = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    img.putalpha(m)
    save(img, "bar_glow")


def posture_ornament() -> None:
    """Gold lozenge with swept wings, the centrepiece of the posture bar."""
    s = 4  # supersample
    w, h = 160 * s, 48 * s
    cx, cy = w // 2, h // 2
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def shape(scale: float, fill) -> None:
        r = 18 * s * scale
        d.polygon([(cx, cy - r), (cx + r * 0.75, cy), (cx, cy + r), (cx - r * 0.75, cy)], fill=fill)
        for side in (-1, 1):
            d.polygon(
                [
                    (cx + side * r * 0.55, cy - 3 * s * scale),
                    (cx + side * 62 * s * scale, cy - 1 * s * scale),
                    (cx + side * 66 * s * scale, cy),
                    (cx + side * 62 * s * scale, cy + 1 * s * scale),
                    (cx + side * r * 0.55, cy + 3 * s * scale),
                ],
                fill=fill,
            )

    shape(1.12, (12, 9, 7, 255))  # dark outline
    shape(1.0, (198, 162, 96, 255))  # gold body
    # inner dark eye of the lozenge
    r = 7 * s
    d.polygon([(cx, cy - r), (cx + r * 0.75, cy), (cx, cy + r), (cx - r * 0.75, cy)], fill=(24, 16, 12, 255))
    img = img.resize((w // s, h // s), Image.LANCZOS)

    # bevel: lighten the top half a touch
    arr = np.asarray(img).astype(np.float32)
    grad = np.linspace(1.18, 0.82, arr.shape[0])[:, None]
    arr[..., :3] = np.clip(arr[..., :3] * grad[..., None], 0, 255)
    img = Image.fromarray(arr.astype(np.uint8), "RGBA")

    glow = blur(img.split()[3].point(lambda a: a * 0.5), 3)
    under = Image.new("RGBA", img.size, (0, 0, 0, 0))
    under.putalpha(glow)
    save(Image.alpha_composite(under, img), "posture_ornament")


# --- Glows, dots, reticle ----------------------------------------------------------

def radial(size: int, falloff: float) -> np.ndarray:
    y, x = np.mgrid[0:size, 0:size]
    r = np.hypot(x - size / 2 + 0.5, y - size / 2 + 0.5) / (size / 2)
    return np.clip(1 - r, 0, 1) ** falloff


def soft_glow() -> None:
    size = 128
    a = (radial(size, 2.2) * 255).astype(np.uint8)
    rgb = np.full((size, size, 3), 255, np.uint8)
    save(Image.fromarray(np.dstack([rgb, a]), "RGBA"), "glow")


def deathblow_dot() -> None:
    """Sekiro's red deathblow marker: hot core, dark ring, crimson halo."""
    size = 160
    halo = radial(size, 2.6)
    core = radial(size, 1.0)
    y, x = np.mgrid[0:size, 0:size]
    r = np.hypot(x - size / 2, y - size / 2)
    ring = np.exp(-((r - 26) ** 2) / 10)
    red = np.zeros((size, size, 4), np.float32)
    red[..., 0] = 255
    red[..., 1] = 40 + 200 * np.clip(core * 1.6 - 0.9, 0, 1)
    red[..., 2] = 30 + 190 * np.clip(core * 1.6 - 0.95, 0, 1)
    alpha = np.clip(halo * 0.9 + np.clip(core * 3 - 2.1, 0, 1) + ring * 0.55, 0, 1)
    red[..., :3] *= (1 - ring[..., None] * 0.45)
    red[..., 3] = alpha * 255
    save(Image.fromarray(red.astype(np.uint8), "RGBA"), "deathblow_dot")


def reticle() -> None:
    s = 4
    size = 64 * s
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = size // 2
    d.ellipse((c - 11 * s, c - 11 * s, c + 11 * s, c + 11 * s), fill=(10, 8, 8, 200))
    d.ellipse((c - 7 * s, c - 7 * s, c + 7 * s, c + 7 * s), fill=(244, 236, 220, 255))
    img = img.resize((64, 64), Image.LANCZOS)
    glow = Image.new("RGBA", (64, 64), (255, 255, 255, 0))
    glow.putalpha(blur(img.split()[3].point(lambda a: a * 0.35), 4))
    save(Image.alpha_composite(glow, img), "reticle")


def vignette() -> None:
    size = 512
    y, x = np.mgrid[0:size, 0:size]
    r = np.hypot((x - size / 2) / (size / 2), (y - size / 2) / (size / 2))
    a = np.clip((r - 0.55) / 0.75, 0, 1) ** 1.6
    rgba = np.zeros((size, size, 4), np.uint8)
    rgba[..., 3] = (a * 255).astype(np.uint8)
    save(Image.fromarray(rgba, "RGBA"), "vignette")


# --- Ink -----------------------------------------------------------------------------

def roughen(mask: Image.Image, amount: float, grain: float) -> Image.Image:
    """Ragged, dry-brush edges: jitter the mask with noise, then threshold softly."""
    w, h = mask.size
    m = np.asarray(blur(mask, amount)).astype(np.float32) / 255
    n = noise(w, h, scale=grain) * 0.6 + noise(w, h, scale=grain / 4) * 0.4
    v = np.clip((m - 0.5 + (n - 0.5) * 0.55) * 6 + 0.5, 0, 1)
    return Image.fromarray((v * 255).astype(np.uint8))


def kanji(text: str, name: str, size: int = 340) -> None:
    """White brush-style kanji: ink-spread strokes, ragged edges, dry-brush gaps and a
    few splatters, over an inky shadow. Tinted in game."""
    font = ImageFont.truetype(MINCHO, size, index=1)  # W6
    left, top, right, bottom = font.getbbox(text)
    pad = 70
    w, h = right - left + pad * 2, bottom - top + pad * 2
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).text((pad - left, pad - top), text, font=font, fill=255)
    # ink spreads into the paper: fatten slightly, then tear the edges
    mask = mask.filter(ImageFilter.MaxFilter(5))
    mask = roughen(mask, 3.5, 7)

    m = np.asarray(mask).astype(np.float32) / 255
    # dry brush: streaky gaps running mostly horizontally and vertically through strokes
    streak_h = np.repeat(noise(1, h, scale=1.2), w, axis=1)
    streak_v = np.repeat(noise(w, 1, scale=1.2), h, axis=0)
    dry = np.clip((streak_h * 0.55 + streak_v * 0.45 - 0.22) * 2.6, 0, 1)
    m = m * (0.82 + 0.18 * dry)
    # splatter flecks around the glyph
    for _ in range(26):
        cx, cy = RNG.integers(pad // 2, w - pad // 2), RNG.integers(pad // 2, h - pad // 2)
        r = RNG.uniform(1.5, 5.5)
        y, x = np.ogrid[0:h, 0:w]
        m = np.maximum(m, np.clip(1 - np.hypot(x - cx, y - cy) / r, 0, 1) * RNG.uniform(0.5, 1.0))
    mask = Image.fromarray((np.clip(m, 0, 1) * 255).astype(np.uint8))

    shadow = blur(mask, 12).point(lambda a: a * 0.8)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    img.putalpha(shadow)
    ink = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    ink.putalpha(mask)
    save(Image.alpha_composite(img, ink), name)


def ink_band() -> None:
    """A thick horizontal sumi brush stroke with flicked tails, used behind banners."""
    w, h = 1024, 260
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    for x in range(w):
        t = x / w
        body = np.sin(np.pi * min(1, max(0, (t - 0.01) / 0.98))) ** 0.35
        thickness = body * 92 + 2
        wobble = np.sin(t * 7.0) * 7 + np.sin(t * 19.0) * 3
        d.line((x, h / 2 - thickness + wobble, x, h / 2 + thickness * 0.85 + wobble * 0.5), fill=255)
    # flicked tails at both ends
    d.polygon([(0, h / 2 - 6), (90, h / 2 - 40), (140, h / 2 - 10), (60, h / 2 + 4)], fill=255)
    d.polygon([(w, h / 2 + 10), (w - 110, h / 2 + 44), (w - 160, h / 2 + 8), (w - 70, h / 2 - 6)], fill=255)
    mask = roughen(mask, 4, 6)
    # bristle streaks that break up along their length, so they read as brushed, not ruled
    bristles = np.repeat(noise(1, h, scale=1.3), w, axis=1) * 0.6 + noise(w, h, scale=24) * 0.4
    dry = np.clip((bristles - 0.18) * 1.7, 0, 1)
    m = np.asarray(mask).astype(np.float32) / 255 * (0.55 + 0.45 * dry)
    img = Image.new("RGBA", (w, h), (8, 6, 6, 0))
    img.putalpha(Image.fromarray((np.clip(m, 0, 1) * 240).astype(np.uint8)))
    save(img, "ink_band")


def gourd() -> None:
    """Healing gourd icon: lacquered gourd with a cord, warm rim light."""
    s = 4
    size = 96 * s
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = size // 2

    def body(grow: int, fill) -> None:
        d.ellipse((c - 26 * s - grow, c + 2 * s - grow, c + 26 * s + grow, c + 42 * s + grow), fill=fill)
        d.ellipse((c - 16 * s - grow, c - 26 * s - grow, c + 16 * s + grow, c + 6 * s + grow), fill=fill)
        d.rectangle((c - 6 * s - grow, c - 36 * s - grow, c + 6 * s + grow, c - 20 * s + grow), fill=fill)

    body(3 * s, (14, 10, 8, 255))
    body(0, (158, 92, 44, 255))
    d.rectangle((c - 7 * s, c - 40 * s, c + 7 * s, c - 34 * s), fill=(60, 40, 28, 255))  # stopper
    d.rectangle((c - 17 * s, c + 1 * s, c + 17 * s, c + 5 * s), fill=(196, 160, 96, 255))  # cord
    img = img.resize((96, 96), Image.LANCZOS)
    arr = np.asarray(img).astype(np.float32)
    shade = np.linspace(1.25, 0.75, 96)[None, :, None]  # light from the left
    arr[..., :3] = np.clip(arr[..., :3] * shade, 0, 255)
    save(Image.fromarray(arr.astype(np.uint8), "RGBA"), "gourd")


if __name__ == "__main__":
    bar_frame()
    bar_fill()
    bar_glow()
    posture_ornament()
    soft_glow()
    deathblow_dot()
    reticle()
    vignette()
    ink_band()
    gourd()
    for text, name in [("危", "kanji_peril"), ("死", "kanji_death"), ("忍殺", "kanji_execution"), ("勝", "kanji_victory"), ("終", "kanji_end"), ("決闘", "kanji_duel"), ("回生", "kanji_resurrect"), ("斬", "kanji_slay"), ("一騎討", "kanji_final"), ("紅月", "kanji_bloodmoon"), ("鉄心", "kanji_ironwill"), ("霧", "kanji_mist")]:
        kanji(text, name)
