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

# The heart, as fractions of the mark's size. LOBE_* and TIP_DY are the
# free parameters; TANGENT_* are derived from them and must be
# recomputed if any of the others move.
LOBE_R = 0.27
LOBE_X = 0.24
LOBE_DY = -0.16
TIP_DY = 0.46
TANGENT_X = 0.430510
TANGENT_Y = 0.031327

# The mark is drawn at 86% of the icon box. Not cosmetic breathing room:
# the heart is 0.51 wide either side of centre, so at full size it would
# reach past the edge - and some watches crop the launcher icon to a
# circle, which takes the lobes off first.
MARK_SCALE = 0.86


def draw_mark(size: int) -> Image.Image:
    """Heart with a bolt punched out. Geometry mirrors AedLogo.draw()."""
    s = size * SUPERSAMPLE
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    cx = s / 2.0
    cy = s / 2.0
    scale = s * MARK_SCALE

    lobe_r = LOBE_R * scale
    lobe_y = cy + LOBE_DY * scale
    lobe_x = LOBE_X * scale

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
    # The V meets the lobes at their tangent points, so the silhouette
    # has no step where circle becomes straight edge. The middle vertex
    # is at lobe-centre height: below y = -0.036 the circles stop
    # overlapping, and a straight edge between the tangent points
    # (y = +0.031) would leave a hole in the cleavage.
    #
    # tools/test_logo_geometry.py rederives TANGENT_* from the lobe
    # constants and checks AedLogo.mc carries the same numbers.
    draw.polygon(
        [
            (cx - TANGENT_X * scale, cy + TANGENT_Y * scale),
            (cx, lobe_y),
            (cx + TANGENT_X * scale, cy + TANGENT_Y * scale),
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

# Connect IQ store listing icon: 500x500, sRGB, at least 10 px of
# padding. Generated from the same geometry as everything else rather
# than exported by hand once - a store icon that drifts from the
# launcher icon is the kind of thing nobody notices for a year.
STORE_SIZE = 500
STORE_PADDING = 40      # well past the 10 px floor; small icons need air

STORE_BACKGROUNDS = {
    # Matches the app, and stands out in a store grid of white tiles.
    "dark": (18, 18, 18, 255),
    # Safer against an unknown page background.
    "light": (255, 255, 255, 255),
}


def draw_store_icon(background: tuple[int, int, int, int]) -> Image.Image:
    """The launcher mark on an opaque square.

    Opaque on purpose: the store composites onto its own page, and a
    transparent PNG would leave the white bolt invisible wherever the
    page happens to be light.
    """
    canvas = Image.new("RGBA", (STORE_SIZE, STORE_SIZE), background)
    inner = STORE_SIZE - 2 * STORE_PADDING
    mark = draw_mark(inner)
    canvas.alpha_composite(mark, (STORE_PADDING, STORE_PADDING))
    # sRGB, no alpha channel - what the store asks for.
    return canvas.convert("RGB")


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

    store = ROOT / "store"
    store.mkdir(exist_ok=True)
    for name, background in STORE_BACKGROUNDS.items():
        path = store / f"store_icon_{name}.png"
        draw_store_icon(background).save(path)
        print(f"wrote store/{path.name} ({STORE_SIZE}x{STORE_SIZE}, sRGB)")


if __name__ == "__main__":
    main()
