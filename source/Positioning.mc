import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;

// Getting a GPS fix, and the escalation ladder for when one doesn't
// arrive.
//
// Extracted from the view because it is the one part of this app that
// cannot be unit-tested at all - it is a state machine over a device
// API whose behaviour differs per watch model and firmware, and the
// only real test is a cold start outdoors. Keeping it in its own file
// means the reasoning below sits next to the code it justifies instead
// of being buried among drawing and networking, and that the view can
// be read without it.
class Positioning {

    // How long to wait for a fix from the device's default GNSS mode
    // before escalating to an explicit multi-GNSS configuration.
    const GPS_ESCALATE_MS = 15000;
    // ...and how long to then give that configuration before giving up
    // on it and returning to the default for good.
    const GPS_DEESCALATE_MS = 25000;

    // The view's position handler. Held rather than called directly
    // because enableLocationEvents needs to be handed the same Method
    // object again on every re-registration.
    private var positionCallback;

    private var gpsTimer as Timer.Timer or Null = null;
    private var escalated as Lang.Boolean = false;
    // True once a live position event has arrived. Distinct from "we
    // have coordinates", which is also true for a seeded last-known
    // position - the escalation must react to the live GPS only.
    private var liveFix as Lang.Boolean = false;

    function initialize(callback) {
        positionCallback = callback;
    }

    // The last position the watch recorded, as [lat, lon] Doubles, or
    // null if it has none.
    //
    // Worth doing before any fix arrives: on a widget people open in a
    // hurry, this is most of the perceived speed. The cached tile for
    // roughly-here can be loaded and a list drawn while the GNSS engine
    // is still acquiring, instead of showing "searching GPS..." at
    // someone who needs an answer now.
    function lastKnownDegrees() as Lang.Array or Null {
        var info = Position.getInfo();
        if (info == null || info.position == null) {
            return null;
        }
        var seed = (info.position as Position.Location).toDegrees();
        return [seed[0].toDouble(), seed[1].toDouble()];
    }

    // Strategy: start with the device's DEFAULT positioning request and
    // escalate to an explicit multi-GNSS configuration only if no fix
    // arrives within GPS_ESCALATE_MS.
    //
    // Why this order: on modern watches the plain call can land on a
    // weak GPS-only mode, which in dense cities acquires slowly or not
    // at all. But asking for a configuration up front is riskier than it
    // looks - hasConfigurationSupport() only reports what the hardware
    // knows, not what the firmware will actually serve to a *widget*,
    // and a wrong guess means no position at all. That is exactly how
    // ZabkaFinder 1.1.1 broke Fenix 7 and Epix Pro. With dozens of
    // supported devices and no way to test them, default-first is the
    // only honest order: nobody who worked before can regress, and
    // watches that genuinely starve on the default get the better
    // constellation mix automatically.
    //
    // NOTE: the example in Garmin's own docs for this API is buggy - it
    // assigns a raw symbol instead of the Position.CONFIGURATION_*
    // constant and skips hasConfigurationSupport, which crashes on
    // device. Do not "fix" this back to match the docs.
    function start() as Void {
        escalated = false;
        liveFix = false;
        startDefault();

        // Arm the escalation only if this device has anything better to
        // offer; otherwise there is nothing to escalate to.
        if (bestConfiguration() != null) {
            armTimer(GPS_ESCALATE_MS);
        }
    }

    function stop() as Void {
        stopTimer();
        Position.enableLocationEvents(Position.LOCATION_DISABLE, positionCallback);
    }

    // Called by the view on every position event: the current mode
    // works, so there is nothing left to escalate or de-escalate.
    function noteFix() as Void {
        if (!liveFix) {
            System.println("GPS: first live fix");
        }
        liveFix = true;
        stopTimer();
    }

    // Timer callback: escalate to multi-GNSS, or - if that already
    // happened and still produced nothing - fall back to the default
    // mode and stay there. Public because Timer needs to reach it.
    function onGpsTimer() as Void {
        gpsTimer = null;
        if (liveFix) {
            return; // a real fix arrived in the meantime
        }

        // Never restart positioning while the GNSS engine is making
        // progress. Acquisition is incremental - the watch accumulates
        // satellite data over seconds - and every enableLocationEvents
        // call throws that progress away, which would make a cold start
        // WORSE, not better. Native activities never do this; they just
        // wait, which is what the GPS progress bar is showing. Only a
        // completely dead engine is worth restarting with a different
        // constellation mix.
        var info = Position.getInfo();
        if (info != null && info.accuracy != Position.QUALITY_NOT_AVAILABLE) {
            System.println("GPS: acquiring (quality " + info.accuracy + "), waiting");
            armTimer(GPS_ESCALATE_MS);
            return;
        }

        if (!escalated) {
            var config = bestConfiguration();
            if (config == null) {
                return;
            }
            escalated = true;
            Position.enableLocationEvents({
                :acquisitionType => Position.LOCATION_CONTINUOUS,
                :configuration => config
            }, positionCallback);
            System.println("GPS: no fix on default, escalating to multi-GNSS");
            armTimer(GPS_DEESCALATE_MS);
        } else {
            System.println("GPS: multi-GNSS gave no fix either, back to default");
            startDefault();
        }
    }

    private function startDefault() as Void {
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, positionCallback);
        System.println("GPS mode: device default");
    }

    // The best GNSS configuration this device reports support for, or
    // null when the configuration API isn't available at all.
    private function bestConfiguration() {
        if (!(Position has :hasConfigurationSupport)) {
            return null;
        }
        if ((Position has :CONFIGURATION_SAT_IQ)
            && Position.hasConfigurationSupport(Position.CONFIGURATION_SAT_IQ)) {
            return Position.CONFIGURATION_SAT_IQ;
        }
        if ((Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5)
            && Position.hasConfigurationSupport(Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5)) {
            return Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5;
        }
        if ((Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU)
            && Position.hasConfigurationSupport(Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU)) {
            return Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU;
        }
        return null;
    }

    private function armTimer(delayMs as Lang.Number) as Void {
        stopTimer();
        gpsTimer = new Timer.Timer();
        (gpsTimer as Timer.Timer).start(method(:onGpsTimer), delayMs, false);
    }

    private function stopTimer() as Void {
        if (gpsTimer != null) {
            (gpsTimer as Timer.Timer).stop();
            gpsTimer = null;
        }
    }
}
