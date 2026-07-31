import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Menu2 item ids.
//
// A module, not a class constant: Monkey C treats `const` inside a class
// as an instance member, so AedFinderDelegate.METRONOME_ITEM_ID does not
// resolve from the menu delegate that has to read it.
module MenuIds {
    // Negative, so it can never collide with an index into the AED list.
    const METRONOME = -1;
}

// Input for the main view.
//
//   START / tap   list of the 5 nearest AEDs; picking one retargets
//   MENU          details of the current target
//
// During the away prompt both are reinterpreted, as its hint line says.
// The fastest path - open, follow the arrow - needs no input at all, so
// a keypress can cost a screen without costing anyone time.
class AedFinderDelegate extends WatchUi.BehaviorDelegate {

    const MENU_MAX_ITEMS = 5;

    private var view as AedFinderView;
    private var strMenuTitle as Lang.String;
    private var strAedFallback as Lang.String;
    private var strCprTitle as Lang.String;
    private var strCprSubtitle as Lang.String;
    // Short forms, for the one menu line. The long ones are on the
    // detail screen, which has room for them.
    private var strAccessShortPrivate as Lang.String;
    private var strAccessShortCustomers as Lang.String;

    function initialize(view as AedFinderView) {
        BehaviorDelegate.initialize();
        self.view = view;
        strMenuTitle = WatchUi.loadResource(Rez.Strings.MenuTitle) as Lang.String;
        strAedFallback = WatchUi.loadResource(Rez.Strings.AedFallbackName) as Lang.String;
        strAccessShortPrivate = WatchUi.loadResource(Rez.Strings.AccessShortPrivate) as Lang.String;
        strAccessShortCustomers = WatchUi.loadResource(Rez.Strings.AccessShortCustomers) as Lang.String;
        strCprTitle = WatchUi.loadResource(Rez.Strings.CprTitle) as Lang.String;
        strCprSubtitle = WatchUi.loadResource(Rez.Strings.CprMenuSubtitle) as Lang.String;
    }

    // On touch devices a screen tap maps to the select behavior; on
    // button devices it's the START key - one handler covers both.
    function onSelect() as Lang.Boolean {
        if (view.isAwayPromptActive()) {
            view.dismissAwayPrompt();
            return true;
        }
        return openAedMenu();
    }

    // MENU (button hold on Fenix/Forerunner, long screen press on touch
    // devices).
    function onMenu() as Lang.Boolean {
        if (view.isAwayPromptActive()) {
            view.dismissAwayPrompt();
            return openAedMenu();
        }

        var target = view.currentTarget();
        if (target == null) {
            // Nothing targeted yet, so details would be empty - fall
            // through to the list, which at least explains itself.
            return openAedMenu();
        }

        view.setCovered(true);
        WatchUi.pushView(
            new AedDetailView(target, view.currentDistance(), view.isServingFromCache()),
            new AedDetailDelegate(view),
            WatchUi.SLIDE_LEFT
        );
        return true;
    }

    private function openAedMenu() as Lang.Boolean {
        var aeds = view.getNearestAeds(MENU_MAX_ITEMS);

        var menu = new WatchUi.Menu2({ :title => strMenuTitle });

        // First, above the defibrillators, which reads wrong under a
        // title that says "nearest AEDs" and is right anyway: the
        // sequence is call, compress, and only then send someone for the
        // AED. Whoever needs this needs it before they need the list,
        // and scrolling past five entries to reach it would be the one
        // place in this app where taxonomy costs seconds.
        //
        // The nearest AED is targeted automatically, so nobody reaches
        // the list by reflex - it is already the deliberate path, and
        // putting this at the top of it costs the AEDs nothing.
        menu.addItem(new WatchUi.MenuItem(
            strCprTitle, strCprSubtitle, MenuIds.METRONOME, {}
        ));

        // No early return when the list is empty any more: with no fix
        // and no tile there is still one thing here worth opening, and
        // that is exactly the situation where someone might need it.
        for (var i = 0; i < aeds.size(); i++) {
            var a = aeds[i] as Lang.Dictionary;
            // The item id is the index into the view's sorted list,
            // which selectAed() maps back to an entry.
            menu.addItem(new WatchUi.MenuItem(
                labelFor(a), subtitleFor(a), i, {}
            ));
        }

        // Keeps GPS alive so distances stay fresh behind the menu.
        view.setCovered(true);
        WatchUi.pushView(menu, new AedMenuDelegate(view), WatchUi.SLIDE_UP);
        return true;
    }

    // Where the device hangs ("przy recepcji") beats a street address
    // here - by this point you can see the street.
    //
    // Truncated because Menu2 is native: fixed size, no wrapping, so a
    // 60-character description runs off both edges. TextFit can't help,
    // it needs a Dc and this text is drawn by the system.
    private function labelFor(aed as Lang.Dictionary) as Lang.String {
        var loc = aed[:loc] as Lang.String or Null;
        if (loc == null || loc.equals("")) {
            return strAedFallback;
        }
        return shorten(loc, titleBudget());
    }

    // Distance, then what would stop you getting in. Hours before
    // access because they matter more often - a door that locks at
    // 17:00 is not a destination at 3 a.m. The tile builder already
    // stripped ":00", which is what made this line fit.
    private function subtitleFor(aed as Lang.Dictionary) as Lang.String {
        var dist = aed[:dist] as Lang.Double;
        var text = dist.format("%.0f") + " m";

        var hours = aed[:hours] as Lang.String or Null;
        if (hours != null && !hours.equals("")) {
            text += " - " + hours;
        }

        var access = aed[:access] as Lang.String or Null;
        if (access != null && access.equals("p")) {
            text += " - " + strAccessShortPrivate;
        } else if (access != null && access.equals("c")) {
            text += " - " + strAccessShortCustomers;
        }
        return shorten(text, subtitleBudget());
    }

    // Characters per menu line. Divisors are empirical - Menu2 gives no
    // way to measure its font - and deliberately pessimistic.
    private function titleBudget() as Lang.Number {
        return System.getDeviceSettings().screenWidth / 18;
    }

    private function subtitleBudget() as Lang.Number {
        return System.getDeviceSettings().screenWidth / 11;
    }

    // Cuts on a word boundary when one is close to the limit.
    private function shorten(text as Lang.String, maxChars as Lang.Number) as Lang.String {
        if (text.length() <= maxChars) {
            return text;
        }
        if (maxChars <= 4) {
            return text.substring(0, maxChars) as Lang.String;
        }

        var cut = maxChars - 3;
        var chars = text.toCharArray();
        // Give up quickly rather than cutting a long word to nothing.
        for (var i = cut; i > cut - 8 && i > 0; i--) {
            if (chars[i] == ' ') {
                cut = i;
                break;
            }
        }
        // Three dots, not U+2026: glyph coverage varies across Garmin
        // fonts, same reason the tile builder folds diacritics.
        return (text.substring(0, cut) as Lang.String) + "...";
    }
}

// Handles selection inside the Menu2 AED list.
class AedMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var view as AedFinderView;

    function initialize(view as AedFinderView) {
        Menu2InputDelegate.initialize();
        self.view = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId() as Lang.Number;

        if (id == MenuIds.METRONOME) {
            // Replaces the menu rather than stacking on it, so leaving
            // the metronome lands back on the arrow in one press.
            // setCovered stays true: GPS keeps running underneath, and
            // whoever stops compressing may need the arrow immediately.
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            WatchUi.pushView(
                new CprMetronomeView(new CprMetronome(
                    new Vibrator(), new Scheduler(), new SystemClock())),
                new CprMetronomeDelegate(view),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        // No confirmation step: the list is already the deliberate path.
        view.selectAed(id);
        view.setCovered(false);
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }

    function onBack() as Void {
        view.setCovered(false);
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

// Dismisses the detail screen.
class AedDetailDelegate extends WatchUi.BehaviorDelegate {

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
