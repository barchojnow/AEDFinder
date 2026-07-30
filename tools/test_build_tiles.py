"""Tests for the tile generator.

The important one is `test_every_nearby_aed_lands_in_the_tile_the_watch_asks_for`.
Everything else here checks that a field is parsed the way it should be;
that one checks the property the whole single-request design rests on:

    for any position P and any AED within SEARCH_RADIUS_M of P,
    A appears in the tile file that P's cell index names.

If that ever stops holding, the watch reports "no AED nearby" while
standing next to one, and no other test in this project would notice. It
is checked by brute force against randomly placed AEDs rather than by
re-deriving the margin arithmetic, so a mistake in that arithmetic
cannot also mark its own homework.

Run with `pytest` from anywhere in the repository.
"""

from __future__ import annotations

import json
import math
import random

import pytest

import build_tiles as bt

# Reserved by RFC 2606 and guaranteed never to resolve, so the download
# failure tests are hermetic - they don't reach the network and can't be
# broken by a resolver that returns a wildcard for typos.
UNRESOLVABLE = "https://openaedmap.invalid/api/v1/countries/{code}.geojson"

# Slot names for the wire format, mirroring AedClient.parseEntries on the
# watch. Written out so that reordering the layout breaks these tests
# loudly instead of silently reinterpreting every field.
LAT, LON, ACCESS, INDOOR, LEVEL, LOC, HOURS, OSM_ID = range(8)


def haversine(lat1, lon1, lat2, lon2):
    """Same formula and Earth radius as GeoMath.mc on the watch."""
    r_lat1, r_lat2 = math.radians(lat1), math.radians(lat2)
    d_lat = math.radians(lat2 - lat1)
    d_lon = math.radians(lon2 - lon1)
    a = (math.sin(d_lat / 2) ** 2
         + math.cos(r_lat1) * math.cos(r_lat2) * math.sin(d_lon / 2) ** 2)
    return bt.EARTH_RADIUS_M * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


# --- field extraction ------------------------------------------------------

def test_reads_coordinates_in_geojson_order(feature):
    # GeoJSON is [lon, lat]; everything else in this project is
    # [lat, lon]. Swapping them puts every Polish AED in Kazakhstan -
    # and the arrow would point confidently at it.
    entry = bt.to_entry(feature(52.2297, 21.0122))
    assert entry[LAT] == 52.2297
    assert entry[LON] == 21.0122


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("yes", "y"),
        ("public", "y"),
        ("permissive", "y"),
        ("designated", "y"),
        ("customers", "c"),
        ("clients", "c"),
        ("private", "p"),
        ("no", "p"),
        ("restricted", "p"),
        # Case and whitespace are not normalised upstream.
        ("  YES  ", "y"),
        # Unknown and untagged both mean "we can't promise" rather than
        # "public", because guessing optimistically here sends someone to
        # a locked door.
        (None, "u"),
        ("something_new", "u"),
    ],
)
def test_classifies_access(raw, expected):
    assert bt.classify_access(raw) == expected


@pytest.mark.parametrize(
    ("tags", "expected"),
    [
        ({"indoor": "yes"}, 1),
        ({"indoor": "true"}, 1),
        ({"indoor": "no"}, 0),
        # A lot of Polish AED data uses location= instead of indoor=.
        ({"location": "indoor"}, 1),
        ({"location": "outdoor"}, 0),
        ({}, -1),
        ({"indoor": "maybe"}, -1),
    ],
)
def test_reads_indoor_from_either_tag(tags, expected):
    assert bt.classify_indoor(tags) == expected


def test_prefers_the_most_specific_location_tag():
    tags = {
        "defibrillator:location": "Przy recepcji, obok windy",
        "description": "gdzies w budynku",
    }
    assert bt.extract_location(tags) == "Przy recepcji, obok windy"


def test_falls_back_to_description_when_there_is_no_specific_tag():
    assert bt.extract_location({"description": "Hol glowny"}) == "Hol glowny"


def test_does_not_mistake_the_indoor_enum_for_a_description():
    # location=indoor is the indoor/outdoor flag, not a hint about where
    # the device hangs - showing "indoor" as the label would be worse
    # than showing nothing.
    assert bt.extract_location({"location": "indoor"}) == ""


def test_folds_diacritics():
    # Garmin's built-in fonts render these inconsistently, so they are
    # folded here rather than on the watch.
    assert bt.fold("Żółć, wejście główne – łąka") == "Zolc, wejscie glowne - laka"


def test_truncates_long_free_text(feature):
    entry = bt.to_entry(feature(52.0, 21.0, **{"defibrillator:location": "x" * 500}))
    assert len(entry[LOC]) <= bt.MAX_LOCATION_CHARS


def test_keeps_osm_id_for_identity_deduplication(feature):
    # Identity, not proximity. Two AEDs on opposite sides of one building
    # lobby are metres apart but are genuinely two devices; a distance
    # threshold would drop one of them.
    assert bt.to_entry(feature(52.0, 21.0, osm_id=123456789))[OSM_ID] == "123456789"


def test_emits_osm_id_as_a_string(feature):
    # Connect IQ's Lang.Number is 32-bit signed and OSM node ids are past
    # 1.3e10, so a numeric id would wrap on the watch and two unrelated
    # defibrillators could deduplicate each other away.
    entry = bt.to_entry(feature(52.0, 21.0, osm_id=13_402_887_651))
    assert isinstance(entry[OSM_ID], str)
    assert entry[OSM_ID] == "13402887651"
    assert int(entry[OSM_ID]) > 2**31


def test_survives_a_feature_with_no_osm_id(feature):
    f = feature(52.0, 21.0)
    del f["properties"]["@osm_id"]
    assert bt.to_entry(f)[OSM_ID] == ""


@pytest.mark.parametrize(
    "broken",
    [
        pytest.param({"geometry": {"coordinates": []}, "properties": {}}, id="no-coords"),
        pytest.param({"geometry": {}, "properties": {}}, id="no-geometry"),
        pytest.param({"geometry": {"coordinates": [21.0]}, "properties": {}}, id="one-coord"),
    ],
)
def test_rejects_features_without_usable_geometry(broken):
    assert bt.to_entry(broken) is None


def test_rejects_coordinates_outside_the_world(feature):
    assert bt.to_entry(feature(931.0, 21.0)) is None
    assert bt.to_entry(feature(52.0, 999.0)) is None


# --- the download ----------------------------------------------------------

# This step runs unattended at 03:40 against someone else's server, and
# it is the only part of the pipeline that can fail for reasons outside
# this repository. The first live run died on an `api.` subdomain that
# does not exist, and said so in forty lines of urllib traceback with
# the URL buried in the middle. These pin the diagnosis to the top.

def test_reports_an_unreachable_host_with_the_url(monkeypatch, tmp_path):
    monkeypatch.setattr(bt, "COUNTRY_URL", UNRESOLVABLE)

    with pytest.raises(SystemExit) as exc:
        bt.fetch_country("pl", None)

    message = str(exc.value)
    assert "openaedmap.invalid" in message, "the failure hid the URL it tried"
    assert "openaedmap.org" in message, (
        "the hint naming the real host is what turns this from a stack "
        "trace into a fix"
    )


def test_a_cached_download_never_touches_the_network(tmp_path, monkeypatch):
    # The --cache flag exists so a local rebuild doesn't re-download 15 MB
    # each time. If it ever stopped short-circuiting, that politeness
    # would silently become a per-run download.
    monkeypatch.setattr(bt, "COUNTRY_URL", UNRESOLVABLE)
    cache = tmp_path / "pl.geojson"
    cache.write_text(
        json.dumps({"type": "FeatureCollection", "features": []}),
        encoding="utf-8",
    )

    # Would raise SystemExit if it tried to resolve the host.
    assert bt.fetch_country("pl", cache)["features"] == []


# --- the coverage guarantee -------------------------------------------------

@pytest.mark.slow
def test_every_nearby_aed_lands_in_the_tile_the_watch_asks_for():
    random.seed(20260730)

    # Poland's bounding box. The latitude extremes matter: longitude
    # degrees shrink with cos(latitude), so the north is where the margin
    # is thinnest in metres.
    aeds = [
        (random.uniform(49.0, 54.9), random.uniform(14.1, 24.2))
        for _ in range(4000)
    ]

    buckets: dict[tuple[int, int], set[tuple[float, float]]] = {}
    for lat, lon in aeds:
        for cell in bt.cells_touched(lat, lon):
            buckets.setdefault(cell, set()).add((lat, lon))

    probes = [
        (random.uniform(49.0, 54.9), random.uniform(14.1, 24.2))
        for _ in range(2000)
    ]
    # Corner and edge probes: a random point almost never lands on a cell
    # border, and the border is the only place the margin can fail.
    for _ in range(500):
        i = random.randint(980, 1098)
        j = random.randint(282, 484)
        probes.append((i * bt.CELL_DEG + 1e-9, j * bt.CELL_DEG + 1e-9))
        probes.append(((i + 1) * bt.CELL_DEG - 1e-9, (j + 1) * bt.CELL_DEG - 1e-9))

    misses = []
    checked = 0
    for plat, plon in probes:
        served = buckets.get(bt.cell_index(plat, plon), set())
        for lat, lon in aeds:
            if haversine(plat, plon, lat, lon) <= bt.SEARCH_RADIUS_M:
                checked += 1
                if (lat, lon) not in served:
                    misses.append(((plat, plon), (lat, lon)))

    assert checked > 0, "the fixture placed no AED within radius of any probe"
    assert not misses, (
        f"{len(misses)} of {checked} in-radius AEDs were missing from the tile "
        f"the watch would have requested; first: probe {misses[0][0]} "
        f"missed AED {misses[0][1]}"
    )


# --- building the tile set --------------------------------------------------

def test_writes_sharded_cells_and_meta(build, feature):
    out, meta = build([
        feature(52.2297, 21.0122, osm_id=1, access="yes", indoor="yes", level="0",
                **{"defibrillator:location": "Recepcja"}),
        feature(52.2350, 21.0200, osm_id=2, access="customers"),
        feature(50.0614, 19.9366, osm_id=3, access="private"),   # Krakow
    ])

    assert meta["aedCount"] == 3
    assert meta["grid"]["cellDeg"] == bt.CELL_DEG

    warsaw = out / "pl" / "1044" / "420.json"
    assert warsaw.exists(), "Warsaw cell was not written"

    payload = json.loads(warsaw.read_text(encoding="utf-8"))
    assert payload["v"] == 1

    ids = {entry[OSM_ID] for entry in payload["a"]}
    assert "1" in ids
    assert "2" in ids, "the second Warsaw AED is missing"
    assert "3" not in ids, "Krakow leaked into the Warsaw cell"

    first = next(e for e in payload["a"] if e[OSM_ID] == "1")
    assert first[ACCESS] == "y"
    assert first[INDOOR] == 1
    assert first[LOC] == "Recepcja"


def test_rebuild_is_byte_identical(build, feature):
    # Deterministic output means a diff in the published data always
    # corresponds to a real change upstream.
    features = [feature(52.0 + i * 0.001, 21.0, osm_id=i) for i in range(40)]

    out, _ = build(features)
    first = {p.name: p.read_bytes() for p in (out / "pl").rglob("*.json")}
    build(features)
    second = {p.name: p.read_bytes() for p in (out / "pl").rglob("*.json")}

    assert first == second


def test_a_cell_with_no_aeds_produces_no_file(build, feature):
    # The watch relies on this: a 404 means "nothing here", which is an
    # answer. AedClientTest asserts the other half - that the watch reads
    # it as one rather than as a failure.
    out, _ = build([feature(52.2297, 21.0122, osm_id=1)])

    i, j = bt.cell_index(49.29899, 19.94983)   # Zakopane
    assert not (out / "pl" / str(i) / f"{j}.json").exists()


def test_finds_the_nearest_aed_the_way_the_watch_would(build, feature):
    """Walks the whole chain the way the watch does, in one test.

    The other tests each check one link. This checks that the links
    connect: build the tiles, take a GPS position, derive the filename
    the way AedTiles.cellIndex does, open exactly that file, decode the
    slots the way AedClient.parseEntries does, filter and sort the way
    AedList does - and land on the AED a human would have picked.

    A mismatch anywhere in that chain - a field in the wrong slot, a
    swapped lat/lon, a cell key off by one - shows up here as the wrong
    defibrillator rather than as a green suite and a confused user.
    """
    here_lat, here_lon = 52.2297, 21.0122
    out, _ = build([
        feature(52.23350, 21.01220, osm_id=100, access="private",
                **{"defibrillator:location": "Biurowiec, 3 pietro"}),
        feature(52.23020, 21.01260, osm_id=200, access="yes", indoor="yes",
                level="0", opening_hours="24/7",
                **{"defibrillator:location": "Recepcja, obok windy"}),
        feature(52.22700, 21.01100, osm_id=300, access="customers"),
        # Well outside the 2 km radius - must not be selected even though
        # the margin means it may share a tile.
        feature(52.26000, 21.01220, osm_id=400, access="yes"),
    ])

    # --- what AedTiles.tilePath() does on the watch ---
    i, j = bt.cell_index(here_lat, here_lon)
    tile = out / "pl" / str(i) / f"{j}.json"
    assert tile.exists(), f"the watch would request pl/{i}/{j}.json and get a 404"

    # --- what AedClient.parseEntries() does ---
    payload = json.loads(tile.read_text(encoding="utf-8"))
    assert payload["v"] == 1
    entries = [e for e in payload["a"] if len(e) >= 8]

    # --- what AedList.update() + sortByDistance() do ---
    in_range = sorted(
        (
            (haversine(here_lat, here_lon, e[LAT], e[LON]), e)
            for e in entries
            if haversine(here_lat, here_lon, e[LAT], e[LON]) <= bt.SEARCH_RADIUS_M
        ),
        key=lambda pair: pair[0],
    )

    assert in_range, "no AED survived the radius filter"
    assert "400" not in {e[OSM_ID] for _, e in in_range}, "an out-of-range AED was kept"

    distance, nearest = in_range[0]
    assert nearest[OSM_ID] == "200"
    assert distance == pytest.approx(56, abs=15)

    # The fields the detail screen reads must have survived the round
    # trip in the right slots.
    assert nearest[ACCESS] == "y"
    assert nearest[INDOOR] == 1
    assert nearest[LEVEL] == "0"
    assert nearest[LOC] == "Recepcja, obok windy"
    assert nearest[HOURS] == "24/7"
