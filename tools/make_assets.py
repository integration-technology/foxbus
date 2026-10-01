#!/usr/bin/env python3
"""Generate foxbus's device assets from assets/screen.png.

Writes build/screen.raw: the 320x320 BGRX background (fox on the blue disc).
The bus screens reuse it with the fox covered.

Text is rendered on the device by the SDK's textrender helper, so no font is needed here.

Usage: tools/make_assets.py
"""
import pathlib

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
W = 320


def bgrx(img):
    rgb = img.convert("RGB").tobytes()
    return bytes(v for j in range(0, len(rgb), 3) for v in (rgb[j + 2], rgb[j + 1], rgb[j], 0))


def screen(src, out):
    (out / "screen.raw").write_bytes(bgrx(src))


def main():
    out = ROOT / "build"
    out.mkdir(exist_ok=True)
    src = Image.open(ROOT / "assets" / "screen.png").convert("RGB")
    screen(src, out)
    print("wrote", ", ".join(sorted(p.name for p in out.iterdir())))


if __name__ == "__main__":
    main()
