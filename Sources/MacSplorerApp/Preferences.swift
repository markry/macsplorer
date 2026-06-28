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
        static let promptOnCollision = "promptOnCollision"
    }

    /// Prompt (Keep Both / Replace / Stop) on a name collision, Finder-style.
    /// Defaults to true; false means silently keep both (append " copy").
    var promptOnCollision: Bool {
        get { defaults.object(forKey: Key.promptOnCollision) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.promptOnCollision) }
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

    /// User-chosen height of the Favorites pane (0 = unset → auto-fit to ~6).
    /// Set when the user drags the divider.
    var favoritesPaneHeight: Double {
        get { defaults.double(forKey: "favoritesPaneHeight") }
        set { defaults.set(newValue, forKey: "favoritesPaneHeight") }
    }

    /// When on, bringing any MacSplorer window forward raises all of them
    /// together. Off by default.
    var raiseAllWindowsTogether: Bool {
        get { defaults.bool(forKey: "raiseAllWindowsTogether") }
        set { defaults.set(newValue, forKey: "raiseAllWindowsTogether") }
    }
}
