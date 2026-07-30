import Toybox.Lang;

// Which way the watch is facing, from whichever of the two sources is
// trustworthy right now.
//
// Neither source is good enough alone. The magnetic compass works
// standing still but in the field it is routinely off by 90-180 degrees
// from wrist tilt and missed calibration - and an arrow confidently
// pointing the wrong way is worse than no arrow. The GPS
// course-over-ground has neither problem but is meaningless below
// walking pace, where it becomes noise. So: course while moving,
// compass while still.
//
// The awkward case is watches with no magnetometer at all (Forerunner
// 55). There the compass never reports, and rather than special-casing
// a device list, this class simply notices: a watch that has never
// delivered a magnetic heading is treated as having none, and the speed
// threshold drops so the GPS course - the only source available -
// starts driving the arrow from a gentle walk instead of a brisk one.
//
// Pure state, no Toybox dependencies beyond Lang, which is what makes
// these rules testable off-device. See HeadingSourceTest.
class HeadingSource {

    // Above this ground speed the GPS course replaces the compass.
    const GPS_MIN_SPEED_MPS = 1.0;
    // ...but when the GPS course is the only source there is, accept it
    // from a gentle walking pace.
    const NO_COMPASS_MIN_SPEED_MPS = 0.5;

    private var currentHeading as Lang.Float = 0.0f;
    // True once ANY source has delivered a direction. Until then the
    // arrow points nowhere meaningful and the view keeps it gray.
    private var valid as Lang.Boolean = false;
    // True while the GPS course is driving; blocks the noisier compass
    // callback from overwriting it mid-stride.
    private var gpsActive as Lang.Boolean = false;
    // True once the magnetometer has reported even once. Never reset:
    // it is a statement about the hardware, not about this moment.
    private var magnetometerSeen as Lang.Boolean = false;

    // A new GPS fix. Both arguments are nullable because Position.Info
    // leaves them null until the engine has enough to compute them.
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
            // Below the threshold the course is dropped, but the last
            // known heading is kept: a stale direction beats an arrow
            // snapping to north the moment you stop walking.
            gpsActive = false;
        }
    }

    // A compass reading. Only drives the arrow while the GPS course
    // isn't.
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

    function isValid() as Lang.Boolean {
        return valid;
    }

    // False on watches that have never reported a magnetic heading -
    // which, after a few seconds of runtime, means they have no compass.
    function hasCompass() as Lang.Boolean {
        return magnetometerSeen;
    }

    function isUsingGpsCourse() as Lang.Boolean {
        return gpsActive;
    }
}
