#!/usr/bin/env python3
"""Generates the launcher icon PNGs.

The in-app mark is drawn with primitives (AedLogo.mc); only the launcher
icon must be a real image, because Garmin renders it. Eight committed
PNGs with no source is how icon sets rot, so this script - not the PNGs -
is the thing to edit:

    python tools/make_icons.py

Sizes come from Garmin's per-product specs and don't follow screen size:
a 390 px Venu wants 60, a 390 px Forerunner 165 wants 54.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

# Garmin launcher icon sizes used across the supported products.
SIZES = [35, 36, 40, 54, 60, 61, 65, 70]

# Rendered at 8x and downsampled: aliasing on the heart's curve is the
# first thing you notice in the app list.
SUPERSAMPLE = 8

RED = (214, 40, 40, 255)
BOLT = (255, 255, 255, 255)


def draw_mark(size: int) -> Image.Image:
    """Heart with a bolt punched out. Geometry mirrors AedLogo.draw()."""
    s = size * SUPERSAMPLE
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    cx = s / 2.0
    cy = s / 2.0
    # Some watches crop to a circle; a heart touching the edge loses
    # its lobes.
    scale = s * 0.86

    lobe_r = 0.27 * scale
    lobe_y = cy - 0.16 * scale
    lobe_x = 0.24 * scale

    draw.ellipse(
        [cx - lobe_x - lobe_r, lobe_y - lobe_r,
         cx - lobe_x + lobe_r, lobe_y + lobe_r],
        fill=RED,
    )
    draw.ellipse(
        [cx + lobe_x - lobe_r, lobe_y - lobe_r,
         cx + lobe_x + lobe_r, lobe_y + lobe_r],
        fill=RED,
    )
    draw.polygon(
        [
            (cx - (lobe_x + lobe_r) + 0.02 * scale, lobe_y + 0.04 * scale),
            (cx + (lobe_x + lobe_r) - 0.02 * scale, lobe_y + 0.04 * scale),
            (cx, cy + 0.46 * scale),
        ],
        fill=RED,
    )

    draw.polygon(
        [
            (cx + 0.10 * scale, cy - 0.30 * scale),
            (cx - 0.14 * scale, cy + 0.02 * scale),
            (cx - 0.01 * scale, cy + 0.02 * scale),
            (cx - 0.09 * scale, cy + 0.32 * scale),
            (cx + 0.15 * scale, cy - 0.02 * scale),
            (cx + 0.01 * scale, cy - 0.02 * scale),
        ],
        fill=BOLT,
    )

    return image.resize((size, size), Image.LANCZOS)


DRAWABLES_XML = """<drawables xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
xsi:noNamespaceSchemaLocation="https://developer.garmin.com/downloads/connect-iq/resources.xsd">
    <bitmap id="LauncherIcon" filename="launcher_icon_{size}.png" dithering="none" />
</drawables>
"""


def main() -> None:
    # Fallback, so an unmapped product still compiles.
    base = ROOT / "resources" / "drawables"
    base.mkdir(parents=True, exist_ok=True)
    draw_mark(60).save(base / "launcher_icon.png")
    (base / "drawables.xml").write_text(
        """<drawables xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
xsi:noNamespaceSchemaLocation="https://developer.garmin.com/downloads/connect-iq/resources.xsd">
    <!-- Fallback launcher icon. Per-product sizes live in variants/
         and are mapped in monkey.jungle; the last resourcePath wins, so
         a variant overrides this. There is no LogoIcon: the in-app mark
         is drawn by AedLogo.mc, which needs no bitmap and no variants. -->
    <bitmap id="LauncherIcon" filename="launcher_icon.png" dithering="none" />
</drawables>
""",
        encoding="utf-8",
    )
    print(f"wrote {base / 'launcher_icon.png'} (60 px fallback)")

    for size in SIZES:
        folder = ROOT / "variants" / f"icon-{size}" / "drawables"
        folder.mkdir(parents=True, exist_ok=True)
        draw_mark(size).save(folder / f"launcher_icon_{size}.png")
        (folder / "drawables.xml").write_text(
            DRAWABLES_XML.format(size=size), encoding="utf-8"
        )
        print(f"wrote variants/icon-{size}/drawables/launcher_icon_{size}.png")


if __name__ == "__main__":
    main()
