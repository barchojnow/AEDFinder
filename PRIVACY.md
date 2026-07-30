# Privacy policy — AED Finder

**Short version: nothing about you leaves the watch. Not even your
position.**

## What the app sends

One HTTP GET, to a static file on GitHub Pages:

```
https://barchojnow.github.io/AEDFinder/pl/1044/420.json
```

That path is the only thing derived from your location, and it is
deliberately coarse: it names a grid cell roughly 5.5 km by 3.5 km, not
a point. The request carries no coordinates, no query string, no
identifier, no account and no cookie. Every watch standing anywhere in
that cell sends a byte-identical request.

This is a consequence of how the app works rather than a promise bolted
on afterwards. The search is answered ahead of time by a scheduled job
that cuts OpenAEDMap's public data into tiles; the watch only picks
which tile to download. There is no server to send a position *to* — a
static file cannot receive one.

GitHub, as the host, will see the request in its ordinary web server
logs, including your phone's IP address, the same as any website you
visit. Their terms govern that: <https://docs.github.com/site-policy>.

## What the app stores

Up to three downloaded tiles are kept in the watch's own app storage
(`Application.Storage`), so the app still works with no phone and no
signal. These hold public OpenStreetMap data about defibrillators —
coordinates, access, floor, opening hours — and nothing about you. They
never leave the watch, and are removed when you uninstall the app.

Your position is held in memory while the app is open and is discarded
when you close it. It is never written to storage and never transmitted.

## What the app does not do

No analytics, no crash reporting, no advertising, no tracking, no
accounts, no third-party SDKs. No location history. Nothing is sold or
shared, because nothing is collected.

## Data source and attribution

Defibrillator data comes from [OpenAEDMap](https://openaedmap.org),
which is built on [OpenStreetMap](https://www.openstreetmap.org).
© OpenStreetMap contributors, available under the
[Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
See <https://www.openstreetmap.org/copyright>.

## Safety note

This app is a navigation aid built on crowd-sourced data. It is not a
medical device and it is not an emergency service. Locations may be out
of date, wrong, or missing entirely, and a defibrillator that is mapped
may be behind a locked door.

**In an emergency, call the emergency number first — 112 in Poland and
across the EU.** The dispatcher can direct you to a defibrillator and
will talk you through using it.

## Contact

Questions or corrections: open an issue at
<https://github.com/barchojnow/AEDFinder/issues>.

Data corrections belong in OpenStreetMap itself, where they help
everyone rather than only this app — the easiest route is the "add a
defibrillator" flow on <https://openaedmap.org>.
