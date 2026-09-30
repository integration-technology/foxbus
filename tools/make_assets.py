#!/usr/bin/env python3
"""Generate foxbus's device assets from assets/screen.png.

Writes to build/:
  screen.raw       320x320 BGRX background (fox upright on the blue disc)
  fox_frames.raw   360 frames of the 140x140 centre box, fox turned 0..359 deg clockwise
  glyphs.raw       Akkurat Bold digits, '.', '-', degree sign and 'C' on the disc blue
                   (only with --font; copy AkkuratNest-Bold.ttf from the device's
                   /nestlabs/share/fonts — it is licensed and must not be committed)

Usage: tools/make_assets.py [--font /path/to/AkkuratNest-Bold.ttf]
"""
import argparse
import pathlib
import struct

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
W = 320
BOX = 140
ORIGIN = 160 - BOX // 2
CENTRE = (159.5, 159.5)
BLUE = (0x43, 0x5F, 0xA6)
GLYPH_CHARS = "0123456789.-°C "


def bgrx(img):
    rgb = img.convert("RGB").tobytes()
    return bytes(v for j in range(0, len(rgb), 3) for v in (rgb[j + 2], rgb[j + 1], rgb[j], 0))


def screen(src, out):
    (out / "screen.raw").write_bytes(bgrx(src))


def fox_frames(src, out):
    with open(out / "fox_frames.raw", "wb") as f:
        for deg in range(360):
            turned = src.rotate(-deg, resample=Image.BICUBIC, center=CENTRE, fillcolor=(0, 0, 0))
            f.write(bgrx(turned.crop((ORIGIN, ORIGIN, ORIGIN + BOX, ORIGIN + BOX))))


def glyphs(font_path, out, size=36):
    font = ImageFont.truetype(str(font_path), size)
    ascent, descent = font.getmetrics()
    height = ascent + descent
    data = bytearray()
    for ch in GLYPH_CHARS:
        width = max(1, round(font.getlength(ch)))
        img = Image.new("RGB", (width, height), BLUE)
        ImageDraw.Draw(img).text((0, 0), ch, font=font, fill=(255, 255, 255))
        data += struct.pack("<BHH", ord(ch), width, height) + bgrx(img)
    (out / "glyphs.raw").write_bytes(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--font", type=pathlib.Path, help="AkkuratNest-Bold.ttf copied from the device")
    args = parser.parse_args()
    out = ROOT / "build"
    out.mkdir(exist_ok=True)
    src = Image.open(ROOT / "assets" / "screen.png").convert("RGB")
    screen(src, out)
    fox_frames(src, out)
    if args.font:
        glyphs(args.font, out)
    print("wrote", ", ".join(sorted(p.name for p in out.iterdir())))


if __name__ == "__main__":
    main()
