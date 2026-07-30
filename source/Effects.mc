import Toybox.Attention;
import Toybox.Lang;
import Toybox.Timer;

// Thin wrappers around the two side effects ProximityAlerts needs:
// buzzing the watch and scheduling a callback. They exist so the alert
// logic can be injected with fakes in unit tests - the state machine
// decides *when* to buzz, these classes only carry it out. Keeping
// them separate also means the untestable part is a handful of lines
// with no branching, which is exactly where bugs don't hide.

class Vibrator {

    // Three distinguishable patterns, because on this app the buzz
    // often IS the message: someone glancing at a watch mid-emergency
    // should be able to tell "found one" from "you're there" from
    // "something needs your attention" without reading the screen.
    // They differ in rhythm rather than only in length, since through
    // a sleeve that is the only difference a wrist reliably feels.

    // Found: one long, calm pulse. Fires once when the first AED is
    // locked on, so the watch can be raised already knowing there is
    // something to walk to.
    function vibrateFound() as Void {
        emit([
            new Attention.VibeProfile(75, 600)
        ]);
    }

    // Arrival: short double pulse - you are within CLOSE_DISTANCE_M,
    // start looking around rather than at the watch.
    function vibrateArrival() as Void {
        emit([
            new Attention.VibeProfile(100, 250),
            new Attention.VibeProfile(0, 100),
            new Attention.VibeProfile(100, 250)
        ]);
    }

    // Alert: three quick pulses, used by the walking-away prompt.
    // Deliberately the most urgent-feeling of the three.
    function vibrateAlert() as Void {
        emit([
            new Attention.VibeProfile(100, 150),
            new Attention.VibeProfile(0, 80),
            new Attention.VibeProfile(100, 150),
            new Attention.VibeProfile(0, 80),
            new Attention.VibeProfile(100, 150)
        ]);
    }

    // Guarded with `has :vibrate`: the API isn't available on every
    // device, and the user can disable it system-wide.
    private function emit(pattern as Lang.Array<Attention.VibeProfile>) as Void {
        if (Attention has :vibrate) {
            Attention.vibrate(pattern);
        }
    }
}

// One-shot timer. Starting a new one always cancels the previous, so
// callers can't leak timers by scheduling twice.
class Scheduler {

    private var timer as Timer.Timer or Null = null;

    function start(callback as (Method() as Void), delayMs as Lang.Number) as Void {
        stop();
        timer = new Timer.Timer();
        (timer as Timer.Timer).start(callback, delayMs, false);
    }

    function stop() as Void {
        if (timer != null) {
            (timer as Timer.Timer).stop();
            timer = null;
        }
    }
}
