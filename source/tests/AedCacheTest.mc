import Toybox.Application;
import Toybox.Lang;
import Toybox.Test;
import Toybox.Time;

// Unit tests for the offline cache.
//
// This is the path that matters most and is hardest to notice breaking.
// Everything else in the app fails loudly - no fix, no phone, an error
// on screen. A broken cache fails silently and only when the network is
// already gone, which is exactly the situation it exists for: phone in
// a rucksack, no signal in a stairwell, flat battery. Nobody discovers
// that by using the widget normally.
//
// These tests write to real Storage in the simulator, so each one
// clears the key first and the suite leaves nothing behind.
module AedCacheTest {

    const CELL = "pl/1044/420.json";
    const OTHER_CELL = "pl/1001/398.json";

    function entry(id as Lang.String) as Lang.Array {
        return [52.23012, 21.01187, "y", 1, "0", "Recepcja", "24/7", id];
    }

    // A cache with an empty Storage behind it.
    function freshCache() as AedCache {
        var cache = new AedCache();
        Application.Storage.deleteValue(cache.STORAGE_KEY);
        return cache;
    }

    // Writes a record straight into Storage, bypassing save(), so a test
    // can construct states the API can't reach - notably a timestamp far
    // in the past, since Time.now() cannot be moved.
    function seedStorage(cache as AedCache, cellKey as Lang.String,
                         ageSeconds as Lang.Number) as Void {
        Application.Storage.setValue(cache.STORAGE_KEY, [
            {
                "k" => cellKey,
                "t" => Time.now().value() - ageSeconds,
                "a" => [entry("1")]
            }
        ]);
    }

    // --- the basic round trip ---------------------------------------------

    (:test)
    function savesAndRestoresATile(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        cache.save(CELL, [entry("111"), entry("222")]);

        var restored = cache.load(CELL);
        if (restored == null) {
            logger.error("nothing came back from a tile just saved");
            return false;
        }
        if (restored.size() != 2) {
            logger.error("expected 2 entries, got " + restored.size());
            return false;
        }
        // The wire format must survive Storage untouched, because the
        // restore path feeds it back through AedClient.parseEntries.
        var first = restored[0] as Lang.Array;
        if (!(first[7] as Lang.String).equals("111")) {
            logger.error("entry came back altered: id " + first[7]);
            return false;
        }
        return true;
    }

    (:test)
    function returnsNullWhenNothingWasEverSaved(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        if (cache.load(CELL) != null) {
            logger.error("an empty cache returned something");
            return false;
        }
        return true;
    }

    // Only the matching cell will do. A neighbour's tile covers a
    // different area, and the margin that guarantees completeness within
    // the search radius is only valid for the cell it belongs to -
    // serving it here would silently hide defibrillators.
    (:test)
    function refusesToServeAnotherCellsTile(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        cache.save(CELL, [entry("111")]);

        if (cache.load(OTHER_CELL) != null) {
            logger.error("a tile for " + CELL + " was served for " + OTHER_CELL);
            return false;
        }
        return true;
    }

    // --- expiry -------------------------------------------------------------

    (:test)
    function rejectsAnExpiredTile(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        seedStorage(cache, CELL, cache.MAX_AGE_SECONDS + 3600);

        if (cache.load(CELL) != null) {
            logger.error("a tile older than the maximum age was served");
            return false;
        }
        return true;
    }

    (:test)
    function acceptsATileJustInsideTheAgeLimit(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        seedStorage(cache, CELL, cache.MAX_AGE_SECONDS - 3600);

        if (cache.load(CELL) == null) {
            logger.error("a tile still inside the age limit was discarded");
            return false;
        }
        return true;
    }

    // A timestamp in the future means the watch's clock moved backwards
    // - a timezone change, a manual set, a sync. The age arithmetic goes
    // negative and would otherwise pass the "not too old" check.
    (:test)
    function rejectsATileFromTheFuture(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        seedStorage(cache, CELL, -86400);   // stamped a day ahead

        if (cache.load(CELL) != null) {
            logger.error("a tile stamped in the future was served");
            return false;
        }
        return true;
    }

    // --- eviction -----------------------------------------------------------

    (:test)
    function keepsAtMostMaxCells(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        var keys = [] as Lang.Array;
        for (var i = 0; i <= cache.MAX_CELLS; i++) {
            var key = "pl/1000/" + i + ".json";
            keys.add(key);
            cache.save(key, [entry(i.toString())]);
        }

        // The first one saved is the one over the limit.
        if (cache.load(keys[0] as Lang.String) != null) {
            logger.error("the oldest cell survived past MAX_CELLS");
            return false;
        }
        // ...and the most recent must still be there.
        if (cache.load(keys[keys.size() - 1] as Lang.String) == null) {
            logger.error("the newest cell was evicted");
            return false;
        }
        return true;
    }

    (:test)
    function resavingACellReplacesItRatherThanAccumulating(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        cache.save(CELL, [entry("old")]);
        cache.save(CELL, [entry("new")]);

        var restored = cache.load(CELL);
        if (restored == null || restored.size() != 1) {
            logger.error("re-saving a cell did not replace it cleanly");
            return false;
        }
        var first = restored[0] as Lang.Array;
        if (!(first[7] as Lang.String).equals("new")) {
            logger.error("the stale copy won: id " + first[7]);
            return false;
        }
        // A cell rewritten repeatedly must not eat the other slots.
        cache.save(OTHER_CELL, [entry("other")]);
        cache.save(CELL, [entry("newer")]);
        if (cache.load(OTHER_CELL) == null) {
            logger.error("rewriting one cell evicted another");
            return false;
        }
        return true;
    }

    (:test)
    function capsEntriesPerCell(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        var many = [] as Lang.Array;
        for (var i = 0; i < cache.MAX_ENTRIES_PER_CELL + 10; i++) {
            many.add(entry(i.toString()));
        }
        cache.save(CELL, many);

        var restored = cache.load(CELL);
        if (restored == null) {
            logger.error("an oversized tile was dropped entirely");
            return false;
        }
        if (restored.size() > cache.MAX_ENTRIES_PER_CELL) {
            logger.error("stored " + restored.size() + " entries, cap is "
                + cache.MAX_ENTRIES_PER_CELL);
            return false;
        }
        return true;
    }

    // --- robustness ---------------------------------------------------------

    // Storage can hold whatever a previous version wrote, or a partially
    // written value. None of it may take the widget down - the cache is
    // an optimisation and the live tile is the source of truth.
    (:test)
    function survivesAValueOfTheWrongType(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        Application.Storage.setValue(cache.STORAGE_KEY, "not an array at all");

        if (cache.load(CELL) != null) {
            logger.error("garbage in Storage was interpreted as a tile");
            return false;
        }
        // ...and the cache must recover, not stay poisoned.
        cache.save(CELL, [entry("111")]);
        if (cache.load(CELL) == null) {
            logger.error("the cache never recovered after garbage");
            return false;
        }
        return true;
    }

    (:test)
    function survivesHalfWrittenRecords(logger as Test.Logger) as Lang.Boolean {
        var cache = freshCache();
        Application.Storage.setValue(cache.STORAGE_KEY, [
            "a bare string where a record should be",
            { "k" => CELL },                          // no timestamp, no entries
            { "t" => Time.now().value(), "a" => [] }  // no key
        ]);

        if (cache.load(CELL) != null) {
            logger.error("an incomplete record was served as a tile");
            return false;
        }
        return true;
    }

    // Leaves Storage as the tests found it, so a test run doesn't hand
    // the next launch of the real widget a tile full of fixtures.
    (:test)
    function cleanup(logger as Test.Logger) as Lang.Boolean {
        Application.Storage.deleteValue((new AedCache()).STORAGE_KEY);
        return true;
    }
}
