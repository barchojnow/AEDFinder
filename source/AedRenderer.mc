import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

// What the main screen looks like. The view decides what is true.
//
// Kept apart so a layout tweak can't touch targeting and a targeting
// change can't quietly move the arrow: the view is logic you can reason
// about, this is offsets you can only judge on a watch.
//
// State is read back through accessors rather than passed per frame -
// onUpdate runs on every compass event. The smoothed angle is owned
// here because easing belongs to the animation, not to the target.
class AedRenderer {

    // Fraction of the remaining angle closed per redraw.
    const ANGLE_SMOOTHING = 0.25;
    // Offsets are tuned for 416x416 and scaled by width/REF_SIZE.
    const REF_SIZE = 416.0f;

    private var view as AedFinderView;
    private var displayedAngle as Lang.Float = 0.0f;

    // Loaded once: used on every redraw. Only what this file draws.
    private var strAwayTitle as Lang.String;
    private var strAwayHint as Lang.String;
    private var strOffline as Lang.String;
    private var strAccessPrivate as Lang.String;
    private var strIndoor as Lang.String;
    private var strLevel as Lang.String;

    function initialize(view as AedFinderView) {
        self.view = view;
        strAwayTitle = WatchUi.loadResource(Rez.Strings.AwayTitle) as Lang.String;
        strAwayHint = WatchUi.loadResource(Rez.Strings.AwayHint) as Lang.String;
        strOffline = WatchUi.loadResource(Rez.Strings.Offline) as Lang.String;
        strAccessPrivate = WatchUi.loadResource(Rez.Strings.AccessPrivate) as Lang.String;
        strIndoor = WatchUi.loadResource(Rez.Strings.Indoor) as Lang.String;
        strLevel = WatchUi.loadResource(Rez.Strings.Level) as Lang.String;
    }

    function draw(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var cy = dc.getHeight() / 2.0;
        var s = dc.getWidth() / REF_SIZE;

        // Top third: whichever of the three matters most right now.
        if (view.isAwayPromptActive()) {
            drawAwayPrompt(dc, cx, s);
        } else if (view.currentTarget() != null) {
            // Worth more as information than branding: an AED behind a
            // locked door at 3 a.m. is not a destination, and you
            // should learn that here rather than on arrival.
            drawTargetInfo(dc, cx, s);
        } else {
            AedLogo.draw(dc, cx, 62 * s, 62 * s, Graphics.COLOR_RED);
        }

        drawArrow(dc, cx, cy, s);
        drawStatus(dc, cx, cy, s);
    }

    // Access, placement and hours, condensed to at most two lines.
    private function drawTargetInfo(dc as Graphics.Dc, cx as Lang.Float,
                                    s as Lang.Float) as Void {
        var t = view.currentTarget() as Lang.Dictionary;

        // Only genuinely restricted access earns the orange line.
        // access=customers is NOT a barrier - in a mall or a shop that
        // is anyone who walked in, and nobody is turned away during a
        // cardiac arrest. Flagging it here would warn about a
        // non-problem while drawing attention away from the real gate,
        // which is the opening hours on the line below.
        var access = t[:access] as Lang.String or Null;
        var accessText = "";
        var accessColor = Graphics.COLOR_ORANGE;
        if (access != null && access.equals("p")) {
            accessText = strAccessPrivate;
        }

        // Line 2: where exactly, plus opening hours when tagged.
        var detail = "";
        var indoor = t[:indoor];
        var level = t[:level] as Lang.String or Null;
        if (indoor != null && indoor == 1) {
            detail = strIndoor;
            if (level != null && !level.equals("")) {
                detail += " " + strLevel + level;
            }
        }
        var hours = t[:hours] as Lang.String or Null;
        if (hours != null && !hours.equals("")) {
            detail = detail.equals("") ? hours : detail + " " + hours;
        }
        if (view.isServingFromCache()) {
            detail = detail.equals("") ? strOffline : strOffline + " " + detail;
        }

        var y = 46 * s;
        if (!accessText.equals("")) {
            var f = TextFit.fitFont(dc, accessText, 3, y, true);
            dc.setColor(accessColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, y, f, accessText, Graphics.TEXT_JUSTIFY_CENTER);
            y += dc.getFontHeight(f) * 0.9;
        }
        if (!detail.equals("")) {
            var f2 = TextFit.fitFont(dc, detail, 4, y, true);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, y, f2, detail, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Red header with a live countdown. The arrow stays visible: the
    // app keeps guiding to the manual pick until something decides.
    private function drawAwayPrompt(dc as Graphics.Dc, cx as Lang.Float,
                                    s as Lang.Float) as Void {
        // Sits lower than the logo it replaces - round screens are
        // narrow near the top.
        var titleText = strAwayTitle + view.awayRemainingSeconds() + "s";
        var titleY = 52 * s;
        var titleFont = TextFit.fitFont(dc, titleText, 2, titleY, true);

        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY, titleFont, titleText, Graphics.TEXT_JUSTIFY_CENTER);

        var hintY = 92 * s;
        var hintFont = TextFit.fitFont(dc, strAwayHint, 4, hintY, true);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, hintY, hintFont, strAwayHint, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Gray searching, red found, green close. Red because that is the
    // colour of the AED sign itself.
    private function accentColor() as Graphics.ColorType {
        if (view.currentTarget() == null) {
            return Graphics.COLOR_LT_GRAY;
        }
        if (view.currentDistance() <= view.closeDistanceM()) {
            return Graphics.COLOR_GREEN;
        }
        return Graphics.COLOR_RED;
    }


    private function drawArrow(dc as Graphics.Dc, cx as Lang.Float,
                               cy as Lang.Float, s as Lang.Float) as Void {
        var hasTarget = (view.currentTarget() != null);
        var targetAngle = 0.0f;
        if (hasTarget) {
            targetAngle = GeoMath.normalizeAngle(
                view.currentBearing() - view.currentHeading());
        }

        // Shortest angular path: removes jitter without visible lag.
        var diff = GeoMath.normalizeAngle(targetAngle - displayedAngle);
        displayedAngle = GeoMath.normalizeAngle(displayedAngle + diff * ANGLE_SMOOTHING);

        var cosA = Math.cos(displayedAngle);
        var sinA = Math.sin(displayedAngle);

        var arrowPoints = [[0, -40 * s], [20 * s, 30 * s], [0, 15 * s], [-20 * s, 30 * s]];
        // Drawn first, larger, dark: reads as a thin outline.
        var outlineScale = 1.25;

        var arrowScreen = new [4];
        var outlineScreen = new [4];

        for (var i = 0; i < 4; i++) {
            var px = arrowPoints[i][0];
            var py = arrowPoints[i][1];


            var rx = (px * cosA) - (py * sinA);
            var ry = (px * sinA) + (py * cosA);
            arrowScreen[i] = [cx + rx, cy + ry];

            var orx = (px * outlineScale * cosA) - (py * outlineScale * sinA);
            var ory = (px * outlineScale * sinA) + (py * outlineScale * cosA);
            outlineScreen[i] = [cx + orx, cy + ory];
        }

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(outlineScreen);

        // Gray until some heading exists, even once an AED is found -
        // nobody should be sent marching the wrong way. On compass-less
        // watches this doubles as a "start walking" cue.
        var arrowColor = view.isHeadingValid() ? accentColor() : Graphics.COLOR_LT_GRAY;
        dc.setColor(arrowColor, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(arrowScreen);

        if (hasTarget && view.currentDistance() <= view.closeDistanceM()) {
            drawCloseIndicator(dc, cx, cy, displayedAngle, s);
        }
    }


    private function drawCloseIndicator(dc as Graphics.Dc, cx as Lang.Float,
                                        cy as Lang.Float, angle as Lang.Float,
                                        s as Lang.Float) as Void {
        var tipX = cx + (40 * s * Math.sin(angle));
        var tipY = cy - (40 * s * Math.cos(angle));

        // From the system clock, not a timer: onUpdate already runs
        // often enough from compass events.
        var phase = System.getTimer() / 250.0;
        var pulse = (3 + 2 * Math.sin(phase)) * s;
        if (pulse < 2) {
            pulse = 2;
        }

        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(tipX, tipY, pulse);
    }

    // Shrinks until it fits the chord.
    private function drawStatus(dc as Graphics.Dc, cx as Lang.Float,
                                cy as Lang.Float, s as Lang.Float) as Void {
        // NOT FONT_NUMBER_*: digits only, and this has a " m" suffix.
        var startIdx = 1; // FONT_MEDIUM for plain messages
        var color = Graphics.COLOR_WHITE;
        if (view.currentTarget() != null) {
            startIdx = 0; // FONT_LARGE for the distance readout
            color = accentColor();
        }

        var status = view.currentStatus();
        var yTop = cy + 80 * s;
        var font = TextFit.fitFont(dc, status, startIdx, yTop, false);

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yTop, font, status, Graphics.TEXT_JUSTIFY_CENTER);
    }
}
