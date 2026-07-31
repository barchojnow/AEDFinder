"""Shared pytest fixtures, and tools/ on sys.path.

pytest's import mode already does the path bit, but only when invoked
so that tools/ is the rootdir. Doing it here means the suite runs the
same from the repo root, from tools/, and from an IDE test runner.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import build_tiles as bt  # noqa: E402


@pytest.fixture
def feature():
    """A GeoJSON feature shaped like OpenAEDMap's country export."""

    def _feature(lat, lon, osm_id=1, **tags):
        props = {"@osm_type": "node", "@osm_id": osm_id, "@osm_version": 3}
        props.update(tags)
        return {
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [lon, lat]},
            "properties": props,
        }

    return _feature


@pytest.fixture
def build(tmp_path):
    """Runs the real generator into a temp tree, via the cache so the
    network is never touched."""

    def _build(features, country="pl"):
        cache = tmp_path / "src.geojson"
        cache.write_text(
            json.dumps({"type": "FeatureCollection", "features": features}),
            encoding="utf-8",
        )
        meta = bt.build(country, tmp_path, cache)
        return tmp_path, meta

    return _build
