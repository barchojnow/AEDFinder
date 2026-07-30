import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

// Application entry point. Wires the single view together with its
// BehaviorDelegate (needed for the AED menu and the detail screen) in
// getInitialView().
class AedFinderApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new AedFinderView();
        return [ view, new AedFinderDelegate(view) ];
    }
}

// Convenience accessor for the running application instance.
function getApp() as AedFinderApp {
    return Application.getApp() as AedFinderApp;
}
