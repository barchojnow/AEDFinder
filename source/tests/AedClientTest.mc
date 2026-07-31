import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

// The two halves that don't touch the network: decoding the wire
// format, and what a response code means.
//
// The parser is one end of a contract whose other end is a Python
// script in CI, and the slots are positional - a field inserted on
// either side still parses, still has the right length, and quietly
// puts opening hours where the floor should be.
// tools/test_build_tiles.py asserts the same layout from the other end.
module AedClientTest {

    // Monkey C can only take a Method of the enclosing class, so the
    // spy has to own the client.
    class Fixture {
        var client as AedClient;
        var calls as Lang.Number = 0;
        var lastCode as Lang.Number = 0;
        var lastEntries as Lang.Array or Null = null;
        var lastRaw as Lang.Array or Null = null;

        function initialize() {
            client = new AedClient(method(:onResult));
        }

        function onResult(code as Lang.Number, entries as Lang.Array or Null,
                          raw as Lang.Array or Null) as Void {
            calls += 1;
            lastCode = code;
            lastEntries = entries;
            lastRaw = raw;
        }
    }

    // One entry in the layout tools/build_tiles.py emits:
    // [lat, lon, access, indoor, level, location, hours, osmId]
    function wireEntry() as Lang.Array {
        return [52.23012, 21.01187, "y", 1, "0",
                "Recepcja, obok windy", "24/7", "13402887651"];
    }

    // --- the wire contract -----------------------------------------------

    (:test)
    function parsesEveryFieldIntoTheRightSlot(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        var parsed = f.client.parseEntries([wireEntry()]);

        if (parsed.size() != 1) {
            logger.error("expected 1 entry, got " + parsed.size());
            return false;
        }
        var a = parsed[0] as Lang.Dictionary;
        var ok = true;

        // A swap here puts every Polish AED in Kazakhstan, with the
        // arrow pointing confidently at it.
        if ((a[:lat] as Lang.Double) < 52.2d || (a[:lat] as Lang.Double) > 52.3d) {
            logger.error("lat came out as " + a[:lat]); ok = false;
        }
        if ((a[:lon] as Lang.Double) < 21.0d || (a[:lon] as Lang.Double) > 21.1d) {
            logger.error("lon came out as " + a[:lon]); ok = false;
        }
        if (!(a[:access] as Lang.String).equals("y")) {
            logger.error("access: " + a[:access]); ok = false;
        }
        if (a[:indoor] != 1) {
            logger.error("indoor: " + a[:indoor]); ok = false;
        }
        if (!(a[:level] as Lang.String).equals("0")) {
            logger.error("level: " + a[:level]); ok = false;
        }
        if (!(a[:loc] as Lang.String).equals("Recepcja, obok windy")) {
            logger.error("loc: " + a[:loc]); ok = false;
        }
        if (!(a[:hours] as Lang.String).equals("24/7")) {
            logger.error("hours: " + a[:hours]); ok = false;
        }
        return ok;
    }

    // Strings end to end: parsed as an integer this id would wrap in
    // CIQ's 32-bit Number and two unrelated devices would compare equal.
    (:test)
    function keepsOsmIdAsAString(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        var a = (f.client.parseEntries([wireEntry()]))[0] as Lang.Dictionary;
        var id = a[:id];

        if (!(id instanceof Lang.String)) {
            logger.error("osm id is not a String: " + id);
            return false;
        }
        if (!(id as Lang.String).equals("13402887651")) {
            logger.error("osm id came out as " + id);
            return false;
        }
        return true;
    }

    // Skipped, not crashed, and not a half-built entry to point at.
    (:test)
    function skipsMalformedEntries(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        var parsed = f.client.parseEntries([
            wireEntry(),
            [52.0, 21.0],                    // truncated
            null,                            // missing entirely
            wireEntry()
        ]);

        if (parsed.size() != 2) {
            logger.error("expected the 2 good entries, got " + parsed.size());
            return false;
        }
        return true;
    }

    (:test)
    function parsesAnEmptyTile(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        if (f.client.parseEntries([]).size() != 0) {
            logger.error("an empty tile did not parse to an empty list");
            return false;
        }
        return true;
    }

    // --- what a response code means ---------------------------------------

    (:test)
    function acceptsAWellFormedTile(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.client.onReceive(200, { "v" => 1, "a" => [wireEntry()] });

        if (f.calls != 1) {
            logger.error("callback fired " + f.calls + " times");
            return false;
        }
        if (f.lastEntries == null || (f.lastEntries as Lang.Array).size() != 1) {
            logger.error("parsed entries did not reach the callback");
            return false;
        }
        // Raw arrays too: that's what the cache stores, so a restore
        // runs through the same parser.
        if (f.lastRaw == null || (f.lastRaw as Lang.Array).size() != 1) {
            logger.error("raw entries did not reach the callback");
            return false;
        }
        return true;
    }

    // The code the platform ACTUALLY delivers for a missing tile.
    // Connect IQ never surfaces the 404: the host's HTML error page
    // fails the JSON parser and the status is replaced by -400. This
    // test exists because the 404 one below passed for months while the
    // real path was unreachable - it asserted a contract Connect IQ
    // does not honour.
    (:test)
    function treatsMinus400AsAnEmptyTile(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.client.onReceive(f.client.INVALID_BODY_RESPONSE_CODE, null);

        if (f.lastCode != f.client.EMPTY_RESPONSE_CODE) {
            logger.error("-400 surfaced as code " + f.lastCode
                + " - the app would say 'no internet' for every empty cell");
            return false;
        }
        if (f.lastEntries == null || (f.lastEntries as Lang.Array).size() != 0) {
            logger.error("-400 should yield an empty list, not null");
            return false;
        }
        if (!f.client.shouldRequest()) {
            logger.error("a missing tile armed the retry backoff");
            return false;
        }
        return true;
    }

    // Kept for the simulator and any host that reports it properly.
    (:test)
    function treats404AsAnEmptyAnswerNotAnError(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.client.onReceive(404, null);

        if (f.lastCode != f.client.EMPTY_RESPONSE_CODE) {
            logger.error("404 surfaced as code " + f.lastCode);
            return false;
        }
        if (f.lastEntries == null || (f.lastEntries as Lang.Array).size() != 0) {
            logger.error("404 should yield an empty list, not null");
            return false;
        }
        // ...and it must not arm the backoff, since nothing failed.
        if (!f.client.shouldRequest()) {
            logger.error("a 404 armed the retry backoff");
            return false;
        }
        return true;
    }

    // Otherwise a rewritten response reads as "no defibrillators here".
    (:test)
    function treatsAMissingArrayAsAFailure(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.client.onReceive(200, { "v" => 1 });

        if (f.lastEntries != null) {
            logger.error("a bodyless 200 was accepted as a tile");
            return false;
        }
        return true;
    }

    (:test)
    function passesServerErrorsThrough(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.client.onReceive(503, null);

        if (f.lastCode != 503) {
            logger.error("expected 503 to reach the view, got " + f.lastCode);
            return false;
        }
        if (f.lastEntries != null) {
            logger.error("a 503 produced entries");
            return false;
        }
        return true;
    }

    // --- backoff -----------------------------------------------------------

    (:test)
    function startsWillingToRequest(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        if (!f.client.shouldRequest()) {
            logger.error("a fresh client refused to make its first request");
            return false;
        }
        return true;
    }

    (:test)
    function backoffBlocksAnImmediateRetryAfterFailure(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.client.onReceive(500, null);

        if (f.client.shouldRequest()) {
            logger.error("retried immediately after a failure - the backoff "
                + "is what keeps a dead network from becoming a busy loop");
            return false;
        }
        return true;
    }

    (:test)
    function successClearsTheBackoff(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.client.onReceive(500, null);
        f.client.onReceive(200, { "v" => 1, "a" => [wireEntry()] });

        if (!f.client.shouldRequest()) {
            logger.error("the backoff outlived the failure that caused it");
            return false;
        }
        return true;
    }

    // --- the watchdog ------------------------------------------------------

    // Firing after a real response would report a failure for a
    // request that succeeded, and arm a backoff nothing earned.
    (:test)
    function aLateWatchdogWithNothingInFlightDoesNothing(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.client.onReceive(200, { "v" => 1, "a" => [wireEntry()] });
        var callsAfterResponse = f.calls;

        f.client.onRequestTimeout();

        if (f.calls != callsAfterResponse) {
            logger.error("a late watchdog invoked the callback again");
            return false;
        }
        if (!f.client.shouldRequest()) {
            logger.error("a late watchdog armed the backoff after a success");
            return false;
        }
        return true;
    }

    // --- addressing --------------------------------------------------------

    // AedTilesTest pins the grid; this checks the client uses it rather
    // than one of its own.
    (:test)
    function cellKeyAgreesWithTheGrid(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        var key = f.client.cellKeyFor(52.2297d, 21.0122d);

        if (!key.equals(AedTiles.tilePath("pl", 52.2297d, 21.0122d))) {
            logger.error("client asks for " + key + ", the grid says "
                + AedTiles.tilePath("pl", 52.2297d, 21.0122d));
            return false;
        }
        if (!key.equals("pl/1740/700.json")) {
            logger.error("unexpected cell key: " + key);
            return false;
        }
        return true;
    }
}
