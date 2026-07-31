"""The store's upload form rejects assets by the pixel.

Every one of these is a rule the Connect IQ dashboard enforces on
upload, which means getting one wrong costs a round trip through a web
form rather than a red test. They are checked against the committed
files, not against make_icons.py, so a hand-edited PNG is caught too.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import make_icons as mi  # noqa: E402

STORE = ROOT / "store"


def test_the_hero_image_exists():
    assert (STORE / "hero.png").exists(), "run: python tools/make_icons.py"


def test_the_hero_is_exactly_the_size_the_store_demands():
    """1440x720. Not "about" - the form refuses anything else."""
    with Image.open(STORE / "hero.png") as image:
        assert image.size == mi.HERO_SIZE, (
            f"hero.png is {image.size}, the store requires {mi.HERO_SIZE}"
        )


def test_the_hero_is_under_the_upload_cap():
    written = (STORE / "hero.png").stat().st_size
    assert written <= mi.HERO_MAX_BYTES, (
        f"hero.png is {written // 1024} KB, over the "
        f"{mi.HERO_MAX_BYTES // 1024} KB limit"
    )


@pytest.mark.parametrize("name", ["store_icon_dark", "store_icon_light"])
def test_the_store_icon_is_square_and_opaque(name):
    """RGB, not RGBA: a transparent icon renders the white bolt invisible
    wherever the store page happens to be light."""
    with Image.open(STORE / f"{name}.png") as image:
        assert image.size == (mi.STORE_SIZE, mi.STORE_SIZE)
        assert image.mode == "RGB", f"{name}.png is {image.mode}, expected RGB"


def test_the_listing_names_the_asset_files():
    """So the copy and the files can't quietly part company."""
    listing = (STORE / "LISTING.md").read_text(encoding="utf-8")
    for asset in ("store_icon_dark.png", "hero.png"):
        assert asset in listing, f"LISTING.md never mentions {asset}"
