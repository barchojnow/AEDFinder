#!/usr/bin/env python3
"""Builds the static AED tile set served to the watch.

The watch cannot query OpenAEDMap directly. Its API exposes only
`/tile/{z}/{x}/{y}.mvt` (Mapbox Vector Tile - protobuf, which Monkey C
cannot decode), `/node/{id}` (needs an id you don't have yet) and
`/countries/{code}.geojson` (the whole country, megabytes). None of
those is answerable from a watch with ~100 KB of heap.

So the spatial query is moved offline: this script downloads the
country GeoJSON once, cuts it into a fixed lat/lon grid and writes one
small JSON file per non-empty cell. The watch computes its own cell key
from its GPS position and fetches exactly one file.

The margin is what makes "exactly one file" true. Every cell also
contains the AEDs lying just outside it, out to MARGIN_*_DEG. Since the
margin is wider than the watch's search radius, an AED within the
search radius of ANY point in the cell is guaranteed to be in that
cell's file - including when the user stands on a cell border. Without
the margin the watch would need up to four requests and would still
miss AEDs diagonally across a corner.

Output layout (published to GitHub Pages):

    meta.json                     build timestamp, grid constants, counts
    pl/<latIdx>/<lonIdx>.json     one cell

Cell file format - arrays, not objects, because every byte is parsed on
a watch that may only have tens of KB free:

    {"v":1,"a":[[lat, lon, access, indoor, level, location, hours, osmId], ...]}

      lat, lon   Float, 5 decimals (~1 m, far below GPS error)
      access     "y" public/yes | "c" customers | "p" private/no | "u" unknown
      indoor     1 inside | 0 outside | -1 unknown
      level      floor as a string ("0", "1", "-1"), or "" when untagged
      location   free-text hint where the device hangs, ASCII-folded
      hours      opening_hours, ASCII-folded ("24/7" is the common case)
      osmId      OSM node id - identity, so the watch can deduplicate
                 two AEDs in one building instead of collapsing them by
                 proximity the way a distance threshold would.
                 Emitted as a STRING, not a number, and this is load
                 bearing: OSM node ids passed 2^31 in 2021 and are now
                 around 1.3e10, while Connect IQ's Lang.Number is
                 32-bit signed. Parsed as an integer on the watch they
                 would wrap, and two unrelated defibrillators could
                 collide onto the same value and deduplicate each other
                 away. String comparison has neither problem.

Everything here must stay byte-compatible with AedTiles.mc on the
watch. The grid constants below are duplicated there on purpose (a
watch cannot read this file); tools/check_grid.py asserts the two
implementations agree on a shared set of vectors.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# --- Grid geometry -------------------------------------------------------
# MUST match the constants in source/AedTiles.mc.

# Cell size in degrees. 0.05 deg is ~5.6 km of latitude and, at Polish
# latitudes, ~3.2-3.6 km of longitude. Small enough that a cell holds a
# handful of AEDs, large enough that the whole country is a few thousand
# files rather than a few hundred thousand.
CELL_DEG = 0.05

# How far beyond its own bounds a cell reaches. Must exceed the watch's
# SEARCH_RADIUS_M (2000 m) everywhere the data is published, otherwise
# the single-request guarantee breaks near cell borders.
#   0.020 deg lat  = 2224 m  (latitude degrees are constant)
#   0.040 deg lon  = 2556 m at 54.9 N, Poland's northern edge and the
#                    worst case, since longitude degrees shrink with
#                    cos(latitude)
MARGIN_LAT_DEG = 0.020
MARGIN_LON_DEG = 0.040

# The radius the watch actually filters to. Only used here to verify the
# margins above still cover it; the watch owns the real constant.
SEARCH_RADIUS_M = 2000

# Mean Earth radius, same value GeoMath.mc uses for Haversine.
EARTH_RADIUS_M = 6371000.0

# The API is served from the site's own host. `api.openaedmap.org` looks
# like the obvious guess and is what this originally used - it resolves,
# returns nothing, and cost one red CI run to notice.
COUNTRY_URL = "https://openaedmap.org/api/v1/countries/{code}.geojson"

# Identify the project to OpenAEDMap's operators, as any non-browser
# client should.
USER_AGENT = "AEDFinder-TileBuilder/1.0 (+https://github.com/barchojnow/AEDFinder)"

# Free text is truncated because it is drawn on a 208-454 px round
# screen and held in a memory-starved widget. Anything longer is
# unreadable on the watch anyway.
MAX_LOCATION_CHARS = 60
MAX_HOURS_CHARS = 24

# Garmin's built-in fonts have inconsistent glyph coverage for Polish
# diacritics, so they are folded here rather than shipping mojibake to
# the watch. Same table as ZabkaFinder used, plus the German/Czech
# letters that show up in border-region OSM data.
_FOLD = str.maketrans({
    "ą": "a", "ć": "c", "ę": "e", "ł": "l", "ń": "n",
    "ó": "o", "ś": "s", "ź": "z", "ż": "z",
    "Ą": "A", "Ć": "C", "Ę": "E", "Ł": "L", "Ń": "N",
    "Ó": "O", "Ś": "S", "Ź": "Z", "Ż": "Z",
    "ä": "a", "ö": "o", "ü": "u", "ß": "ss",
    "Ä": "A", "Ö": "O", "Ü": "U",
    "á": "a", "č": "c", "ď": "d", "é": "e", "ě": "e", "í": "i",
    "ň": "n", "ř": "r", "š": "s", "ť": "t", "ú": "u", "ů": "u",
    "ý": "y", "ž": "z",
    "Á": "A", "Č": "C", "Ď": "D", "É": "E", "Ě": "E", "Í": "I",
    "Ň": "N", "Ř": "R", "Š": "S", "Ť": "T", "Ú": "U", "Ů": "U",
    "Ý": "Y", "Ž": "Z",
    # Typographic punctuation that survives OSM but not Garmin fonts.
    "–": "-", "—": "-", "‘": "'", "’": "'",
    "“": '"', "”": '"', " ": " ",
})

# OSM access values grouped by what they mean to someone who needs the
# device right now: can I take it, do I have to be a customer, or is it
# behind a locked door?
_ACCESS_PUBLIC = {"yes", "public", "permissive", "designated"}
_ACCESS_CUSTOMERS = {"customers", "customer", "clients"}
_ACCESS_PRIVATE = {"private", "no", "restricted", "permit"}


def fold(text: str) -> str:
    """ASCII-folds and collapses whitespace for on-watch display."""
    return " ".join(text.translate(_FOLD).split())


def cell_index(lat: float, lon: float) -> tuple[int, int]:
    """Returns the (latIdx, lonIdx) of the cell containing a point.

    math.floor, not int(): int() truncates toward zero, which would put
    -0.03 and +0.03 in the same cell and silently corrupt every cell
    south of the equator or west of Greenwich. Poland is in neither
    hemisphere that would expose it, which is exactly why it has to be
    right here rather than discovered later.
    """
    return math.floor(lat / CELL_DEG), math.floor(lon / CELL_DEG)


def cells_touched(lat: float, lon: float) -> set[tuple[int, int]]:
    """Every cell whose margin-expanded bounds contain this AED.

    An AED near a border belongs to its own cell and to the neighbours
    that reach it - that duplication is the whole point of the margin.
    """
    lat_min, lon_min = cell_index(lat - MARGIN_LAT_DEG, lon - MARGIN_LON_DEG)
    lat_max, lon_max = cell_index(lat + MARGIN_LAT_DEG, lon + MARGIN_LON_DEG)
    return {
        (i, j)
        for i in range(lat_min, lat_max + 1)
        for j in range(lon_min, lon_max + 1)
    }


def classify_access(raw: str | None) -> str:
    if raw is None:
        return "u"
    value = raw.strip().lower()
    if value in _ACCESS_PUBLIC:
        return "y"
    if value in _ACCESS_CUSTOMERS:
        return "c"
    if value in _ACCESS_PRIVATE:
        return "p"
    return "u"


def classify_indoor(tags: dict) -> int:
    """1 inside, 0 outside, -1 unknown.

    `indoor` is the canonical tag, but a lot of Polish AED data uses
    `location=indoor|outdoor` instead, so both are read.
    """
    indoor = (tags.get("indoor") or "").strip().lower()
    if indoor in ("yes", "true", "1"):
        return 1
    if indoor in ("no", "false", "0"):
        return 0

    location = (tags.get("location") or "").strip().lower()
    if location in ("indoor", "inside", "building"):
        return 1
    if location in ("outdoor", "outside", "street"):
        return 0
    return -1


def extract_location(tags: dict) -> str:
    """The most useful 'where exactly is it' string OSM offers.

    Ordered by how specific each tag tends to be. `defibrillator:location`
    is purpose-built for this and usually reads like "przy recepcji, obok
    windy"; `description` is the common fallback; bare `location` is only
    used when it isn't the indoor/outdoor enum handled above.
    """
    for key in ("defibrillator:location", "description", "location"):
        value = tags.get(key)
        if not value:
            continue
        text = fold(str(value))
        if key == "location" and text.lower() in (
            "indoor", "outdoor", "inside", "outside", "building", "street"
        ):
            continue
        if text:
            return text[:MAX_LOCATION_CHARS]
    return ""


def extract_hours(tags: dict) -> str:
    value = tags.get("opening_hours")
    if not value:
        return ""
    return fold(str(value))[:MAX_HOURS_CHARS]


def to_entry(feature: dict) -> list | None:
    """Turns one GeoJSON feature into the compact array the watch reads."""
    geometry = feature.get("geometry") or {}
    coords = geometry.get("coordinates") or []
    if len(coords) < 2:
        return None

    # GeoJSON is [lon, lat] - the reverse of the convention used
    # everywhere else in this project.
    lon, lat = float(coords[0]), float(coords[1])
    if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        return None

    props = feature.get("properties") or {}
    osm_id = props.get("@osm_id")
    # Tags come flattened into properties alongside the @-prefixed
    # metadata; the @ keys are OpenAEDMap's, everything else is OSM's.
    tags = {k: v for k, v in props.items() if not k.startswith("@")}

    return [
        round(lat, 5),
        round(lon, 5),
        classify_access(tags.get("access")),
        classify_indoor(tags),
        fold(str(tags.get("level", "")))[:6],
        extract_location(tags),
        extract_hours(tags),
        str(osm_id) if osm_id is not None else "",
    ]


def verify_margins() -> None:
    """Fails the build if the margin no longer covers the search radius.

    This is the invariant the single-request design rests on. It is
    checked on every build rather than trusted, because the failure mode
    is silent: the watch would just report "no AED nearby" while
    standing next to one.
    """
    lat_margin_m = math.radians(MARGIN_LAT_DEG) * EARTH_RADIUS_M
    # Worst case is the highest latitude published, where a degree of
    # longitude is shortest. Poland's northern tip is ~54.9 N.
    worst_lat = 54.9
    lon_margin_m = math.radians(MARGIN_LON_DEG) * EARTH_RADIUS_M * math.cos(
        math.radians(worst_lat)
    )

    if lat_margin_m < SEARCH_RADIUS_M:
        raise SystemExit(
            f"MARGIN_LAT_DEG covers only {lat_margin_m:.0f} m, "
            f"below the {SEARCH_RADIUS_M} m search radius"
        )
    if lon_margin_m < SEARCH_RADIUS_M:
        raise SystemExit(
            f"MARGIN_LON_DEG covers only {lon_margin_m:.0f} m at {worst_lat} N, "
            f"below the {SEARCH_RADIUS_M} m search radius"
        )
    print(
        f"margins ok: {lat_margin_m:.0f} m lat, {lon_margin_m:.0f} m lon "
        f"at {worst_lat} N (radius {SEARCH_RADIUS_M} m)"
    )


def fetch_country(code: str, cache: Path | None) -> dict:
    if cache and cache.exists():
        print(f"using cached {cache}")
        return json.loads(cache.read_text(encoding="utf-8"))

    url = COUNTRY_URL.format(code=code.upper())
    print(f"downloading {url}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    # Every failure here is reported with the URL that produced it. This
    # step runs unattended at 03:40 and is the only one that depends on
    # someone else's server, so the difference between "HTTP 404 for
    # <url>" and a bare traceback is the difference between fixing it in
    # a minute and bisecting a workflow.
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            payload = response.read()
    except urllib.error.HTTPError as exc:
        raise SystemExit(
            f"OpenAEDMap returned HTTP {exc.code} ({exc.reason}) for {url}\n"
            f"  the country code may be wrong, or the API may have moved"
        ) from exc
    except urllib.error.URLError as exc:
        raise SystemExit(
            f"could not reach {url}: {exc.reason}\n"
            f"  check the host resolves - the API lives on openaedmap.org, "
            f"not on an api. subdomain"
        ) from exc

    print(f"  {len(payload) / 1_048_576:.1f} MB")

    try:
        collection = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise SystemExit(
            f"{url} did not return JSON ({exc})\n"
            f"  first bytes: {payload[:120]!r}"
        ) from exc

    if not isinstance(collection, dict) or "features" not in collection:
        raise SystemExit(
            f"{url} returned JSON that is not a FeatureCollection\n"
            f"  top-level keys: "
            f"{list(collection)[:10] if isinstance(collection, dict) else type(collection)}"
        )

    if cache:
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_bytes(payload)
    return collection


def build(country: str, out_dir: Path, cache: Path | None) -> dict:
    verify_margins()

    collection = fetch_country(country, cache)
    features = collection.get("features") or []
    print(f"{len(features)} features in {country.upper()}")

    buckets: dict[tuple[int, int], list] = {}
    kept = 0
    for feature in features:
        entry = to_entry(feature)
        if entry is None:
            continue
        kept += 1
        for cell in cells_touched(entry[0], entry[1]):
            buckets.setdefault(cell, []).append(entry)

    country_dir = out_dir / country.lower()
    if country_dir.exists():
        shutil.rmtree(country_dir)

    total_bytes = 0
    largest = (0, None)
    for (lat_idx, lon_idx), entries in sorted(buckets.items()):
        # Sorted output keeps rebuilds byte-identical when the upstream
        # data hasn't changed, so a diff means something actually moved.
        entries.sort(key=lambda e: (e[0], e[1], str(e[7])))
        body = json.dumps(
            {"v": 1, "a": entries},
            separators=(",", ":"),
            ensure_ascii=True,
        )

        path = country_dir / str(lat_idx) / f"{lon_idx}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")

        total_bytes += len(body)
        if len(body) > largest[0]:
            largest = (len(body), f"{lat_idx}/{lon_idx}")

    meta = {
        "version": 1,
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "OpenAEDMap / OpenStreetMap contributors, ODbL 1.0",
        "countries": [country.lower()],
        "grid": {
            "cellDeg": CELL_DEG,
            "marginLatDeg": MARGIN_LAT_DEG,
            "marginLonDeg": MARGIN_LON_DEG,
            "searchRadiusM": SEARCH_RADIUS_M,
        },
        "aedCount": kept,
        "cellCount": len(buckets),
    }
    (out_dir / "meta.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="utf-8"
    )

    print(f"{kept} AEDs -> {len(buckets)} cells")
    print(f"  total {total_bytes / 1024:.0f} KB, "
          f"mean {total_bytes / max(len(buckets), 1):.0f} B/cell, "
          f"largest {largest[0]} B ({largest[1]})")

    # A cell the watch cannot hold is a bug even if the build succeeds.
    if largest[0] > 60_000:
        print(f"WARNING: largest cell is {largest[0]} B - "
              f"budget watches may fail to parse it", file=sys.stderr)
    return meta


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--country", default="pl",
                        help="ISO country code to build (default: pl)")
    parser.add_argument("--out", type=Path, default=Path("data"),
                        help="output directory (default: data)")
    parser.add_argument("--cache", type=Path, default=None,
                        help="reuse/store the downloaded GeoJSON here")
    args = parser.parse_args()

    build(args.country, args.out, args.cache)


if __name__ == "__main__":
    main()
