import Toybox.Lang;
import Toybox.Math;

// Position -> the name of the one static file guaranteed to hold every
// AED within SEARCH_RADIUS_M. The guarantee comes from the margin
// build_tiles.py bakes into each tile: it is wider than the search
// radius, so one request always suffices, even standing on a border.
//
// CONSTANTS ARE DUPLICATED IN tools/build_tiles.py and cannot be shared
// (CI can't run Monkey C, a watch can't read Python). tools/check_grid.py
// fails the data build if they drift - the failure is otherwise silent:
// the watch would request files published under different keys and say
// "no AED nearby" while standing next to one.
module AedTiles {

    const BASE_URL = "https://barchojnow.github.io/AEDFinder";

    // The one place the app's version is written down. It used to be
    // spelled out inside AedClient's User-Agent, where it would have sat
    // at 1.0 through every release - and a version string nobody bumps
    // is worse than none, because it answers "which build is this?"
    // confidently and wrongly.
    //
    // Lives here because this module already owns who we are on the
    // wire. tools/test_version.py fails if a second copy appears
    // anywhere in source/, which is the only way this drifts again.
    const VERSION = "0.0.1";

    // A function rather than a concatenated const: Monkey C's rules for
    // what counts as a compile-time constant expression are not worth
    // discovering at build time. Called once per tile fetch.
    function userAgent() as Lang.String {
        return "AEDFinder/" + VERSION
            + " (+https://github.com/barchojnow/AEDFinder)";
    }

    // Must keep the `d` suffix: Monkey C's Float is 32-bit, and rounding
    // a cell index at 32-bit precision puts positions near a boundary in
    // a different cell than the 64-bit generator chose.
    const CELL_DEG = 0.03d;

    const SEARCH_RADIUS_M = 1500;

    // Math.floor, not toNumber(): toNumber truncates toward zero, which
    // would merge cells either side of the equator or Greenwich. Poland
    // never exposes it, which is why it has to be right before the tile
    // set is ever extended.
    function cellIndex(degrees as Lang.Double) as Lang.Number {
        return Math.floor(degrees / CELL_DEG).toNumber();
    }

    // e.g. "pl/1740/700.json"
    function tilePath(country as Lang.String, lat as Lang.Double,
                      lon as Lang.Double) as Lang.String {
        return country + "/" + cellIndex(lat) + "/" + cellIndex(lon) + ".json";
    }

    function tileUrl(country as Lang.String, lat as Lang.Double,
                     lon as Lang.Double) as Lang.String {
        return BASE_URL + "/" + tilePath(country, lat, lon);
    }

    // Leaving the cell is the only event that can reveal a new AED, so
    // this is what keeps an hour's walk to a single request.
    function sameCell(lat1 as Lang.Double, lon1 as Lang.Double,
                      lat2 as Lang.Double, lon2 as Lang.Double) as Lang.Boolean {
        return cellIndex(lat1) == cellIndex(lat2)
            && cellIndex(lon1) == cellIndex(lon2);
    }
}
