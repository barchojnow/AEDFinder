import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Haptic feedback state machines: the found-an-AED buzz, the one-shot
// arrival vibration (with hysteresis) and the "walking away from a
// manually picked AED" prompt with its decision timer. Owns no UI -
// the view draws the prompt and decides what happens on timeout via
// the callback passed to the constructor.
//
// Both side effects (buzzing, scheduling) are injected rather than
// called directly, so unit tests can substitute a vibrator that just
// counts calls and a scheduler whose timer the test fires by hand.
// See ProximityAlertsTest.
class ProximityAlerts {

    // Below this distance the arrival vibration fires (the view also
    // uses this threshold for the green colour and the pulsing dot).
    // 25 m rather than a store-finder's 30: an AED is a specific box
    // on a specific wall, not a shopfront you can see from across the
    // street, so "you have arrived" should mean the right building.
    const CLOSE_DISTANCE_M = 25.0;
    // The vibration re-arms only after walking back out past this
    // distance (hysteresis), so GPS jitter around the 25 m line can't
    // retrigger it over and over.
    const VIBE_REARM_DISTANCE_M = 45.0;
    // The away-event fires once the distance to the chosen AED grows
    // this much above the minimum reached since it was picked (GPS
    // noise won't produce a 75 m monotonic drift).
    const AWAY_TRIGGER_DELTA_M = 75.0;
    // How long the prompt waits for a decision before the timeout
    // callback fires (the view then auto-switches to the nearest).
    const AWAY_PROMPT_TIMEOUT_MS = 15000;

    // One-shot latch for the arrival vibration.
    private var hasVibrated as Lang.Boolean = false;
    // One-shot latch for the found buzz. Unlike the arrival latch this
    // one never re-arms: it marks the transition from "this widget
    // knows of no defibrillator" to "it knows of one", which happens
    // once per session. Re-buzzing every time a background refresh
    // retargets would train users to ignore it.
    private var hasAnnouncedFound as Lang.Boolean = false;

    // Smallest distance to the manual target since it was picked.
    private var minManualDistance as Lang.Float = 1000000.0f;
    private var awayActive as Lang.Boolean = false;
    private var awayDeadlineMs as Lang.Number = 0;

    // Invoked when the prompt times out without a decision.
    private var timeoutCallback as (Method() as Void);
    // Injected side effects (Vibrator / Scheduler in production).
    private var vibrator;
    private var scheduler;

    function initialize(onTimeout as (Method() as Void), vibrator, scheduler) {
        timeoutCallback = onTimeout;
        self.vibrator = vibrator;
        self.scheduler = scheduler;
    }

    // The first AED of the session has been located. Buzzes once so
    // the user learns there is something to walk to without having to
    // be looking at the screen when the search completes.
    function onFirstAedFound() as Void {
        if (hasAnnouncedFound) {
            return;
        }
        hasAnnouncedFound = true;
        vibrator.vibrateFound();
    }

    // Called on every GPS-driven distance update (never from redraws,
    // so nothing here can fire once per frame). suppressAway blocks
    // the away-prompt while the AED menu covers the view.
    function onDistanceUpdated(distance as Lang.Float, manualTarget as Lang.Boolean,
                               suppressAway as Lang.Boolean) as Void {
        // Arrival vibration with re-arm hysteresis.
        if (distance <= CLOSE_DISTANCE_M) {
            if (!hasVibrated) {
                hasVibrated = true;
                vibrator.vibrateArrival();
            }
        } else if (distance > VIBE_REARM_DISTANCE_M) {
            hasVibrated = false;
        }

        // Walking-away detection, only for manually picked targets.
        if (!manualTarget || awayActive || suppressAway) {
            return;
        }
        if (distance < minManualDistance) {
            minManualDistance = distance;
        } else if (distance > minManualDistance + AWAY_TRIGGER_DELTA_M) {
            startAwayPrompt();
        }
    }

    // A new navigation target: re-arm the arrival vibration.
    function onNewTarget() as Void {
        hasVibrated = false;
    }

    // An explicit pick from the menu: end any pending prompt and reset
    // the baseline ABOVE any plausible distance, so the next distance
    // update lowers it to the real one.
    function onManualPick() as Void {
        scheduler.stop();
        awayActive = false;
        minManualDistance = 1000000.0f;
    }

    function isAwayActive() as Lang.Boolean {
        return awayActive;
    }

    // Seconds left on the prompt countdown, for drawing.
    function awayRemainingSeconds() as Lang.Number {
        var remaining = (awayDeadlineMs - System.getTimer()) / 1000;
        return remaining < 0 ? 0 : remaining;
    }

    // User chose to stay with the manual target: end the event with a
    // vibration and reset the baseline to the current distance, so
    // walking away *again* re-triggers it later.
    function dismissAway(currentDistance as Lang.Float) as Void {
        if (!awayActive) {
            return;
        }
        scheduler.stop();
        awayActive = false;
        minManualDistance = currentDistance;
        vibrator.vibrateAlert();
    }

    // Full teardown for View.onHide().
    function reset() as Void {
        scheduler.stop();
        awayActive = false;
    }

    private function startAwayPrompt() as Void {
        awayActive = true;
        awayDeadlineMs = System.getTimer() + AWAY_PROMPT_TIMEOUT_MS;
        vibrator.vibrateAlert();
        scheduler.start(method(:onAwayTimerFired), AWAY_PROMPT_TIMEOUT_MS);
        WatchUi.requestUpdate();
    }

    // Timer callback: end the event audibly and let the owner decide
    // what to retarget to. Public so tests can trigger the timeout
    // without waiting 15 seconds.
    function onAwayTimerFired() as Void {
        if (!awayActive) {
            return;
        }
        awayActive = false;
        vibrator.vibrateAlert();
        timeoutCallback.invoke();
    }
}
