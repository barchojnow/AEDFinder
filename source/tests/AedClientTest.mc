import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

// Unit tests for AedClient's two halves that don't touch the network:
// decoding the wire format, and deciding what a response code means.
//
// The parser is the more important of the two. It is one end of a
// contract whose other end is a Python script running in CI, and the
// slots are positional - so a field inserted, reordered or renamed on
// either side produces a payload that still parses, still has the right
// number of elements, and quietly puts opening hours where the floor
// should be. tools/test_build_tiles.py asserts the same layout from the
// generator's side; between them, a change to one end that isn't
// mirrored at the other fails somewhere.
module AedClientTest {

    // Holds the client plus whatever its callback was invoked with.
    // Monkey C can only take a Method of the enclosing class, so the
    // spy has to be the thing that owns the client.
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

        // Latitude and longitude in that order. A swap here would put
        // every Polish defibrillator in Kazakhstan, and the arrow would
        // point confidently at it.
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

    // OSM node ids passed 2^31 years ago and Connect IQ's Number is
    // 32-bit signed, so they travel as Strings end to end. Parsed as an
    // integer this id would wrap, and two unrelated defibrillators could
    // compare equal and deduplicate each other out of the list.
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

    // A truncated or null element must be skipped, not crash the widget
    // and not become a half-built entry the arrow might point at.
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
        // The raw arrays go to the callback too, because that is what
        // the cache stores - unparsed, so a restore runs through the
        // very same parser.
        if (f.lastRaw == null || (f.lastRaw as Lang.Array).size() != 1) {
            logger.error("raw entries did not reach the callback");
            return false;
        }
        return true;
    }

    // No file for a cell means the generator found no defibrillator
    // anywhere near it. That is an answer, and a correct one - reporting
    // it as an error would put the widget in a retry loop over a
    // question that is already settled.
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

    // A 200 whose body isn't a tile is a failure, not an empty tile -
    // otherwise a truncated or rewritten response would look like "no
    // defibrillators here".
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

    // The timeout timer can fire just after a real response arrived. If
    // it acted anyway it would report a failure for a request that had
    // already succeeded, and arm a backoff nothing earned.
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

    // The client must ask for the file the generator actually wrote.
    // AedTilesTest pins the grid itself against the shared fixture; this
    // checks the client is using that grid rather than one of its own.
    (:test)
    function cellKeyAgreesWithTheGrid(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        var key = f.client.cellKeyFor(52.2297d, 21.0122d);

        if (!key.equals(AedTiles.tilePath("pl", 52.2297d, 21.0122d))) {
            logger.error("client asks for " + key + ", the grid says "
                + AedTiles.tilePath("pl", 52.2297d, 21.0122d));
            return false;
        }
        if (!key.equals("pl/1044/420.json")) {
            logger.error("unexpected cell key: " + key);
            return false;
        }
        return true;
    }
}
