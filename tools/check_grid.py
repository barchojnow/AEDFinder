#!/usr/bin/env python3
"""Guards the one invariant that spans both languages in this project.

The tile grid is implemented twice - in `tools/build_tiles.py`, which
runs in CI and decides what each published file is called, and in
`source/AedTiles.mc`, which runs on the watch and decides what file to
ask for. There is no way to share the code: CI cannot run Monkey C and
a watch cannot read a Python file.

If the two ever disagree the build still succeeds, Pages still deploys,
the watch still gets HTTP 200 for some file - and every user is told
"no AED nearby" while standing next to a defibrillator. Nothing goes
red. That is why this check exists and why it runs before the download
in the data workflow rather than after.

It does two things:

1. Parses the constants out of AedTiles.mc and compares them
   numerically with the Python ones.
2. Re-derives every vector in grid_vectors.json with the Python
   implementation. The Monkey C unit test (source/tests/AedTilesTest.mc)
   asserts the same vectors on-device, so agreeing with the fixture in
   both places means agreeing with each other.

Boundary vectors matter most and are deliberately over-represented:
0.05 has no exact binary representation, so a coordinate landing
exactly on a cell edge is where a 32-bit/64-bit mismatch or a
floor-vs-truncate mistake would first show up.
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import build_tiles  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
TILES_MC = ROOT / "source" / "AedTiles.mc"
TILES_TEST_MC = ROOT / "source" / "tests" / "AedTilesTest.mc"
VECTORS = Path(__file__).parent / "grid_vectors.json"

# ["name", 52.2297d, 21.0122d, 1044, 420],
_MC_VECTOR_RE = re.compile(
    r'\[\s*"([^"]+)"\s*,\s*(-?[\d.]+)d\s*,\s*(-?[\d.]+)d\s*,'
    r'\s*(-?\d+)\s*,\s*(-?\d+)\s*\]'
)


def parse_mc_constants() -> dict[str, float]:
    """Pulls `const NAME = <number>[d];` out of the Monkey C source."""
    text = TILES_MC.read_text(encoding="utf-8")
    found = {}
    for name, value in re.findall(
        r"const\s+(\w+)\s*=\s*(-?[\d.]+)d?\s*;", text
    ):
        found[name] = float(value)
    return found


def check_constants() -> list[str]:
    mc = parse_mc_constants()
    errors = []

    expected = {
        "CELL_DEG": build_tiles.CELL_DEG,
        "SEARCH_RADIUS_M": float(build_tiles.SEARCH_RADIUS_M),
    }
    for name, py_value in expected.items():
        if name not in mc:
            errors.append(f"{name} not found in AedTiles.mc")
        elif mc[name] != py_value:
            errors.append(
                f"{name}: AedTiles.mc has {mc[name]}, build_tiles.py has {py_value}"
            )

    # The Double suffix is not cosmetic. Without it Monkey C parses the
    # literal as a 32-bit Float, and `lat / CELL_DEG` rounds differently
    # than the 64-bit generator - which only ever bites near a cell
    # boundary, i.e. rarely enough to reach users.
    text = TILES_MC.read_text(encoding="utf-8")
    if not re.search(r"const\s+CELL_DEG\s*=\s*[\d.]+d\s*;", text):
        errors.append(
            "CELL_DEG in AedTiles.mc must use the Double suffix (0.05d), "
            "otherwise the watch computes cell indices at 32-bit precision"
        )
    return errors


def check_vectors() -> list[str]:
    if not VECTORS.exists():
        return [f"{VECTORS} is missing"]

    fixture = json.loads(VECTORS.read_text(encoding="utf-8"))
    errors = []

    if fixture.get("cellDeg") != build_tiles.CELL_DEG:
        errors.append(
            f"grid_vectors.json was generated for cellDeg="
            f"{fixture.get('cellDeg')}, build_tiles.py uses "
            f"{build_tiles.CELL_DEG} - regenerate it"
        )
        return errors

    for case in fixture["cases"]:
        lat, lon = case["lat"], case["lon"]
        got_lat, got_lon = build_tiles.cell_index(lat, lon)
        if [got_lat, got_lon] != case["cell"]:
            errors.append(
                f"{case['name']}: ({lat}, {lon}) -> [{got_lat}, {got_lon}], "
                f"fixture says {case['cell']}"
            )
        expected_path = f"pl/{case['cell'][0]}/{case['cell'][1]}.json"
        if case["path"] != expected_path:
            errors.append(
                f"{case['name']}: path {case['path']} disagrees with its "
                f"own cell {case['cell']}"
            )
    return errors


def check_watch_test_table() -> list[str]:
    """The Monkey C test table must still be the fixture, verbatim.

    Without this, someone could edit a vector in AedTilesTest.mc to make
    a failing on-device test pass, and the two implementations would
    part company with every check still green.
    """
    if not TILES_TEST_MC.exists():
        return [f"{TILES_TEST_MC} is missing"]

    fixture = json.loads(VECTORS.read_text(encoding="utf-8"))
    expected = {
        case["name"]: (case["lat"], case["lon"], case["cell"][0], case["cell"][1])
        for case in fixture["cases"]
    }

    found = {}
    for name, lat, lon, i, j in _MC_VECTOR_RE.findall(
        TILES_TEST_MC.read_text(encoding="utf-8")
    ):
        found[name] = (float(lat), float(lon), int(i), int(j))

    errors = []
    for name in expected.keys() - found.keys():
        errors.append(f"vector {name!r} is in the fixture but not in AedTilesTest.mc")
    for name in found.keys() - expected.keys():
        errors.append(f"vector {name!r} is in AedTilesTest.mc but not in the fixture")
    for name in expected.keys() & found.keys():
        if expected[name] != found[name]:
            errors.append(
                f"vector {name!r}: AedTilesTest.mc has {found[name]}, "
                f"the fixture has {expected[name]}"
            )
    return errors


def check_margin_covers_radius() -> list[str]:
    """Re-checks the coverage guarantee against real cell geometry.

    build_tiles.verify_margins() checks the margin at Poland's worst
    latitude. This checks the property that actually matters: for the
    least favourable point in a cell (a corner) and the least
    favourable AED position, is the AED still inside the margin?
    """
    errors = []
    radius = build_tiles.SEARCH_RADIUS_M

    for lat in (49.0, 52.0, 54.9):
        # Metres per degree at this latitude, using the same Earth
        # radius as GeoMath.mc.
        m_per_deg_lat = math.radians(1.0) * build_tiles.EARTH_RADIUS_M
        m_per_deg_lon = m_per_deg_lat * math.cos(math.radians(lat))

        lat_reach = build_tiles.MARGIN_LAT_DEG * m_per_deg_lat
        lon_reach = build_tiles.MARGIN_LON_DEG * m_per_deg_lon

        if lat_reach < radius:
            errors.append(
                f"at {lat} N the latitude margin reaches only "
                f"{lat_reach:.0f} m, under the {radius} m radius"
            )
        if lon_reach < radius:
            errors.append(
                f"at {lat} N the longitude margin reaches only "
                f"{lon_reach:.0f} m, under the {radius} m radius"
            )
    return errors


def main() -> None:
    errors = (
        check_constants()
        + check_vectors()
        + check_watch_test_table()
        + check_margin_covers_radius()
    )

    if errors:
        print("grid check FAILED:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        raise SystemExit(1)

    fixture = json.loads(VECTORS.read_text(encoding="utf-8"))
    print(
        f"grid check ok: constants match, {len(fixture['cases'])} vectors "
        f"agree in Python and in AedTilesTest.mc, margins cover "
        f"{build_tiles.SEARCH_RADIUS_M} m across Poland"
    )


if __name__ == "__main__":
    main()
