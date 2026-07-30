import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

// Everything the main screen looks like. The view decides what is true;
// this decides how it appears.
//
// The split is not only about file length. The view's remaining job -
// positions in, target out - is logic that can be reasoned about; this
// is a pile of pixel offsets that can only be judged by looking at a
// watch. Keeping them apart means a layout tweak can't touch targeting
// behaviour, and a targeting change can't quietly move the arrow.
//
// State lives on the view and is read back through accessors rather
// than passed in per frame: onUpdate runs on every compass event, and
// building an argument dictionary that often is real memory churn on a
// watch with tens of kilobytes free. The one piece of state that IS
// owned here is the smoothed arrow angle, because easing is a property
// of the animation, not of where the defibrillator is.
class AedRenderer {

    // How much of the remaining angle is closed per redraw (0..1).
    // Lower is smoother and slower, higher is snappier and jitterier.
    const ANGLE_SMOOTHING = 0.25;
    // Every pixel offset below was tuned on a 416x416 screen and is
    // scaled by dc.getWidth()/REF_SIZE, so the layout keeps its
    // proportions from a 208 px Forerunner to a 454 px Fenix.
    const REF_SIZE = 416.0f;

    private var view as AedFinderView;
    private var displayedAngle as Lang.Float = 0.0f;

    // Presentation strings, loaded once - they are used on every redraw,
    // so they must not go through loadResource each frame. Only the
    // strings this file draws live here; the view keeps the ones it
    // assigns to the status line.
    private var strAwayTitle as Lang.String;
    private var strAwayHint as Lang.String;
    private var strOffline as Lang.String;
    private var strAccessPrivate as Lang.String;
    private var strAccessCustomers as Lang.String;
    private var strIndoor as Lang.String;
    private var strLevel as Lang.String;

    function initialize(view as AedFinderView) {
        self.view = view;
        strAwayTitle = WatchUi.loadResource(Rez.Strings.AwayTitle) as Lang.String;
        strAwayHint = WatchUi.loadResource(Rez.Strings.AwayHint) as Lang.String;
        strOffline = WatchUi.loadResource(Rez.Strings.Offline) as Lang.String;
        strAccessPrivate = WatchUi.loadResource(Rez.Strings.AccessPrivate) as Lang.String;
        strAccessCustomers = WatchUi.loadResource(Rez.Strings.AccessCustomers) as Lang.String;
        strIndoor = WatchUi.loadResource(Rez.Strings.Indoor) as Lang.String;
        strLevel = WatchUi.loadResource(Rez.Strings.Level) as Lang.String;
    }

    function draw(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var cy = dc.getHeight() / 2.0;
        var s = dc.getWidth() / REF_SIZE;

        // The top third of the screen carries whichever of three things
        // matters most right now, in descending order of urgency.
        if (view.isAwayPromptActive()) {
            drawAwayPrompt(dc, cx, s);
        } else if (view.currentTarget() != null) {
            // Once there is something to walk to, that space is worth
            // more as information than as branding: public or not,
            // indoors, which floor. An AED behind a locked door at
            // 3 a.m. is not a destination, and the user should learn
            // that here rather than on arrival.
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

        // Line 1: whether you can actually get to it. Restricted access
        // is orange because it changes the decision, not just the trip.
        var access = t[:access] as Lang.String or Null;
        var accessText = "";
        var accessColor = Graphics.COLOR_LT_GRAY;
        if (access != null && access.equals("p")) {
            accessText = strAccessPrivate;
            accessColor = Graphics.COLOR_ORANGE;
        } else if (access != null && access.equals("c")) {
            accessText = strAccessCustomers;
            accessColor = Graphics.COLOR_ORANGE;
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

    // The "walking away from your chosen AED" prompt: red header with a
    // live countdown plus a hint line. The arrow and distance stay
    // visible underneath - the widget keeps guiding to the manual target
    // until the user, or the timeout, decides.
    private function drawAwayPrompt(dc as Graphics.Dc, cx as Lang.Float,
                                    s as Lang.Float) as Void {
        // Round screens are narrow near the top, so the prompt sits
        // lower than the logo it replaces, and both lines auto-fit to
        // the chord at their own height.
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

    // Colour for both the arrow and the distance readout: gray while
    // searching, red once found, bright green once close. Red rather
    // than ZabkaFinder's orange - it is the colour of the AED sign
    // itself, and of this whole category of equipment.
    private function accentColor() as Graphics.ColorType {
        if (view.currentTarget() == null) {
            return Graphics.COLOR_LT_GRAY;
        }
        if (view.currentDistance() <= view.closeDistanceM()) {
            return Graphics.COLOR_GREEN;
        }
        return Graphics.COLOR_RED;
    }

    // The direction arrow, easing towards the target angle each redraw,
    // with a dark outline for contrast and a pulsing dot at the tip once
    // we are close.
    private function drawArrow(dc as Graphics.Dc, cx as Lang.Float,
                               cy as Lang.Float, s as Lang.Float) as Void {
        var hasTarget = (view.currentTarget() != null);
        var targetAngle = 0.0f;
        if (hasTarget) {
            targetAngle = GeoMath.normalizeAngle(
                view.currentBearing() - view.currentHeading());
        }

        // Ease via the shortest angular path, which removes most of the
        // compass jitter without adding perceptible lag.
        var diff = GeoMath.normalizeAngle(targetAngle - displayedAngle);
        displayedAngle = GeoMath.normalizeAngle(displayedAngle + diff * ANGLE_SMOOTHING);

        var cosA = Math.cos(displayedAngle);
        var sinA = Math.sin(displayedAngle);

        var arrowPoints = [[0, -40 * s], [20 * s, 30 * s], [0, 15 * s], [-20 * s, 30 * s]];
        // A slightly larger copy drawn first in a dark colour, so it
        // reads as a thin outline around the coloured arrow on top.
        var outlineScale = 1.25;

        var arrowScreen = new [4];
        var outlineScreen = new [4];

        for (var i = 0; i < 4; i++) {
            var px = arrowPoints[i][0];
            var py = arrowPoints[i][1];

            // Standard 2D rotation matrix about the screen centre.
            var rx = (px * cosA) - (py * sinA);
            var ry = (px * sinA) + (py * cosA);
            arrowScreen[i] = [cx + rx, cy + ry];

            var orx = (px * outlineScale * cosA) - (py * outlineScale * sinA);
            var ory = (px * outlineScale * sinA) + (py * outlineScale * cosA);
            outlineScreen[i] = [cx + orx, cy + ory];
        }

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(outlineScreen);

        // Until a heading has arrived from either source the arrow's
        // direction is meaningless - keep it gray even once an AED has
        // been found, so nobody is sent marching the wrong way. On
        // compass-less watches this doubles as a "start walking" cue:
        // the arrow colours up as soon as movement yields a GPS course.
        var arrowColor = view.isHeadingValid() ? accentColor() : Graphics.COLOR_LT_GRAY;
        dc.setColor(arrowColor, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(arrowScreen);

        if (hasTarget && view.currentDistance() <= view.closeDistanceM()) {
            drawCloseIndicator(dc, cx, cy, displayedAngle, s);
        }
    }

    // Small pulsing dot just beyond the arrow tip, once within the close
    // distance.
    private function drawCloseIndicator(dc as Graphics.Dc, cx as Lang.Float,
                                        cy as Lang.Float, angle as Lang.Float,
                                        s as Lang.Float) as Void {
        var tipX = cx + (40 * s * Math.sin(angle));
        var tipY = cy - (40 * s * Math.cos(angle));

        // Pulse the radius from the system clock rather than a timer:
        // onUpdate already runs frequently from compass events, so an
        // extra timer would only cost battery.
        var phase = System.getTimer() / 250.0;
        var pulse = (3 + 2 * Math.sin(phase)) * s;
        if (pulse < 2) {
            pulse = 2;
        }

        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(tipX, tipY, pulse);
    }

    // The distance in a large coloured font once known, or a smaller
    // plain message otherwise, shrinking until it fits the chord.
    private function drawStatus(dc as Graphics.Dc, cx as Lang.Float,
                                cy as Lang.Float, s as Lang.Float) as Void {
        // NOT a FONT_NUMBER_* font: those carry digit glyphs only, and
        // the status includes a trailing " m" suffix.
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
