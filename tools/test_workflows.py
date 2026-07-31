"""Checks the GitHub Actions workflows without waiting for a red run.

A workflow is only exercised by pushing it, so a mistake in one costs a
round trip through GitHub every time. These catch the mechanical errors
locally: unparseable YAML, a step pointing at a file that isn't in the
repository, and the pip-cache misconfiguration that this project has
already hit once.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.yml"))


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def triggers(spec: dict) -> dict:
    # PyYAML parses the bare key `on:` as the boolean True.
    return spec.get("on", spec.get(True)) or {}


def steps(spec: dict):
    for job in spec.get("jobs", {}).values():
        for step in job.get("steps", []) or []:
            yield step


def test_there_are_workflows():
    assert WORKFLOWS, "no workflow files found"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_parses_and_has_a_trigger(path):
    spec = load(path)
    assert spec.get("name"), f"{path.name} has no name"
    assert triggers(spec), f"{path.name} has no trigger"
    assert spec.get("jobs"), f"{path.name} has no jobs"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_pip_cache_points_at_a_file_that_exists(path):
    """setup-python errors out when its cache glob matches nothing.

    The default is requirements.txt or pyproject.toml; this project has
    neither, so `cache: pip` without an explicit path fails the run
    before a single test executes.
    """
    for step in steps(load(path)):
        using = step.get("uses", "")
        if not using.startswith("actions/setup-python"):
            continue
        with_ = step.get("with", {}) or {}
        if with_.get("cache") != "pip":
            continue

        dependency_path = with_.get("cache-dependency-path")
        assert dependency_path, (
            f"{path.name}: `cache: pip` needs cache-dependency-path, "
            f"because neither requirements.txt nor pyproject.toml exists"
        )
        assert (ROOT / dependency_path).exists(), (
            f"{path.name}: cache-dependency-path {dependency_path!r} does not exist"
        )


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_referenced_repository_files_exist(path):
    """`python tools/x.py` and `pip install -r y.txt` must resolve."""
    missing = []
    for step in steps(load(path)):
        run = step.get("run") or ""
        for rel in re.findall(r"python\s+(\S+\.py)", run):
            if not (ROOT / rel).exists():
                missing.append(rel)
        for rel in re.findall(r"-r\s+(\S+\.txt)", run):
            if not (ROOT / rel).exists():
                missing.append(rel)
    assert not missing, f"{path.name} references missing files: {missing}"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_a_workflow_that_pushes_can_write(path):
    """`git push` without contents: write fails at the last step."""
    spec = load(path)
    pushes = any("git push" in (s.get("run") or "") for s in steps(spec))
    if not pushes:
        return
    assert spec.get("permissions", {}).get("contents") == "write", (
        f"{path.name} runs `git push` but does not request contents: write"
    )


def test_the_data_build_commits_something():
    """The nightly rebuild has to keep its own schedule alive.

    GitHub disables scheduled workflows in a public repository after 60
    days with no commit activity, and only commits reset that clock. If
    this step ever goes away, the rebuild stops after two quiet months
    and nothing anywhere turns red.
    """
    data = next(
        (p for p in WORKFLOWS if load(p).get("name") == "Build AED tiles"), None
    )
    assert data is not None, "no workflow named 'Build AED tiles'"
    assert any("git push" in (s.get("run") or "") for s in steps(load(data))), (
        "the data build no longer commits anything, so its own schedule "
        "will be disabled after 60 days of repository silence"
    )


def test_ci_runs_on_every_push_with_no_path_filter():
    """The grid guard must fire on the change it guards.

    build-data.yml filters by path, so a commit to source/AedTiles.mc
    used to run nothing at all - which is precisely the file
    check_grid.py exists to watch.
    """
    ci = next((p for p in WORKFLOWS if load(p).get("name") == "CI"), None)
    assert ci is not None, "no workflow named CI"

    push = triggers(load(ci)).get("push", None)
    assert push is None or "paths" not in (push or {}), (
        "CI must not filter by path: a change to the grid has to run the "
        "check that guards it"
    )
