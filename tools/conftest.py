"""Shared pytest setup for the tile generator tests.

`build_tiles.py` is a script that lives next to its tests rather than an
installed package, so the directory has to be on sys.path before
`import build_tiles` can work. pytest's default import mode already does
this, but only when invoked in ways that make `tools/` the rootdir -
doing it explicitly here means the suite runs the same from the
repository root, from `tools/`, and from an IDE's test runner, which is
where the implicit version usually breaks.
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
    """Builds a GeoJSON feature shaped like OpenAEDMap's country export.

    Returned as a factory rather than a value because almost every test
    needs several, each differing in one tag.
    """

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
    """Runs the real generator over a list of features into a temp tree.

    Writes the collection to a file and hands it to build() as its cache,
    so the network is never touched - the download path is the one part
    of the generator these tests deliberately don't exercise.
    """

    def _build(features, country="pl"):
        cache = tmp_path / "src.geojson"
        cache.write_text(
            json.dumps({"type": "FeatureCollection", "features": features}),
            encoding="utf-8",
        )
        meta = bt.build(country, tmp_path, cache)
        return tmp_path, meta

    return _build
