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
        (defaults.array(forKey: key) as? [String] ?? []).map(Self.decode)
    }

    func contains(_ url: URL) -> Bool {
        let id = Self.identity(url)
        return folders().contains { Self.identity($0) == id }
    }

    /// Append `url` if not already present (compared by identity).
    func add(_ url: URL) {
        let item = Self.canonical(url)
        var list = folders()
        guard !list.contains(where: { Self.identity($0) == Self.identity(item) }) else { return }
        list.append(item)
        save(list)
    }

    func remove(_ url: URL) {
        let id = Self.identity(url)
        save(folders().filter { Self.identity($0) != id })
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
        let item = Self.canonical(url)
        let id = Self.identity(item)
        var list = folders()
        var dest = index
        if let existing = list.firstIndex(where: { Self.identity($0) == id }) {
            list.remove(at: existing)
            if existing < dest { dest -= 1 }
        }
        list.insert(item, at: min(max(dest, 0), list.count))
        save(list)
    }

    private func save(_ urls: [URL]) {
        defaults.set(urls.map(Self.encode), forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: URL ⇄ stored string, and identity
    //
    // Favorites can be local folders OR S3 (s3://) locations, so the store can't
    // assume file URLs. Local URLs are stored as plain paths (backward compatible
    // with the original format); a remote URL — which a bare path would strip the
    // scheme/host from — is stored as its full URL string.

    private static func isLocal(_ url: URL) -> Bool { url.isFileURL || url.scheme == nil }

    private static func canonical(_ url: URL) -> URL {
        isLocal(url) ? url.standardizedFileURL : url
    }
    private static func identity(_ url: URL) -> String {
        isLocal(url) ? url.standardizedFileURL.path : url.absoluteString
    }
    private static func encode(_ url: URL) -> String {
        isLocal(url) ? url.standardizedFileURL.path : url.absoluteString
    }
    private static func decode(_ s: String) -> URL {
        s.contains("://") ? (URL(string: s) ?? URL(fileURLWithPath: s)) : URL(fileURLWithPath: s)
    }
}
