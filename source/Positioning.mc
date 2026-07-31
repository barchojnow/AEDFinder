import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;

// GPS acquisition and the escalation ladder for when no fix arrives.
// Kept separate because it is the one part of this app that cannot be
// unit-tested at all - a state machine over a device API that behaves
// differently per watch model and firmware.
class Positioning {

    const GPS_ESCALATE_MS = 15000;
    const GPS_DEESCALATE_MS = 25000;

    // Held rather than called: enableLocationEvents needs the same
    // Method object again on every re-registration.
    private var positionCallback;

    private var gpsTimer as Timer.Timer or Null = null;
    private var escalated as Lang.Boolean = false;
    // Distinct from "we have coordinates", which is also true for a
    // seeded last-known position.
    private var liveFix as Lang.Boolean = false;

    function initialize(callback) {
        positionCallback = callback;
    }

    // [lat, lon] from the last position the watch recorded, or null.
    // On an app people open in a hurry this is most of the perceived
    // speed: the cached tile can be drawn while GNSS is still acquiring.
    function lastKnownDegrees() as Lang.Array or Null {
        var info = Position.getInfo();
        if (info == null || info.position == null) {
            return null;
        }
        var seed = (info.position as Position.Location).toDegrees();
        return [seed[0].toDouble(), seed[1].toDouble()];
    }

    // Default mode first, escalating only if nothing arrives.
    //
    // Asking for a better configuration up front looks tempting but
    // hasConfigurationSupport() reports what the HARDWARE knows, not
    // what the firmware serves to this app - a wrong guess means no
    // position at all, which is how ZabkaFinder 1.1.1 broke Fenix 7 and
    // Epix Pro. Default-first can't regress anyone who worked before.
    //
    // NOTE: Garmin's own doc example for this API is buggy (raw symbol
    // instead of the CONFIGURATION_* constant, no support check) and
    // crashes on device. Don't "fix" this to match the docs.
    function start() as Void {
        escalated = false;
        liveFix = false;
        startDefault();

        if (bestConfiguration() != null) {
            armTimer(GPS_ESCALATE_MS);
        }
    }

    function stop() as Void {
        stopTimer();
        Position.enableLocationEvents(Position.LOCATION_DISABLE, positionCallback);
    }

    function noteFix() as Void {
        if (!liveFix) {
            System.println("GPS: first live fix");
        }
        liveFix = true;
        stopTimer();
    }

    // Public because Timer needs to reach it.
    function onGpsTimer() as Void {
        gpsTimer = null;
        if (liveFix) {
            return;
        }

        // Never restart while the engine is making progress: acquisition
        // is incremental and every enableLocationEvents call throws that
        // progress away, making a cold start worse. Only a completely
        // dead engine is worth a different constellation mix.
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

    // Null when this device has nothing better to escalate to.
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
