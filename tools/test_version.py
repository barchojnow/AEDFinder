"""Keeps the version in exactly one place.

The app used to carry its version inside AedClient's User-Agent string,
where it read 1.0 and would have stayed 1.0 through every release. A
version that never moves is worse than no version at all: it answers
"which build is talking to me?" confidently and wrongly, so the one time
you go looking in server logs, it lies.

The fix is a single constant. The thing that makes the fix hold is this
file, which fails the moment a second copy appears - because that is the
only way a single constant ever stops being single.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "source"
TILES = SOURCE / "AedTiles.mc"

# Not source/tests: fixtures legitimately contain version-shaped numbers.
APP_FILES = sorted(p for p in SOURCE.glob("*.mc"))


def declared_version() -> str:
    match = re.search(r'const VERSION = "([^"]+)";', TILES.read_text(encoding="utf-8"))
    assert match, "AedTiles.mc no longer declares VERSION"
    return match.group(1)


def test_the_version_looks_like_a_version():
    version = declared_version()
    assert re.fullmatch(r"\d+\.\d+\.\d+", version), (
        f"VERSION is {version!r}; the store and git tags both want "
        f"major.minor.patch"
    )


def test_nothing_else_hardcodes_the_product_version():
    """The exact shape of the bug: 'AEDFinder/1.0' written out by hand."""
    offenders = []
    for path in APP_FILES:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if re.search(r'AEDFinder/\d', line):
                offenders.append(f"{path.name}:{number}: {line.strip()}")
    assert not offenders, (
        "the version is written out by hand here; build it from "
        "AedTiles.VERSION instead:\n  " + "\n  ".join(offenders)
    )


def test_the_version_constant_is_declared_once():
    declarations = [p.name for p in APP_FILES
                    if re.search(r'const VERSION\s*=', p.read_text(encoding="utf-8"))]
    assert declarations == ["AedTiles.mc"], (
        f"VERSION is declared in {declarations}; two copies drift and the "
        f"User-Agent starts disagreeing with the tag again"
    )


def test_the_user_agent_is_built_from_the_constant():
    body = TILES.read_text(encoding="utf-8")
    match = re.search(r"function userAgent\(\).*?\n    \}", body, re.DOTALL)
    assert match, "AedTiles.mc no longer builds a User-Agent"
    assert "VERSION" in match.group(0), (
        "userAgent() no longer interpolates VERSION, so the constant is "
        "decorative and the wire says something else"
    )


@pytest.mark.parametrize("doc", ["README.md", "store/LISTING.md", "PRIVACY.md"])
def test_the_docs_do_not_pin_a_stale_version(doc):
    """Prose is where version numbers go to rot unnoticed."""
    path = ROOT / doc
    if not path.exists():
        pytest.skip(f"{doc} not present")
    stale = re.findall(r"AEDFinder[/ ]v?(\d+\.\d+(?:\.\d+)?)", path.read_text(encoding="utf-8"))
    wrong = [s for s in stale if s != declared_version()]
    assert not wrong, f"{doc} names version(s) {wrong}, but the app is {declared_version()}"
