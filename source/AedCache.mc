import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

// Persists downloaded tiles in Application.Storage so the widget still
// knows where the defibrillators are when the network doesn't.
//
// This is the one feature that has no counterpart in ZabkaFinder, and
// the reason is the use case rather than the code. A shop finder that
// needs the phone is merely inconvenient; a defibrillator finder that
// needs the phone fails exactly when it matters - phone in a rucksack,
// no signal in a stairwell, flat battery, Bluetooth dropped. A tile
// that was correct yesterday is still correct today, because
// defibrillators do not move. Holding onto it costs a few kilobytes.
//
// What is stored is the raw wire format (arrays of scalars), not the
// parsed symbol-keyed dictionaries: it is smaller, it survives
// Storage's serialisation without relying on Symbol keys round-tripping,
// and it means the restore path runs through the very same parser as
// the network path, so a parsing bug cannot affect only one of them.
class AedCache {

    // Storage key. Versioned in the name, so a future format change is
    // a new key rather than a migration - the old value is simply
    // ignored and re-downloaded.
    const STORAGE_KEY = "aedTiles.v1";

    // How many cells to remember. Three covers the pattern that
    // actually occurs - home, work, and wherever you happen to be -
    // without letting Storage grow unbounded on a device that has very
    // little of it.
    const MAX_CELLS = 3;

    // Entries per cell are already bounded by the tile builder, but a
    // corrupted or hostile payload shouldn't be able to exhaust memory.
    const MAX_ENTRIES_PER_CELL = 120;

    // Tiles are rebuilt daily and defibrillators are permanent
    // fixtures, so staleness is about OSM edits, not about the data
    // going wrong. A month is long enough to be useful offline and
    // short enough that a removed device doesn't linger forever.
    const MAX_AGE_SECONDS = 30 * 24 * 3600;

    // Returns the cached raw entries for this cell, or null when there
    // is nothing usable. "Usable" means same cell and not expired -
    // a neighbouring cell's tile is deliberately not accepted, because
    // only the matching cell carries the margin that guarantees
    // completeness within the search radius.
    function load(cellKey as Lang.String) as Lang.Array or Null {
        var record = findCell(readAll(), cellKey);
        if (record == null) {
            return null;
        }

        var age = Time.now().value() - (record["t"] as Lang.Number);
        if (age < 0 || age > MAX_AGE_SECONDS) {
            System.println("cache: " + cellKey + " expired (" + age + "s)");
            return null;
        }

        var entries = record["a"] as Lang.Array;
        System.println("cache: restored " + entries.size() + " AEDs for "
            + cellKey + ", age " + (age / 3600) + "h");
        return entries;
    }

    // Stores the raw entries of a freshly downloaded tile, evicting the
    // least recently written cell once MAX_CELLS is exceeded.
    function save(cellKey as Lang.String, entries as Lang.Array) as Void {
        var trimmed = entries;
        if (entries.size() > MAX_ENTRIES_PER_CELL) {
            trimmed = entries.slice(0, MAX_ENTRIES_PER_CELL);
        }

        var cells = readAll();
        var kept = [] as Lang.Array;
        // Newest first: this cell at the front, previous versions of it
        // dropped, everything else in its existing order.
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
            // Storage being full or unavailable must never take the
            // widget down: the cache is an optimisation, the live tile
            // is the source of truth.
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
            var record = cells[i] as Lang.Dictionary;
            // Defensive: a value written by a different version, or a
            // partially written one, must not throw here.
            if (!(record instanceof Lang.Dictionary)) {
                continue;
            }
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
