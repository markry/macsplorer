import Foundation

/// Persisted user preferences, backed by `UserDefaults` so toggles survive
/// relaunches. Central + tiny on purpose: new options get an obvious home here.
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let showHiddenFiles = "showHiddenFiles"
        static let singleClickToOpen = "singleClickToOpen"
    }

    /// Both default to `false` (UserDefaults.bool returns false when unset),
    /// matching Mac conventions: extensions/hidden off, double-click to open.
    var showHiddenFiles: Bool {
        get { defaults.bool(forKey: Key.showHiddenFiles) }
        set { defaults.set(newValue, forKey: Key.showHiddenFiles) }
    }

    var singleClickToOpen: Bool {
        get { defaults.bool(forKey: Key.singleClickToOpen) }
        set { defaults.set(newValue, forKey: Key.singleClickToOpen) }
    }
}
