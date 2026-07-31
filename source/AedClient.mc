import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// Fetching and decoding one tile. There is no search API behind this:
// build_tiles.py answers the spatial question ahead of time, and the
// watch just fetches the file its position names. One request, no query
// string, no rate limit, and HTTP 404 as a legitimate "nothing here".
class AedClient {

    // Shorter than a shop finder's would be: the user may be standing
    // over someone who is not breathing.
    const RETRY_BASE_DELAY_MS = 3000;
    const RETRY_MAX_DELAY_MS = 20000;
    const REQUEST_TIMEOUT_MS = 15000;

    const TIMEOUT_RESPONSE_CODE = -999;
    // Our own synthetic "the cell holds nothing" code.
    const EMPTY_RESPONSE_CODE = 204;

    // Connect IQ never delivers a 404 for a JSON request. A missing file
    // returns the host's HTML error page, the JSON parser rejects it,
    // and the callback sees -400 instead - the status is lost on the way.
    // So for a static tile set, -400 is what "no such cell" looks like.
    //
    // It can also mean a genuinely malformed body, but not from this
    // origin: every tile is machine-generated and its JSON verified at
    // build time. And treating it as empty is safe even when wrong,
    // because AedList merges rather than replaces - a spurious empty
    // response cannot delete a defibrillator already known.
    const INVALID_BODY_RESPONSE_CODE = -400;

    // invoke(responseCode, entries, rawEntries) - raw goes to the cache
    // unparsed, both null on failure.
    private var resultCallback;

    private var inFlight as Lang.Boolean = false;
    private var watchdogTimer as Timer.Timer or Null = null;
    private var retryCount as Lang.Number = 0;
    private var nextRetryAllowedMs as Lang.Number = 0;
    // So a response can be attributed to a cell even if the user has
    // walked on since.
    private var pendingCell as Lang.String = "";

    function initialize(callback) {
        resultCallback = callback;
    }

    function shouldRequest() as Lang.Boolean {
        return !inFlight && System.getTimer() >= nextRetryAllowedMs;
    }

    function cellKeyFor(lat as Lang.Double, lon as Lang.Double) as Lang.String {
        return AedTiles.tilePath("pl", lat, lon);
    }

    function fetch(lat as Lang.Double, lon as Lang.Double) as Void {
        inFlight = true;
        pendingCell = cellKeyFor(lat, lon);

        var url = AedTiles.tileUrl("pl", lat, lon);
        System.println("tile request: " + url);

        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => {
                "User-Agent" => "AEDFinder/1.0 (+https://github.com/barchojnow/AEDFinder)"
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };

        // No query parameters: every watch in the same cell requests a
        // byte-identical URL and hits the CDN cache rather than origin.
        Communications.makeWebRequest(url, null, options, method(:onReceive));

        watchdogTimer = new Timer.Timer();
        (watchdogTimer as Timer.Timer).start(method(:onRequestTimeout), REQUEST_TIMEOUT_MS, false);
    }

    function pendingCellKey() as Lang.String {
        return pendingCell;
    }

    // Also called from View.onHide() so no timer outlives the view.
    function stopWatchdog() as Void {
        if (watchdogTimer != null) {
            (watchdogTimer as Timer.Timer).stop();
            watchdogTimer = null;
        }
    }

    function onRequestTimeout() as Void {
        if (!inFlight) {
            return;   // the real response arrived at about the same time
        }
        inFlight = false;
        watchdogTimer = null;
        registerFailure();
        resultCallback.invoke(TIMEOUT_RESPONSE_CODE, null, null);
    }

    function onReceive(responseCode as Lang.Number, data as Lang.Dictionary or Null) as Void {
        stopWatchdog();
        inFlight = false;
        System.println("tile response: " + responseCode
            + ", data null? " + (data == null));

        if (responseCode == 200 && data != null) {
            // The payload is an object, not a bare array: Connect IQ's
            // JSON parsing rejects a top-level array outright.
            var raw = data["a"] as Lang.Array or Null;
            if (raw == null) {
                // A 200 that isn't a tile is a failure, not an empty
                // tile - otherwise a rewritten response reads as "no
                // defibrillators here".
                registerFailure();
                resultCallback.invoke(responseCode, null, null);
                return;
            }
            registerSuccess();
            resultCallback.invoke(responseCode, parseEntries(raw), raw);
            return;
        }

        // 404 is what a well-behaved host would send and what the
        // simulator can produce; -400 is what Connect IQ actually
        // reports for the same thing over a real connection.
        if (responseCode == 404 || responseCode == INVALID_BODY_RESPONSE_CODE) {
            // An answer, and a correct one. Retrying would be a loop
            // over a settled question.
            registerSuccess();
            resultCallback.invoke(EMPTY_RESPONSE_CODE, [] as Lang.Array, [] as Lang.Array);
            return;
        }

        registerFailure();
        resultCallback.invoke(responseCode, null, null);
    }

    // Wire layout, mirrored from tools/build_tiles.py:
    //   [0] lat  [1] lon  [2] access  [3] indoor
    //   [4] level  [5] location  [6] hours  [7] OSM node id
    //
    // Also used for cached entries, so both paths share one parser.
    function parseEntries(raw as Lang.Array) as Lang.Array {
        var result = [] as Lang.Array;
        for (var i = 0; i < raw.size(); i++) {
            var e = raw[i] as Lang.Array;
            if (e == null || e.size() < 8) {
                continue;
            }
            result.add({
                :lat => e[0].toDouble(),
                :lon => e[1].toDouble(),
                :access => e[2] as Lang.String,
                :indoor => e[3] as Lang.Number,
                :level => e[4] as Lang.String,
                :loc => e[5] as Lang.String,
                :hours => e[6] as Lang.String,
                // String, never a Number: OSM ids passed 2^31 long ago
                // and would wrap in Connect IQ's 32-bit Number, making
                // two different devices compare equal.
                :id => e[7] as Lang.String
            });
        }
        return result;
    }

    function registerSuccess() as Void {
        retryCount = 0;
        nextRetryAllowedMs = 0;
    }

    private function registerFailure() as Void {
        retryCount += 1;
        var delay = RETRY_BASE_DELAY_MS * retryCount;
        if (delay > RETRY_MAX_DELAY_MS) {
            delay = RETRY_MAX_DELAY_MS;
        }
        nextRetryAllowedMs = System.getTimer() + delay;
    }
}
