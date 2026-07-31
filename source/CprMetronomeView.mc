import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// The metronome screen: a ring that flashes on the beat, the elapsed
// time, and nothing else.
//
// Deliberately sparse. Whoever is looking at this is kneeling over
// someone and counting - anything more to read is something to read
// instead of compressing.
class CprMetronomeView extends WatchUi.View {

    const REF_SIZE = 416.0f;

    private var metronome as CprMetronome;
    private var strTitle as Lang.String;
    private var strRate as Lang.String;
    private var strStopHint as Lang.String;

    function initialize(metronome as CprMetronome) {
        View.initialize();
        self.metronome = metronome;
        strTitle = WatchUi.loadResource(Rez.Strings.CprTitle) as Lang.String;
        strRate = WatchUi.loadResource(Rez.Strings.CprRate) as Lang.String;
        strStopHint = WatchUi.loadResource(Rez.Strings.CprStopHint) as Lang.String;
    }

    function onShow() as Void {
        metronome.start();
    }

    function onHide() as Void {
        metronome.stop();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var cy = dc.getHeight() / 2.0;
        var s = dc.getWidth() / REF_SIZE;

        drawTitle(dc, cx, s);
        drawBeatRing(dc, cx, cy, s);
        drawElapsed(dc, cx, cy, s);
        drawHint(dc, cx, cy, s);
    }

    private function drawTitle(dc as Graphics.Dc, cx as Lang.Float,
                               s as Lang.Float) as Void {
        var y = 44 * s;
        var font = TextFit.fitFont(dc, strTitle, 3, y, true);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, font, strTitle, Graphics.TEXT_JUSTIFY_CENTER);

        var rateY = y + dc.getFontHeight(font) * 0.95;
        var rateFont = TextFit.fitFont(dc, strRate, 4, rateY, true);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, rateY, rateFont, strRate, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Alternates on every beat rather than fading over time: onUpdate is
    // driven BY the beat, so parity is exact and free, where an
    // animation would need a second timer to chase the first.
    private function drawBeatRing(dc as Graphics.Dc, cx as Lang.Float,
                                  cy as Lang.Float, s as Lang.Float) as Void {
        var radius = 78 * s;
        var onBeat = (metronome.beatCount() % 2) == 0;

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth((6 * s).toNumber() + 1);
        dc.drawCircle(cx, cy, radius);

        if (onBeat) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(cx, cy, radius - 8 * s);
        }
    }

    private function drawElapsed(dc as Graphics.Dc, cx as Lang.Float,
                                 cy as Lang.Float, s as Lang.Float) as Void {
        var text = metronome.elapsedText();
        var onBeat = (metronome.beatCount() % 2) == 0;
        // White on the red disc, red on black: readable either way, and
        // the number stays put while the disc blinks under it.
        dc.setColor(onBeat ? Graphics.COLOR_WHITE : Graphics.COLOR_RED,
            Graphics.COLOR_TRANSPARENT);
        var font = Graphics.FONT_NUMBER_MEDIUM;
        dc.drawText(cx, cy - dc.getFontHeight(font) / 2.0, font, text,
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function drawHint(dc as Graphics.Dc, cx as Lang.Float,
                              cy as Lang.Float, s as Lang.Float) as Void {
        var y = cy + 110 * s;
        var font = TextFit.fitFont(dc, strStopHint, 4, y, false);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, font, strStopHint, Graphics.TEXT_JUSTIFY_CENTER);
    }
}

// Any button leaves. There is no pause, no settings, no confirmation:
// the only thing anyone wants from this screen besides the rhythm is
// out of it.
class CprMetronomeDelegate extends WatchUi.BehaviorDelegate {

    private var view as AedFinderView;

    function initialize(view as AedFinderView) {
        BehaviorDelegate.initialize();
        self.view = view;
    }

    function onBack() as Lang.Boolean {
        pop();
        return true;
    }

    function onSelect() as Lang.Boolean {
        pop();
        return true;
    }

    private function pop() as Void {
        view.setCovered(false);
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
