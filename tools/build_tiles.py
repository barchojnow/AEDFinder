#!/usr/bin/env python3
"""Builds the static AED tile set served to the watch.

OpenAEDMap can't be queried from a watch - its API offers only .mvt
vector tiles (protobuf), single nodes by id, and whole-country GeoJSON.
So the spatial query happens here instead: download the country once,
cut it into a lat/lon grid, write one small JSON file per non-empty
cell. The watch computes its own cell key and fetches exactly one file.

The margin is what makes "one file" true: every cell also carries the
AEDs just outside it, further out than the search radius, so any AED
within range of ANY point in the cell is in that cell's file - even
standing on a border.

Output (published to GitHub Pages):

    meta.json                     timestamp, grid constants, counts
    pl/<latIdx>/<lonIdx>.json     one cell

    {"v":1,"a":[[lat, lon, access, indoor, level, location, hours, osmId], ...]}

      access     "y" public | "c" customers | "p" private | "u" unknown
      indoor     1 inside | 0 outside | -1 unknown
      level      floor as a string, "" when untagged
      osmId      a STRING, and that is load bearing: OSM ids are past
                 1.3e10 and would wrap in Connect IQ's 32-bit Number,
                 making two unrelated devices compare equal

Arrays rather than objects because every byte is parsed on a watch with
tens of KB free. Grid constants are duplicated in AedTiles.mc (a watch
can't read this file); tools/check_grid.py asserts they agree.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# --- Grid geometry -------------------------------------------------------
# MUST match the constants in source/AedTiles.mc.

# ~3.3 km of latitude, ~2.1 km of longitude at Polish latitudes.
#
# Measured, not chosen - see --tune. Shrinking the cell barely helps the
# peak: the margin alone forces every tile to cover ~3.3 x 3.6 km, so
# 0.005 deg cells still peaked at 25 KB while total data went 4 -> 103 MB.
# So the cell is sized for cost and the peak handled by MAX_TILE_ENTRIES.
CELL_DEG = 0.03

# Must exceed SEARCH_RADIUS_M everywhere published, or the
# single-request guarantee breaks near cell borders.
#   0.015 lat = 1668 m; 0.026 lon = 1662 m at 54.9 N, the worst case
#   (longitude degrees shrink with cos(latitude))
MARGIN_LAT_DEG = 0.015
MARGIN_LON_DEG = 0.026

# The radius the watch actually filters to. Only used here to verify the
# margins above still cover it; the watch owns the real constant.
SEARCH_RADIUS_M = 1500

# Enforced by spatial thinning. Measured across the country
# (--cap-report): caps 85 of 22,512 tiles, leaves no position without an
# AED in range, worst case 419 m of extra walking - against six stranded
# positions at 50, and only 84 m better at 100 for 40% larger tiles.
MAX_TILE_ENTRIES = 70

# Backstop, not the density control - 70 entries can't reach 12 KB even
# at maximum text length, so this only fires on a bug. A failure, not a
# warning: the previous version warned above 60 KB, which let a real
# 51 KB tile ship.
MAX_TILE_BYTES = 12288

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
# screen and held in a memory-starved app. Anything longer is
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
    """ASCII-folds and collapses whitespace: Garmin fonts vary."""
    return " ".join(text.translate(_FOLD).split())


def cell_index(lat: float, lon: float,
               cell_deg: float = CELL_DEG) -> tuple[int, int]:
    """Returns the (latIdx, lonIdx) of the cell containing a point.

    math.floor, not int(): int() truncates toward zero and would merge
    cells either side of the equator or Greenwich. Poland never exposes
    it, which is why it has to be right before anyone extends the set.

    cell_deg is a parameter only so --tune can sweep it.
    """
    return math.floor(lat / cell_deg), math.floor(lon / cell_deg)


def cells_touched(
    lat: float,
    lon: float,
    cell_deg: float = CELL_DEG,
    margin_lat: float = MARGIN_LAT_DEG,
    margin_lon: float = MARGIN_LON_DEG,
) -> set[tuple[int, int]]:
    """Every cell whose margin-expanded bounds contain this AED.

    An AED near a border belongs to its own cell and to the neighbours
    that reach it - that duplication is the whole point of the margin.
    """
    lat_min, lon_min = cell_index(lat - margin_lat, lon - margin_lon, cell_deg)
    lat_max, lon_max = cell_index(lat + margin_lat, lon + margin_lon, cell_deg)
    return {
        (i, j)
        for i in range(lat_min, lat_max + 1)
        for j in range(lon_min, lon_max + 1)
    }


def margins_for(radius_m: float, worst_lat: float = 54.9,
                safety: float = 1.10) -> tuple[float, float]:
    """Smallest margins still covering radius_m, plus 10% slack.

    Longitude degrees shrink with cos(latitude), so the binding case is
    the highest latitude published. The slack absorbs rounding and a
    country a little further north later.
    """
    m_per_deg_lat = math.radians(1.0) * EARTH_RADIUS_M
    m_per_deg_lon = m_per_deg_lat * math.cos(math.radians(worst_lat))

    def round_up(value: float) -> float:
        return math.ceil(value * 1000) / 1000

    return (
        round_up(radius_m * safety / m_per_deg_lat),
        round_up(radius_m * safety / m_per_deg_lon),
    )


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
    """1 inside, 0 outside, -1 unknown. Polish data often uses
    location=indoor|outdoor instead of the canonical indoor tag."""
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
    """The most specific "where exactly" string OSM offers.

    Bare `location` only counts when it isn't the indoor/outdoor enum.
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
    """opening_hours, compressed but not reinterpreted.

        "Mo-Fr 07:00-17:00"  ->  "Mo-Fr 07-17"
        "Mo-Fr 07:30-17:00"  ->  "Mo-Fr 07:30-17"

    Only whole hours collapse - dropping :30 would be a lie, not a
    shortening. The raw form doesn't fit the menu's single native
    non-shrinking line; day names stay in OSM's English abbreviations
    so the tiles remain language-neutral.
    """
    value = tags.get("opening_hours")
    if not value:
        return ""

    text = fold(str(value))
    # HH:00 -> HH, only when the whole time span is on the hour.
    text = re.sub(r"\b(\d{1,2}):00\b", r"\1", text)
    # "; " between rules is the single biggest space waster.
    text = text.replace("; ", ";")
    return text[:MAX_HOURS_CHARS]


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
    """Fails the build if the margin stops covering the search radius.

    Checked rather than trusted: the failure is silent, the watch would
    just say "no AED nearby" while standing next to one.
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

    # Runs unattended at 03:40 against someone else's server, so every
    # failure carries the URL rather than a bare traceback.
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
    capped_tiles = 0
    dropped_copies = 0
    worst_spacing = 0.0

    for (lat_idx, lon_idx), entries in sorted(buckets.items()):
        # Sorted first, so thinning sees a deterministic order and
        # rebuilds stay byte-identical when the upstream data hasn't
        # changed - a diff then means something actually moved.
        entries.sort(key=lambda e: (e[0], e[1], str(e[7])))

        if len(entries) > MAX_TILE_ENTRIES:
            before = len(entries)
            entries, spacing = cap_entries(entries, MAX_TILE_ENTRIES)
            capped_tiles += 1
            dropped_copies += before - len(entries)
            worst_spacing = max(worst_spacing, spacing)

        body = json.dumps(
            {"v": 1, "a": entries},
            separators=(",", ":"),
            ensure_ascii=True,
        )
        if len(body) > MAX_TILE_BYTES:
            raise SystemExit(
                f"tile {lat_idx}/{lon_idx} is {len(body)} B, over the "
                f"{MAX_TILE_BYTES} B ceiling, with only {len(entries)} entries.\n"
                f"  MAX_TILE_ENTRIES should have prevented this - either the "
                f"thinning is broken or the free-text limits have grown."
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
        "maxTileEntries": MAX_TILE_ENTRIES,
        "aedCount": kept,
        "cellCount": len(buckets),
        # Published so the effect of thinning is visible from outside,
        # not just in a build log nobody reads.
        "cappedTiles": capped_tiles,
        "droppedEntryCopies": dropped_copies,
    }
    (out_dir / "meta.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="utf-8"
    )

    print(f"{kept} AEDs -> {len(buckets)} cells")
    print(f"  total {total_bytes / 1024:.0f} KB, "
          f"mean {total_bytes / max(len(buckets), 1):.0f} B/cell, "
          f"largest {largest[0]} B ({largest[1]})")
    if capped_tiles:
        print(f"  thinned {capped_tiles} tiles "
              f"({100.0 * capped_tiles / len(buckets):.2f}%) to "
              f"{MAX_TILE_ENTRIES} entries, dropping {dropped_copies} copies "
              f"at up to {worst_spacing:.0f} m spacing")
    return meta


def tile_sizes(entries: list, cell_deg: float,
               margin_lat: float, margin_lon: float) -> list[int]:
    """Byte size of every non-empty tile, without writing any.

    Serialises for real rather than estimating: an average is what hid
    the 100x outlier this function exists to find.
    """
    buckets: dict[tuple[int, int], list] = {}
    for entry in entries:
        for cell in cells_touched(entry[0], entry[1], cell_deg, margin_lat, margin_lon):
            buckets.setdefault(cell, []).append(entry)

    return [
        len(json.dumps({"v": 1, "a": v}, separators=(",", ":"), ensure_ascii=True))
        for v in buckets.values()
    ]


def haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in metres. Same formula as GeoMath.mc."""
    r_lat1, r_lat2 = math.radians(lat1), math.radians(lat2)
    d_lat = math.radians(lat2 - lat1)
    d_lon = math.radians(lon2 - lon1)
    a = (math.sin(d_lat / 2) ** 2
         + math.cos(r_lat1) * math.cos(r_lat2) * math.sin(d_lon / 2) ** 2)
    return EARTH_RADIUS_M * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _thin(entries: list, spacing_m: float) -> list:
    """Greedily keeps entries no closer than spacing_m to an earlier one."""
    kept: list = []
    for e in entries:
        if all(haversine(e[0], e[1], k[0], k[1]) >= spacing_m for k in kept):
            kept.append(e)
    return kept


def cap_entries(entries: list, cap: int) -> tuple[list, float]:
    """Thins a too-large tile to `cap` entries. Returns entries + spacing.

    The obvious rule - keep the N nearest the cell centre - was measured
    and thrown away: it left someone in a cell corner up to a kilometre
    further from a defibrillator than they were.

    Thinning drops an AED only when another kept one lies within
    `spacing` of it, so for ANY position the nearest kept AED is at most
    `spacing` further than the nearest real one. Bounded by
    construction, not small on average and unbounded in the corners.

    Spacing is bisected, so a tile barely over the cap keeps almost
    everything.
    """
    if len(entries) <= cap:
        return entries, 0.0

    low, high = 0.0, 4000.0
    kept = entries
    for _ in range(14):
        mid = (low + high) / 2.0
        candidate = _thin(entries, mid)
        if len(candidate) > cap:
            low = mid          # too dense still, spread further apart
        else:
            high = mid         # fits; try to keep more
            kept = candidate
    return kept, high


def cap_report(country: str, cache: Path | None, radius: int,
               cell_deg: float, cap: int, probes_per_side: int = 12) -> None:
    """Measures what capping actually costs users.

    "A tile only overflows where AEDs are dense, so the dropped ones are
    redundant" is a plausible story; this checks it against the data.

    Probes a grid of positions across each capped cell and compares the
    nearest AED that exists with the nearest the capped tile still
    carries. `worst` decides whether the cap is acceptable.
    """
    margin_lat, margin_lon = margins_for(radius)
    collection = fetch_country(country, cache)
    entries = [e for e in (to_entry(f) for f in collection["features"]) if e]

    buckets: dict[tuple[int, int], list] = {}
    for entry in entries:
        for c in cells_touched(entry[0], entry[1], cell_deg, margin_lat, margin_lon):
            buckets.setdefault(c, []).append(entry)

    capped = {c: v for c, v in buckets.items() if len(v) > cap}
    dropped = sum(len(v) - cap for v in capped.values())

    print(f"radius {radius} m, cell {cell_deg}, cap {cap}")
    print(f"  {len(buckets)} tiles, {len(capped)} capped "
          f"({100.0 * len(capped) / max(len(buckets), 1):.2f}%), "
          f"{dropped} entry-copies dropped\n")

    if not capped:
        print("  nothing is capped at this setting")
        return

    penalties: list[float] = []
    spacings: list[float] = []
    stranded = 0
    probes = 0

    for cell, full in capped.items():
        kept, spacing = cap_entries(full, cap)
        spacings.append(spacing)
        for pi in range(probes_per_side):
            for pj in range(probes_per_side):
                plat = (cell[0] + (pi + 0.5) / probes_per_side) * cell_deg
                plon = (cell[1] + (pj + 0.5) / probes_per_side) * cell_deg

                best_full = min(
                    (haversine(plat, plon, e[0], e[1]) for e in full),
                    default=float("inf"))
                if best_full > radius:
                    continue      # nothing in range anyway; the cap is irrelevant
                probes += 1

                best_kept = min(
                    (haversine(plat, plon, e[0], e[1]) for e in kept),
                    default=float("inf"))
                if best_kept > radius:
                    stranded += 1
                else:
                    penalties.append(best_kept - best_full)

    penalties.sort()
    spacings.sort()
    print(f"  thinning spacing used: median {spacings[len(spacings) // 2]:.0f} m, "
          f"max {spacings[-1]:.0f} m")
    print(f"  {probes} probe positions inside capped cells that had an AED in range")
    print(f"  stranded (cap left nothing in range): {stranded}")
    if penalties:
        print("  extra distance to the nearest AED, in metres:")
        print(f"    median {penalties[len(penalties) // 2]:8.0f}")
        print(f"    p95    {penalties[int(len(penalties) * 0.95)]:8.0f}")
        print(f"    p99    {penalties[int(len(penalties) * 0.99)]:8.0f}")
        print(f"    worst  {penalties[-1]:8.0f}")
        # The bound the thinning rule promises. If `worst` ever exceeds
        # the largest spacing used, the rule is not doing what its
        # docstring claims and the measurement is the thing to trust.
        if penalties[-1] > spacings[-1] + 1.0:
            print(f"    WARNING: worst case {penalties[-1]:.0f} m exceeds the "
                  f"{spacings[-1]:.0f} m spacing bound - the thinning rule "
                  f"is not behaving as documented")


def tune(country: str, cache: Path | None,
         radii: tuple[int, ...], budget: int) -> None:
    """Measures what different grids would actually produce.

    Radius and cell size pull against each other: a smaller cell shrinks
    the biggest tile, but the margin stays fixed by the radius, so each
    AED lands in more cells and the total grows. No closed form - it
    depends on how AEDs are actually distributed.

    Read `over` first: if only a handful of tiles exceed the budget, the
    grid is fine and the fix is a cap on those few.
    """
    collection = fetch_country(country, cache)
    entries = [e for e in (to_entry(f) for f in collection["features"]) if e]
    print(f"{len(entries)} AEDs in {country.upper()}, "
          f"budget {budget} B per tile\n")

    header = (f"{'radius':>7} {'cell':>7} {'margin lat/lon':>15} "
              f"{'tiles':>7} {'copies':>7} {'total':>9} "
              f"{'median':>7} {'p95':>8} {'PEAK':>9} {'over':>6} {'over%':>7}")
    print(header)
    print("-" * len(header))

    for radius in radii:
        margin_lat, margin_lon = margins_for(radius)
        # Cells smaller than the margin are included on purpose: the
        # duplication cost is high, but at a large radius they may be
        # the only thing that brings the peak down, and `copies` shows
        # exactly what that costs.
        for cell in (0.005, 0.0075, 0.01, 0.015, 0.02, 0.03, 0.05):
            sizes = sorted(tile_sizes(entries, cell, margin_lat, margin_lon))
            if not sizes:
                continue

            total = sum(sizes)
            over = sum(1 for s in sizes if s > budget)
            marker = "  <-- current" if (radius == 2000 and cell == 0.05) else ""

            print(
                f"{radius:>7} {cell:>7.4f} {margin_lat:>7.3f}/{margin_lon:<7.3f} "
                f"{len(sizes):>7} "
                f"{total / max(len(entries), 1) / 110:>7.1f} "
                f"{total / 1_048_576:>8.1f}M "
                f"{sizes[len(sizes) // 2]:>6}B "
                f"{sizes[int(len(sizes) * 0.95)]:>7}B "
                f"{sizes[-1]:>8}B "
                f"{over:>6} "
                f"{100.0 * over / len(sizes):>6.2f}%{marker}"
            )
        print()

    print(
        "PEAK   the largest tile. The watch parses the whole file into\n"
        "       dictionaries, and the parsed form costs several times the\n"
        "       text, so this is the number that decides whether the app\n"
        "       runs at all on the tightest device.\n"
        "over   how many tiles exceed the budget. A small number here\n"
        "       means the grid is right and only the tail needs capping.\n"
        "copies roughly how many tiles each AED is duplicated into -\n"
        "       what drives total size and the nightly upload."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--country", default="pl",
                        help="ISO country code to build (default: pl)")
    parser.add_argument("--out", type=Path, default=Path("data"),
                        help="output directory (default: data)")
    parser.add_argument("--cache", type=Path, default=None,
                        help="reuse/store the downloaded GeoJSON here")
    parser.add_argument("--tune", action="store_true",
                        help="measure what different grids would produce, "
                             "then exit without writing anything")
    parser.add_argument("--radius", type=int, nargs="+",
                        default=[500, 1000, 1500, 2000],
                        help="radii to sweep in --tune mode")
    parser.add_argument("--budget", type=int, default=8192,
                        help="per-tile byte budget used for the `over` "
                             "column in --tune mode (default: 8192)")
    parser.add_argument("--cap-report", type=int, metavar="N",
                        help="measure what capping tiles at N entries would "
                             "cost users, then exit")
    parser.add_argument("--cell", type=float, default=CELL_DEG,
                        help="cell size for --cap-report")
    args = parser.parse_args()

    if args.cap_report:
        cap_report(args.country, args.cache, args.radius[0],
                   args.cell, args.cap_report)
        return

    if args.tune:
        tune(args.country, args.cache, tuple(args.radius), args.budget)
        return

    build(args.country, args.out, args.cache)


if __name__ == "__main__":
    main()
