"""Keeps PRIVACY.md's factual claims tied to the code.

This file exists because the document went stale in exactly the way
that matters. It described the grid cell as "5.5 km by 3.5 km" - true
of the old 0.05 degree grid - and kept saying so after the grid was
retuned to 0.03. The number moved in the direction that overstates the
protection: the request revealed a *more* precise location than the
policy admitted.

Prose has no compiler, so a privacy policy drifts silently while every
other number in the project is checked. These tests give it the same
treatment as the grid itself.
"""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import build_tiles as bt  # noqa: E402

DOC = (ROOT / "PRIVACY.md").read_text(encoding="utf-8")

# Markdown hard-wraps at ~72 columns, so any phrase long enough to be
# worth asserting on will sooner or later straddle a newline. Match
# against the collapsed text and the assertions stop depending on where
# the author happened to press Enter.
FLAT = " ".join(DOC.split())

# Poland, generously. Only has to be tight enough to catch a path from
# a different grid - the old 1044/420 decodes to the Mediterranean.
LAT_RANGE = (49.0, 54.9)
LON_RANGE = (14.1, 24.2)

KM_PER_LAT_DEG = 111.32


def test_the_quoted_cell_size_is_the_real_one():
    quoted = re.findall(r"(\d+\.\d+)\s*°", FLAT)
    assert quoted, "PRIVACY.md no longer states the cell size in degrees"
    assert all(float(q) == bt.CELL_DEG for q in quoted), (
        f"PRIVACY.md says {quoted}, but the grid is {bt.CELL_DEG}"
    )


def test_the_quoted_north_south_width_matches():
    """The one figure a reader can actually picture."""
    match = re.search(r"about (\d+(?:\.\d+)?) km north–south", FLAT)
    assert match, "PRIVACY.md no longer states a north-south cell width"

    claimed = float(match.group(1))
    actual = bt.CELL_DEG * KM_PER_LAT_DEG
    assert abs(claimed - actual) < 0.1, (
        f"PRIVACY.md claims {claimed} km north-south; the grid gives "
        f"{actual:.2f} km"
    )


def test_the_quoted_east_west_width_matches():
    """Longitude shrinks with latitude, so this one is a range."""
    match = re.search(r"roughly (\d+(?:\.\d+)?) km east–west", FLAT)
    assert match, "PRIVACY.md no longer states an east-west cell width"

    claimed = float(match.group(1))
    widest = bt.CELL_DEG * KM_PER_LAT_DEG * math.cos(math.radians(LAT_RANGE[0]))
    narrowest = bt.CELL_DEG * KM_PER_LAT_DEG * math.cos(math.radians(LAT_RANGE[1]))
    assert narrowest - 0.3 <= claimed <= widest + 0.3, (
        f"PRIVACY.md claims {claimed} km east-west; across Poland the cell "
        f"is {narrowest:.2f}-{widest:.2f} km"
    )


def test_the_example_url_is_a_real_cell_on_the_current_grid():
    """A path from the old grid decodes to somewhere absurd.

    Checking the indices land in Poland is what distinguishes a stale
    example from a fresh one: pl/1044/420 was correct at 0.05 degrees
    and points at the Mediterranean at 0.03.
    """
    match = re.search(r"AEDFinder/([a-z]{2})/(-?\d+)/(-?\d+)\.json", FLAT)
    assert match, "PRIVACY.md no longer shows an example tile URL"

    country, lat_idx, lon_idx = match.group(1), int(match.group(2)), int(match.group(3))
    assert country == "pl", f"example URL is for {country!r}, not Poland"

    lat = lat_idx * bt.CELL_DEG
    lon = lon_idx * bt.CELL_DEG
    assert LAT_RANGE[0] <= lat <= LAT_RANGE[1], (
        f"example URL decodes to latitude {lat:.2f}, outside Poland - "
        f"it is probably left over from a different cell size"
    )
    assert LON_RANGE[0] <= lon <= LON_RANGE[1], (
        f"example URL decodes to longitude {lon:.2f}, outside Poland"
    )

    # ...and round-trips: a point inside that cell must name it back.
    assert bt.cell_index(lat + bt.CELL_DEG / 2, lon + bt.CELL_DEG / 2) == (
        lat_idx,
        lon_idx,
    )


@pytest.mark.parametrize(
    "claim",
    [
        "112",              # the number to call
        "not a medical device",
        "ODbL",             # the licence the data travels under
        "OpenStreetMap",
    ],
)
def test_the_non_negotiable_claims_survive_editing(claim):
    """Things that must not quietly disappear in a rewrite."""
    assert claim in FLAT, f"PRIVACY.md no longer mentions {claim!r}"
