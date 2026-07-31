import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Paces chest compressions by vibration.
//
// 110 per minute: the middle of the 100-120 window that AHA, ILCOR and
// ERC all agree on. Fixed rather than selectable, because the moment
// this screen gets opened is the worst possible moment to present a
// choice.
//
// The vibration channel carries exactly one meaning - press now. There
// is deliberately NO two-minute rescuer-change signal, even though the
// guidelines recommend swapping: a lone rescuer has nobody to swap
// with, and a second kind of buzz would only break the rhythm they are
// following. The elapsed time on screen marks those two minutes for
// anyone who looks, and costs nothing to anyone who doesn't.
//
// Nothing stops it but the user. An automatic cutoff would mean the
// metronome going quiet mid-resuscitation, which is worse than a flat
// battery.
class CprMetronome {

    const BEATS_PER_MINUTE = 110;
    const MS_PER_MINUTE = 60000;

    // Below this, treat the grid as lost rather than late. See onBeat.
    const MIN_DELAY_MS = 20;

    private var vibrator;
    private var scheduler;
    private var clock;

    private var running as Lang.Boolean = false;
    private var startedAtMs as Lang.Number = 0;
    private var beats as Lang.Number = 0;

    // Injected, so a test can drive time by hand: the entire value of
    // this class is that the rhythm stays inside 100-120 for minutes,
    // and that is not observable by using it.
    function initialize(vibrator, scheduler, clock) {
        self.vibrator = vibrator;
        self.scheduler = scheduler;
        self.clock = clock;
    }

    // When beat `index` is due, measured from the start rather than by
    // adding an interval to "now". Adding accumulates every timer
    // overshoot: at 545 ms a consistent 5 ms late costs a beat a minute,
    // which walks out of the guideline window while someone is relying
    // on it. Integer division truncates, so the grid stays exact rather
    // than compounding a rounded 545.
    function beatDeadlineMs(index as Lang.Number) as Lang.Number {
        return startedAtMs + (MS_PER_MINUTE * index) / BEATS_PER_MINUTE;
    }

    function start() as Void {
        if (running) {
            return;
        }
        running = true;
        startedAtMs = clock.now();
        beats = 0;
        onBeat();
    }

    function stop() as Void {
        if (!running) {
            return;
        }
        running = false;
        scheduler.stop();
    }

    function isRunning() as Lang.Boolean {
        return running;
    }

    function beatCount() as Lang.Number {
        return beats;
    }

    function elapsedMs() as Lang.Number {
        if (!running) {
            return 0;
        }
        return clock.now() - startedAtMs;
    }

    // "1:23". Seconds are what a second rescuer reads to know when two
    // minutes are up.
    function elapsedText() as Lang.String {
        var total = elapsedMs() / 1000;
        var minutes = total / 60;
        var seconds = total % 60;
        return minutes.toString() + (seconds < 10 ? ":0" : ":") + seconds.toString();
    }

    // Public so tests can advance the rhythm without waiting in real time.
    function onBeat() as Void {
        if (!running) {
            return;
        }
        vibrator.vibrateBeat();
        beats += 1;
        WatchUi.requestUpdate();

        var now = clock.now();
        var delay = beatDeadlineMs(beats) - now;

        if (delay < MIN_DELAY_MS) {
            // The watch stalled - a fetch, a notification, a menu - and
            // several deadlines went by while it was busy. Clamping to a
            // minimum would fire every swallowed beat back to back at
            // 20 ms until it caught up, which on a wrist is one long
            // buzz and no rhythm at all.
            //
            // So rejoin the grid HERE: move the origin so the next beat
            // falls a full interval from now. A missed beat is a missed
            // beat; the rate is what matters, and the rate resumes
            // immediately.
            delay = MS_PER_MINUTE / BEATS_PER_MINUTE;
            startedAtMs = now + delay - (MS_PER_MINUTE * beats) / BEATS_PER_MINUTE;
        }
        scheduler.start(method(:onBeat), delay);
    }
}

// System.getTimer() behind an interface, so tests can move time.
class SystemClock {
    function now() as Lang.Number {
        return System.getTimer();
    }
}
