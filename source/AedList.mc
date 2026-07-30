import Toybox.Lang;

// The collection of known defibrillators: filtering a freshly fetched
// tile to the true circular radius, merging it with what was already
// known, distance-sorting and menu queries. Pure data logic - no UI,
// no networking, no storage.
//
// Entries are Dictionaries {:lat, :lon, :access, :indoor, :level,
// :loc, :hours, :id} plus a :dist key refreshed by sortByDistance().
// Menu item ids are indices into this list, so sorting always happens
// on the internal array itself.
class AedList {

    // Fallback duplicate threshold, used only for entries that reached
    // us without an OSM id.
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

        // Merge instead of replace: previously known AEDs that are
        // still within range survive a refresh, so the list only ever
        // gains knowledge. This matters more here than in a shop
        // finder - a cached defibrillator from ten minutes ago is
        // still a defibrillator, and losing it because a request came
        // back thin is not an acceptable failure mode. Fresh data wins
        // on duplicates.
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

    // Identity comparison, by OSM node id where one exists.
    //
    // ZabkaFinder deduplicated purely by proximity and documented the
    // consequence: two genuinely distinct shops less than 25 m apart
    // collapsed into one entry. For defibrillators that trade-off is
    // wrong - a hospital lobby and the ward next to it can each have
    // one a few metres apart, and dropping either could send someone
    // to the wrong wall. The tile format carries the OSM id precisely
    // so identity, not distance, decides.
    //
    // Ids are Strings, compared with equals(): OSM node ids exceed
    // Connect IQ's 32-bit Number, so they never become integers
    // anywhere in this app. Proximity survives only as a fallback for
    // entries whose id didn't make it through (empty string).
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

    // Re-sorts the whole list ascending by distance from (lat, lon),
    // storing the fresh distance in each entry's :dist. Must operate on
    // the internal array because menu ids are indices into it.
    // Insertion sort - at most a few dozen entries.
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

    // Returns up to `max` AEDs for the selection menu, freshly
    // re-sorted by distance from the current position (so menu ids
    // keep matching internal indices).
    function getNearest(max as Lang.Number, lat as Lang.Double, lon as Lang.Double) as Lang.Array {
        sortByDistance(lat, lon);
        var result = [] as Lang.Array;
        var count = aeds.size() < max ? aeds.size() : max;
        for (var i = 0; i < count; i++) {
            result.add(aeds[i]);
        }
        return result;
    }

    // Filters raw entries down to radiusM around (lat, lon), sorted
    // ascending by distance (insertion sort).
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
