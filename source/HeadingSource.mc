import Toybox.Lang;

// Which way the watch is facing. Neither source works alone: the
// compass is usable standing still but is routinely 90-180 degrees off
// from wrist tilt and missed calibration, while the GPS course has no
// such problem but is noise below walking pace. So course while moving,
// compass while still.
//
// Watches with no magnetometer (Forerunner 55) are detected rather than
// listed: one that has never reported a heading is treated as having no
// compass, and the speed threshold drops so the GPS course - its only
// source - starts driving the arrow from a gentle walk.
//
// Pure state, no Toybox dependencies, so the rules are testable
// off-device. See HeadingSourceTest.
class HeadingSource {

    const GPS_MIN_SPEED_MPS = 1.0;
    // Lower, because here the GPS course is the only source there is.
    const NO_COMPASS_MIN_SPEED_MPS = 0.5;

    private var currentHeading as Lang.Float = 0.0f;
    private var valid as Lang.Boolean = false;
    // Blocks the noisier compass from overwriting the course mid-stride.
    private var gpsActive as Lang.Boolean = false;
    // Never reset: a statement about the hardware, not about right now.
    private var magnetometerSeen as Lang.Boolean = false;

    // Both arguments are nullable - Position.Info leaves them null until
    // the engine can compute them.
    function onGpsUpdate(speed as Lang.Float or Null,
                         gpsHeading as Lang.Float or Null) as Void {
        var minSpeed = magnetometerSeen
            ? GPS_MIN_SPEED_MPS
            : NO_COMPASS_MIN_SPEED_MPS;

        if (speed != null && gpsHeading != null && speed >= minSpeed) {
            currentHeading = gpsHeading;
            gpsActive = true;
            valid = true;
        } else {
            // Keep the last heading: an arrow snapping to north the
            // moment you pause is worse than a slightly stale one.
            gpsActive = false;
        }
    }

    function onCompassUpdate(compassHeading as Lang.Float or Null) as Void {
        if (compassHeading == null) {
            return;
        }
        magnetometerSeen = true;
        if (!gpsActive) {
            currentHeading = compassHeading;
            valid = true;
        }
    }

    function heading() as Lang.Float {
        return currentHeading;
    }

    // False until some source reports; the view keeps the arrow gray
    // until then rather than pointing it somewhere plausible.
    function isValid() as Lang.Boolean {
        return valid;
    }

    function hasCompass() as Lang.Boolean {
        return magnetometerSeen;
    }

    function isUsingGpsCourse() as Lang.Boolean {
        return gpsActive;
    }
}
