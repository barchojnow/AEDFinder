import Toybox.Lang;
import Toybox.Test;

// Unit tests for AedList - the radius filtering, merging and distance
// sorting that decide which defibrillator the arrow points at. This is
// where a silent bug is most expensive (people walk the wrong way), and
// it is pure logic, so it is fully testable off-device.
module AedListTest {

    const LAT = 52.2297d;
    const LON = 21.0122d;
    // 1 milli-degree of latitude is ~111.19 m, so the offsets below are
    // easy to reason about: +0.002 = ~222 m, +0.02 = ~2224 m.
    const RADIUS_M = 2000;

    function aed(latOffset as Lang.Double, id as Lang.String,
                 loc as Lang.String) as Lang.Dictionary {
        return {
            :lat => LAT + latOffset, :lon => LON,
            :access => "y", :indoor => -1, :level => "",
            :loc => loc, :hours => "", :id => id
        };
    }

    // --- radius filtering ------------------------------------------------

    (:test)
    function dropsAedsBeyondRadius(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        var count = list.update([
            aed(0.002d, "1", "in range ~222 m"),
            aed(0.04d, "2", "out of range ~4448 m")
        ], LAT, LON, RADIUS_M);

        if (count != 1 || list.size() != 1) {
            logger.error("expected 1 in range, got fresh=" + count
                + " total=" + list.size());
            return false;
        }
        var kept = list.get(0) as Lang.Dictionary;
        if (!(kept[:id] as Lang.String).equals("1")) {
            logger.error("wrong entry kept: id " + kept[:id]);
            return false;
        }
        return true;
    }

    // --- identity, not proximity -----------------------------------------

    // The rule this whole app differs from ZabkaFinder on. Two
    // defibrillators a few metres apart - a hospital lobby and the ward
    // next to it, opposite sides of a mall entrance - are two devices.
    // ZabkaFinder collapsed anything within 25 m into one entry and
    // documented the consequence as a known limitation; here that would
    // mean sending someone to the wrong wall, so the OSM node id
    // decides instead.
    (:test)
    function keepsTwoDistinctAedsMetresApart(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        // ~5.6 m apart: far inside any plausible proximity threshold.
        list.update([
            aed(0.00000d, "111", "lobby, by the desk"),
            aed(0.00005d, "222", "lobby, by the lift")
        ], LAT, LON, RADIUS_M);

        if (list.size() != 2) {
            logger.error("expected both AEDs kept, got " + list.size()
                + " - distinct devices were collapsed by proximity");
            return false;
        }
        return true;
    }

    // The same device coming back in a later tile must not appear twice.
    (:test)
    function mergesTheSameAedByOsmId(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([aed(0.001d, "999", "old label")], LAT, LON, RADIUS_M);
        // Same id, coordinates nudged the way an OSM edit would nudge
        // them, and a corrected label.
        list.update([aed(0.0011d, "999", "new label")], LAT, LON, RADIUS_M);

        if (list.size() != 1) {
            logger.error("expected 1 entry after re-fetching the same AED, got "
                + list.size());
            return false;
        }
        // Fresh data must win, otherwise corrections in OSM never reach
        // the watch.
        var kept = list.get(0) as Lang.Dictionary;
        if (!(kept[:loc] as Lang.String).equals("new label")) {
            logger.error("stale entry survived: " + kept[:loc]);
            return false;
        }
        return true;
    }

    // Entries that arrived without an id (empty string) still have to be
    // deduplicated somehow, so proximity remains as the fallback.
    (:test)
    function fallsBackToProximityWhenIdIsMissing(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([aed(0.001d, "", "unidentified")], LAT, LON, RADIUS_M);
        list.update([aed(0.001d, "", "unidentified")], LAT, LON, RADIUS_M);

        if (list.size() != 1) {
            logger.error("expected proximity fallback to merge idless entries, got "
                + list.size());
            return false;
        }
        return true;
    }

    // --- merging ---------------------------------------------------------

    // A refresh that returns fewer entries must not lose knowledge. This
    // matters more here than in a shop finder: a defibrillator known ten
    // minutes ago is still a defibrillator, and dropping it because one
    // response came back thin is not an acceptable failure mode.
    (:test)
    function keepsPreviouslyKnownAedsStillInRange(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([
            aed(0.001d, "1", "first"),
            aed(0.002d, "2", "second")
        ], LAT, LON, RADIUS_M);

        // A later tile that only mentions one of them.
        list.update([aed(0.001d, "1", "first")], LAT, LON, RADIUS_M);

        if (list.size() != 2) {
            logger.error("expected the known AED to survive a thin refresh, got "
                + list.size());
            return false;
        }
        return true;
    }

    // ...but one that has fallen out of range should not linger.
    (:test)
    function dropsKnownAedsOnceOutOfRange(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([aed(0.001d, "1", "near home")], LAT, LON, RADIUS_M);

        // The user has walked ~4.4 km north; the old entry is now far
        // outside the radius measured from here.
        var farLat = LAT + 0.04d;
        list.update([aed(0.041d, "2", "near here")], farLat, LON, RADIUS_M);

        if (list.size() != 1) {
            logger.error("expected the out-of-range AED to be dropped, got "
                + list.size());
            return false;
        }
        var kept = list.get(0) as Lang.Dictionary;
        if (!(kept[:id] as Lang.String).equals("2")) {
            logger.error("kept the wrong entry: id " + kept[:id]);
            return false;
        }
        return true;
    }

    // --- sorting ---------------------------------------------------------

    (:test)
    function sortsByDistanceAscending(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([
            aed(0.004d, "far", "far"),
            aed(0.0005d, "near", "near"),
            aed(0.002d, "mid", "mid")
        ], LAT, LON, RADIUS_M);
        list.sortByDistance(LAT, LON);

        var expected = ["near", "mid", "far"];
        for (var i = 0; i < expected.size(); i++) {
            var a = list.get(i) as Lang.Dictionary;
            if (!(a[:id] as Lang.String).equals(expected[i])) {
                logger.error("position " + i + ": expected " + expected[i]
                    + ", got " + a[:id]);
                return false;
            }
        }
        return true;
    }

    // The menu shows live distances, so getNearest must re-sort from the
    // CURRENT position rather than serving the order captured when the
    // tile was fetched. ZabkaFinder had exactly this bug: a menu frozen
    // at search time, which is why the test exists.
    (:test)
    function menuReSortsFromTheCurrentPosition(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([
            aed(0.001d, "north", "north"),
            aed(-0.001d, "south", "south")
        ], LAT, LON, RADIUS_M);

        // The user walks north, so the northern AED becomes the closer.
        var walkedLat = LAT + 0.0009d;
        var nearest = list.getNearest(2, walkedLat, LON);

        if (nearest.size() != 2) {
            logger.error("expected 2 menu entries, got " + nearest.size());
            return false;
        }
        var first = nearest[0] as Lang.Dictionary;
        if (!(first[:id] as Lang.String).equals("north")) {
            logger.error("menu order is stale: first entry is " + first[:id]);
            return false;
        }
        return true;
    }

    (:test)
    function menuCapsAtTheRequestedCount(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        var fresh = [] as Lang.Array;
        for (var i = 0; i < 12; i++) {
            fresh.add(aed(0.0002d * (i + 1), i.toString(), "aed " + i));
        }
        list.update(fresh, LAT, LON, RADIUS_M);

        if (list.getNearest(5, LAT, LON).size() != 5) {
            logger.error("expected the menu to cap at 5 entries");
            return false;
        }
        return true;
    }

    (:test)
    function menuAsksForMoreThanExist(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([aed(0.001d, "1", "only one")], LAT, LON, RADIUS_M);

        if (list.getNearest(5, LAT, LON).size() != 1) {
            logger.error("asking for 5 of 1 should give 1");
            return false;
        }
        return true;
    }

    // --- empty and out-of-range access -----------------------------------

    // The view reaches for these before any tile has arrived - on the
    // very first frame, and again whenever a cell turns out to hold
    // nothing. Returning null rather than throwing is what lets the
    // caller stay free of guards.
    (:test)
    function nearestOfAnEmptyListIsNull(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        if (list.nearest() != null) {
            logger.error("an empty list produced a nearest AED");
            return false;
        }
        if (list.size() != 0) {
            logger.error("a new list is not empty");
            return false;
        }
        return true;
    }

    // Menu item ids are indices into this list, and the list is re-sorted
    // and re-merged underneath an open menu. An id can therefore outlive
    // the entry it pointed at, so an out-of-range read has to be
    // survivable rather than merely unlikely.
    (:test)
    function outOfRangeGetReturnsNull(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([aed(0.001d, "1", "only one")], LAT, LON, RADIUS_M);

        var ok = true;
        if (list.get(-1) != null) {
            logger.error("get(-1) returned an entry"); ok = false;
        }
        if (list.get(1) != null) {
            logger.error("get(1) on a 1-entry list returned something"); ok = false;
        }
        if (list.get(9999) != null) {
            logger.error("get(9999) returned an entry"); ok = false;
        }
        if (list.get(0) == null) {
            logger.error("get(0) on a 1-entry list returned nothing"); ok = false;
        }
        return ok;
    }

    (:test)
    function sortingAnEmptyListIsHarmless(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.sortByDistance(LAT, LON);
        if (list.size() != 0) {
            logger.error("sorting an empty list changed its size");
            return false;
        }
        return true;
    }

    // An empty tile is a legitimate answer (HTTP 404 from the tile set),
    // and it must not disturb what is already known - the user may be
    // walking to a defibrillator found in the previous cell.
    (:test)
    function anEmptyTileDoesNotDiscardKnownAeds(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([aed(0.001d, "1", "known")], LAT, LON, RADIUS_M);
        var fresh = list.update([], LAT, LON, RADIUS_M);

        if (fresh != 0) {
            logger.error("an empty tile reported " + fresh + " fresh entries");
            return false;
        }
        if (list.size() != 1) {
            logger.error("an empty tile wiped a known AED");
            return false;
        }
        return true;
    }

    // The return value drives the caller's retry decision, so it has to
    // count what arrived in this tile - not what the list happens to
    // hold after merging in everything remembered from before.
    (:test)
    function freshCountExcludesMergedSurvivors(logger as Test.Logger) as Lang.Boolean {
        var list = new AedList();
        list.update([
            aed(0.001d, "1", "first"),
            aed(0.002d, "2", "second")
        ], LAT, LON, RADIUS_M);

        var fresh = list.update([aed(0.003d, "3", "third")], LAT, LON, RADIUS_M);

        if (fresh != 1) {
            logger.error("expected 1 fresh entry, got " + fresh);
            return false;
        }
        if (list.size() != 3) {
            logger.error("expected 3 known AEDs after the merge, got " + list.size());
            return false;
        }
        return true;
    }
}
