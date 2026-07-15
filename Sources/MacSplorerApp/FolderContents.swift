import AppKit
import MacSplorerCore

/// A view that presents the contents of one folder (the details table or the
/// icon grid). `FolderContents` drives whichever one is active through this
/// narrow surface, so all the model + file-operation logic lives in one place.
protocol FolderContentsPresenter: AnyObject {
    /// Indexes (into `FolderContents.items`) currently selected in this view.
    var selectedIndexes: IndexSet { get }
    /// Select exactly these indexes (after create/paste, to highlight results).
    func selectItems(at indexes: IndexSet)
    /// Rebuild the whole view from the model's items.
    func reloadContents()
    /// Reload just one item — async size/thumbnail fill-in.
    func reloadItem(at index: Int)
    /// Scroll back to the top (after navigating into a folder).
    func scrollToTop()
    /// Begin an inline rename of the item at `index`.
    func beginRename(at index: Int)
    /// The window hosting this view — used to make the app active + window key
    /// before starting an inline edit (a right-click "New…" from another app
    /// leaves the window un-key, so the field editor can't take focus).
    var presentingWindow: NSWindow? { get }
}

/// The folder being browsed in one tab's right pane: its items, sort order, live
/// directory watching, and every file-operation command — independent of how the
/// items are drawn. A `FolderContentsPresenter` (the list or the grid) renders
/// them and reports selection back.
final class FolderContents: NSObject {
    /// The active view. Swapped when the user toggles list ⇄ icon.
    weak var presenter: FolderContentsPresenter?

    private(set) var folder: URL?
    /// What the active view renders: the real entries plus, when enabled, a
    /// leading ".." row.
    private(set) var items: [FSItem] = []
    /// The real on-disk entries (no ".."), in sort order.
    private var realItems: [FSItem] = []

    /// Show a leading ".." row that navigates to the parent. Set, then reload.
    var showUpItem = false

    /// User opened a folder — coordinator should navigate to it.
    var onOpenFolder: ((URL) -> Void)?
    /// Fresh status-bar text (item / selection counts).
    var onStatus: ((String) -> Void)?

    /// Set by the active presenter while an inline rename is in progress, so a
    /// directory-watcher refresh doesn't yank the edit out from under it.
    var isRenaming = false

    private let watcher = DirectoryWatcher()

    /// Packages whose aggregate-size computation is in flight, to avoid
    /// scheduling the same walk twice.
    private var pendingSizeChecks = Set<ObjectIdentifier>()

    /// Standardized paths of online-only files whose contents we're currently
    /// materializing (download-on-open), for the spinner + click-guard.
    private var downloadingPaths = Set<String>()

    /// Whether hidden (dot) files are shown. Set, then call `reload`.
    var showHiddenFiles = false

    /// When true, a plain single click opens (web-style); ⇧/⌘ clicks still just
    /// adjust the selection. (The list view also underlines rows on hover.)
    var singleClickToOpen = false

    // Sort state — owned here so both views show the same order. The list view
    // changes it via its column headers; the grid follows along.
    private(set) var sortKey = "name"
    private(set) var sortAscending = true

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(folderDidChange(_:)),
            name: FolderChange.didChange, object: nil)
        watcher.onChange = { [weak self] in self?.reload() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func item(at index: Int) -> FSItem? { items.indices.contains(index) ? items[index] : nil }

    /// Index of the first real (non-"..") item — what a fresh keyboard selection
    /// should land on.
    var firstSelectableIndex: Int? { items.firstIndex { !$0.isParentLink } }

    // MARK: Loading

    func show(folder url: URL) {
        folder = url
        watcher.watch(url)
        loadItems()
        presenter?.reloadContents()
        if !items.isEmpty { presenter?.scrollToTop() }
        emitStatus()
    }

    /// Re-list the current folder in place, preserving the selection by path.
    func reload() {
        guard !isRenaming else { return }
        guard folder != nil else { return }
        let selectedPaths = Set(selectedIndexes()
            .filter { !items[$0].isParentLink }
            .map { items[$0].url.standardizedFileURL.path })
        loadItems()
        presenter?.reloadContents()
        if !selectedPaths.isEmpty {
            let rows = items.enumerated()
                .filter { !$0.element.isParentLink && selectedPaths.contains($0.element.url.standardizedFileURL.path) }
                .map(\.offset)
            if !rows.isEmpty { presenter?.selectItems(at: IndexSet(rows)) }
        }
        emitStatus()
    }

    /// (Re)read the folder, sort the real entries, and compose the displayed list
    /// (prepending ".." when enabled and not at a volume root).
    private func loadItems() {
        guard let folder else { realItems = []; items = []; return }
        realItems = FSItem.contents(of: folder, includeHidden: showHiddenFiles)
        sortRealItems()
        composeItems()
    }

    private func composeItems() {
        if showUpItem, let parent = parentFolder() {
            items = [FSItem(parentLinkTo: parent)] + realItems
        } else {
            items = realItems
        }
    }

    /// The parent folder to navigate up to, or nil at a volume root.
    private func parentFolder() -> URL? {
        guard let folder, folder.standardizedFileURL.path != "/" else { return nil }
        return folder.deletingLastPathComponent()
    }

    @objc private func folderDidChange(_ note: Notification) {
        guard let folder else { return }
        let path = folder.standardizedFileURL.path
        if FolderChange.folders(from: note).contains(where: { $0.path == path }) { reload() }
    }

    // MARK: Sorting

    func setSort(key: String, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        sortRealItems()
        composeItems()
        presenter?.reloadContents()
    }

    private func sortRealItems() {
        realItems.sort { a, b in
            // Folders always group before files, regardless of column/direction.
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var result = Self.order(a, b, key: sortKey)
            if result == .orderedSame { result = a.name.localizedStandardCompare(b.name) }
            if !sortAscending { result = result.reversed }
            return result == .orderedAscending
        }
    }

    private static func order(_ a: FSItem, _ b: FSItem, key: String) -> ComparisonResult {
        switch key {
        case "dateModified":   return compareOptional(a.modificationDate, b.modificationDate)
        case "dateCreated":    return compareOptional(a.creationDate, b.creationDate)
        case "dateAdded":      return compareOptional(a.addedToDirectoryDate, b.addedToDirectoryDate)
        case "dateLastOpened": return compareOptional(a.lastOpenedDate, b.lastOpenedDate)
        case "size":           return compareOptional(a.displayByteSize, b.displayByteSize)
        case "type":           return (a.typeDescription ?? "")
                                      .localizedStandardCompare(b.typeDescription ?? "")
        default:               return a.name.localizedStandardCompare(b.name)
        }
    }

    private static func compareOptional<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case let (x?, y?): return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (nil, nil):   return .orderedSame
        case (nil, _):     return .orderedAscending
        case (_, nil):     return .orderedDescending
        }
    }

    // MARK: Selection helpers

    private func selectedIndexes() -> [Int] {
        (presenter?.selectedIndexes ?? []).filter { $0 < items.count }.sorted()
    }

    /// Selected real entries only — the ".." row is never a file-operation target.
    func selectedURLs() -> [URL] {
        selectedIndexes().filter { !items[$0].isParentLink }.map { items[$0].url }
    }

    var hasSelection: Bool { !(presenter?.selectedIndexes.isEmpty ?? true) }
    var canPaste: Bool { Clipboard.shared.canPaste }
    var selectedFileURLs: [URL] { selectedURLs() }

    private func singleSelectedFolderURL() -> URL? {
        let rows = selectedIndexes()
        guard rows.count == 1, let row = rows.first else { return nil }
        let item = items[row]
        return (item.isDirectory && !item.isPackage) ? item.url : nil
    }

    // MARK: Status

    func emitStatus() {
        let count = realItems.count
        let selection = selectedIndexes().filter { !items[$0].isParentLink }
        if selection.isEmpty {
            onStatus?("\(count) item\(count == 1 ? "" : "s")")
        } else if selection.count == 1, let row = selection.first {
            let item = items[row]
            let showSize = !item.isDirectory || item.isPackage
            let size = showSize ? " · \(FSFormat.size(item.displayByteSize))" : ""
            onStatus?("\(count) items · 1 selected\(size)")
        } else {
            let total = selection.reduce(0) { $0 + (items[$1].displayByteSize ?? 0) }
            onStatus?("\(count) items · \(selection.count) selected · \(FSFormat.size(total))")
        }
    }

    /// Compute a package's aggregate size off the main thread, then refresh just
    /// that item once it's known. Mirrors the tree's background subfolder probe.
    func scheduleSizeCheck(for item: FSItem) {
        let key = ObjectIdentifier(item)
        guard !pendingSizeChecks.contains(key) else { return }
        pendingSizeChecks.insert(key)
        let url = item.url
        DispatchQueue.global(qos: .utility).async {
            let size = FSItem.directoryTotalSize(at: url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingSizeChecks.remove(key)
                item.setPackageSize(size)
                guard let row = self.items.firstIndex(where: { $0 === item }) else { return }
                self.presenter?.reloadItem(at: row)
            }
        }
    }

    // MARK: Opening

    func openSelected() {
        let rows = selectedIndexes()
        guard !rows.isEmpty else { return }
        for row in rows { openItem(items[row]) }
    }

    func openItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        openItem(items[index])
    }

    func openItem(_ item: FSItem) {
        if item.isDirectory && !item.isPackage {
            onOpenFolder?(item.url)
        } else if item.isCloudPlaceholder {
            downloadThenOpen(item)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Whether `item`'s online-only contents are currently being fetched, so the
    /// active presenter can show a spinner in place of the cloud badge. Keyed by
    /// path (not object identity) so it survives the item being rebuilt by a
    /// directory-watcher reload mid-download.
    func isDownloading(_ item: FSItem) -> Bool {
        downloadingPaths.contains(item.url.standardizedFileURL.path)
    }

    /// Open an "online only" cloud file (OneDrive/iCloud File Provider placeholder).
    /// `NSWorkspace.open` alone hands the launched app a dataless placeholder, so
    /// nothing opens. Finder first materializes the file; we do the same by taking
    /// a coordinated read, which makes the File Provider fetch the real bytes to
    /// disk. That download can block, so we run it off the main thread, showing a
    /// spinner meanwhile, and open once the file is present.
    private func downloadThenOpen(_ item: FSItem) {
        let url = item.url
        let key = url.standardizedFileURL.path
        // Click-guard: ignore repeat opens while the same file is still downloading.
        guard downloadingPaths.insert(key).inserted else { return }
        refreshRow(for: item)   // swap the badge for a spinner

        // Materialize through the *resolved* path. Our item URLs are re-based onto
        // the friendly ~/OneDrive symlink; coordinating a read on that symlink path
        // returns success but never reaches the File Provider, so the file stays
        // dataless and the subsequent open fails. The real CloudStorage path does
        // trigger the fetch.
        let materializeURL = url.resolvingSymlinksInPath()
        DispatchQueue.global(qos: .userInitiated).async {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            coordinator.coordinate(readingItemAt: materializeURL, options: [], error: &coordinationError) { readURL in
                // Actually read the bytes: this forces the File Provider to fetch
                // the whole file and blocks until it's on disk, so the file is
                // guaranteed present before we open it. Chunked to bound memory on
                // large files.
                if let handle = try? FileHandle(forReadingFrom: readURL) {
                    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {}
                    try? handle.close()
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.downloadingPaths.remove(key)
                // Re-list so the now-materialized file drops its placeholder badge
                // (and the spinner), then launch it.
                self.reload()
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Reload just the row currently backing `item`, if it's still on screen.
    private func refreshRow(for item: FSItem) {
        if let index = items.firstIndex(where: { $0 === item }) {
            presenter?.reloadItem(at: index)
        }
    }
}

extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
