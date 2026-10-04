#!/usr/bin/env python3
"""Draws docs/faces-en.png and docs/faces-ko.png: one face per mood, rendered by the real
firmware code in the simulator (needs a C++ compiler and Pillow)."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / 'tools' / 'firmware_sim'
sys.path.insert(0, str(ROOT / 'core'))
from aiface import i18n, moods  # noqa: E402

CW, CH, OX, OY = 200, 180, 20, 30
FONTS = {'en': '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
         'ko': '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'}


def pick(mood):
    """The most telling frame: one with effects or a special eye shape, else the first."""
    frames = mood['frames']
    scored = sorted(range(len(frames)), key=lambda i: -(bool(frames[i]['fx']) * 2 + bool(frames[i]['eyes'])
                                                        + (frames[i]['left'] > 30)))
    return frames[scored[0]]


def render(frames):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for name in ('stub.h', 'render_moods.cpp'):
            (tmp / name).write_text((SIM / name).read_text())
        subprocess.run([sys.executable, str(SIM / 'mkfw.py'), str(ROOT / 'firmware/ESP32_Display/ESP32_Display.ino'),
                        str(tmp / 'fw.cpp')], check=True)
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O1', '-w', '-o', str(tmp / 'r'),
                        str(tmp / 'render_moods.cpp')], check=True)
        lines = '\n'.join(','.join(str(f[k]) for k in moods.FIELDS) for f in frames) + '\n'
        subprocess.run([str(tmp / 'r'), str(tmp / 'out.raw')], input=lines, text=True, check=True)
        data = (tmp / 'out.raw').read_bytes()
    size = CW * CH * 2
    out = []
    for k in range(len(frames)):
        chunk = data[k * size:(k + 1) * size]
        im = Image.new('RGB', (CW, CH))
        px = im.load()
        for i in range(CW * CH):
            v = chunk[2 * i] | chunk[2 * i + 1] << 8
            px[i % CW, i // CW] = ((v >> 11) << 3, ((v >> 5) & 63) << 2, (v & 31) << 3)
        out.append(im)
    return out


def marks(im, frame):
    """The firmware prints ? and ! with the GFX font, which the simulator does not draw."""
    d = ImageDraw.Draw(im)
    font = ImageFont.truetype(FONTS['en'], 26)
    fx = frame['fx']
    if fx & moods.QUESTION:
        d.text((178 - OX, 34 - OY), '?', font=font, fill=(255, 255, 255))
    if fx & moods.EXCLAIM:
        d.text(((156 if fx & moods.QUESTION else 182) - OX, 34 - OY), '!', font=font, fill=(255, 215, 60))


def sheet(lang, faces, cols=8):
    i18n.set_lang(lang)
    catalog = [m for m in moods.emotions() if m['id'] != 'auto']
    font = ImageFont.truetype(FONTS[lang], 22)
    cell_w, cell_h, label = CW, CH, 34
    rows = (len(catalog) + cols - 1) // cols
    img = Image.new('RGB', (cols * cell_w, rows * (cell_h + label)), (0, 0, 0))
    d = ImageDraw.Draw(img)
    for n, (mood, face) in enumerate(zip(catalog, faces)):
        x, y = (n % cols) * cell_w, (n // cols) * (cell_h + label)
        img.paste(face, (x, y))
        d.rectangle([x, y + cell_h, x + cell_w - 1, y + cell_h + label - 1], fill=(30, 30, 30))
        d.text((x + 8, y + cell_h + 4), mood['name'], font=font, fill=(235, 235, 235))
    path = ROOT / 'docs' / f'faces-{lang}.png'
    img.save(path, optimize=True)
    print('wrote', path)


def main():
    i18n.set_lang('en')
    catalog = [m for m in moods.emotions() if m['id'] != 'auto']
    frames = [pick(m) for m in catalog]
    faces = render(frames)
    for face, frame in zip(faces, frames):
        # Hide the corners of the owner ring that fall inside the canvas.
        mask = Image.new('L', (CW, CH), 0)
        ImageDraw.Draw(mask).ellipse([120 - 108 - OX, 120 - 108 - OY, 120 + 108 - OX, 120 + 108 - OY], fill=255)
        face.paste(Image.new('RGB', (CW, CH)), (0, 0), Image.eval(mask, lambda v: 255 - v))
        marks(face, frame)
    for lang in ('en', 'ko'):
        sheet(lang, faces)


if __name__ == '__main__':
    main()
