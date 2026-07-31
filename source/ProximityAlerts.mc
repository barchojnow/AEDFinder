import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// The haptic state machines: found, arrival, and the walking-away
// prompt. Owns no UI - the view draws the prompt and decides what
// happens on timeout via the callback.
//
// Buzzing and scheduling are injected so tests can count vibrations and
// fire the timer by hand. See ProximityAlertsTest.
class ProximityAlerts {

    // 25 m rather than a shop finder's 30: an AED is a box on a
    // specific wall, not a shopfront visible from across the street.
    const CLOSE_DISTANCE_M = 25.0;
    // Re-arm only past here, so GPS jitter around the line can't
    // retrigger the arrival buzz.
    const VIBE_REARM_DISTANCE_M = 45.0;
    // GPS noise won't produce a 75 m monotonic drift.
    const AWAY_TRIGGER_DELTA_M = 75.0;
    const AWAY_PROMPT_TIMEOUT_MS = 15000;

    private var hasVibrated as Lang.Boolean = false;
    // Never re-arms: this marks the transition from "knows of no
    // defibrillator" to "knows of one", which happens once per session.
    // Buzzing on every background retarget would train users to ignore it.
    private var hasAnnouncedFound as Lang.Boolean = false;

    private var minManualDistance as Lang.Float = 1000000.0f;
    private var awayActive as Lang.Boolean = false;
    private var awayDeadlineMs as Lang.Number = 0;

    private var timeoutCallback as (Method() as Void);
    private var vibrator;
    private var scheduler;

    function initialize(onTimeout as (Method() as Void), vibrator, scheduler) {
        timeoutCallback = onTimeout;
        self.vibrator = vibrator;
        self.scheduler = scheduler;
    }

    function onFirstAedFound() as Void {
        if (hasAnnouncedFound) {
            return;
        }
        hasAnnouncedFound = true;
        vibrator.vibrateFound();
    }

    // Called on GPS updates only, never from redraws, so nothing here
    // can fire once per frame. suppressAway blocks the prompt while a
    // subview covers the screen.
    function onDistanceUpdated(distance as Lang.Float, manualTarget as Lang.Boolean,
                               suppressAway as Lang.Boolean) as Void {
        if (distance <= CLOSE_DISTANCE_M) {
            if (!hasVibrated) {
                hasVibrated = true;
                vibrator.vibrateArrival();
            }
        } else if (distance > VIBE_REARM_DISTANCE_M) {
            hasVibrated = false;
        }

        // Only a manual pick can trigger the prompt: in automatic mode
        // the app just retargets, so there is no choice to defend.
        if (!manualTarget || awayActive || suppressAway) {
            return;
        }
        if (distance < minManualDistance) {
            minManualDistance = distance;
        } else if (distance > minManualDistance + AWAY_TRIGGER_DELTA_M) {
            startAwayPrompt();
        }
    }

    function onNewTarget() as Void {
        hasVibrated = false;
    }

    // Baseline reset ABOVE any plausible distance, so the next update
    // lowers it to the real one.
    function onManualPick() as Void {
        scheduler.stop();
        awayActive = false;
        minManualDistance = 1000000.0f;
    }

    function isAwayActive() as Lang.Boolean {
        return awayActive;
    }

    function awayRemainingSeconds() as Lang.Number {
        var remaining = (awayDeadlineMs - System.getTimer()) / 1000;
        return remaining < 0 ? 0 : remaining;
    }

    // Baseline resets to here, so walking away *again* re-triggers later.
    function dismissAway(currentDistance as Lang.Float) as Void {
        if (!awayActive) {
            return;
        }
        scheduler.stop();
        awayActive = false;
        minManualDistance = currentDistance;
        vibrator.vibrateAlert();
    }

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

    // Public so tests can trigger the timeout without waiting 15 s.
    function onAwayTimerFired() as Void {
        if (!awayActive) {
            return;
        }
        awayActive = false;
        vibrator.vibrateAlert();
        timeoutCallback.invoke();
    }
}
