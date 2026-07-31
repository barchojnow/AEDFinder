"""Keeps the heart's silhouette honest, in both languages.

The mark is drawn twice - once with Monkey C primitives in
source/AedLogo.mc for the watch, once with Pillow in make_icons.py for
the launcher and store PNGs. Nothing but discipline keeps those two in
step, and the numbers are unlabelled fractions, so a drift shows up as
"the icon looks slightly off" months later.

Two real bugs live here, both found by eye and both invisible to every
other check:

  1. The V used to meet the lobes at an arbitrary inset, so each circle
     bulged past the straight edge and left a step in the outline.
  2. The first fix - a plain triangle between the tangent points - put
     the top edge BELOW the height at which the two circles stop
     overlapping, punching a hole through the middle of the heart.

So these tests assert the geometry, not the literals: tangency, and
that the cleavage is actually closed.
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

import make_icons as mi  # noqa: E402

LOGO = (ROOT / "source" / "AedLogo.mc").read_text(encoding="utf-8")


def monkeyc_const(name: str) -> float:
    match = re.search(rf"const {name} = ([\d.]+);", LOGO)
    assert match, f"AedLogo.mc no longer defines {name}"
    return float(match.group(1))


def test_the_tangent_point_is_actually_tangent():
    """|CT| = r, and CT is perpendicular to the edge running to the tip."""
    cx, cy = -mi.LOBE_X, mi.LOBE_DY          # left lobe centre
    tx, ty = -mi.TANGENT_X, mi.TANGENT_Y     # claimed tangent point

    radius = math.hypot(tx - cx, ty - cy)
    assert radius == pytest.approx(mi.LOBE_R, abs=1e-5), (
        f"the tangent point is {radius:.5f} from the lobe centre, but the "
        f"lobe radius is {mi.LOBE_R} - so it is not on the circle at all"
    )

    # Edge from the tangent point down to the bottom tip.
    edge = (0 - tx, mi.TIP_DY - ty)
    spoke = (tx - cx, ty - cy)
    dot = edge[0] * spoke[0] + edge[1] * spoke[1]
    assert dot == pytest.approx(0.0, abs=1e-5), (
        "the edge is not perpendicular to the radius, so the lobe bulges "
        "past it and the silhouette has a step"
    )


def test_the_cleavage_is_closed():
    """The bug that punched a hole through the middle of the heart.

    Below this height the two lobes no longer overlap, so the polygon
    has to reach at least that high in the middle or the gap between
    them shows through.
    """
    lowest_overlap = mi.LOBE_DY + math.sqrt(mi.LOBE_R ** 2 - mi.LOBE_X ** 2)
    middle_vertex = mi.LOBE_DY      # both files put it at lobe-centre height

    assert middle_vertex < lowest_overlap, (
        f"the polygon's middle vertex sits at y={middle_vertex:.5f}, below "
        f"the last overlap at y={lowest_overlap:.5f} - the cleavage would "
        f"be a hole"
    )
    assert mi.TANGENT_Y > lowest_overlap, (
        "the tangent points are above the last overlap, which means a "
        "plain triangle would have worked and this test is guarding "
        "nothing - recheck the constants"
    )


def test_the_lobes_actually_overlap():
    """Two separate circles with a V under them is not a heart."""
    assert mi.LOBE_X < mi.LOBE_R, (
        f"lobe centres are {2 * mi.LOBE_X} apart with radius {mi.LOBE_R}; "
        f"they no longer meet"
    )


@pytest.mark.parametrize("name", ["TANGENT_X", "TANGENT_Y"])
def test_the_watch_carries_the_same_numbers(name):
    """AedLogo.mc and make_icons.py draw the same mark or neither is right."""
    assert monkeyc_const(name) == pytest.approx(getattr(mi, name), abs=1e-6), (
        f"{name} differs between AedLogo.mc and make_icons.py: the watch "
        f"and the store icon would show different hearts"
    )


def test_the_mark_fits_inside_the_icon_box():
    """MARK_SCALE has to be small enough to contain the widest point.

    Raise a lobe or widen the heart without touching MARK_SCALE and the
    launcher icons get clipped - lobes first, and on watches that crop
    the icon to a circle, badly.
    """
    extents = {
        "half-width": mi.LOBE_X + mi.LOBE_R,
        "top": abs(mi.LOBE_DY) + mi.LOBE_R,
        "tip": mi.TIP_DY,
    }
    for what, extent in extents.items():
        drawn = extent * mi.MARK_SCALE
        assert drawn <= 0.5, (
            f"the mark's {what} reaches {drawn:.4f} of the box at "
            f"MARK_SCALE={mi.MARK_SCALE}; anything over 0.5 is clipped"
        )
