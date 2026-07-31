import Toybox.Attention;
import Toybox.Lang;
import Toybox.Timer;

// The two side effects ProximityAlerts needs, wrapped so tests can
// substitute fakes. The state machine decides when to buzz; these only
// carry it out, which keeps the untestable part branch-free.

class Vibrator {

    // Three patterns, distinguished by rhythm rather than length -
    // through a sleeve that is the only difference a wrist feels. On
    // this app the buzz often IS the message.

    // Found: one long pulse, so the watch can be raised already knowing
    // there is something to walk to.
    function vibrateFound() as Void {
        emit([
            new Attention.VibeProfile(75, 600)
        ]);
    }

    // Arrival: within CLOSE_DISTANCE_M - look around, not at the watch.
    function vibrateArrival() as Void {
        emit([
            new Attention.VibeProfile(100, 250),
            new Attention.VibeProfile(0, 100),
            new Attention.VibeProfile(100, 250)
        ]);
    }

    // Alert: the walking-away prompt. Deliberately the most urgent.
    function vibrateAlert() as Void {
        emit([
            new Attention.VibeProfile(100, 150),
            new Attention.VibeProfile(0, 80),
            new Attention.VibeProfile(100, 150),
            new Attention.VibeProfile(0, 80),
            new Attention.VibeProfile(100, 150)
        ]);
    }

    // Guarded: not every device has it, and users can disable it.
    private function emit(pattern as Lang.Array<Attention.VibeProfile>) as Void {
        if (Attention has :vibrate) {
            Attention.vibrate(pattern);
        }
    }
}

// One-shot timer. Starting cancels any previous, so callers can't leak
// timers by scheduling twice.
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
