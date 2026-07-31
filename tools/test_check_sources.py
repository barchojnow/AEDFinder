"""Tests that the source check actually catches things.

Same argument as test_check_grid.py: a checker that never fails is
indistinguishable from one that works. Each case breaks a real .mc file
in a scratch copy and asserts the check notices.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def tree(tmp_path):
    """A scratch copy of everything check_sources.py reads."""
    for rel in ("source", "resources/strings", "resources-pol/strings"):
        shutil.copytree(ROOT / rel, tmp_path / rel)
    (tmp_path / "tools").mkdir()
    shutil.copy(ROOT / "tools/check_sources.py", tmp_path / "tools/check_sources.py")
    return tmp_path


def run(tree) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(tree / "tools" / "check_sources.py")],
        capture_output=True, text=True,
    )


def patch(tree, rel: str, old: str, new: str) -> None:
    path = tree / rel
    text = path.read_text(encoding="utf-8")
    assert old in text, f"{rel} no longer contains {old!r}"
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def test_accepts_the_repository_as_it_stands(tree):
    result = run(tree)
    assert result.returncode == 0, result.stdout + result.stderr


def test_catches_a_call_to_a_method_that_does_not_exist(tree):
    patch(tree, "source/AedFinderView.mc",
          "renderer.draw(dc);", "renderer.render(dc);")
    result = run(tree)
    assert result.returncode != 0
    assert "renderer.render" in result.stderr


def test_catches_unbalanced_braces(tree):
    patch(tree, "source/AedList.mc",
          "    function size() as Lang.Number {",
          "    function size() as Lang.Number {{")
    result = run(tree)
    assert result.returncode != 0
    assert "braces" in result.stderr


def test_catches_an_unknown_class(tree):
    patch(tree, "source/AedFinderView.mc",
          "new HeadingSource()", "new HeadingSauce()")
    result = run(tree)
    assert result.returncode != 0
    assert "HeadingSauce" in result.stderr


def test_catches_a_string_that_is_not_defined(tree):
    patch(tree, "source/AedFinderView.mc",
          "Rez.Strings.StatusNoAed", "Rez.Strings.StatusNoAeds")
    result = run(tree)
    assert result.returncode != 0
    assert "StatusNoAeds" in result.stderr


def test_catches_a_missing_polish_translation(tree):
    path = tree / "resources-pol/strings/strings.xml"
    text = path.read_text(encoding="utf-8")
    line = [l for l in text.splitlines() if 'id="StatusNoAed"' in l][0]
    path.write_text(text.replace(line + "\n", ""), encoding="utf-8")

    result = run(tree)
    assert result.returncode != 0
    assert "Polish" in result.stderr


def test_catches_an_orphaned_string(tree):
    patch(tree, "resources/strings/strings.xml",
          "</strings>",
          '    <string id="Orphan">nobody reads this</string>\n</strings>')
    patch(tree, "resources-pol/strings/strings.xml",
          "</strings>",
          '    <string id="Orphan">nikt tego nie czyta</string>\n</strings>')
    result = run(tree)
    assert result.returncode != 0
    assert "Orphan" in result.stderr


def test_url_in_a_string_is_not_mistaken_for_a_comment(tree):
    # The `//` in https:// once ate the rest of the line and produced a
    # false unbalanced-brace report. AedTiles.mc holds the base URL.
    result = run(tree)
    assert result.returncode == 0, (
        "a URL in a string literal broke the comment stripping:\n" + result.stderr
    )
