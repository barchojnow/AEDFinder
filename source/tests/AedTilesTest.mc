import Toybox.Lang;
import Toybox.Test;

// The watch half of the cross-language grid check. If this and
// build_tiles.py disagree, nothing goes red - the build succeeds, Pages
// deploys, and every user is told "no AED nearby" while standing next
// to a defibrillator.
//
// Generated from tools/grid_vectors.json; check_grid.py asserts both
// implementations still reproduce it.
//
// DO NOT EDIT THE TABLE BY HAND - regenerate it from the fixture.
module AedTilesTest {

    // name, latitude, longitude, expected lat index, expected lon index
    function vectors() as Lang.Array {
        return [
            ["warsaw-centre", 52.2297d, 21.0122d, 1740, 700],
            ["krakow-rynek", 50.06143d, 19.93658d, 1668, 664],
            ["gdansk-north", 54.35205d, 18.64637d, 1811, 621],
            ["zakopane-south", 49.29899d, 19.94983d, 1643, 664],
            ["szczecin-west", 53.42894d, 14.55302d, 1780, 485],
            ["hrubieszow-east", 50.805d, 23.89d, 1693, 796],
            ["boundary-exact-lat", 52.26d, 21.0122d, 1742, 700],
            ["boundary-exact-lon", 52.2297d, 21.0d, 1740, 700],
            ["boundary-exact-both", 52.26d, 21.03d, 1742, 701],
            ["boundary-just-below", 52.2599999d, 20.9999999d, 1741, 699],
            ["boundary-just-above", 52.2600001d, 21.0000001d, 1742, 700],
            ["boundary-multiple-30", 51.0d, 21.0d, 1700, 700],
            ["negative-lon", 51.50722d, -0.1275d, 1716, -5],
            ["negative-both", -33.8688d, -151.2093d, -1129, -5041],
            ["origin", 0.0d, 0.0d, 0, 0],
            ["just-below-origin", -0.0000001d, -0.0000001d, -1, -1],
        ];
    }

    (:test)
    function matchesTheSharedFixture(logger as Test.Logger) as Lang.Boolean {
        var cases = vectors();
        var ok = true;

        for (var i = 0; i < cases.size(); i++) {
            var c = cases[i] as Lang.Array;
            var name = c[0] as Lang.String;
            var gotLat = AedTiles.cellIndex(c[1] as Lang.Double);
            var gotLon = AedTiles.cellIndex(c[2] as Lang.Double);

            if (gotLat != (c[3] as Lang.Number) || gotLon != (c[4] as Lang.Number)) {
                logger.error(name + ": got [" + gotLat + ", " + gotLon
                    + "], fixture says [" + c[3] + ", " + c[4] + "]");
                ok = false;
            }
        }
        return ok;
    }

    // Poland is entirely north and east of zero, so this can only break
    // when the tile set is extended - the kind of change nobody re-tests.
    //
    // Half a cell, not a fixed number of degrees: an earlier version
    // used a literal 0.03, which became exactly one whole cell when
    // CELL_DEG was retuned to 0.03 and started asserting something else.
    (:test)
    function flooringGoesDownwardsNotTowardsZero(logger as Test.Logger) as Lang.Boolean {
        var half = AedTiles.CELL_DEG / 2.0d;

        if (AedTiles.cellIndex(-half) != -1) {
            logger.error("cellIndex(-" + half + ") = " + AedTiles.cellIndex(-half)
                + ", expected -1 (truncation toward zero would give 0)");
            return false;
        }
        if (AedTiles.cellIndex(half) != 0) {
            logger.error("cellIndex(" + half + ") = " + AedTiles.cellIndex(half)
                + ", expected 0");
            return false;
        }
        return true;
    }

    (:test)
    function buildsThePathTheGeneratorWrote(logger as Test.Logger) as Lang.Boolean {
        var path = AedTiles.tilePath("pl", 52.2297d, 21.0122d);
        if (!path.equals("pl/1740/700.json")) {
            logger.error("tilePath = " + path + ", expected pl/1740/700.json");
            return false;
        }
        return true;
    }

    // Inside one cell another request could not return anything new.
    (:test)
    function recognisesStayingInsideTheSameCell(logger as Test.Logger) as Lang.Boolean {
        if (!AedTiles.sameCell(52.2297d, 21.0122d, 52.2100d, 21.0250d)) {
            logger.error("two points in one cell reported as different cells");
            return false;
        }
        if (AedTiles.sameCell(52.2297d, 21.0122d, 52.2900d, 21.0122d)) {
            logger.error("points in different cells reported as the same cell");
            return false;
        }
        return true;
    }
}
