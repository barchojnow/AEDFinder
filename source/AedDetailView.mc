import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Everything OSM knows about one defibrillator, on one screen.
//
// No counterpart in ZabkaFinder, and the main reason the port isn't a
// rename: a shop is its own signage, a defibrillator is a box that may
// be behind a reception desk, on the second floor, in a building that
// locks at 18:00. The arrow gets you to the postcode; these tags get
// you to the wall - and only if read before setting off.
//
// Wrapped against the round screen's chord at each line's own height.
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
    private var strAttribution as Lang.String;

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
        strAttribution = WatchUi.loadResource(Rez.Strings.Attribution) as Lang.String;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var s = dc.getWidth() / REF_SIZE;
        var y = 40.0 * s;


        y = drawBlock(dc, cx, y, strTitle, Graphics.FONT_XTINY,
            Graphics.COLOR_DK_GRAY, s);


        y = drawBlock(dc, cx, y + 2 * s, distance.format("%.0f") + " m",
            Graphics.FONT_MEDIUM, Graphics.COLOR_RED, s);

        // Only `private` is a warning. `customers` is white because it
        // describes where the device lives, not whether you may take it
        // - in a mall that is anyone who walked in, and the real gate is
        // the opening hours below. Orange rather than red even for
        // private: the AED is there, you may just have to ask someone.
        var access = aed[:access] as Lang.String or Null;
        var accessText = strAccessUnknown;
        var accessColor = Graphics.COLOR_LT_GRAY;
        if (access != null) {
            if (access.equals("y")) {
                accessText = strAccessPublic;
                accessColor = Graphics.COLOR_GREEN;
            } else if (access.equals("c")) {
                accessText = strAccessCustomers;
                accessColor = Graphics.COLOR_WHITE;
            } else if (access.equals("p")) {
                accessText = strAccessPrivate;
                accessColor = Graphics.COLOR_ORANGE;
            }
        }
        y = drawBlock(dc, cx, y + 4 * s, accessText, Graphics.FONT_XTINY,
            accessColor, s);

        // Which door, then which staircase.
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

        // Longest, and the one worth reading properly once moving.
        var loc = aed[:loc] as Lang.String or Null;
        var locText = (loc != null && !loc.equals("")) ? loc : strUnknownLocation;
        var locColor = (loc != null && !loc.equals(""))
            ? Graphics.COLOR_WHITE
            : Graphics.COLOR_DK_GRAY;
        y = drawBlock(dc, cx, y + 6 * s, locText, Graphics.FONT_XTINY, locColor, s);

        if (fromCache) {
            y = drawBlock(dc, cx, y + 4 * s, strOffline, Graphics.FONT_XTINY,
                Graphics.COLOR_ORANGE, s);
        }

        // Attribution lives here rather than on the main screen. ODbL
        // wants the credit to travel with the data and this is the
        // screen that shows the most of it - while the main screen is
        // read in the first seconds of an emergency, where a licence
        // notice is just one more thing between the user and the arrow.
        //
        // Last, and only if it fits: on a 208 px watch a long location
        // note can already reach the bottom, and losing the footnote is
        // better than overprinting the sentence that tells you which
        // wall the box is on.
        var bottom = dc.getHeight() - dc.getFontHeight(Graphics.FONT_XTINY);
        if (y + 4 * s < bottom) {
            drawBlock(dc, cx, y + 4 * s, strAttribution, Graphics.FONT_XTINY,
                Graphics.COLOR_DK_GRAY, s);
        }
    }

    // Returns the y below the block, so callers can stack them.
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

            // Chord at THIS line's height: near the top a line has
            // barely half the width of one through the middle.
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

    // No String.split at API level 3.1.
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
