#!/usr/bin/env python3
"""Squeezes simulator screenshots under the store's 150 KB limit.

    python tools/pack_screenshots.py store/*.png

Palette PNG rather than JPEG on purpose. The images are a photographic
watch bezel around a flat black screen with crisp red-on-black text, and
JPEG's weakness is exactly that: high-contrast chroma edges. A slightly
banded bezel costs nothing; ringing around the words the screenshot
exists to show costs the whole point of it.

Writes screen-1.png, screen-2.png ... next to the originals and leaves
the originals alone.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageChops

MAX_BYTES = 150 * 1024
TARGET_HEIGHT = 1000
# Tried 256 first: one image landed at 147 KB, which is 2% of headroom
# and would break the next time anything is re-exported.
COLORS = 192


def trimmed(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGB")
    white = Image.new("RGB", image.size, (255, 255, 255))
    box = (ImageChops.difference(image, white)
           .convert("L").point(lambda v: 255 if v > 8 else 0).getbbox())
    return image.crop(box) if box else image


def main(argv: list[str]) -> int:
    sources = [Path(a) for a in argv]
    if not sources:
        print(__doc__)
        return 2

    for index, source in enumerate(sorted(sources), 1):
        image = trimmed(source)
        height = min(TARGET_HEIGHT, image.height)
        image = image.resize(
            (round(image.width * height / image.height), height), Image.LANCZOS)

        out = source.parent / f"screen-{index}.png"
        image.quantize(COLORS, method=Image.MAXCOVERAGE).save(out, optimize=True)

        written = out.stat().st_size
        status = "ok" if written <= MAX_BYTES else "STILL TOO BIG"
        print(f"{source.name} -> {out.name}  {image.size}  "
              f"{written / 1024:.0f} KB  {status}")
        if written > MAX_BYTES:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
