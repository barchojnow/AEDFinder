import Toybox.Lang;
import Toybox.Test;

// These exist because the extraction made them possible: inlined in
// the view, the only way to check which source drove the arrow was to
// walk outside with a watch.
//
// Every rule here is a tradeoff that looks arbitrary until it's wrong -
// an arrow snapping to north when you stop, or trusting a miscalibrated
// compass while running, sends someone the wrong way.
module HeadingSourceTest {

    const NORTH = 0.0f;
    const EAST = 1.5708f;    // pi/2
    const SOUTH = 3.1416f;

    // --- validity --------------------------------------------------------

    // Until something reports, the direction is meaningless and the view
    // keeps the arrow gray rather than pointing it somewhere plausible.
    (:test)
    function startsInvalid(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        if (h.isValid()) {
            logger.error("heading claimed valid before any source reported");
            return false;
        }
        return true;
    }

    // A GPS update while standing still carries no usable course, so it
    // must not make the arrow look trustworthy.
    (:test)
    function standingStillGpsDoesNotMakeItValid(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        h.onGpsUpdate(0.0f, NORTH);
        if (h.isValid()) {
            logger.error("a stationary GPS update was accepted as a heading");
            return false;
        }
        return true;
    }

    // --- compass while standing ------------------------------------------

    (:test)
    function compassDrivesTheArrowWhenStill(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        h.onCompassUpdate(EAST);

        if (!h.isValid() || h.heading() != EAST) {
            logger.error("expected the compass heading " + EAST
                + ", got " + h.heading() + " (valid=" + h.isValid() + ")");
            return false;
        }
        return true;
    }

    // --- GPS course while walking ----------------------------------------

    // The central rule. In the field the magnetometer is routinely off
    // by 90-180 degrees from wrist tilt and missed calibration, so once
    // there is real movement the course wins.
    (:test)
    function gpsCourseOverridesTheCompassWhileWalking(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        h.onCompassUpdate(NORTH);
        h.onGpsUpdate(1.4f, EAST);      // brisk walk

        if (h.heading() != EAST) {
            logger.error("GPS course did not take over: " + h.heading());
            return false;
        }
        if (!h.isUsingGpsCourse()) {
            logger.error("isUsingGpsCourse() disagrees with the heading it returned");
            return false;
        }
        return true;
    }

    // ...and while the course is driving, a compass reading arriving
    // mid-stride must not yank the arrow back.
    (:test)
    function compassCannotOverwriteAnActiveGpsCourse(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        h.onCompassUpdate(NORTH);
        h.onGpsUpdate(1.4f, EAST);
        h.onCompassUpdate(SOUTH);       // miscalibrated compass

        if (h.heading() != EAST) {
            logger.error("the compass overwrote an active GPS course: " + h.heading());
            return false;
        }
        return true;
    }

    // Slowing down hands control back, because a course computed at
    // standstill is noise.
    (:test)
    function compassTakesOverAgainOnStopping(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        h.onCompassUpdate(NORTH);
        h.onGpsUpdate(1.4f, EAST);
        h.onGpsUpdate(0.1f, SOUTH);     // stopped; this course is junk
        h.onCompassUpdate(NORTH);

        if (h.heading() != NORTH) {
            logger.error("the compass did not regain control after stopping: "
                + h.heading());
            return false;
        }
        return true;
    }

    // Dropping below the threshold must not reset the heading. An arrow
    // that snaps to north the moment you pause is worse than a slightly
    // stale one.
    (:test)
    function keepsTheLastHeadingWhenMovementStops(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        h.onCompassUpdate(NORTH);
        h.onGpsUpdate(1.4f, EAST);
        h.onGpsUpdate(0.0f, null);      // stopped, no course at all

        if (h.heading() != EAST) {
            logger.error("the heading was reset on stopping: " + h.heading());
            return false;
        }
        if (!h.isValid()) {
            logger.error("validity was lost on stopping");
            return false;
        }
        return true;
    }

    // --- watches with no magnetometer -------------------------------------

    // Forerunner 55 and friends never report a magnetic heading. Rather
    // than carry a device list, the class notices - and drops the speed
    // threshold, because the GPS course is the only source it has.
    (:test)
    function compasslessWatchAcceptsAGentleWalk(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        // No compass update ever.
        h.onGpsUpdate(0.7f, EAST);      // gentle walk, under GPS_MIN_SPEED_MPS

        if (!h.isValid() || h.heading() != EAST) {
            logger.error("a compass-less watch rejected a gentle walking pace: "
                + h.heading() + " (valid=" + h.isValid() + ")");
            return false;
        }
        return true;
    }

    // The same 0.7 m/s on a watch that HAS a compass must be rejected,
    // because there the compass is the better source at that pace. Same
    // input, opposite outcome - which is the whole point of tracking
    // whether a magnetometer was ever seen.
    (:test)
    function compassWatchRejectsTheSameGentleWalk(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        h.onCompassUpdate(NORTH);       // this watch has a compass
        h.onGpsUpdate(0.7f, EAST);

        if (h.heading() != NORTH) {
            logger.error("a compass watch used a 0.7 m/s GPS course: " + h.heading());
            return false;
        }
        return true;
    }

    (:test)
    function reportsWhetherAMagnetometerWasEverSeen(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        if (h.hasCompass()) {
            logger.error("claimed a compass before any magnetic reading");
            return false;
        }
        h.onCompassUpdate(NORTH);
        if (!h.hasCompass()) {
            logger.error("did not register the magnetometer after a reading");
            return false;
        }
        return true;
    }

    // --- null handling ----------------------------------------------------

    // Position.Info leaves speed and heading null until the engine can
    // compute them, and Sensor.Info does the same for heading. None of
    // that may throw.
    (:test)
    function toleratesNullsFromTheDeviceApis(logger as Test.Logger) as Lang.Boolean {
        var h = new HeadingSource();
        h.onGpsUpdate(null, null);
        h.onGpsUpdate(2.0f, null);      // moving, but no course yet
        h.onGpsUpdate(null, EAST);      // course, but no speed
        h.onCompassUpdate(null);

        if (h.isValid()) {
            logger.error("a heading was accepted from entirely null input");
            return false;
        }
        return true;
    }
}
