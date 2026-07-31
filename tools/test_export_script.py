"""Checks the one guard in export.ps1 that can silently stop guarding.

Before packaging, export.ps1 compares the grid this build was compiled
against with the grid GitHub Pages is actually serving, and refuses to
export when they disagree. That comparison is the only thing standing
between a mismatch and a store release that returns "no AED nearby" for
every user - and it hangs entirely on one regex scraping CELL_DEG out
of build_tiles.py.

Rename or reformat that constant and the regex quietly matches nothing.
So the regex is read out of the PowerShell source and applied here,
which means the two cannot drift apart without a red test.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import build_tiles as bt  # noqa: E402

SCRIPT = (ROOT / "tools" / "export.ps1").read_text(encoding="utf-8")
BUILDER = (ROOT / "tools" / "build_tiles.py").read_text(encoding="utf-8")


def test_the_grid_regex_still_finds_the_constant():
    quoted = re.search(r"-Pattern '([^']+)'", SCRIPT)
    assert quoted, "export.ps1 no longer scrapes build_tiles.py with a -Pattern"

    found = re.search(quoted.group(1), BUILDER, re.MULTILINE)
    assert found, (
        f"export.ps1's pattern {quoted.group(1)!r} matches nothing in "
        f"build_tiles.py, so the live-data check would fail before it "
        f"could compare anything"
    )
    assert float(found.group(1)) == bt.CELL_DEG


def test_it_checks_the_published_metadata():
    assert "meta.json" in SCRIPT, (
        "export.ps1 no longer fetches the published meta.json, so a "
        "package could ship against a grid Pages is not serving"
    )
    assert "cellDeg" in SCRIPT, "export.ps1 no longer compares the cell size"


def test_the_referenced_helper_scripts_exist():
    for rel in re.findall(r"tools\\(\w+\.py)", SCRIPT):
        assert (ROOT / "tools" / rel).exists(), f"export.ps1 calls missing {rel}"


def test_packaging_is_a_release_export_not_a_device_build():
    """-e packages every product; -d would build for one and ship that."""
    monkeyc = [l for l in SCRIPT.splitlines() if "$monkeyc " in l and "-o " in l]
    assert monkeyc, "no monkeyc invocation found in export.ps1"
    line = monkeyc[0]
    assert " -e" in line, "the store package needs -e (export), not a plain build"
    assert " -r" in line, "the store package should be a release build (-r)"
    assert " -d " not in line, "-d builds for a single device; the .iq must cover all"
