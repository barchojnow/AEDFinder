import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// Everything about fetching a tile lives here: building the URL, the
// watchdog timeout, retry backoff bookkeeping and parsing the payload
// into the dictionaries the rest of the app uses. The view never
// touches Communications directly.
//
// There is no search API behind this. ZabkaFinder asked Overpass, then
// Nominatim, to answer "what is near me?" at request time, and paid for
// it in latency, rate limits and - in Overpass's case - an outage that
// forced a rewrite. Here the question is answered ahead of time by
// tools/build_tiles.py, which cuts OpenAEDMap's country export into a
// grid, and the watch just fetches the one file its position names.
//
// What that buys, in the order it matters for this particular app:
//   - one request, ~1-3 KB, no query, cacheable by every CDN hop;
//   - no shared public instance to be polite to, and no usage policy
//     that a widget opened during an emergency could violate;
//   - HTTP 404 as a first-class answer meaning "nothing here", rather
//     than an error to retry;
//   - a payload small enough to keep in Storage, which is what makes
//     the app work with no phone at all.
class AedClient {

    // Backoff after a failed request, growing with each consecutive
    // failure and capped. Shorter than a shop finder's would be: the
    // user may be standing over someone who is not breathing.
    const RETRY_BASE_DELAY_MS = 3000;
    const RETRY_MAX_DELAY_MS = 20000;
    // Hard ceiling on a single request. Also shorter than ZabkaFinder's
    // 25 s, for the same reason - a stuck request should fail and
    // retry rather than hold the screen.
    const REQUEST_TIMEOUT_MS = 15000;

    // Synthetic response code passed to the callback when the watchdog
    // fires before any real response arrived.
    const TIMEOUT_RESPONSE_CODE = -999;
    // Synthetic response code meaning "the tile exists conceptually but
    // holds nothing" - i.e. HTTP 404 from Pages, which for a static
    // tile set is a legitimate answer, not a failure.
    const EMPTY_RESPONSE_CODE = 204;

    // Result callback: callback.invoke(responseCode, entries, rawEntries)
    // where entries is an Array of parsed Dictionaries on success,
    // rawEntries the untouched wire arrays (handed to the cache), and
    // both are null on failure.
    private var resultCallback;

    private var inFlight as Lang.Boolean = false;
    private var watchdogTimer as Timer.Timer or Null = null;
    private var retryCount as Lang.Number = 0;
    private var nextRetryAllowedMs as Lang.Number = 0;
    // Cell key of the request currently in flight, so the response can
    // be attributed to a cell even if the user has walked on since.
    private var pendingCell as Lang.String = "";

    function initialize(callback) {
        resultCallback = callback;
    }

    // True when it's OK to fire a new request: nothing in flight and
    // the retry backoff window has elapsed.
    function shouldRequest() as Lang.Boolean {
        return !inFlight && System.getTimer() >= nextRetryAllowedMs;
    }

    function cellKeyFor(lat as Lang.Double, lon as Lang.Double) as Lang.String {
        return AedTiles.tilePath("pl", lat, lon);
    }

    // Fetches the tile covering this position.
    function fetch(lat as Lang.Double, lon as Lang.Double) as Void {
        inFlight = true;
        pendingCell = cellKeyFor(lat, lon);

        var url = AedTiles.tileUrl("pl", lat, lon);
        System.println("tile request: " + url);

        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => {
                "User-Agent" => "AEDFinder-GarminWidget/1.0 (open-source hobby project)"
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };

        // No query parameters: the position is encoded in the path, so
        // every watch standing in the same cell requests a
        // byte-identical URL and hits the CDN's cache rather than the
        // origin.
        Communications.makeWebRequest(url, null, options, method(:onReceive));

        // Start (or restart) the watchdog: if onReceive hasn't fired
        // within REQUEST_TIMEOUT_MS, treat it as a failure so the
        // widget is never stuck on "searching" indefinitely, whatever
        // the reason the call didn't complete.
        watchdogTimer = new Timer.Timer();
        (watchdogTimer as Timer.Timer).start(method(:onRequestTimeout), REQUEST_TIMEOUT_MS, false);
    }

    function pendingCellKey() as Lang.String {
        return pendingCell;
    }

    // Stops and clears the watchdog, if one is running. Also called by
    // the view's onHide() so no timer outlives the view.
    function stopWatchdog() as Void {
        if (watchdogTimer != null) {
            (watchdogTimer as Timer.Timer).stop();
            watchdogTimer = null;
        }
    }

    function onRequestTimeout() as Void {
        if (!inFlight) {
            // The real response arrived right around the same time.
            return;
        }
        inFlight = false;
        watchdogTimer = null;
        registerFailure();
        resultCallback.invoke(TIMEOUT_RESPONSE_CODE, null, null);
    }

    // makeWebRequest callback.
    function onReceive(responseCode as Lang.Number, data as Lang.Dictionary or Null) as Void {
        stopWatchdog();
        inFlight = false;
        System.println("tile response: " + responseCode
            + ", data null? " + (data == null));

        if (responseCode == 200 && data != null) {
            // The payload is a JSON *object* ({"v":1,"a":[...]}) rather
            // than a bare array on purpose: Connect IQ's automatic JSON
            // parsing rejects a top-level array with INVALID_HTTP_BODY.
            var raw = data["a"] as Lang.Array or Null;
            if (raw == null) {
                registerFailure();
                resultCallback.invoke(responseCode, null, null);
                return;
            }
            registerSuccess();
            resultCallback.invoke(responseCode, parseEntries(raw), raw);
            return;
        }

        if (responseCode == 404) {
            // No file for this cell means the generator found no
            // defibrillator anywhere near it. That is an answer, and a
            // correct one - reporting it as an error would put the
            // widget into a retry loop over a question already settled.
            registerSuccess();
            resultCallback.invoke(EMPTY_RESPONSE_CODE, [] as Lang.Array, [] as Lang.Array);
            return;
        }

        registerFailure();
        resultCallback.invoke(responseCode, null, null);
    }

    // Converts wire arrays into the symbol-keyed dictionaries the rest
    // of the app works with. Also used for entries restored from the
    // cache, so both paths share one parser and cannot drift apart.
    //
    // Wire layout, mirrored from tools/build_tiles.py:
    //   [0] lat  [1] lon  [2] access  [3] indoor
    //   [4] level  [5] location  [6] opening hours  [7] OSM node id
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
                // Kept as a String, never a Number: OSM node ids passed
                // 2^31 years ago and no longer fit Connect IQ's 32-bit
                // Number, so parsing one as an integer would silently
                // wrap and make two different devices compare equal.
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
