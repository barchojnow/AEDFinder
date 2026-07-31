import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

// Persists downloaded tiles so the app still knows where the
// defibrillators are when the network doesn't - phone in a rucksack, no
// signal in a stairwell, flat battery. Yesterday's tile is still
// correct; defibrillators don't move.
//
// Stores the raw wire format, not parsed dictionaries: smaller, no
// reliance on Symbol keys surviving serialisation, and the restore path
// then runs through the same parser as the network path.
class AedCache {

    // Versioned in the name: a format change is a new key, so the old
    // value is ignored rather than migrated.
    const STORAGE_KEY = "aedTiles.v1";

    // Home, work, and wherever you are.
    const MAX_CELLS = 3;

    // A corrupted or hostile payload must not exhaust memory.
    const MAX_ENTRIES_PER_CELL = 120;

    // Long enough to be useful offline, short enough that a removed
    // device doesn't linger forever.
    const MAX_AGE_SECONDS = 30 * 24 * 3600;

    // Only the matching cell will do: the margin that guarantees
    // completeness within the search radius is valid only for the cell
    // it belongs to.
    function load(cellKey as Lang.String) as Lang.Array or Null {
        var record = findCell(readAll(), cellKey);
        if (record == null) {
            return null;
        }

        var age = Time.now().value() - (record["t"] as Lang.Number);
        // Negative means the clock moved backwards - a timezone change,
        // a manual set - and would otherwise pass the "not too old" test.
        if (age < 0 || age > MAX_AGE_SECONDS) {
            System.println("cache: " + cellKey + " expired (" + age + "s)");
            return null;
        }

        var entries = record["a"] as Lang.Array;
        System.println("cache: restored " + entries.size() + " AEDs for "
            + cellKey + ", age " + (age / 3600) + "h");
        return entries;
    }

    function save(cellKey as Lang.String, entries as Lang.Array) as Void {
        var trimmed = entries;
        if (entries.size() > MAX_ENTRIES_PER_CELL) {
            trimmed = entries.slice(0, MAX_ENTRIES_PER_CELL);
        }

        var cells = readAll();
        var kept = [] as Lang.Array;
        // Newest first; older versions of this cell dropped.
        kept.add({ "k" => cellKey, "t" => Time.now().value(), "a" => trimmed });
        for (var i = 0; i < cells.size() && kept.size() < MAX_CELLS; i++) {
            var record = cells[i] as Lang.Dictionary;
            if (!(record["k"] as Lang.String).equals(cellKey)) {
                kept.add(record);
            }
        }

        try {
            Application.Storage.setValue(STORAGE_KEY, kept);
            System.println("cache: saved " + trimmed.size() + " AEDs for "
                + cellKey + " (" + kept.size() + " cells held)");
        } catch (ex) {
            // Full or unavailable Storage must not take the app down:
            // the cache is an optimisation, the live tile is the truth.
            System.println("cache: save failed, continuing without it");
        }
    }

    private function readAll() as Lang.Array {
        try {
            var stored = Application.Storage.getValue(STORAGE_KEY);
            if (stored instanceof Lang.Array) {
                return stored as Lang.Array;
            }
        } catch (ex) {
            System.println("cache: unreadable, discarding");
        }
        return [] as Lang.Array;
    }

    private function findCell(cells as Lang.Array, cellKey as Lang.String) as Lang.Dictionary or Null {
        for (var i = 0; i < cells.size(); i++) {
            // Read, check, THEN cast. Casting on the way out of the
            // array asserts the type to the checker, which makes the
            // instanceof below always true and this guard dead code -
            // the compiler says so ("Statement is not reachable"). The
            // guard exists because Storage can hold whatever a previous
            // version, or a half-finished write, left behind.
            var raw = cells[i];
            if (!(raw instanceof Lang.Dictionary)) {
                continue;
            }
            var record = raw as Lang.Dictionary;

            var key = record["k"];
            var entries = record["a"];
            var stamp = record["t"];
            if (key == null || entries == null || stamp == null) {
                continue;
            }
            if ((key as Lang.String).equals(cellKey) && entries instanceof Lang.Array) {
                return record;
            }
        }
        return null;
    }
}
