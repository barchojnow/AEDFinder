import Toybox.Lang;
import Toybox.Test;

// The rules here are invisible from outside - a latch, a hysteresis
// band, a countdown - and the ones that matter ("exactly one buzz per
// approach") can only be checked by counting vibrations. Hence the
// injected fakes: no hardware, no waiting 15 seconds for a timer.
module ProximityAlertsTest {

    // Per kind, because the three patterns mean three different things
    // to someone not looking at the screen - counting "some vibration
    // happened" would pass while the watch said the wrong thing.
    class VibratorSpy {
        var found as Lang.Number = 0;
        var arrival as Lang.Number = 0;
        var alert as Lang.Number = 0;

        function vibrateFound() as Void { found += 1; }
        function vibrateArrival() as Void { arrival += 1; }
        function vibrateAlert() as Void { alert += 1; }
    }

    // Records the scheduled callback so the test can fire it on demand,
    // and tracks stop() so cleanup can be asserted.
    class SchedulerFake {
        var pending as (Method() as Void) or Null = null;
        var startCount as Lang.Number = 0;
        var stopCount as Lang.Number = 0;

        function start(callback as (Method() as Void), delayMs as Lang.Number) as Void {
            pending = callback;
            startCount += 1;
        }

        function stop() as Void {
            pending = null;
            stopCount += 1;
        }

        // "Advance time" to the deadline.
        function fire() as Void {
            var callback = pending;
            pending = null;
            if (callback != null) {
                callback.invoke();
            }
        }
    }

    class Fixture {
        var vibrator as VibratorSpy;
        var scheduler as SchedulerFake;
        var alerts as ProximityAlerts;
        var timedOut as Lang.Boolean = false;

        function initialize() {
            vibrator = new VibratorSpy();
            scheduler = new SchedulerFake();
            alerts = new ProximityAlerts(method(:onTimeout), vibrator, scheduler);
        }

        function onTimeout() as Void {
            timedOut = true;
        }
    }

    // --- the found buzz --------------------------------------------------

    // Firing again on every background refresh would train people to
    // ignore it, so the latch never re-arms.
    (:test)
    function foundBuzzesOncePerSession(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onFirstAedFound();
        f.alerts.onFirstAedFound();
        f.alerts.onFirstAedFound();

        if (f.vibrator.found != 1) {
            logger.error("expected exactly 1 found buzz, got " + f.vibrator.found);
            return false;
        }
        return true;
    }

    // A retarget is not a discovery: switching to a nearer AED must not
    // repeat the "found something" signal.
    (:test)
    function retargetingDoesNotRepeatTheFoundBuzz(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onFirstAedFound();
        f.alerts.onNewTarget();
        f.alerts.onFirstAedFound();

        if (f.vibrator.found != 1) {
            logger.error("expected 1 found buzz across a retarget, got "
                + f.vibrator.found);
            return false;
        }
        return true;
    }

    // --- arrival vibration ----------------------------------------------

    // The core rule: crossing the close threshold buzzes once, and
    // staying close does not buzz again on every GPS update.
    (:test)
    function arrivalBuzzesExactlyOnce(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onDistanceUpdated(120.0f, false, false);
        f.alerts.onDistanceUpdated(22.0f, false, false);   // enter the zone
        f.alerts.onDistanceUpdated(18.0f, false, false);
        f.alerts.onDistanceUpdated(9.0f, false, false);
        f.alerts.onDistanceUpdated(24.0f, false, false);

        if (f.vibrator.arrival != 1) {
            logger.error("expected exactly 1 arrival buzz, got "
                + f.vibrator.arrival);
            return false;
        }
        return true;
    }

    // GPS jitter around the threshold must not retrigger it: the latch
    // re-arms only past VIBE_REARM_DISTANCE_M, not just past
    // CLOSE_DISTANCE_M.
    (:test)
    function jitterAcrossTheThresholdDoesNotRetrigger(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onDistanceUpdated(22.0f, false, false);   // buzz
        f.alerts.onDistanceUpdated(27.0f, false, false);   // out, but inside
        f.alerts.onDistanceUpdated(23.0f, false, false);   // back in
        f.alerts.onDistanceUpdated(30.0f, false, false);   // still under re-arm
        f.alerts.onDistanceUpdated(24.0f, false, false);

        if (f.vibrator.arrival != 1) {
            logger.error("hysteresis failed: " + f.vibrator.arrival + " buzzes");
            return false;
        }
        return true;
    }

    // Walking properly away and coming back is a genuine second
    // approach and should buzz again.
    (:test)
    function walkingOutPastRearmAllowsASecondArrival(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onDistanceUpdated(20.0f, false, false);   // buzz
        f.alerts.onDistanceUpdated(90.0f, false, false);   // clearly out
        f.alerts.onDistanceUpdated(15.0f, false, false);   // buzz again

        if (f.vibrator.arrival != 2) {
            logger.error("expected 2 arrival buzzes, got " + f.vibrator.arrival);
            return false;
        }
        return true;
    }

    // --- the walking-away prompt -----------------------------------------

    // Only a manually picked target can trigger it: in automatic mode
    // the widget simply retargets, so there is no choice to defend.
    (:test)
    function autoTargetNeverRaisesTheAwayPrompt(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onDistanceUpdated(100.0f, false, false);
        f.alerts.onDistanceUpdated(400.0f, false, false);

        if (f.alerts.isAwayActive()) {
            logger.error("away prompt fired for an automatic target");
            return false;
        }
        return true;
    }

    (:test)
    function drivingAwayFromAManualPickRaisesThePrompt(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);   // baseline
        f.alerts.onDistanceUpdated(120.0f, true, false);   // +20, not enough
        f.alerts.onDistanceUpdated(200.0f, true, false);   // +100, trigger

        if (!f.alerts.isAwayActive()) {
            logger.error("away prompt did not fire after drifting 100 m");
            return false;
        }
        if (f.vibrator.alert != 1) {
            logger.error("expected 1 alert buzz, got " + f.vibrator.alert);
            return false;
        }
        if (f.scheduler.startCount != 1) {
            logger.error("expected the countdown to be scheduled once, got "
                + f.scheduler.startCount);
            return false;
        }
        return true;
    }

    // Approaching does not trigger it, however far you have come: the
    // baseline tracks the minimum, so only a genuine reversal counts.
    (:test)
    function approachingNeverRaisesThePrompt(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(900.0f, true, false);
        f.alerts.onDistanceUpdated(600.0f, true, false);
        f.alerts.onDistanceUpdated(300.0f, true, false);
        f.alerts.onDistanceUpdated(120.0f, true, false);

        if (f.alerts.isAwayActive()) {
            logger.error("away prompt fired while closing in");
            return false;
        }
        return true;
    }

    // While the menu or the detail screen covers the view, the prompt
    // must not fire behind it - the user is already choosing.
    (:test)
    function suppressedWhileASubviewCoversTheScreen(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, true);
        f.alerts.onDistanceUpdated(400.0f, true, true);

        if (f.alerts.isAwayActive()) {
            logger.error("away prompt fired while a subview was open");
            return false;
        }
        return true;
    }

    (:test)
    function dismissingEndsThePromptAndStopsTheTimer(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);
        f.alerts.onDistanceUpdated(200.0f, true, false);   // trigger

        f.alerts.dismissAway(200.0f);

        if (f.alerts.isAwayActive()) {
            logger.error("prompt still active after dismissal");
            return false;
        }
        if (f.scheduler.stopCount < 1) {
            logger.error("the countdown timer was left running");
            return false;
        }
        if (f.timedOut) {
            logger.error("the timeout callback fired despite dismissal");
            return false;
        }
        return true;
    }

    // After dismissing, the baseline resets to where you are now, so
    // continuing to walk away eventually asks again rather than never
    // asking again.
    (:test)
    function dismissingRearmsFromTheCurrentDistance(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);
        f.alerts.onDistanceUpdated(200.0f, true, false);   // trigger
        f.alerts.dismissAway(200.0f);

        f.alerts.onDistanceUpdated(210.0f, true, false);   // +10, not enough
        if (f.alerts.isAwayActive()) {
            logger.error("prompt re-fired too eagerly after dismissal");
            return false;
        }
        f.alerts.onDistanceUpdated(300.0f, true, false);   // +100 from 200
        if (!f.alerts.isAwayActive()) {
            logger.error("prompt never re-armed after dismissal");
            return false;
        }
        return true;
    }

    // The timeout is the "do nothing" path: it hands control back to
    // the view, which retargets to the nearest AED.
    (:test)
    function timeoutEndsThePromptAndNotifiesTheOwner(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);
        f.alerts.onDistanceUpdated(200.0f, true, false);   // trigger

        f.scheduler.fire();

        if (f.alerts.isAwayActive()) {
            logger.error("prompt still active after the countdown expired");
            return false;
        }
        if (!f.timedOut) {
            logger.error("the owner was never told the prompt timed out");
            return false;
        }
        // One buzz raising it, one closing it.
        if (f.vibrator.alert != 2) {
            logger.error("expected 2 alert buzzes, got " + f.vibrator.alert);
            return false;
        }
        return true;
    }

    // A stale timer firing after the prompt was already dismissed must
    // not retarget behind the user's back.
    (:test)
    function aLateTimerAfterDismissalDoesNothing(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);
        f.alerts.onDistanceUpdated(200.0f, true, false);
        f.alerts.dismissAway(200.0f);

        f.alerts.onAwayTimerFired();

        if (f.timedOut) {
            logger.error("a late timer retargeted after the user chose to stay");
            return false;
        }
        return true;
    }

    (:test)
    function resetClearsAPendingPrompt(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);
        f.alerts.onDistanceUpdated(200.0f, true, false);

        f.alerts.reset();

        if (f.alerts.isAwayActive()) {
            logger.error("reset left the prompt active");
            return false;
        }
        return true;
    }
}
