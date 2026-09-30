#!/usr/bin/env python3
"""Generate foxbus's device assets from assets/screen.png.

Writes to build/:
  screen.raw       320x320 BGRX background (fox upright on the blue disc)
  fox_frames.raw   360 frames of the 140x140 centre box, fox turned 0..359 deg clockwise

Text is rendered on the device by the SDK's textrender helper, so no font is needed here.

Usage: tools/make_assets.py
"""
import pathlib

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
W = 320
BOX = 140
ORIGIN = 160 - BOX // 2
CENTRE = (159.5, 159.5)


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


def main():
    out = ROOT / "build"
    out.mkdir(exist_ok=True)
    src = Image.open(ROOT / "assets" / "screen.png").convert("RGB")
    screen(src, out)
    fox_frames(src, out)
    print("wrote", ", ".join(sorted(p.name for p in out.iterdir())))


if __name__ == "__main__":
    main()
