import Toybox.Lang;

// The known defibrillators: radius filtering, merging, distance
// sorting, menu queries. Pure data logic.
//
// Entries are {:lat, :lon, :access, :indoor, :level, :loc, :hours, :id}
// plus :dist, refreshed by sortByDistance(). Menu ids are indices into
// this array, so sorting must happen in place.
class AedList {

    // Fallback only, for entries that arrived without an OSM id.
    const DUPLICATE_EPSILON_M = 15.0;

    private var aeds as Lang.Array = [];

    function size() as Lang.Number {
        return aeds.size();
    }

    function get(index as Lang.Number) as Lang.Dictionary or Null {
        if (index < 0 || index >= aeds.size()) {
            return null;
        }
        return aeds[index] as Lang.Dictionary;
    }

    // The current nearest AED - only meaningful right after
    // sortByDistance().
    function nearest() as Lang.Dictionary or Null {
        return get(0);
    }

    // Takes freshly parsed entries, filters them to radiusM around
    // (lat, lon), merges them with what was already known and adopts
    // the result. Returns how many FRESH entries were in range.
    function update(entries as Lang.Array, lat as Lang.Double, lon as Lang.Double,
                    radiusM as Lang.Number) as Lang.Number {
        var fresh = buildSorted(entries, lat, lon, radiusM);
        var freshCount = fresh.size();

        // Merge, don't replace: a defibrillator known ten minutes ago
        // is still a defibrillator, and losing it because one response
        // came back thin is not an acceptable failure. Fresh wins on
        // duplicates.
        for (var i = 0; i < aeds.size(); i++) {
            var old = aeds[i] as Lang.Dictionary;
            var oLat = old[:lat] as Lang.Double;
            var oLon = old[:lon] as Lang.Double;

            if (GeoMath.haversineDistance(lat, lon, oLat, oLon) > radiusM) {
                continue;
            }
            if (!containsSame(fresh, freshCount, old)) {
                fresh.add(old);
            }
        }

        aeds = fresh;
        return freshCount;
    }

    // Identity, not proximity. A hospital lobby and the ward next to
    // it can each have one a few metres apart; collapsing them by
    // distance - as ZabkaFinder did - could send someone to the wrong
    // wall. Ids are Strings because OSM ids exceed 32-bit Number.
    private function containsSame(list as Lang.Array, count as Lang.Number,
                                  candidate as Lang.Dictionary) as Lang.Boolean {
        var candidateId = candidate[:id] as Lang.String or Null;
        var hasId = (candidateId != null) && !candidateId.equals("");

        for (var i = 0; i < count; i++) {
            var other = list[i] as Lang.Dictionary;
            if (hasId) {
                var otherId = other[:id] as Lang.String or Null;
                if (otherId != null && otherId.equals(candidateId)) {
                    return true;
                }
            } else if (GeoMath.haversineDistance(
                        candidate[:lat] as Lang.Double, candidate[:lon] as Lang.Double,
                        other[:lat] as Lang.Double, other[:lon] as Lang.Double)
                    < DUPLICATE_EPSILON_M) {
                return true;
            }
        }
        return false;
    }

    // In place, because menu ids are indices into this array.
    // Insertion sort: at most a few dozen entries.
    function sortByDistance(lat as Lang.Double, lon as Lang.Double) as Void {
        var sorted = [] as Lang.Array;
        for (var i = 0; i < aeds.size(); i++) {
            var a = aeds[i] as Lang.Dictionary;
            var d = GeoMath.haversineDistance(lat, lon, a[:lat] as Lang.Double, a[:lon] as Lang.Double);
            a[:dist] = d;

            var pos = 0;
            while (pos < sorted.size()
                   && ((sorted[pos] as Lang.Dictionary)[:dist] as Lang.Double) <= d) {
                pos += 1;
            }
            sorted.add(null);
            for (var j = sorted.size() - 1; j > pos; j--) {
                sorted[j] = sorted[j - 1];
            }
            sorted[pos] = a;
        }
        aeds = sorted;
    }

    // Re-sorted from the CURRENT position, so the menu isn't frozen at
    // fetch time.
    function getNearest(max as Lang.Number, lat as Lang.Double, lon as Lang.Double) as Lang.Array {
        sortByDistance(lat, lon);
        var result = [] as Lang.Array;
        var count = aeds.size() < max ? aeds.size() : max;
        for (var i = 0; i < count; i++) {
            result.add(aeds[i]);
        }
        return result;
    }

    // Filter to radiusM, sorted ascending by distance.
    private function buildSorted(entries as Lang.Array, lat as Lang.Double,
                                 lon as Lang.Double, radiusM as Lang.Number) as Lang.Array {
        var list = [] as Lang.Array;
        var dists = [] as Lang.Array;

        for (var i = 0; i < entries.size(); i++) {
            var entry = entries[i] as Lang.Dictionary;
            var d = GeoMath.haversineDistance(lat, lon,
                entry[:lat] as Lang.Double, entry[:lon] as Lang.Double);
            if (d > radiusM) {
                continue;
            }

            var pos = 0;
            while (pos < dists.size() && (dists[pos] as Lang.Double) <= d) {
                pos += 1;
            }
            dists.add(0.0d);
            list.add(null);
            for (var j = dists.size() - 1; j > pos; j--) {
                dists[j] = dists[j - 1];
                list[j] = list[j - 1];
            }
            dists[pos] = d;
            entry[:dist] = d;
            list[pos] = entry;
        }
        return list;
    }
}
