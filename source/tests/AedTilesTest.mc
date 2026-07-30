import Toybox.Lang;
import Toybox.Test;

// The watch half of the cross-language grid check.
//
// The tile grid is implemented twice - here in Monkey C, which decides
// what file to ask for, and in tools/build_tiles.py, which decides what
// the published files are called. The two cannot share code: CI cannot
// run Monkey C, and a watch cannot read a Python file.
//
// If they ever disagree, nothing goes red. The build succeeds, Pages
// deploys, the watch gets a perfectly valid HTTP response for some
// file - and every user is told "no AED nearby" while standing next to
// a defibrillator. That silence is why the agreement is pinned by a
// shared fixture instead of by inspection.
//
// The vectors below are generated from tools/grid_vectors.json, and
// tools/check_grid.py asserts three things on every data build: that the
// Python implementation still reproduces the fixture, that this table
// still matches the fixture, and that the constants in AedTiles.mc still
// equal the Python ones. Agreeing with the fixture on both sides is what
// makes the two implementations agree with each other.
//
// DO NOT EDIT THE TABLE BY HAND - regenerate it from the fixture.
module AedTilesTest {

    // name, latitude, longitude, expected lat index, expected lon index
    function vectors() as Lang.Array {
        return [
            ["warsaw-centre", 52.2297d, 21.0122d, 1044, 420],
            ["krakow-rynek", 50.06143d, 19.93658d, 1001, 398],
            ["gdansk-north", 54.35205d, 18.64637d, 1087, 372],
            ["zakopane-south", 49.29899d, 19.94983d, 985, 398],
            ["szczecin-west", 53.42894d, 14.55302d, 1068, 291],
            ["hrubieszow-east", 50.805d, 23.89d, 1016, 477],
            ["boundary-exact-lat", 52.25d, 21.0122d, 1045, 420],
            ["boundary-exact-lon", 52.2297d, 21.0d, 1044, 420],
            ["boundary-exact-both", 52.25d, 21.05d, 1045, 421],
            ["boundary-just-below", 52.2499999d, 20.9999999d, 1044, 419],
            ["boundary-just-above", 52.2500001d, 21.0000001d, 1045, 420],
            ["boundary-multiple-20", 51.0d, 20.0d, 1020, 400],
            ["negative-lon", 51.50722d, -0.1275d, 1030, -3],
            ["negative-both", -33.8688d, -151.2093d, -678, -3025],
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

    // Truncation toward zero would put -0.03 and +0.03 in the same cell.
    // Poland is entirely north and east of zero, so this can only ever
    // break when the tile set is extended - which is exactly the kind of
    // change nobody would think to re-test.
    (:test)
    function flooringGoesDownwardsNotTowardsZero(logger as Test.Logger) as Lang.Boolean {
        if (AedTiles.cellIndex(-0.03d) != -1) {
            logger.error("cellIndex(-0.03) = " + AedTiles.cellIndex(-0.03d)
                + ", expected -1 (truncation would give 0)");
            return false;
        }
        if (AedTiles.cellIndex(0.03d) != 0) {
            logger.error("cellIndex(0.03) = " + AedTiles.cellIndex(0.03d)
                + ", expected 0");
            return false;
        }
        return true;
    }

    (:test)
    function buildsThePathTheGeneratorWrote(logger as Test.Logger) as Lang.Boolean {
        var path = AedTiles.tilePath("pl", 52.2297d, 21.0122d);
        if (!path.equals("pl/1044/420.json")) {
            logger.error("tilePath = " + path + ", expected pl/1044/420.json");
            return false;
        }
        return true;
    }

    // A walk that stays inside one cell must not trigger a fetch: the
    // loaded tile already covers the whole cell plus a margin wider than
    // the search radius, so another request could not return anything
    // new. This is what keeps an hour's walk to one request.
    (:test)
    function recognisesStayingInsideTheSameCell(logger as Test.Logger) as Lang.Boolean {
        if (!AedTiles.sameCell(52.2297d, 21.0122d, 52.2350d, 21.0180d)) {
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
