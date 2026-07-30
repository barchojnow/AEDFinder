import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;
import Toybox.WatchUi;

// Main view: positions in, a navigation target out.
//
// What is left here after the refactor is the decision-making - which
// tile to load, which defibrillator to point at, what the status line
// says - and the widget lifecycle that drives it. Everything with a
// different reason to change lives elsewhere:
//
//   Positioning     - the GNSS escalation ladder. Untestable device
//                     state machine; isolated so it can't be confused
//                     with logic that is testable.
//   HeadingSource   - compass vs GPS course. Pure rules, so they get
//                     unit tests instead of field reports.
//   AedRenderer     - every pixel. Judged by looking at a watch, not by
//                     reasoning, so it must not share a file with code
//                     that is judged by reasoning.
//   AedTiles        - which static tile covers a position
//   AedClient       - fetching and parsing that tile
//   AedCache        - keeping tiles across launches, for offline use
//   AedList         - the collection: filtering, merging, sorting
//   ProximityAlerts - found/arrival buzzes and the walking-away prompt
//   GeoMath         - distance/bearing/angle math
//
// The renderer reads state back through the accessors near the bottom
// of this file rather than being handed it, because onUpdate runs on
// every compass event and per-frame allocation is not free here.
class AedFinderView extends WatchUi.View {

    // Auto-retargeting treats two AEDs closer than this to each other as
    // the same one, so the arrival latch isn't re-armed for a "new"
    // target that is the one already being walked to.
    const TARGET_CHANGE_EPSILON_M = 2.0;

    // --- State --------------------------------------------------------------

    private var status as Lang.String = "";

    // Status strings, loaded once. Only the ones this file assigns; the
    // renderer owns the ones it draws.
    private var strSearchGps as Lang.String = "";
    private var strSearchAed as Lang.String = "";
    private var strNoAed as Lang.String = "";
    private var strNoPhone as Lang.String = "";
    private var strNoInternet as Lang.String = "";
    private var strErrTimeout as Lang.String = "";
    private var strErrPrefix as Lang.String = "";

    private var distance as Lang.Float = 0.0f;
    private var aedBearing as Lang.Float = 0.0f;

    private var myLat as Lang.Double or Null = null;
    private var myLon as Lang.Double or Null = null;
    private var targetLat as Lang.Double or Null = null;
    private var targetLon as Lang.Double or Null = null;
    // The full entry for the current target, so the info line and the
    // detail view can read its tags without another lookup.
    private var target as Lang.Dictionary or Null = null;

    // True while a pushed view (AED menu or details) covers this one.
    // onHide() then keeps GPS/compass running, so distances stay fresh
    // and there's no slow re-acquisition after popping back.
    private var covered as Lang.Boolean = false;

    // True when the current target was explicitly picked from the menu.
    // Background refreshes then update the list but never silently
    // retarget the arrow away from the user's choice.
    private var manualSelection as Lang.Boolean = false;

    // Cell key of the tile currently loaded, "" when none.
    private var loadedCell as Lang.String = "";
    // True when everything known came from Storage and no successful
    // download has happened this session - surfaced in the UI, because
    // "these are yesterday's coordinates" is something the user is
    // entitled to know before running somewhere.
    private var servingFromCache as Lang.Boolean = false;

    private var client as AedClient;
    private var cache as AedCache;
    private var aedList as AedList;
    private var alerts as ProximityAlerts;
    private var positioning as Positioning;
    private var headingSource as HeadingSource;
    private var renderer as AedRenderer;

    function initialize() {
        View.initialize();
        client = new AedClient(method(:onTileResult));
        cache = new AedCache();
        aedList = new AedList();
        alerts = new ProximityAlerts(method(:onAwayAutoSwitch), new Vibrator(), new Scheduler());
        positioning = new Positioning(method(:onPosition));
        headingSource = new HeadingSource();
        renderer = new AedRenderer(self);

        strSearchGps = WatchUi.loadResource(Rez.Strings.StatusSearchingGps) as Lang.String;
        strSearchAed = WatchUi.loadResource(Rez.Strings.StatusSearchingAed) as Lang.String;
        strNoAed = WatchUi.loadResource(Rez.Strings.StatusNoAed) as Lang.String;
        strNoPhone = WatchUi.loadResource(Rez.Strings.StatusNoPhone) as Lang.String;
        strNoInternet = WatchUi.loadResource(Rez.Strings.StatusNoInternet) as Lang.String;
        strErrTimeout = WatchUi.loadResource(Rez.Strings.ErrorTimeout) as Lang.String;
        strErrPrefix = WatchUi.loadResource(Rez.Strings.ErrorPrefix) as Lang.String;
        status = strSearchGps;
    }

    // --- Lifecycle -----------------------------------------------------------

    function onShow() as Void {
        covered = false;
        Sensor.enableSensorEvents(method(:onSensorData));

        // Seed from the last known position before any fix arrives, so
        // the cached tile for roughly-here can be shown while the GNSS
        // engine is still acquiring.
        var seed = positioning.lastKnownDegrees();
        if (seed != null) {
            myLat = seed[0] as Lang.Double;
            myLon = seed[1] as Lang.Double;
            loadFromCache();
        }
        positioning.start();
    }

    // Called by the delegate right before pushing a subview, so onHide()
    // knows not to tear down GPS/sensors.
    function setCovered(value as Lang.Boolean) as Void {
        covered = value;
    }

    function onHide() as Void {
        if (covered) {
            return;
        }
        client.stopWatchdog();
        alerts.reset();
        positioning.stop();
        Sensor.enableSensorEvents(null);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        renderer.draw(dc);
    }

    // --- Sensors -------------------------------------------------------------

    function onPosition(info as Position.Info) as Void {
        var pos = info.position;
        if (pos == null) {
            return;
        }
        positioning.noteFix();

        var loc = (pos as Position.Location).toDegrees();
        myLat = loc[0].toDouble();
        myLon = loc[1].toDouble();

        headingSource.onGpsUpdate(info.speed, info.heading);

        refreshTargetGeometry();
        maybeFetchTile();
        WatchUi.requestUpdate();
    }

    function onSensorData(sensorInfo as Sensor.Info) as Void {
        headingSource.onCompassUpdate(sensorInfo.heading);
        // Redraw either way: the smoothed arrow keeps easing towards the
        // target angle between heading changes.
        WatchUi.requestUpdate();
    }

    // --- Tiles ---------------------------------------------------------------

    // Fetches a tile when, and only when, the user has entered a cell
    // whose tile isn't loaded yet.
    //
    // ZabkaFinder re-searched after 100 m of walking, throttled to once
    // per 30 s, because Nominatim's answer depended on exactly where you
    // asked from. Here it cannot: a tile covers its whole cell plus a
    // margin wider than the search radius, so while you remain in one
    // cell the loaded data is already provably complete and another
    // request could not return anything new. Crossing a cell border is
    // the only event that changes the answer - which is why an hour's
    // walk around a city block generates one request rather than forty.
    private function maybeFetchTile() as Void {
        if (myLat == null) {
            return;
        }
        var cell = client.cellKeyFor(myLat as Lang.Double, myLon as Lang.Double);
        if (cell.equals(loadedCell) && !servingFromCache) {
            return;
        }
        if (!client.shouldRequest()) {
            return;
        }

        // A cached tile for this cell is used immediately, before any
        // network attempt: it is the same data the request would return,
        // and it is available now. The request still goes out to refresh
        // it, but the user is already navigating.
        if (!cell.equals(loadedCell)) {
            loadFromCache();
        }

        // HTTP goes through the paired phone, so without a connection
        // the request is doomed to fail with -104. Say what to fix
        // instead of burning retries - unless the cache already
        // answered, in which case there is nothing to complain about.
        if (!System.getDeviceSettings().phoneConnected) {
            if (targetLat == null) {
                status = strNoPhone;
            }
            return;
        }

        if (targetLat == null) {
            status = strSearchAed;
        }
        client.fetch(myLat as Lang.Double, myLon as Lang.Double);
    }

    // Restores a persisted tile for the current cell, if there is one.
    // This is what makes the widget useful with the phone left at home.
    private function loadFromCache() as Void {
        if (myLat == null) {
            return;
        }
        var cell = client.cellKeyFor(myLat as Lang.Double, myLon as Lang.Double);
        var raw = cache.load(cell);
        if (raw == null) {
            return;
        }

        // Same parser as the network path, so a cached tile and a fresh
        // one cannot be interpreted differently.
        adoptEntries(client.parseEntries(raw), cell);
        servingFromCache = true;
    }

    // Callback from AedClient.
    function onTileResult(responseCode as Lang.Number, entries as Lang.Array or Null,
                          raw as Lang.Array or Null) as Void {
        var hadTarget = (targetLat != null);

        if (entries != null && raw != null) {
            var cell = client.pendingCellKey();
            cache.save(cell, raw);
            servingFromCache = false;
            adoptEntries(entries, cell);

            if (aedList.size() == 0 && !hadTarget) {
                status = strNoAed;
            }
            WatchUi.requestUpdate();
            return;
        }

        // Errors only surface while there is nothing to guide to; during
        // background refreshes they stay silent, because an arrow still
        // pointing at a real defibrillator is worth more than an error
        // message about a refresh nobody asked for.
        if (!hadTarget) {
            status = errorMessage(responseCode);
        }
        WatchUi.requestUpdate();
    }

    // Error messages as rules, not a lookup table. HTTP statuses are
    // positive and Connect IQ transport errors are negative, so a new
    // transport error code doesn't need a new release.
    private function errorMessage(responseCode as Lang.Number) as Lang.String {
        if (responseCode == client.TIMEOUT_RESPONSE_CODE) {
            return strErrTimeout;
        }
        if (responseCode == Communications.BLE_CONNECTION_UNAVAILABLE) {
            return strNoPhone;
        }
        if (responseCode < 0) {
            // From the user's point of view every negative code means
            // the same thing: the phone is paired but the request never
            // reached the internet - no data, airplane mode, a captive
            // portal, a BLE hiccup. Showing "error: -300" helps nobody;
            // say what to fix.
            return strNoInternet;
        }
        // Positive codes describe the server rather than the user's
        // setup, so the number is worth showing.
        return strErrPrefix + responseCode;
    }

    // Merges a parsed tile into the list and picks a target.
    private function adoptEntries(entries as Lang.Array, cell as Lang.String) as Void {
        if (myLat == null) {
            return;
        }
        var hadTarget = (targetLat != null);
        // The radius must never exceed the margin baked into the tiles
        // (AedTiles owns both numbers), or results near a cell border
        // would be silently incomplete.
        aedList.update(entries, myLat as Lang.Double, myLon as Lang.Double,
            AedTiles.SEARCH_RADIUS_M);
        loadedCell = cell;

        if (aedList.size() == 0) {
            return;
        }

        aedList.sortByDistance(myLat as Lang.Double, myLon as Lang.Double);
        var nearest = aedList.nearest() as Lang.Dictionary;

        if (!hadTarget) {
            // First lock of the session: take the nearest automatically
            // and buzz, so the watch can be raised already knowing there
            // is something to walk to.
            manualSelection = false;
            setTarget(nearest);
            alerts.onFirstAedFound();
        } else if (!manualSelection) {
            // Refresh in auto mode: follow the nearest, but only
            // retarget when it is actually a different device -
            // otherwise the arrival latch would re-arm for the one
            // already being walked to.
            var shift = GeoMath.haversineDistance(
                targetLat as Lang.Double, targetLon as Lang.Double,
                nearest[:lat] as Lang.Double, nearest[:lon] as Lang.Double);
            if (shift > TARGET_CHANGE_EPSILON_M) {
                setTarget(nearest);
            }
        }
        status = distance.format("%.0f") + " m";
    }

    // --- Target selection ----------------------------------------------------

    // Called by the menu delegate when the user picks an AED.
    function selectAed(index as Lang.Number) as Void {
        var entry = aedList.get(index);
        if (entry == null) {
            return;
        }
        manualSelection = true;
        alerts.onManualPick();
        setTarget(entry);
        WatchUi.requestUpdate();
    }

    private function setTarget(entry as Lang.Dictionary) as Void {
        target = entry;
        targetLat = entry[:lat] as Lang.Double;
        targetLon = entry[:lon] as Lang.Double;
        alerts.onNewTarget();
        refreshTargetGeometry();
    }

    // Recomputes distance and bearing to the target, then feeds the
    // fresh distance to the haptic state machines. Called from position
    // events only, never from redraws, so nothing here can fire once per
    // frame.
    private function refreshTargetGeometry() as Void {
        if (myLat == null || targetLat == null) {
            return;
        }
        var lat1 = myLat as Lang.Double;
        var lon1 = myLon as Lang.Double;
        var lat2 = targetLat as Lang.Double;
        var lon2 = targetLon as Lang.Double;

        distance = GeoMath.haversineDistance(lat1, lon1, lat2, lon2).toFloat();
        aedBearing = GeoMath.initialBearing(lat1, lon1, lat2, lon2);
        status = distance.format("%.0f") + " m";

        alerts.onDistanceUpdated(distance, manualSelection, covered);
    }

    // --- Away-prompt bridge (state lives in ProximityAlerts) ----------------

    function isAwayPromptActive() as Lang.Boolean {
        return alerts.isAwayActive();
    }

    function awayRemainingSeconds() as Lang.Number {
        return alerts.awayRemainingSeconds();
    }

    // Tap/START during the prompt: keep the user's chosen AED.
    function dismissAwayPrompt() as Void {
        alerts.dismissAway(distance);
        WatchUi.requestUpdate();
    }

    // Prompt timed out: retarget to whatever is nearest now.
    function onAwayAutoSwitch() as Void {
        if (aedList.size() > 0 && myLat != null) {
            aedList.sortByDistance(myLat as Lang.Double, myLon as Lang.Double);
            manualSelection = false;
            setTarget(aedList.nearest() as Lang.Dictionary);
        }
        WatchUi.requestUpdate();
    }

    // --- Accessors -----------------------------------------------------------
    // Read by the renderer every frame and by the delegate on input.

    function getNearestAeds(max as Lang.Number) as Lang.Array {
        if (myLat == null) {
            return [] as Lang.Array;
        }
        return aedList.getNearest(max, myLat as Lang.Double, myLon as Lang.Double);
    }

    function currentTarget() as Lang.Dictionary or Null {
        return target;
    }

    function currentDistance() as Lang.Float {
        return distance;
    }

    function currentBearing() as Lang.Float {
        return aedBearing;
    }

    function currentHeading() as Lang.Float {
        return headingSource.heading();
    }

    function isHeadingValid() as Lang.Boolean {
        return headingSource.isValid();
    }

    function currentStatus() as Lang.String {
        return status;
    }

    function isServingFromCache() as Lang.Boolean {
        return servingFromCache;
    }

    // The "you have arrived" threshold, owned by ProximityAlerts because
    // it also gates the vibration; the renderer needs it for the green
    // accent and the pulsing dot.
    function closeDistanceM() as Lang.Float {
        return alerts.CLOSE_DISTANCE_M;
    }
}
