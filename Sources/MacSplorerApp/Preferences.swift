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
        static let detailsColumns = "detailsColumns"
        static let detailsColumnWidths = "detailsColumnWidths"
    }

    /// Ordered ids of the visible details-pane columns. "name" is always present
    /// and leftmost. Defaults to the original four; the rest are opt-in.
    var detailsColumns: [String] {
        get { (defaults.array(forKey: Key.detailsColumns) as? [String])
                ?? ["name", "dateModified", "type", "size"] }
        set { defaults.set(newValue, forKey: Key.detailsColumns) }
    }

    /// Persisted details-pane column widths, keyed by column id, so a column keeps
    /// its width across hide/show and relaunch.
    var detailsColumnWidths: [String: Double] {
        get { defaults.dictionary(forKey: Key.detailsColumnWidths) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: Key.detailsColumnWidths) }
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

    /// Show a ".." row at the top of the file list/grid that navigates up to the
    /// parent folder. Off by default.
    var showParentItem: Bool {
        get { defaults.bool(forKey: "showParentItem") }
        set { defaults.set(newValue, forKey: "showParentItem") }
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

    /// Whether the pinned Favorites pane is shown. On by default; remembered if
    /// the user hides it.
    var showFavorites: Bool {
        get { defaults.object(forKey: "showFavorites") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showFavorites") }
    }

    /// Whether the in-window menu bar is shown. On by default.
    var showMenuBar: Bool {
        get { defaults.object(forKey: "showMenuBar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showMenuBar") }
    }

    /// Right-pane view: "list" (details table) or "icon" (thumbnail grid).
    /// Defaults to list — the app's core experience.
    var rightPaneView: String {
        get { defaults.string(forKey: "rightPaneView") ?? "list" }
        set { defaults.set(newValue, forKey: "rightPaneView") }
    }

    /// Icon-grid thumbnail size: "small" or "large". Defaults to large.
    var iconSize: String {
        get { defaults.string(forKey: "iconSize") ?? "large" }
        set { defaults.set(newValue, forKey: "iconSize") }
    }
}

/// The thumbnail edge length (points) for each icon-grid size preset.
enum IconSize: String, CaseIterable {
    case small, large

    var thumbnailEdge: CGFloat {
        switch self {
        case .small: return 48
        case .large: return 128
        }
    }

    /// Total grid-cell size, leaving room for the two-line name label below.
    var cellSize: NSSize {
        let edge = thumbnailEdge
        return NSSize(width: edge + 36, height: edge + 34)
    }

    static func current() -> IconSize { IconSize(rawValue: Preferences.shared.iconSize) ?? .large }
}
