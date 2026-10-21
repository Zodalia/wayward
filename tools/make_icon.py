#!/usr/bin/env python3
# Draws Wayward's icon: a gold map pin at the end of a dashed trail, over a
# night-teal topographic map. Pillow only, so it runs anywhere:
#   python3 tools/make_icon.py
# writes Wayward/Media/Icon.tga (64x64, the TOC's IconTexture and the minimap
# button) and art/wayward-icon-512.png (the CurseForge / Wago thumbnail).
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
S = 2048  # drawn at 4x the thumbnail, then downsampled


def px(v):
    return int(round(v * S))


def gradient_fill(mask, inner, outer, radial=True):
    """`mask` filled with a gradient from `inner` (centre / top) to `outer`."""
    g = Image.radial_gradient("L") if radial else Image.linear_gradient("L")
    g = g.resize(mask.size, Image.BICUBIC)
    a = Image.new("RGB", mask.size, inner)
    b = Image.new("RGB", mask.size, outer)
    out = Image.composite(b, a, g).convert("RGBA")
    out.putalpha(mask)
    return out


def bezier(p0, p1, p2, p3, n=600):
    pts = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        pts.append(tuple(
            u * u * u * p0[k] + 3 * u * u * t * p1[k] + 3 * u * t * t * p2[k] + t * t * t * p3[k]
            for k in range(2)))
    return pts


def dashes(pts, dash, gap):
    """Splits a polyline into dash segments of `dash` length, `gap` apart."""
    out, cur, acc, on = [], [pts[0]], 0.0, True
    for a, b in zip(pts, pts[1:]):
        acc += math.dist(a, b)
        if on:
            cur.append(b)
        if acc >= (dash if on else gap):
            if on:
                out.append(cur)
            acc, on, cur = 0.0, not on, [b]
    if on and len(cur) > 1:
        out.append(cur)
    return out


def stroke(draw, pts, width, fill):
    draw.line(pts, fill=fill, width=width, joint="curve")
    r = width / 2
    for x, y in (pts[0], pts[-1]):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def pin_polygon(cx, cy, r, tip_y, n=200):
    """A teardrop: a circle at (cx, cy) with tangents meeting at (cx, tip_y)."""
    d = tip_y - cy
    spread = math.acos(r / d)  # tangent points, either side of straight down
    start = math.pi / 2 + spread
    sweep = 2 * math.pi - 2 * spread
    pts = [(cx + r * math.cos(start + sweep * i / n), cy + r * math.sin(start + sweep * i / n))
           for i in range(n + 1)]
    pts.append((cx, tip_y))
    return pts


def draw():
    full = Image.new("L", (S, S), 255)

    # Background: deep teal, darker towards the edges.
    img = gradient_fill(full, (38, 92, 98), (8, 20, 30))

    # Topographic contours around a hill under the pin.
    topo = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(topo)
    hx, hy = 0.60, 0.40
    for ring in range(1, 12):
        base = 0.07 * ring
        pts = []
        for i in range(361):
            t = math.radians(i)
            r = base * (1 + 0.10 * math.sin(3 * t + ring * 0.7) + 0.06 * math.sin(5 * t - ring))
            pts.append((px(hx + r * math.cos(t)), px(hy + r * 0.82 * math.sin(t))))
        td.line(pts, fill=(170, 220, 205, 46), width=px(0.006))
    img = Image.alpha_composite(img, topo)

    # The trail: from the bottom-left corner, winding up to the pin's tip.
    tip = (0.60, 0.70)
    trail = [(px(x), px(y)) for x, y in bezier((0.10, 0.98), (0.10, 0.62), (0.52, 0.98), tip)]
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).line(trail, fill=(255, 214, 120, 120), width=px(0.05), joint="curve")
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(px(0.02))))
    path = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pd = ImageDraw.Draw(path)
    for seg in dashes(trail[:-40], px(0.055), px(0.035)):
        stroke(pd, seg, px(0.030), (246, 228, 178, 255))
    img = Image.alpha_composite(img, path)

    # The pin: shadow, gold body, highlight, dark eye.
    cx, cy, r = 0.60, 0.33, 0.20
    body = Image.new("L", (S, S), 0)
    ImageDraw.Draw(body).polygon([(px(x), px(y)) for x, y in pin_polygon(cx, cy, r, tip[1])], fill=255)

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(ImageChops.offset(body, px(0.02), px(0.03)).filter(ImageFilter.GaussianBlur(px(0.025))))
    shadow.putalpha(shadow.getchannel("A").point(lambda a: a * 0.7))
    img = Image.alpha_composite(img, shadow)

    outline = body.filter(ImageFilter.MaxFilter(2 * (px(0.012) // 2) + 1))
    img = Image.alpha_composite(img, gradient_fill(outline, (70, 38, 8), (40, 20, 4), radial=False))
    img = Image.alpha_composite(img, gradient_fill(body, (255, 214, 92), (196, 112, 24), radial=False))

    shine = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shine).ellipse((px(cx - r * 0.72), px(cy - r * 0.86), px(cx + r * 0.10), px(cy - r * 0.10)), fill=110)
    shine = ImageChops.multiply(shine.filter(ImageFilter.GaussianBlur(px(0.03))), body)
    glare = Image.new("RGBA", (S, S), (255, 248, 220, 0))
    glare.putalpha(shine)
    img = Image.alpha_composite(img, glare)

    eye = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    er = r * 0.46
    ed = ImageDraw.Draw(eye)
    ed.ellipse((px(cx - er), px(cy - er), px(cx + er), px(cy + er)), fill=(74, 40, 8, 255))
    er2 = er * 0.78
    ed.ellipse((px(cx - er2), px(cy - er2), px(cx + er2), px(cy + er2)), fill=(20, 50, 58, 255))
    # A compass star in the eye: long points north-south, short east-west.
    star = []
    for i in range(16):
        a = -math.pi / 2 + i * math.pi / 8
        rr = er2 * (0.86 if i % 4 == 0 else 0.22 if i % 2 else 0.30)
        if i % 8 == 4:
            rr = er2 * 0.56
        star.append((px(cx + rr * math.cos(a)), px(cy + rr * math.sin(a))))
    ed.polygon(star, fill=(246, 228, 178, 255))
    img = Image.alpha_composite(img, eye)

    return img.convert("RGB")


def main():
    img = draw()
    art = ROOT / "art"
    art.mkdir(exist_ok=True)
    img.resize((512, 512), Image.LANCZOS).save(art / "wayward-icon-512.png", optimize=True)
    media = ROOT / "Wayward" / "Media"
    media.mkdir(exist_ok=True)
    # WoW wants power-of-two textures; uncompressed TGA loads everywhere.
    img.resize((64, 64), Image.LANCZOS).save(media / "Icon.tga", compression=None)
    print("art/wayward-icon-512.png, Wayward/Media/Icon.tga")


if __name__ == "__main__":
    main()
