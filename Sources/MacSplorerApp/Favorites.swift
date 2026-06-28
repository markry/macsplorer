import Foundation

/// Persisted, ordered list of favorite folders, shared across all windows/tabs.
/// Posts `didChange` so every open tree refreshes.
final class Favorites {
    static let shared = Favorites()
    static let didChange = Notification.Name("MacSplorerFavoritesDidChange")

    private let defaults: UserDefaults
    private let key = "favoriteFolders"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The favorites, in user order.
    func folders() -> [URL] {
        (defaults.array(forKey: key) as? [String] ?? []).map { URL(fileURLWithPath: $0) }
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return folders().contains { $0.standardizedFileURL.path == path }
    }

    /// Append `url` if not already present (compared by standardized path).
    func add(_ url: URL) {
        let std = url.standardizedFileURL
        var list = folders()
        guard !list.contains(where: { $0.standardizedFileURL.path == std.path }) else { return }
        list.append(std)
        save(list)
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        save(folders().filter { $0.standardizedFileURL.path != path })
    }

    /// Move the favorite at `from` to position `to` (drag-reorder).
    func move(from: Int, to: Int) {
        var list = folders()
        guard list.indices.contains(from) else { return }
        let item = list.remove(at: from)
        list.insert(item, at: min(max(to, 0), list.count))
        save(list)
    }

    /// Insert `url` at `index` (drag-drop). If it's already a favorite, move it
    /// there instead, applying the standard remove-then-insert index shift.
    func insert(_ url: URL, at index: Int) {
        let std = url.standardizedFileURL
        var list = folders()
        var dest = index
        if let existing = list.firstIndex(where: { $0.standardizedFileURL.path == std.path }) {
            list.remove(at: existing)
            if existing < dest { dest -= 1 }
        }
        list.insert(std, at: min(max(dest, 0), list.count))
        save(list)
    }

    private func save(_ urls: [URL]) {
        defaults.set(urls.map(\.path), forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
