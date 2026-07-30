import Toybox.Lang;
import Toybox.WatchUi;

// Input handling for the main view.
//
//   START / tap   the list of the 5 nearest AEDs; picking one retargets
//                 the arrow immediately
//   MENU          full details of the AED currently being navigated to
//
// During the walking-away prompt both keys are reinterpreted, exactly
// as the prompt's own hint line says: START means "keep going", MENU
// means "show me the others".
//
// The split is deliberate. The fastest possible path - open the widget,
// follow the arrow - needs no input at all, because the nearest AED is
// targeted automatically. Every button here belongs to the deliberate
// path, so a key can cost a screen without costing anyone time in an
// emergency.
class AedFinderDelegate extends WatchUi.BehaviorDelegate {

    const MENU_MAX_ITEMS = 5;

    private var view as AedFinderView;
    private var strMenuTitle as Lang.String;
    private var strAedFallback as Lang.String;
    private var strAccessPrivate as Lang.String;
    private var strAccessCustomers as Lang.String;

    function initialize(view as AedFinderView) {
        BehaviorDelegate.initialize();
        self.view = view;
        strMenuTitle = WatchUi.loadResource(Rez.Strings.MenuTitle) as Lang.String;
        strAedFallback = WatchUi.loadResource(Rez.Strings.AedFallbackName) as Lang.String;
        strAccessPrivate = WatchUi.loadResource(Rez.Strings.AccessPrivate) as Lang.String;
        strAccessCustomers = WatchUi.loadResource(Rez.Strings.AccessCustomers) as Lang.String;
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
        if (aeds.size() == 0) {
            // Nothing to choose from yet (no fix / nothing nearby):
            // let the system handle the event normally.
            return false;
        }

        var menu = new WatchUi.Menu2({ :title => strMenuTitle });
        for (var i = 0; i < aeds.size(); i++) {
            var a = aeds[i] as Lang.Dictionary;
            // The item id is the index into the view's sorted list,
            // which selectAed() maps back to an entry.
            menu.addItem(new WatchUi.MenuItem(
                labelFor(a), subtitleFor(a), i, {}
            ));
        }

        // Keep GPS/sensors alive while the menu covers the view, so
        // distances stay fresh and there's no fix re-acquisition after
        // returning to the arrow screen.
        view.setCovered(true);
        WatchUi.pushView(menu, new AedMenuDelegate(view), WatchUi.SLIDE_UP);
        return true;
    }

    // Title line: the free-text hint about where the device hangs, when
    // OSM has one. That string ("przy recepcji", "obok windy") is far
    // more useful for picking between two AEDs than a street address
    // would be, because by this point you can already see the street.
    private function labelFor(aed as Lang.Dictionary) as Lang.String {
        var loc = aed[:loc] as Lang.String or Null;
        if (loc != null && !loc.equals("")) {
            return loc;
        }
        return strAedFallback;
    }

    // Subtitle: live distance, then whatever would stop you getting to
    // it - restricted access first, opening hours second.
    private function subtitleFor(aed as Lang.Dictionary) as Lang.String {
        var dist = aed[:dist] as Lang.Double;
        var text = dist.format("%.0f") + " m";

        var access = aed[:access] as Lang.String or Null;
        if (access != null && access.equals("p")) {
            text += " | " + strAccessPrivate;
        } else if (access != null && access.equals("c")) {
            text += " | " + strAccessCustomers;
        }

        var hours = aed[:hours] as Lang.String or Null;
        if (hours != null && !hours.equals("")) {
            text += " | " + hours;
        }
        return text;
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
        // Retarget immediately and go back to the arrow. No confirmation
        // step: the list is already the deliberate path, and the detail
        // screen is one MENU press away from where this lands.
        view.selectAed(item.getId() as Lang.Number);
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
