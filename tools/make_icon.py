#!/usr/bin/env python3
"""Draws app/macos/Resources/AppIcon.png (1024x1024): the happy face on its round screen
with the Claude-orange ring, on a macOS-style rounded square. Needs Pillow.
The build script turns it into AppIcon.icns with sips + iconutil."""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
S = 4096   # drawn large, scaled down for smooth edges


def stroke(d, pts, w, fill):
    """A thick round-capped line: stamp circles along the points (no seams at joints)."""
    r = w / 2
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        n = max(1, int(((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5 / (r / 3)))
        for k in range(n + 1):
            x, y = x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n
            d.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def main():
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    m, radius = int(S * 100 / 1024), int(S * 185 / 1024)   # macOS icon grid
    bg = Image.new('RGBA', (S, S))
    bd = ImageDraw.Draw(bg)
    for i in range(S):
        t = i / S
        bd.line([(0, i), (S, i)], fill=(int(40 - 26 * t), int(44 - 30 * t), int(68 - 42 * t), 255))
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, S - m, S - m], radius=radius, fill=255)
    img.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(img)
    cx = cy = S // 2
    R = int(S * 0.34)
    d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=(0, 0, 0, 255),
              outline=(0xD9, 0x77, 0x57, 255), width=int(S * 0.03))
    k = R / 120.0

    def P(x, y):   # LCD coordinates (240x240) to pixels
        return cx + (x - 120) * k, cy + (y - 120) * k
    white = (255, 255, 255, 255)
    for ex in (80, 160):   # ^ ^ eyes and pink cheeks
        stroke(d, [P(ex - 13 + 26 * i / 40, 94 - 11 * (1 - (i / 20 - 1) ** 2)) for i in range(41)], 9 * k, white)
        x0, y0 = P(ex - 15, 110)
        x1, y1 = P(ex + 15, 121)
        d.rounded_rectangle([x0, y0, x1, y1], radius=int(5.5 * k), fill=(240, 100, 140, 255))
    us = [i / 40 - 1 for i in range(81)]   # big open smile with rounded corners
    top = [P(120 + u * 44, 138 + 20 * (1 - u * u)) for u in us]
    bottom = [P(120 + u * 44, 138 + 20 * (1 - u * u) - 13 * (1 - u * u)) for u in us]
    d.polygon(top + bottom[::-1], fill=white)
    stroke(d, top, 8 * k, white)
    out = ROOT / 'app' / 'macos' / 'Resources' / 'AppIcon.png'
    img.resize((1024, 1024), Image.LANCZOS).save(out, optimize=True)
    print('wrote', out)


if __name__ == '__main__':
    main()
