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

    // Found: short then long. Was one 600 ms pulse at 75%, which tested
    // badly on a wrist - a single sustained buzz has one onset to notice
    // and blends into the watch's own notifications. A wrist reads
    // rhythm and onsets, so this is now two, at full strength, with
    // unequal lengths to stay distinct from arrival's two equal ones.
    function vibrateFound() as Void {
        emit([
            new Attention.VibeProfile(100, 200),
            new Attention.VibeProfile(0, 120),
            new Attention.VibeProfile(100, 500)
        ]);
        light();
    }

    // Arrival: within CLOSE_DISTANCE_M - look around, not at the watch.
    function vibrateArrival() as Void {
        emit([
            new Attention.VibeProfile(100, 250),
            new Attention.VibeProfile(0, 100),
            new Attention.VibeProfile(100, 250)
        ]);
        light();
    }

    // Beat: the CPR metronome, ~110 times a minute for as long as
    // someone is compressing. Short and sharp on purpose - the wrist
    // needs the ONSET, not the duration, and at 545 ms apart a longer
    // pulse would start to smear into the next one. No backlight here:
    // it fires twice a second, and the screen is not what this is for.
    function vibrateBeat() as Void {
        emit([
            new Attention.VibeProfile(100, 80)
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

    // Wakes the screen for the two events worth looking at, so the buzz
    // arrives with something to see. A watch-app cannot change the
    // display timeout - only the user can, in System > Display - so on
    // an AMOLED the screen is usually off by the time an AED is found.
    //
    // try/catch, not a `has` check: devices with burn-in protection
    // throw if asked to hold the display too long, and a failed backlight
    // must never take down a navigation screen.
    private function light() as Void {
        if (!(Attention has :backlight)) {
            return;
        }
        try {
            Attention.backlight(true);
        } catch (e) {
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
