# AEDFinder

A Garmin Connect IQ **widget** that points you to the nearest
**automated external defibrillator (AED)**. It shows a rotating arrow
and the live distance, buzzes when it finds one and again when you
arrive, lets you pick from the five nearest, and tells you the things
the arrow can't: whether the device is public, indoors, on which floor,
behind which door, and at what hours.

Data comes from [OpenAEDMap](https://openaedmap.org) — OpenStreetMap
Polska's map of defibrillators — © OpenStreetMap contributors, ODbL 1.0.

> **This is a navigation aid, not a medical device.** The data is
> crowd-sourced and may be wrong, stale or missing. **In an emergency,
> call 112 first.** The dispatcher knows where the nearest defibrillator
> is and will talk you through using it.

The navigation core — GPS/compass handling, the smoothed arrow, the
GNSS escalation, the round-screen text fitting, the selection menu, the
haptic state machines — is carried over from
[ZabkaFinder](https://github.com/barchojnow/ZabkaFinder). What is new is
everything downstream of "where do the coordinates come from", and that
turned out to be most of the interesting design.

## Why there is no search API

OpenAEDMap cannot be queried from a watch. Its public API
([openaedmap-backend](https://github.com/openstreetmap-polska/openaedmap-backend))
exposes exactly three things:

| Endpoint | Why it doesn't work here |
|---|---|
| `/api/v1/tile/{z}/{x}/{y}.mvt` | Mapbox Vector Tile — protobuf, gzipped. Monkey C has no decoder and no practical access to raw response bytes. |
| `/api/v1/node/{id}` | Needs an id you don't have yet. It answers "what is this?", not "what is near me?". |
| `/api/v1/countries/{code}.geojson` | The entire country in one file — megabytes, against a widget heap measured in tens of kilobytes. |

Overpass would answer the question directly, and ZabkaFinder used it
until the primary instance started rejecting legitimate requests with
HTTP 406 ([Overpass-API#791](https://github.com/drolbr/Overpass-API/issues/791))
and the mirrors that absorbed the traffic buckled in turn. That is why
ZabkaFinder moved to Nominatim — and Nominatim is no help here either,
because it searches by *name*, and an AED is an unnamed node carrying
`emergency=defibrillator`.

So the spatial query is moved off the watch entirely and answered before
anyone asks it.

## How it works

1. **A scheduled job cuts the country into tiles.** `tools/build_tiles.py`,
   run daily by GitHub Actions, downloads `PL.geojson` from OpenAEDMap
   and buckets every defibrillator into a fixed 0.05° grid — one small
   JSON file per non-empty cell, published to GitHub Pages. The tiles
   are never committed: they're deployed straight from the workflow
   artifact, so a few thousand regenerated files a night don't turn the
   repository history into landfill.

2. **The watch computes its own filename.** Given a GPS fix,
   `AedTiles.cellIndex()` floors the coordinates into a cell and the
   client fetches `pl/1044/420.json`. One request, ~1–3 KB, no query
   string, no rate limit, no origin server — a CDN edge answers it.

3. **The margin is what makes it one request.** Each cell file also
   contains the AEDs lying up to 0.02° north/south and 0.04° east/west
   *outside* it. Because that margin (2224 m and 2556 m at Poland's
   northern edge) is wider than the 2000 m search radius, every AED
   within range of *any* point in the cell is in that cell's file —
   including when you're standing hard against a border. Without it the
   watch would need up to four requests and would still miss AEDs
   diagonally across a corner.

4. **A refresh only happens when you leave the cell.** ZabkaFinder
   re-searched every 100 m of walking, throttled to once per 30 s,
   because Nominatim's answer depended on exactly where you asked from.
   Here it cannot: while you remain in one cell the loaded tile is
   already provably complete, so another request could not return
   anything new. An hour walking around a city block costs one request.

5. **Tiles are kept in `Application.Storage`.** Up to three cells,
   expiring after 30 days. This is the one feature with no ZabkaFinder
   counterpart, and the reason is the use case, not the code: a shop
   finder that needs your phone is inconvenient, a defibrillator finder
   that needs your phone fails exactly when it matters — phone in a
   rucksack, no signal in a stairwell, flat battery. Yesterday's tile is
   still correct, because defibrillators don't move. The UI says
   "offline data" while serving one, so nobody runs somewhere on
   day-old coordinates without knowing.

6. **The nearest AED is targeted automatically, and the watch buzzes.**
   One long pulse on the first lock of the session, so you can raise
   your wrist already knowing there's something to walk to. A double
   pulse on arrival within 25 m, exactly once per approach (the latch
   re-arms only past 45 m, so GPS jitter around the line can't retrigger
   it). Three quick pulses for the walking-away prompt. The patterns
   differ in *rhythm*, not just length — through a sleeve that's the
   only difference a wrist reliably feels.

7. **Hybrid heading.** While walking (≥ 1 m/s) the arrow follows the GPS
   course-over-ground, which is immune to compass miscalibration and
   wrist tilt; standing still, the magnetic compass takes over. Watches
   with no compass at all (Forerunner 55) use the GPS course from a
   gentle walking pace. Until *some* heading exists the arrow stays gray
   — a meaningless direction is worse than none.

8. **The screen carries the information the arrow can't.** Once a target
   is locked, the top of the display shows restricted access in orange,
   plus indoors/floor/hours. **MENU** opens the full detail screen:
   access, placement, opening hours and the free-text
   `defibrillator:location` note ("przy recepcji, obok windy"). An AED
   behind a locked door at 3 a.m. is not a destination, and you should
   learn that before setting off rather than on arrival.

9. **HTTP 404 is an answer, not an error.** No file for a cell means the
   generator found no defibrillator near it. Treating that as a failure
   would put the widget in a retry loop over a settled question.

10. **Error messages are rules, not lookup tables.** HTTP statuses are
    positive, Connect IQ transport errors are negative — so `-104`
    becomes "connect your phone", every other negative code becomes "no
    internet", and positive codes are shown with their number because
    they describe the server rather than your setup. A new transport
    error code doesn't need a new release.

## Controls

| | Main screen | During the walking-away prompt |
|---|---|---|
| **START** / tap | list of the 5 nearest AEDs | keep navigating to your pick |
| **MENU** / long press | details of the current target | open the list instead |

The fastest path — open the widget, follow the arrow — needs no input at
all, because the nearest AED is targeted automatically. Every button
belongs to the deliberate path, so a keypress can cost a screen without
costing anyone time in an emergency.

## Project structure

```
manifest.xml                  Connect IQ manifest (permissions, 65 target devices)
monkey.jungle                 Per-product launcher icon mapping
pytest.ini                    Test discovery + the `slow` marker
requirements-dev.txt          pytest (tests only - the generator is stdlib)
PRIVACY.md                    Privacy policy (linked from the store listing)

source/
  AedFinderApp.mc             Application entry point
  AedFinderView.mc            Main view: positions in, navigation target out
  AedFinderDelegate.mc        Input handling, the Menu2 AED list
  AedDetailView.mc            Full tag detail screen with round-screen wrapping
  AedRenderer.mc              Every pixel of the main screen
  Positioning.mc              GNSS acquisition and the escalation ladder
  HeadingSource.mc            Compass vs GPS course, and which to trust
  AedTiles.mc                 The grid: position -> tile filename
  AedClient.mc                Tile fetching, watchdog, backoff, parsing
  AedCache.mc                 Application.Storage persistence for offline use
  AedList.mc                  The collection: radius filtering, merging, sorting
  ProximityAlerts.mc          Found/arrival buzzes, walking-away state machine
  AedLogo.mc                  The heart-and-bolt mark, drawn with primitives
  GeoMath.mc                  Haversine distance, bearing, angle normalization
  TextFit.mc                  Adaptive font sizing for round screens
  Effects.mc                  Vibrator + Scheduler: the injectable side effects
  tests/                      (:test) annotated unit tests

tools/
  build_tiles.py              Country GeoJSON -> static tile set
  check_grid.py               Cross-language grid verification (see below)
  grid_vectors.json           The shared fixture both languages assert against
  conftest.py                 Shared pytest fixtures and sys.path setup
  test_build_tiles.py         Generator tests, incl. the coverage property
  test_check_grid.py          Breaks the grid on purpose to prove the guard bites
  make_icons.py               Generates every launcher icon PNG
  run-tests.ps1               Runs the Monkey C suite across several devices

.github/workflows/
  build-data.yml              Daily tile rebuild + GitHub Pages deploy

resources/                    Strings (English), fallback launcher icon
resources-pol/                Polish strings (auto-selected by watch language)
variants/icon-*/              Per-product launcher icons, mapped in the jungle
```

### One binary, 65 watches

- **Layout scales with the screen.** Every pixel offset is multiplied by
  `screenWidth / 416`, and text picks the largest font that fits the
  round screen's *chord* at its own vertical position (`TextFit`) — so
  labels never clip, whatever the language or screen size.
- **The logo is drawn, not shipped.** ZabkaFinder needed ten pre-scaled
  PNGs and a `variants/` folder wired into the jungle product by
  product, because runtime bitmap scaling isn't available on every CIQ
  level and looks poor where it is. `AedLogo.mc` draws the mark from
  circles and polygons instead: resolution-independent by construction,
  no resource memory, no jungle entry. Only the launcher icon still has
  to be a bitmap, because Garmin renders that one itself — and those are
  generated by `tools/make_icons.py` rather than committed as binaries
  nobody can edit.

## The one invariant that spans both languages

The grid is implemented twice: in `tools/build_tiles.py`, which decides
what each published file is *called*, and in `source/AedTiles.mc`, which
decides what the watch *asks for*. They cannot share code — CI can't run
Monkey C, and a watch can't read a Python file.

If they ever disagree, **nothing goes red.** The build succeeds, Pages
deploys, the watch gets a valid HTTP response for some file, and every
user is told "no AED nearby" while standing next to a defibrillator.

So the agreement is pinned rather than assumed. `tools/grid_vectors.json`
holds 16 vectors — real Polish cities, plus a deliberate over-supply of
exact cell boundaries, because 0.05 has no exact binary representation
and a coordinate landing on an edge is where a 32-bit/64-bit mismatch or
a floor-vs-truncate mistake shows up first. `tools/check_grid.py` runs
**before the download** in the data workflow and asserts four things:

1. the Python implementation still reproduces every vector;
2. the table in `source/tests/AedTilesTest.mc` is still that fixture,
   verbatim — so nobody can "fix" a failing on-device test by editing
   the expectation;
3. the constants in `AedTiles.mc` still equal the Python ones, including
   that `CELL_DEG` keeps its `d` suffix (without it Monkey C parses the
   literal as a 32-bit Float and rounds cell indices differently from
   the 64-bit generator — visible only near a border, i.e. rarely enough
   to reach users);
4. the margins still cover the search radius across Poland's full
   latitude range.

Agreeing with the fixture on both sides is what makes the two
implementations agree with each other.

## Tests

### Python — 46 tests, `pytest`

```bash
pip install -r requirements-dev.txt
pytest                    # from anywhere in the repo
pytest -m "not slow"      # skips the brute-force coverage check (~8 s)
```

`test_build_tiles.py` covers field parsing, diacritic folding,
deterministic output and an end-to-end pass that walks the whole chain
the way the watch does — derive the filename, open that file, decode the
slots, filter, sort — and lands on the AED a human would have picked.
Plus the one that matters most: **`CoverageTest`**. It places 4000
random AEDs across Poland, probes 3000 positions — including cell
corners and edges, where a random point almost never lands and where the
margin is the only thing standing between the user and a wrong answer —
and brute-forces the property the whole design rests on:

> for any position P and any AED within 2000 m of P, that AED appears in
> the tile file P's cell index names.

It checks this by exhaustive search rather than by re-deriving the
margin arithmetic, so a mistake in that arithmetic can't also mark its
own homework.

`test_check_grid.py` tests the guard rather than the code. It breaks the
grid eight different ways — renumbering a vector in the watch's test
table, deleting one, inventing one, changing the cell size on one side,
dropping the `d` suffix, regenerating the fixture at a different cell
size, shrinking the margin, growing the radius past it — and asserts
`check_grid.py` rejects each, *and* that the failure mentions the thing
that was broken, so a check failing for an unrelated reason can't pass
for the right one. A guard that cannot fail looks identical in CI to one
that works, forever, until the day it matters; this is the button on the
smoke detector.

Only the tests need pytest. `build_tiles.py` and `check_grid.py` are
stdlib-only by design, so the two workflow steps that actually produce
and verify the published data would still run on a bare interpreter if
the dependency ever became a problem.

### Monkey C — 77 tests, `tools/run-tests.ps1`

| Suite | Covers |
|---|---|
| `GeoMathTest` | Haversine, initial bearing, angle normalization |
| `AedTilesTest` | the shared grid vectors, floor-vs-truncate, cell identity |
| `AedClientTest` | the wire format, response classification, backoff, a late watchdog |
| `AedCacheTest` | the offline path: round trip, expiry, eviction, corrupt Storage |
| `AedListTest` | radius filtering, identity merging, live re-sorting, empty cases |
| `ProximityAlertsTest` | the buzz latches, hysteresis, the walking-away prompt |
| `HeadingSourceTest` | compass vs GPS course, and watches with neither |

They use the Connect IQ test framework: functions are annotated
`(:test)`, so they're compiled into test builds only and never ship.

`AedCacheTest` earns its place by covering the one path that fails
silently. Everything else in this app fails loudly — no fix, no phone,
an error on screen — but a broken cache only shows up once the network
is already gone, which is precisely the situation it exists for. Nobody
finds that by using the widget normally. It writes to real Storage in
the simulator, clears the key before each test and leaves nothing
behind.

`AedClientTest` guards the other end of the contract that
`test_build_tiles.py` guards from CI. The tile slots are positional, so
a field inserted or reordered on either side yields a payload that still
parses, still has the right length, and quietly puts opening hours where
the floor should be.

The `HeadingSource` tests only exist because the class does. While that
logic sat inside the view it was reachable only through `Position.Info`
and `Sensor.Info`, so the sole way to check which source was driving the
arrow was to walk outside with a watch — which is why the rules had none
of the coverage they deserve. Every one of them is a tradeoff that looks
arbitrary until it's wrong: an arrow that snaps to north when you pause,
or that trusts a miscalibrated compass while you run, sends someone the
wrong way during an emergency.

`ProximityAlerts` is testable because its two side effects — buzzing and
scheduling — are injected (`Effects.mc` in production, fakes in tests).
The state machine decides *when* to buzz; the test counts buzzes **per
pattern** and fires the timeout by hand instead of waiting 15 seconds.
Counting per pattern is the point: the three rhythms mean three
different things to someone not looking at the screen, so a test that
only asserted "something vibrated" would pass while the watch said the
wrong thing.

```powershell
.\tools\run-tests.ps1                    # representative device set
.\tools\run-tests.ps1 -Devices venu2     # a single device
.\tools\run-tests.ps1 -All               # every product in the manifest
.\tools\run-tests.ps1 -KeepSimulator     # reuse one instance (fast, flaky)
```

The default set covers what actually varies: tightest memory (`fr55`,
which is also the no-compass case), oldest API (`fenix5`), touch
(`venu2`) and newest hardware (`fenix847mm`). `-All` exists for
completeness but takes ~30 minutes for little extra signal — **Monkey C:
Export Project** already proves the code compiles on every product.

**The script restarts the simulator between devices, on purpose.** The
Connect IQ simulator only simulates one device at a time. Pushing a
binary built for device B into an instance currently running device A
makes it discard the loaded app — `Unsupported app was removed:
...PRG` — and re-initialise, leaving `monkeydo` waiting for a handshake
from an app that no longer exists. It never times out on its own, so the
run just hangs with the simulator sitting on its idle screen.
`-KeepSimulator` opts out, which is only safe when every run targets the
same device.

Restarting isn't quite enough by itself, and the reason is worth knowing
before anyone "simplifies" it: the simulator **persists its session**
(last device, last loaded app) and only writes that state on a clean
exit. Killed outright it comes back up on a half-written session, tries
to restore a `.prg` built for a different device, and can then refuse
the push that follows — reintroducing the exact hang the restart was
meant to prevent. So the restart closes the window first and only kills
what refuses to go.

**And restarting the simulator does not help at all with the actual
cause**, which took a hang that survived every restart to find.
`monkeydo.bat` is only a wrapper; the process that talks to the
simulator is the SDK's `shell.exe`, and it holds a port in the
1234–1238 range. It is not reliably a child of the batch file, so
killing the batch's process tree can leave it running — and the next
device's `shell.exe`, scanning that same range, finds the port taken and
blocks. The simulator sits on its idle screen looking like the problem
while the real culprit is an orphan from the previous device. So the
script kills it explicitly, matched by path so only the SDK's own
`shell.exe` is ever touched.

That port turns out to answer the readiness question too. There is no
API for "is the IPC listener up yet", and the process exists well before
it is, so the script waits for the port to start listening instead of
sleeping a hopeful number of seconds — and waits for it to clear after
shutdown, since the socket outlives the process and connecting into that
gap looks exactly like a hang.

Each `monkeydo` call is still bounded by `-TimeoutSec` (default 45,
process tree killed on expiry) and retried up to `-Retries` times with a
longer settle, as a backstop for the machines where port state can't be
read. A device that times out on every attempt is a real failure and
shows as `TIMEOUT` in the summary; one that succeeds on the second
attempt was just a slow simulator, which isn't worth a red build.
Per-device output is kept in `bin/test/<device>.out.log`.

If a run does wedge anyway, the simulator's **File → Kill Device**
clears the loaded device and app by hand — the manual version of what
the restart is doing.

## Setup

### The watch app

1. Open the folder in VS Code with the Monkey C extension installed.
2. Press **F5** and pick a configuration from `.vscode/launch.json`.
3. **Monkey C: Export Project** builds a release `.iq` for every device.

Requires the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
with device files downloaded via the SDK Manager, and a watch (or the
simulator) with GPS and a phone connection. A magnetic compass is
optional.

### The data

1. In the repository settings, set **Pages → Source** to **GitHub
   Actions**.
2. Run the **Build AED tiles** workflow once by hand
   (`workflow_dispatch`), or wait for 03:40 UTC.
3. Confirm the base URL in `source/AedTiles.mc` matches where Pages
   published — the default assumes `barchojnow.github.io/AEDFinder`.

To rebuild locally without hitting OpenAEDMap repeatedly:

```bash
python tools/build_tiles.py --country pl --out _site --cache /tmp/pl.geojson
```

Extending beyond Poland is a change to the country code in the workflow,
not to the app — though the grid constants would want re-checking at
latitudes far from Poland's, since a degree of longitude shrinks with
`cos(latitude)` and the margin is expressed in degrees.

## Supported devices

Declared in `manifest.xml` (`minApiLevel 3.1.0`) — all round-screen
Fenix, Enduro, Epix, Forerunner and Venu models from the Fenix 5 /
FR 245 / Venu 1 generation onwards, 65 products.

Not supported: devices below Connect IQ 3.1 (no `Menu2` API), FR 45 (no
widget support at all) and rectangular screens (Venu Sq/Sq 2, Venu X1) —
the layout is designed for round displays.

## Permissions

- `Communications` — fetching the tile
- `Positioning` — reading GPS
- `Sensor` — reading the magnetic compass

`Attention.vibrate` requires no manifest permission.

## Known limitations

- **Poland only for now.** The generator takes a country code; the
  workflow passes `pl`. Adding neighbours is a one-line change plus a
  longer Action.
- **Tiles are up to a day old.** Fine for permanent fixtures, but a
  defibrillator added to OSM this morning won't appear until tomorrow.
- **Only what OSM knows.** An unmapped defibrillator does not exist as
  far as this app is concerned, and a mapped one may have moved, been
  removed, or never have been tagged with its floor or opening hours.
  Corrections belong in OpenStreetMap, where they help everyone — the
  "add a defibrillator" flow on openaedmap.org is the easiest route.
- **Access tags are sparse.** Where `access` is untagged the app says
  "access unknown" rather than guessing, which is honest but not
  helpful. That's a data problem, not a code one.
- **No favourites**, and no way to report a wrong location from the
  watch.

## Privacy

See [PRIVACY.md](PRIVACY.md) — the short version: nothing about you
leaves the watch, not even your position. The only request is for a
static file whose name identifies a ~5.5 × 3.5 km grid cell, with no
coordinates, no query string and no identifier.

## License

Open source — see [LICENSE](LICENSE).

Defibrillator data © OpenStreetMap contributors, available under the
[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/), via
[OpenAEDMap](https://openaedmap.org).
