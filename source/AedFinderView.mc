import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;
import Toybox.WatchUi;

// Positions in, navigation target out. What tile to load, which
// defibrillator to point at, what the status line says.
//
// Split out by reason to change: Positioning (untestable device state
// machine), HeadingSource (pure rules, so they get tests), AedRenderer
// (pixels, judged by looking at a watch). Plus AedTiles / AedClient /
// AedCache / AedList / ProximityAlerts / GeoMath.
//
// The renderer reads state through the accessors at the bottom rather
// than being handed it: onUpdate runs on every compass event.
class AedFinderView extends WatchUi.View {

    // Below this, a "new" nearest is the one already being walked to,
    // so the arrival latch must not re-arm.
    const TARGET_CHANGE_EPSILON_M = 2.0;

    // --- State --------------------------------------------------------------

    private var status as Lang.String = "";

    // Only the ones this file assigns; the renderer owns what it draws.
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
    // Full entry, so the info line and detail view can read its tags.
    private var target as Lang.Dictionary or Null = null;

    // While a subview covers this one, onHide() keeps GPS running so
    // there's no re-acquisition after popping back.
    private var covered as Lang.Boolean = false;

    // A manual pick is never silently retargeted by a refresh.
    private var manualSelection as Lang.Boolean = false;

    // Cell key of the tile currently loaded, "" when none.
    private var loadedCell as Lang.String = "";
    // Surfaced in the UI: "yesterday's coordinates" is something the
    // user is entitled to know before running somewhere.
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

        // Show the cached tile for roughly-here while GNSS acquires.
        var seed = positioning.lastKnownDegrees();
        if (seed != null) {
            myLat = seed[0] as Lang.Double;
            myLon = seed[1] as Lang.Double;
            loadFromCache();
        }
        positioning.start();
    }

    // Set by the delegate before pushing a subview.
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

    // Only when the user enters a cell whose tile isn't loaded.
    //
    // Inside one cell the loaded tile is already provably complete - the
    // margin is wider than the search radius - so another request could
    // not return anything new. ZabkaFinder re-searched every 100 m
    // because Nominatim's answer depended on where you asked from; here
    // it cannot. An hour around a city block costs one request.
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

        // Same data the request would return, available now. The
        // request still goes out, but navigation starts immediately.
        if (!cell.equals(loadedCell)) {
            loadFromCache();
        }

        // HTTP goes through the phone; without it the request is
        // doomed. Say what to fix instead of burning retries.
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

    // What makes the app useful with the phone left at home.
    private function loadFromCache() as Void {
        if (myLat == null) {
            return;
        }
        var cell = client.cellKeyFor(myLat as Lang.Double, myLon as Lang.Double);
        var raw = cache.load(cell);
        if (raw == null) {
            return;
        }

        // Same parser as the network path.
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

        // Silent during background refreshes: an arrow still pointing
        // at a real defibrillator beats an error about a refresh.
        if (!hadTarget) {
            status = errorMessage(responseCode);
        }
        WatchUi.requestUpdate();
    }

    // Rules, not a lookup table: HTTP statuses are positive and CIQ
    // transport errors negative, so a new code needs no new release.
    private function errorMessage(responseCode as Lang.Number) as Lang.String {
        if (responseCode == client.TIMEOUT_RESPONSE_CODE) {
            return strErrTimeout;
        }
        if (responseCode == Communications.BLE_CONNECTION_UNAVAILABLE) {
            return strNoPhone;
        }
        if (responseCode < 0) {
            // Every negative code means the same to the user: paired,
            // but the request never reached the internet. "error: -300"
            // helps nobody.
            return strNoInternet;
        }
        // Positive codes describe the server, so the number is useful.
        return strErrPrefix + responseCode;
    }

    // Merges a parsed tile into the list and picks a target.
    private function adoptEntries(entries as Lang.Array, cell as Lang.String) as Void {
        if (myLat == null) {
            return;
        }
        var hadTarget = (targetLat != null);
        // Must never exceed the margin baked into the tiles.
        aedList.update(entries, myLat as Lang.Double, myLon as Lang.Double,
            AedTiles.SEARCH_RADIUS_M);
        loadedCell = cell;

        if (aedList.size() == 0) {
            return;
        }

        aedList.sortByDistance(myLat as Lang.Double, myLon as Lang.Double);
        var nearest = aedList.nearest() as Lang.Dictionary;

        if (!hadTarget) {
            // First lock of the session.
            manualSelection = false;
            setTarget(nearest);
            alerts.onFirstAedFound();
        } else if (!manualSelection) {
            // Follow the nearest, but only if it's a different device.
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

    // From position events only, never redraws, so the haptics below
    // can't fire once per frame.
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

    // --- Accessors, read by the renderer every frame -------------------------

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

    // Owned by ProximityAlerts because it also gates the vibration.
    function closeDistanceM() as Lang.Float {
        return alerts.CLOSE_DISTANCE_M;
    }
}
