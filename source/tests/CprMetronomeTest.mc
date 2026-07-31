import Toybox.Lang;
import Toybox.Test;

// The one thing this feature is for is a rhythm that stays inside
// 100-120 for as long as someone leans on it - and that is precisely
// what you cannot check by using it. Two minutes of drift is invisible
// to the person compressing; they just get slower and never know.
//
// So the clock is injected and driven by hand. These tests run minutes
// of metronome in milliseconds and measure the grid the beats land on.
module CprMetronomeTest {

    class VibratorSpy {
        var beats as Lang.Number = 0;
        function vibrateBeat() as Void { beats += 1; }
    }

    // Holds the requested delay too - the delay is the thing under test.
    class SchedulerFake {
        var pending as (Method() as Void) or Null = null;
        var lastDelayMs as Lang.Number = 0;
        var stopCount as Lang.Number = 0;

        function start(callback as (Method() as Void), delayMs as Lang.Number) as Void {
            pending = callback;
            lastDelayMs = delayMs;
        }

        function stop() as Void {
            pending = null;
            stopCount += 1;
        }
    }

    class ClockFake {
        var ms as Lang.Number = 100000;   // not zero: catches "assumed 0 start"
        function now() as Lang.Number { return ms; }
    }

    class Fixture {
        var vibrator as VibratorSpy;
        var scheduler as SchedulerFake;
        var clock as ClockFake;
        var metronome as CprMetronome;

        function initialize() {
            vibrator = new VibratorSpy();
            scheduler = new SchedulerFake();
            clock = new ClockFake();
            metronome = new CprMetronome(vibrator, scheduler, clock);
        }

        // Advances to exactly when the scheduler was asked to fire, then
        // fires it - a watch whose timers are perfect.
        function tick() as Void {
            clock.ms += scheduler.lastDelayMs;
            var callback = scheduler.pending;
            scheduler.pending = null;
            if (callback != null) {
                callback.invoke();
            }
        }

        // A watch that is `lateMs` slow every single time.
        function tickLate(lateMs as Lang.Number) as Void {
            clock.ms += scheduler.lastDelayMs + lateMs;
            var callback = scheduler.pending;
            scheduler.pending = null;
            if (callback != null) {
                callback.invoke();
            }
        }
    }

    // --- the rhythm itself -------------------------------------------------

    (:test)
    function beatsImmediatelyOnStart(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.metronome.start();
        if (f.vibrator.beats != 1) {
            logger.error("expected a beat the moment it started, got "
                + f.vibrator.beats);
            return false;
        }
        return true;
    }

    // The headline number. 110/min is 545.45 ms, so any single interval
    // is 545 or 546 - what matters is that 110 beats take a minute.
    (:test)
    function holdsOneHundredAndTenPerMinute(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.metronome.start();
        var startedAt = f.clock.ms;

        for (var i = 1; i < 110; i++) {
            f.tick();
        }

        var elapsed = f.clock.ms - startedAt;
        // 109 intervals of 60000/110.
        if (elapsed < 59000 || elapsed > 60000) {
            logger.error("110 beats took " + elapsed + " ms, expected ~59455");
            return false;
        }
        if (f.vibrator.beats != 110) {
            logger.error("expected 110 beats, got " + f.vibrator.beats);
            return false;
        }
        return true;
    }

    // The reason deadlines are computed from the start instead of by
    // adding an interval to "now". A watch that is consistently 8 ms
    // late would, with naive scheduling, lose almost a beat a minute and
    // keep losing it. Here the error must not accumulate at all.
    (:test)
    function aConsistentlyLateTimerDoesNotAccumulateDrift(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.metronome.start();
        var startedAt = f.clock.ms;

        // Four minutes of resuscitation, always 8 ms late.
        for (var i = 1; i < 440; i++) {
            f.tickLate(8);
        }

        var elapsed = f.clock.ms - startedAt;
        var perMinute = (440 * 60000) / elapsed;
        if (perMinute < 100 || perMinute > 120) {
            logger.error("after 4 minutes the rate was " + perMinute
                + "/min, outside the 100-120 guideline");
            return false;
        }
        // Total slip must stay near one lateness, not 439 of them.
        if (elapsed > 239455 + 200) {
            logger.error("drift accumulated: " + elapsed + " ms for 440 beats");
            return false;
        }
        return true;
    }

    // 545.45 ms cannot be represented, so individual gaps alternate
    // between 545 and 546. What must hold exactly is the total: 110
    // beats span one minute to the millisecond, because the grid is
    // computed from the start rather than by summing rounded intervals.
    (:test)
    function oneHundredAndTenBeatsSpanExactlyOneMinute(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.metronome.start();
        var base = f.metronome.beatDeadlineMs(0);

        var minutes = [1, 2, 5, 10];
        for (var i = 0; i < minutes.size(); i++) {
            var m = minutes[i] as Lang.Number;
            var span = f.metronome.beatDeadlineMs(110 * m) - base;
            if (span != 60000 * m) {
                logger.error(m + " minute(s) of beats spanned " + span
                    + " ms, expected " + (60000 * m));
                return false;
            }
        }

        // ...and no single gap strays outside the pair either side of
        // 545.45, which is what a summed-and-rounded grid would do.
        for (var n = 1; n < 300; n++) {
            var gap = f.metronome.beatDeadlineMs(n) - f.metronome.beatDeadlineMs(n - 1);
            if (gap < 545 || gap > 546) {
                logger.error("gap before beat " + n + " was " + gap + " ms");
                return false;
            }
        }
        return true;
    }

    // A stall - a fetch, a notification, a menu - leaves several
    // deadlines in the past. Catching up would fire them back to back,
    // which on a wrist is one long buzz and no rhythm at all.
    (:test)
    function aStallDoesNotProduceABurst(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.metronome.start();
        f.tick();

        // Five seconds go missing - nine beats' worth.
        f.clock.ms += 5000;
        var before = f.vibrator.beats;
        var callback = f.scheduler.pending;
        if (callback != null) {
            callback.invoke();
        }

        if (f.vibrator.beats != before + 1) {
            logger.error("a 5 s stall produced " + (f.vibrator.beats - before)
                + " beats at once");
            return false;
        }
        // The real test: the NEXT beat must be a full interval away, not
        // a clamped minimum. Clamping would machine-gun through every
        // deadline the stall swallowed.
        if (f.scheduler.lastDelayMs < 500) {
            logger.error("after the stall the next beat was scheduled in "
                + f.scheduler.lastDelayMs + " ms - it is catching up, not resuming");
            return false;
        }

        // And the rhythm is genuinely back: ten more beats at the real rate.
        var resumedAt = f.clock.ms;
        for (var i = 0; i < 10; i++) {
            f.tick();
        }
        var span = f.clock.ms - resumedAt;
        if (span < 5400 || span > 5500) {
            logger.error("ten beats after the stall took " + span
                + " ms, expected ~5455");
            return false;
        }
        return true;
    }

    // --- start and stop ----------------------------------------------------

    (:test)
    function stopSilencesItAndCancelsTheTimer(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.metronome.start();
        f.tick();
        var before = f.vibrator.beats;

        f.metronome.stop();
        if (f.metronome.isRunning()) {
            logger.error("still running after stop()");
            return false;
        }
        if (f.scheduler.stopCount == 0) {
            logger.error("the timer was left armed after stop()");
            return false;
        }

        // Nothing may beat afterwards, even if a timer somehow fires.
        f.metronome.onBeat();
        if (f.vibrator.beats != before) {
            logger.error("it beat after being stopped");
            return false;
        }
        return true;
    }

    // Reopening the screen must restart the grid, not resume an old one:
    // a stale start time would put the first beats anywhere.
    (:test)
    function restartingResetsTheGrid(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.metronome.start();
        f.tick();
        f.metronome.stop();

        f.clock.ms += 30000;
        f.metronome.start();

        if (f.metronome.beatCount() != 1) {
            logger.error("beat count carried over: " + f.metronome.beatCount());
            return false;
        }
        if (f.metronome.beatDeadlineMs(0) != f.clock.ms) {
            logger.error("the grid did not restart at the new start time");
            return false;
        }
        return true;
    }

    // Double-tapping the menu item must not run two rhythms at once.
    (:test)
    function startingTwiceDoesNotDoubleTheRhythm(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.metronome.start();
        var after = f.vibrator.beats;
        f.metronome.start();

        if (f.vibrator.beats != after) {
            logger.error("a second start() added beats");
            return false;
        }
        return true;
    }

    // --- the readout -------------------------------------------------------

    // Two minutes is when a second rescuer should take over, so the
    // seconds have to be readable at a glance and zero-padded.
    (:test)
    function elapsedReadsAsMinutesAndSeconds(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.metronome.start();

        var cases = [[0, "0:00"], [9000, "0:09"], [65000, "1:05"], [120000, "2:00"]];
        for (var i = 0; i < cases.size(); i++) {
            var c = cases[i] as Lang.Array;
            f.clock.ms = f.metronome.beatDeadlineMs(0) + (c[0] as Lang.Number);
            var got = f.metronome.elapsedText();
            if (!got.equals(c[1] as Lang.String)) {
                logger.error("at " + c[0] + " ms expected " + c[1] + ", got " + got);
                return false;
            }
        }
        return true;
    }
}
