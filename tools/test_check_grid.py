"""Tests that the grid guard actually guards.

`check_grid.py` is the only thing standing between this project and its
worst failure mode: the Python and Monkey C grids drifting apart, tiles
published under keys the watch never requests, and every user told "no
AED nearby" while standing next to a defibrillator - with nothing going
red anywhere.

A guard like that is worth exactly as much as its willingness to fail.
One that passed unconditionally would look identical in CI to one that
works, forever, until the day it mattered. So each case below breaks the
grid in a specific way and asserts the check notices - the same argument
as pressing the button on a smoke detector, rather than trusting it
because it has never gone off.

Every mutation is a real mistake someone could make: renumbering a
vector to make a red on-device test go green, adding one to the fixture
but not the watch, retuning the cell size in one language, dropping a
`d` suffix, tightening the margin, growing the radius.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent

# The files check_grid.py reads. Copied into a scratch tree so a test can
# corrupt one without touching the repository.
TREE = [
    Path("tools/check_grid.py"),
    Path("tools/build_tiles.py"),
    Path("tools/grid_vectors.json"),
    Path("source/AedTiles.mc"),
    Path("source/tests/AedTilesTest.mc"),
]


@dataclass
class GridTree:
    """A throwaway copy of the grid, and the ability to break it."""

    root: Path

    def patch(self, rel: str, old: str, new: str) -> None:
        path = self.root / rel
        text = path.read_text(encoding="utf-8")
        assert old in text, f"{rel} no longer contains {old!r} to patch"
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def check(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(self.root / "tools" / "check_grid.py")],
            capture_output=True,
            text=True,
        )


@pytest.fixture
def grid(tmp_path):
    for rel in TREE:
        dest = tmp_path / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, dest)
    return GridTree(tmp_path)


def test_accepts_the_repository_as_it_stands(grid):
    result = grid.check()
    assert result.returncode == 0, (
        "the grid check fails on an unmodified checkout:\n"
        + result.stdout + result.stderr
    )


# Each case: which file to break, the exact text to replace, what to
# replace it with, and a word the failure must mention - so a check that
# fails for an unrelated reason doesn't pass for the right one.
MUTATIONS = [
    pytest.param(
        "source/tests/AedTilesTest.mc",
        '["warsaw-centre", 52.2297d, 21.0122d, 1044, 420]',
        '["warsaw-centre", 52.2297d, 21.0122d, 1044, 421]',
        "warsaw-centre",
        id="vector-renumbered-to-make-a-red-test-green",
    ),
    pytest.param(
        "source/tests/AedTilesTest.mc",
        '            ["gdansk-north", 54.35205d, 18.64637d, 1087, 372],\n',
        "",
        "gdansk-north",
        id="vector-dropped-from-the-watch-test",
    ),
    pytest.param(
        "source/tests/AedTilesTest.mc",
        '["origin", 0.0d, 0.0d, 0, 0],',
        '["origin", 0.0d, 0.0d, 0, 0],\n            ["invented", 1.0d, 1.0d, 20, 20],',
        "invented",
        id="vector-invented-on-the-watch-side-only",
    ),
    pytest.param(
        "source/AedTiles.mc",
        "const CELL_DEG = 0.05d;",
        "const CELL_DEG = 0.02d;",
        "CELL_DEG",
        id="cell-size-retuned-in-one-language-only",
    ),
    pytest.param(
        # Without the Double suffix Monkey C parses the literal as a
        # 32-bit Float and rounds cell indices differently from the
        # 64-bit generator. It diverges only near a cell boundary - which
        # is to say rarely enough to survive testing and reach users.
        "source/AedTiles.mc",
        "const CELL_DEG = 0.05d;",
        "const CELL_DEG = 0.05;",
        "double",
        id="double-suffix-dropped-from-the-cell-size",
    ),
    pytest.param(
        "tools/grid_vectors.json",
        '"cellDeg": 0.05',
        '"cellDeg": 0.1',
        "cellDeg",
        id="fixture-regenerated-at-a-different-cell-size",
    ),
    pytest.param(
        # The margin is what makes one request per cell sufficient.
        # Tighten it below the search radius and AEDs near a cell border
        # silently stop being found.
        "tools/build_tiles.py",
        "MARGIN_LON_DEG = 0.040",
        "MARGIN_LON_DEG = 0.010",
        "margin",
        id="margin-tightened-below-the-search-radius",
    ),
    pytest.param(
        # The same mistake from the other direction.
        "tools/build_tiles.py",
        "SEARCH_RADIUS_M = 2000",
        "SEARCH_RADIUS_M = 5000",
        "margin",
        id="search-radius-grown-past-the-margin",
    ),
]


@pytest.mark.parametrize(("rel", "old", "new", "mentions"), MUTATIONS)
def test_rejects_a_broken_grid(grid, rel, old, new, mentions):
    grid.patch(rel, old, new)
    result = grid.check()

    assert result.returncode != 0, (
        "check_grid.py accepted a broken grid:\n" + result.stdout
    )
    combined = (result.stdout + result.stderr).lower()
    assert mentions.lower() in combined, (
        f"it failed, but never mentioned {mentions!r} - so it may have "
        f"failed for an unrelated reason:\n{combined}"
    )
