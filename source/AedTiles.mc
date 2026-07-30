import Toybox.Lang;
import Toybox.Math;

// The grid that lets a watch do a spatial query without a spatial
// database: given a GPS position, compute the name of the one static
// file that is guaranteed to contain every AED within SEARCH_RADIUS_M.
//
// The guarantee comes from the margin baked into the files by
// tools/build_tiles.py: each cell also carries the AEDs lying up to
// MARGIN_*_DEG outside it. Because that margin is wider than the
// search radius, a user standing anywhere in the cell - including
// hard against a border - finds every nearby AED in that cell's file.
// One request, always, with no neighbour fetches and no seams.
//
// THE CONSTANTS BELOW ARE DUPLICATED IN tools/build_tiles.py.
// They cannot be shared: the generator runs in CI, the watch has no
// way to read it. tools/check_grid.py parses this file and fails the
// data build if the two ever disagree, because the failure mode is
// silent - the watch would request cells that were published under
// different keys and report "no AED nearby" while standing next to one.
module AedTiles {

    // Where the tiles are published. GitHub Pages rather than a server:
    // static files on a CDN have no cold start, no rate limit, no
    // uptime to maintain and no usage policy to comply with, which
    // matters for something people may open in an emergency.
    const BASE_URL = "https://barchojnow.github.io/AEDFinder";

    // Cell size in degrees. Must be a Double literal (`d` suffix):
    // Monkey C's Float is 32-bit, and rounding a cell index at 32-bit
    // precision would put positions near a cell boundary in a
    // different cell than the 64-bit generator did - the watch would
    // then fetch a neighbouring file and quietly miss AEDs.
    const CELL_DEG = 0.05d;

    // Kept in sync with build_tiles.py's margins; the watch only needs
    // them to document the radius it is allowed to filter to.
    const SEARCH_RADIUS_M = 2000;

    // Floor division of a coordinate into a cell index.
    //
    // Math.floor, not toNumber(): toNumber() truncates toward zero, so
    // -0.03 and +0.03 would land in the same cell. Poland is entirely
    // north and east of zero so this never fires here - which is
    // precisely why it has to be correct now, rather than becoming a
    // bug the first time the tile set is extended westwards.
    function cellIndex(degrees as Lang.Double) as Lang.Number {
        return Math.floor(degrees / CELL_DEG).toNumber();
    }

    // The path of the single tile covering this position, e.g.
    // "pl/1044/420.json".
    function tilePath(country as Lang.String, lat as Lang.Double,
                      lon as Lang.Double) as Lang.String {
        return country + "/" + cellIndex(lat) + "/" + cellIndex(lon) + ".json";
    }

    function tileUrl(country as Lang.String, lat as Lang.Double,
                     lon as Lang.Double) as Lang.String {
        return BASE_URL + "/" + tilePath(country, lat, lon);
    }

    // True when the user has left the cell whose tile is already
    // loaded, which is the only moment a new tile is actually needed.
    // Walking inside one cell can never reveal an AED the current file
    // doesn't already hold, so this is what keeps a walk from
    // generating a request every hundred metres.
    function sameCell(lat1 as Lang.Double, lon1 as Lang.Double,
                      lat2 as Lang.Double, lon2 as Lang.Double) as Lang.Boolean {
        return cellIndex(lat1) == cellIndex(lat2)
            && cellIndex(lon1) == cellIndex(lon2);
    }
}
