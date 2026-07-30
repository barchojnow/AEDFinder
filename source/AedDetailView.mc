import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Everything OpenStreetMap knows about one defibrillator, on one
// screen: how far, whether you can reach it, indoors or out, which
// floor, when it's accessible, and the free-text note saying where on
// the wall it actually hangs.
//
// This screen has no counterpart in ZabkaFinder and is the main reason
// the port isn't just a rename. A shop is its own signage: you arrive,
// you see it. A defibrillator is a box that may be behind a reception
// desk, on the second floor, in a building that locks at 18:00. The
// arrow can get someone to the right postcode; only these tags get them
// to the right wall, and only in time if they read them before setting
// off rather than after.
//
// Text is laid out top-down and wrapped against the round screen's
// chord at each line's own height, so nothing clips on a 208 px
// Forerunner and nothing floats in the middle of a 454 px Fenix.
class AedDetailView extends WatchUi.View {

    const REF_SIZE = 416.0f;

    private var aed as Lang.Dictionary;
    private var distance as Lang.Float;
    private var fromCache as Lang.Boolean;

    private var strTitle as Lang.String;
    private var strAccessPublic as Lang.String;
    private var strAccessPrivate as Lang.String;
    private var strAccessCustomers as Lang.String;
    private var strAccessUnknown as Lang.String;
    private var strIndoor as Lang.String;
    private var strOutdoor as Lang.String;
    private var strLevel as Lang.String;
    private var strHours as Lang.String;
    private var strOffline as Lang.String;
    private var strUnknownLocation as Lang.String;

    function initialize(aed as Lang.Dictionary, distance as Lang.Float,
                        fromCache as Lang.Boolean) {
        View.initialize();
        self.aed = aed;
        self.distance = distance;
        self.fromCache = fromCache;

        strTitle = WatchUi.loadResource(Rez.Strings.DetailTitle) as Lang.String;
        strAccessPublic = WatchUi.loadResource(Rez.Strings.AccessPublic) as Lang.String;
        strAccessPrivate = WatchUi.loadResource(Rez.Strings.AccessPrivate) as Lang.String;
        strAccessCustomers = WatchUi.loadResource(Rez.Strings.AccessCustomers) as Lang.String;
        strAccessUnknown = WatchUi.loadResource(Rez.Strings.AccessUnknown) as Lang.String;
        strIndoor = WatchUi.loadResource(Rez.Strings.Indoor) as Lang.String;
        strOutdoor = WatchUi.loadResource(Rez.Strings.Outdoor) as Lang.String;
        strLevel = WatchUi.loadResource(Rez.Strings.Level) as Lang.String;
        strHours = WatchUi.loadResource(Rez.Strings.Hours) as Lang.String;
        strOffline = WatchUi.loadResource(Rez.Strings.Offline) as Lang.String;
        strUnknownLocation = WatchUi.loadResource(Rez.Strings.UnknownLocation) as Lang.String;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var s = dc.getWidth() / REF_SIZE;
        var y = 40.0 * s;

        // Header, small and gray - it's a label, not information.
        y = drawBlock(dc, cx, y, strTitle, Graphics.FONT_XTINY,
            Graphics.COLOR_DK_GRAY, s);

        // Distance, the one number worth reading from arm's length.
        y = drawBlock(dc, cx, y + 2 * s, distance.format("%.0f") + " m",
            Graphics.FONT_MEDIUM, Graphics.COLOR_RED, s);

        // Access, coloured by whether it stops you: green when the
        // device is public, orange when it isn't. Orange, not red - the
        // AED is still there, you just may need to ask someone.
        var access = aed[:access] as Lang.String or Null;
        var accessText = strAccessUnknown;
        var accessColor = Graphics.COLOR_LT_GRAY;
        if (access != null) {
            if (access.equals("y")) {
                accessText = strAccessPublic;
                accessColor = Graphics.COLOR_GREEN;
            } else if (access.equals("c")) {
                accessText = strAccessCustomers;
                accessColor = Graphics.COLOR_ORANGE;
            } else if (access.equals("p")) {
                accessText = strAccessPrivate;
                accessColor = Graphics.COLOR_ORANGE;
            }
        }
        y = drawBlock(dc, cx, y + 4 * s, accessText, Graphics.FONT_XTINY,
            accessColor, s);

        // Indoors/outdoors and floor, joined because they answer one
        // question: which door, then which staircase.
        var placement = "";
        var indoor = aed[:indoor];
        if (indoor != null && indoor == 1) {
            placement = strIndoor;
        } else if (indoor != null && indoor == 0) {
            placement = strOutdoor;
        }
        var level = aed[:level] as Lang.String or Null;
        if (level != null && !level.equals("")) {
            placement = placement.equals("")
                ? strLevel + level
                : placement + ", " + strLevel + level;
        }
        if (!placement.equals("")) {
            y = drawBlock(dc, cx, y + 2 * s, placement, Graphics.FONT_XTINY,
                Graphics.COLOR_WHITE, s);
        }

        var hours = aed[:hours] as Lang.String or Null;
        if (hours != null && !hours.equals("")) {
            y = drawBlock(dc, cx, y + 2 * s, strHours + " " + hours,
                Graphics.FONT_XTINY, Graphics.COLOR_WHITE, s);
        }

        // The free-text hint, last because it's the longest and the one
        // worth reading properly once you're moving.
        var loc = aed[:loc] as Lang.String or Null;
        var locText = (loc != null && !loc.equals("")) ? loc : strUnknownLocation;
        var locColor = (loc != null && !loc.equals(""))
            ? Graphics.COLOR_WHITE
            : Graphics.COLOR_DK_GRAY;
        y = drawBlock(dc, cx, y + 6 * s, locText, Graphics.FONT_XTINY, locColor, s);

        if (fromCache) {
            drawBlock(dc, cx, y + 4 * s, strOffline, Graphics.FONT_XTINY,
                Graphics.COLOR_ORANGE, s);
        }
    }

    // Draws one wrapped block starting at yTop and returns the y just
    // below it, so callers can stack blocks without tracking heights.
    private function drawBlock(dc as Graphics.Dc, cx as Lang.Float, yTop as Lang.Float,
                               text as Lang.String, font as Graphics.FontType,
                               color as Graphics.ColorType, s as Lang.Float) as Lang.Float {
        var lineHeight = dc.getFontHeight(font).toFloat();
        var y = yTop;

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var words = split(text);
        var line = "";

        for (var i = 0; i < words.size(); i++) {
            var word = words[i] as Lang.String;
            var candidate = line.equals("") ? word : line + " " + word;

            // The usable width is the chord at THIS line's height, not a
            // fixed margin: on a round screen a line near the top has
            // barely half the width of one through the middle, and text
            // sized for the middle would run off the glass up there.
            if (dc.getTextWidthInPixels(candidate, font)
                    <= TextFit.chordWidth(dc, y + lineHeight / 2.0)
                || line.equals("")) {
                line = candidate;
            } else {
                dc.drawText(cx, y, font, line, Graphics.TEXT_JUSTIFY_CENTER);
                y += lineHeight;
                line = word;
            }
        }
        if (!line.equals("")) {
            dc.drawText(cx, y, font, line, Graphics.TEXT_JUSTIFY_CENTER);
            y += lineHeight;
        }
        return y;
    }

    // Splits on spaces. Monkey C has no String.split at the API level
    // this app targets (3.1), so it's done by hand.
    private function split(text as Lang.String) as Lang.Array {
        var words = [] as Lang.Array;
        var current = "";
        var chars = text.toCharArray();

        for (var i = 0; i < chars.size(); i++) {
            var c = chars[i] as Lang.Char;
            if (c == ' ') {
                if (!current.equals("")) {
                    words.add(current);
                    current = "";
                }
            } else {
                current += c.toString();
            }
        }
        if (!current.equals("")) {
            words.add(current);
        }
        return words;
    }
}
