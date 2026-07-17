import Foundation

/// A single filesystem entry (file or folder) plus the metadata MacSplorer
/// displays. It's a reference type so `NSOutlineView` can track tree nodes by
/// identity and we can cache lazily-loaded folder children.
public final class FSItem {
    public let url: URL
    /// Full on-disk name including extension — always shown (a core ask: never
    /// hide suffixes the way Finder can).
    public let name: String
    public let isDirectory: Bool
    /// App/document bundles (.app, .rtfd, …): directories on disk, but the user
    /// thinks of them as single items, so we don't let the tree descend into them.
    public let isPackage: Bool
    /// True for symbolic links / aliases. `isDirectory`/`isPackage` describe the
    /// link's *target*, so a symlink to a folder browses and trees like a folder.
    public let isSymlink: Bool
    public let modificationDate: Date?
    /// Creation date (`.creationDateKey`) — an optional details column.
    public let creationDate: Date?
    /// When this item was added to its containing folder (`.addedToDirectoryDateKey`),
    /// matching Finder's "Date Added" — an optional details column.
    public let addedToDirectoryDate: Date?
    /// Last access date (`.contentAccessDateKey`) — an optional "Date Last Opened"
    /// column. Approximate: the OS updates it on access, not only deliberate opens.
    public let lastOpenedDate: Date?
    /// File size in bytes; nil for directories (shown blank, like Explorer).
    public let byteSize: Int?
    /// Localized kind, e.g. "Folder", "Plain Text Document", "PNG image".
    public let typeDescription: String?
    /// A synthetic ".." row pointing at the parent folder (not a real entry on
    /// disk). Rendered specially, excluded from file operations; opening it just
    /// navigates up.
    public let isParentLink: Bool

    /// True for a cloud file (OneDrive/iCloud File Provider placeholder) whose
    /// contents aren't on disk yet — "online only". Such a file must be
    /// materialized before it can be opened; we badge it and download-on-open.
    /// See `.ubiquitousItemDownloadingStatusKey`; `.notDownloaded` == placeholder.
    public let isCloudPlaceholder: Bool

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .contentModificationDateKey, .creationDateKey,
        .addedToDirectoryDateKey, .contentAccessDateKey,
        .fileSizeKey, .totalFileAllocatedSizeKey,
        .localizedTypeDescriptionKey, .localizedNameKey,
        .ubiquitousItemDownloadingStatusKey,
    ]

    private var cachedFolderChildren: [FSItem]?
    private var cachedChildrenIncludeHidden = false
    private var cachedHasSubfolders: Bool?
    private var cachedHasSubfoldersIncludeHidden = false

    /// Aggregate size of a package/bundle (.app, .pvm, …), computed lazily in the
    /// background since it requires walking the bundle. nil until computed.
    private var cachedPackageSize: Int?

    /// The size to display and sort by: a plain file's size, or — once computed —
    /// a package's aggregate. Plain folders stay nil (shown blank, like Explorer).
    public var displayByteSize: Int? { byteSize ?? cachedPackageSize }

    /// Whether this entry should show a size that needs background computation
    /// (a package whose aggregate isn't known yet).
    public var needsPackageSize: Bool { byteSize == nil && isPackage && cachedPackageSize == nil }

    public func knownPackageSize() -> Int? { cachedPackageSize }
    public func setPackageSize(_ value: Int) { cachedPackageSize = value }

    public init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: Set(FSItem.resourceKeys))
        let last = url.lastPathComponent
        // lastPathComponent is empty for a volume root ("/") — fall back to the
        // localized volume name there, but otherwise keep the literal filename
        // so extensions are always visible.
        self.name = last.isEmpty ? (values?.localizedName ?? url.path) : last

        let symlink = values?.isSymbolicLink ?? false
        self.isSymlink = symlink

        var directory = values?.isDirectory ?? false
        var package = values?.isPackage ?? false
        if symlink {
            // .isDirectoryKey reports the link itself (false for a symlink), so
            // resolve and classify by the target — otherwise symlinked folders
            // (e.g. ~/OneDrive) are treated as files: absent from the tree and
            // sorted among files instead of grouped with folders.
            let resolved = url.resolvingSymlinksInPath()
            if let target = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
                directory = target.isDirectory ?? false
                package = target.isPackage ?? false
            }
        }
        self.isDirectory = directory
        self.isPackage = package
        self.modificationDate = values?.contentModificationDate
        self.creationDate = values?.creationDate
        self.addedToDirectoryDate = values?.addedToDirectoryDate
        self.lastOpenedDate = values?.contentAccessDate
        self.byteSize = directory ? nil : (values?.fileSize ?? values?.totalFileAllocatedSize)
        self.typeDescription = values?.localizedTypeDescription
        self.isParentLink = false
        // A File Provider item whose contents haven't been downloaded yet reports
        // `.notDownloaded`; local files (and non-cloud files, where the key is nil)
        // are treated as materialized.
        self.isCloudPlaceholder = values?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// A synthetic ".." entry that navigates to `parent`. Carries no metadata and
    /// is never a file-operation target.
    public init(parentLinkTo parent: URL) {
        self.url = parent
        self.name = ".."
        self.isDirectory = true
        self.isPackage = false
        self.isSymlink = false
        self.modificationDate = nil
        self.creationDate = nil
        self.addedToDirectoryDate = nil
        self.lastOpenedDate = nil
        self.byteSize = nil
        self.typeDescription = nil
        self.isParentLink = true
        self.isCloudPlaceholder = false
    }

    /// All entries in a directory (files + folders), unsorted. Returns [] on
    /// failure (e.g. permission denied) rather than throwing.
    public static func contents(of directory: URL,
                                includeHidden: Bool = false) -> [FSItem] {
        let options: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        // Enumerate through the *resolved* directory: listing a symlink path
        // directly (e.g. ~/OneDrive -> ~/Library/CloudStorage/OneDrive-Personal)
        // fails, while the resolved target lists fine. Re-base each child under
        // the original `directory` so the address bar and tree keep the friendly
        // symlink-based path rather than exposing the CloudStorage location.
        let enumerationURL = directory.resolvingSymlinksInPath()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: enumerationURL,
            includingPropertiesForKeys: resourceKeys,
            options: options
        ) else { return [] }
        return urls.map { FSItem(url: directory.appendingPathComponent($0.lastPathComponent)) }
    }

    /// Folder-only children for the left tree — lazy, cached, name-sorted. The
    /// cache is keyed by `includeHidden` so toggling hidden files re-reads.
    public func folderChildren(includeHidden: Bool = false) -> [FSItem] {
        if let cached = cachedFolderChildren, cachedChildrenIncludeHidden == includeHidden {
            return cached
        }
        // Synchronous local read: the tree's NSOutlineView data source can't await.
        // S3 tree nodes will use an async-load-then-cache path instead of this.
        let folders = FSItem.contents(of: url, includeHidden: includeHidden)
            .filter { $0.isDirectory && !$0.isPackage }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cachedFolderChildren = folders
        cachedChildrenIncludeHidden = includeHidden
        return folders
    }

    /// Drop cached children so the next access re-reads from disk.
    public func invalidateChildren() {
        cachedFolderChildren = nil
        cachedHasSubfolders = nil
    }

    /// Re-read folder children from disk but REUSE the existing child instances
    /// for entries that still exist — so any expanded subtrees (tracked by
    /// NSOutlineView via object identity) survive the refresh, and only genuinely
    /// new folders get fresh (collapsed) nodes. Returns whether the set of child
    /// names changed, so callers can skip a needless `reloadItem`.
    ///
    /// This is what lets the tree pick up folders created outside the app (e.g.
    /// cloud sync) without the jarring full-collapse that `invalidateChildren`
    /// would cause.
    @discardableResult
    public func refreshFolderChildren(includeHidden: Bool) -> Bool {
        let previous = cachedFolderChildren ?? []
        let existingByName = Dictionary(previous.map { ($0.name, $0) },
                                        uniquingKeysWith: { first, _ in first })
        let merged = FSItem.contents(of: url, includeHidden: includeHidden)
            .filter { $0.isDirectory && !$0.isPackage }
            .map { existingByName[$0.name] ?? $0 }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let changed = merged.map { $0.name } != previous.map { $0.name }
        cachedFolderChildren = merged
        cachedChildrenIncludeHidden = includeHidden
        cachedHasSubfolders = nil   // membership changed → recompute the triangle
        return changed
    }

    /// Gate for tree expansion: only a real (non-package) directory can ever show
    /// a disclosure triangle. Whether one is *actually* shown also depends on
    /// `knownHasSubfolders`, determined lazily off the main thread.
    public var isExpandableInTree: Bool { isDirectory && !isPackage }

    /// Cached "has at least one subfolder?" answer for the given hidden setting,
    /// or nil if not yet determined. Main-thread only (pairs with setHasSubfolders).
    public func knownHasSubfolders(includeHidden: Bool) -> Bool? {
        guard let value = cachedHasSubfolders,
              cachedHasSubfoldersIncludeHidden == includeHidden else { return nil }
        return value
    }

    public func setHasSubfolders(_ value: Bool, includeHidden: Bool) {
        cachedHasSubfolders = value
        cachedHasSubfoldersIncludeHidden = includeHidden
    }

    /// Pure, side-effect-free check suitable for a background queue: does `url`
    /// contain at least one non-package subfolder? Stops at the first match.
    public static func directoryHasSubfolders(at url: URL, includeHidden: Bool) -> Bool {
        let options: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        let enumerationURL = url.resolvingSymlinksInPath()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: enumerationURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
            options: options
        ) else { return false }
        for child in urls {
            guard let values = try? child.resourceValues(
                forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]) else { continue }
            var isDir = values.isDirectory ?? false
            var isPkg = values.isPackage ?? false
            if values.isSymbolicLink == true,
               let target = try? child.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
                isDir = target.isDirectory ?? false
                isPkg = target.isPackage ?? false
            }
            if isDir && !isPkg { return true }
        }
        return false
    }

    /// Total logical size of everything inside `url` — for packages/bundles shown
    /// as a single item. Pure and side-effect-free, so safe on a background queue.
    public static func directoryTotalSize(at url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey]
        let enumerationURL = url.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: enumerationURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else { return 0 }
        var total = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: keys)
            total += values?.fileSize ?? values?.totalFileAllocatedSize ?? 0
        }
        return total
    }
}
