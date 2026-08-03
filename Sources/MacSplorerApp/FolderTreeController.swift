import AppKit
import MacSplorerCore

/// A file-operation the tree's folder context menu delegates to the details pane
/// (which owns the implementations), so both panes' menus are identical.
enum FolderCommand {
    case cut, copy, duplicate, rename, trash
    case newFolder
    case newDocument(NewDocumentType)
    case internetShortcut
}

/// Drives the left-hand folder tree (`NSOutlineView`): folders only, lazily
/// expanded, rooted at Home and the startup volume. Reports the selected
/// folder's URL via `onSelect`.
final class FolderTreeController: NSObject {
    private let outlineView: FolderOutlineView
    private var roots: [FSItem]

    /// Stable S3 profile nodes injected under /Volumes when connected. Cached (and
    /// rebuilt only when the profile set changes) so NSOutlineView keeps a consistent
    /// identity per node across data-source calls.
    private var cachedS3ProfileNodes: [FSItem] = []

    /// S3 tree nodes whose async child-load is in flight, so a re-query doesn't
    /// start a second load for the same node.
    private var loadingNodes = Set<ObjectIdentifier>()

    /// Tree roots: Home, optionally the startup disk ("/"), and /Volumes.
    /// /Volumes is its own root because it carries the `hidden` flag — it never
    /// appears under "/" (the tree skips hidden items) yet is where mounted volumes
    /// live and a common navigation target; as a root, volume paths reveal right.
    private static func makeRoots() -> [FSItem] {
        var roots = [FSItem(url: FileManager.default.homeDirectoryForCurrentUser)]
        if Preferences.shared.showStartupDiskRoot {
            roots.append(FSItem(url: URL(fileURLWithPath: "/")))
        }
        roots.append(FSItem(url: URL(fileURLWithPath: "/Volumes")))
        return roots
    }

    /// Rebuild the roots if the startup-disk preference changed, then re-reveal
    /// `url`. Cheap no-op when the root set is unchanged (keeps expansion state).
    func applyRootPreferences(revealing url: URL?) {
        let desired = (Preferences.shared.showStartupDiskRoot
            ? [FileManager.default.homeDirectoryForCurrentUser.path, "/", "/Volumes"]
            : [FileManager.default.homeDirectoryForCurrentUser.path, "/Volumes"])
        guard roots.map({ $0.url.path }) != desired else { return }
        roots = FolderTreeController.makeRoots()
        outlineView.reloadData()
        if let url { reveal(url) }
    }

    /// Called when the user selects a folder in the tree.
    var onSelect: ((URL) -> Void)?

    /// Routes a folder file-operation chosen in the tree's context menu to the
    /// details pane, which owns the implementations — so the left and right
    /// folder menus are identical.
    var onFolderCommand: ((FolderCommand, URL) -> Void)?

    /// Whether hidden (dot) folders are shown. Set, then call `refresh`.
    var showHiddenFiles = false

    /// Items whose subfolder-check is currently running, to avoid duplicate work.
    private var pendingSubfolderChecks = Set<ObjectIdentifier>()

    /// Determine off the main thread whether `item` actually has subfolders, so
    /// the disclosure triangle only appears when expanding would do something.
    /// Called from `isItemExpandable`, so it only ever runs for nodes the tree is
    /// currently displaying — never a full-hierarchy walk.
    private func scheduleHasSubfoldersCheck(for item: FSItem) {
        let key = ObjectIdentifier(item)
        guard !pendingSubfolderChecks.contains(key) else { return }
        pendingSubfolderChecks.insert(key)
        let includeHidden = showHiddenFiles
        let url = item.url
        Task {
            let hasSubfolders = await Providers.provider(for: url).hasChildFolders(at: url, includeHidden: includeHidden)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingSubfolderChecks.remove(key)
                guard includeHidden == self.showHiddenFiles else { return } // stale toggle
                item.setHasSubfolders(hasSubfolders, includeHidden: includeHidden)
                if !hasSubfolders {
                    self.outlineView.reloadItem(item) // remove the now-unneeded triangle
                }
            }
        }
    }

    /// Rebuild the tree (e.g. after toggling hidden files) and re-reveal the
    /// given location so the user doesn't lose their place.
    func refresh(revealing url: URL?) {
        outlineView.reloadData()
        if let url { reveal(url) }
    }

    /// Re-read one folder's subtree after a file operation changed its contents
    /// (new/renamed/deleted/pasted folder), without collapsing the rest of the tree.
    func refreshSubtree(at url: URL) {
        guard let root = bestRoot(for: url),
              let item = itemChain(from: root, to: url).last else { return }
        item.invalidateChildren()
        outlineView.reloadItem(item, reloadChildren: true)
    }

    init(outlineView: FolderOutlineView) {
        self.outlineView = outlineView
        self.roots = FolderTreeController.makeRoots()
        super.init()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.onContextMenu = { [weak self] row in self?.contextMenu(forRow: row) }
        outlineView.reloadData()
        NotificationCenter.default.addObserver(
            self, selector: #selector(folderDidChange(_:)),
            name: FolderChange.didChange, object: nil)
        // Lazy-load an S3 node's children (buckets/prefixes) when it's expanded.
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemWillExpand(_:)),
            name: NSOutlineView.itemWillExpandNotification, object: outlineView)
        // Refresh the Volumes node when a disk mounts/unmounts/renames (eject,
        // plugging in a drive, mounting a DMG…) — these come from NSWorkspace's
        // own center, not the default one.
        let workspace = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didMountNotification,
                                          NSWorkspace.didUnmountNotification,
                                          NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
        // When the app returns to the foreground, re-read the expanded folders so
        // changes made while we were in the background — most notably folders
        // created by cloud sync (OneDrive/Drive) or another app — show up in the
        // tree without the user having to navigate into them.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func folderDidChange(_ note: Notification) {
        for folder in FolderChange.folders(from: note) {
            refreshSubtree(at: folder)
        }
    }

    @objc private func volumesChanged(_ note: Notification) {
        refreshSubtree(at: URL(fileURLWithPath: "/Volumes"))
    }

    /// When an S3 (non-file) node is about to expand and its children aren't loaded
    /// yet, fetch them asynchronously, then reload + re-expand so they appear.
    @objc private func itemWillExpand(_ note: Notification) {
        guard let item = note.userInfo?["NSObject"] as? FSItem,
              !item.url.isFileURL, item.providerChildren == nil else { return }
        let id = ObjectIdentifier(item)
        guard !loadingNodes.contains(id) else { return }
        loadingNodes.insert(id)
        let url = item.url
        let hidden = showHiddenFiles
        Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = (try? await Providers.provider(for: url)
                .children(of: url, includeHidden: hidden)) ?? []
            let folders = loaded
                .filter { $0.isDirectory && !$0.isPackage }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            item.setProviderChildren(folders)
            self.loadingNodes.remove(id)
            self.outlineView.reloadItem(item, reloadChildren: true)
            if !folders.isEmpty { self.outlineView.expandItem(item) }
        }
    }

    @objc private func appBecameActive() {
        refreshExpandedNodes()
    }

    /// Re-read every currently-expanded folder from disk and reload the ones whose
    /// contents changed. Cheap: it only touches nodes the user has expanded (what's
    /// on screen), and reuses child instances so expansion state is preserved.
    private func refreshExpandedNodes() {
        func walk(_ item: FSItem) {
            guard outlineView.isItemExpanded(item) else { return }
            if item.refreshFolderChildren(includeHidden: showHiddenFiles) {
                outlineView.reloadItem(item, reloadChildren: true)
            }
            for child in item.folderChildren(includeHidden: showHiddenFiles) {
                walk(child)
            }
        }
        for root in roots { walk(root) }
    }

    /// Expand + select the Home root (row 0). Done after the coordinator wires
    /// `onSelect`, so this also drives the initial folder load.
    func selectHome() {
        guard let home = roots.first else { return }
        outlineView.expandItem(home)
        let row = outlineView.row(forItem: home)
        if row >= 0 {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    /// Expand the tree down to `target` and select it, so the left pane tracks
    /// wherever the user navigated (double-click in the details pane, address
    /// bar, etc.). No-op if the target isn't under one of our roots.
    func reveal(_ target: URL) {
        guard let root = bestRoot(for: target) else { return }
        let chain = itemChain(from: root, to: target)
        for ancestor in chain.dropLast() { outlineView.expandItem(ancestor) }
        guard let leaf = chain.last else { return }
        let row = outlineView.row(forItem: leaf)
        if row >= 0 {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    /// The deepest root (longest path) that contains `target`.
    private func bestRoot(for target: URL) -> FSItem? {
        let targetPath = target.standardizedFileURL.path
        return roots
            .filter { root in
                let rootPath = root.url.standardizedFileURL.path
                return targetPath == rootPath
                    || targetPath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
            }
            .max { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
    }

    /// Walk root → target one path component at a time, matching against each
    /// node's folder children (which also resolves symlinked folders correctly).
    private func itemChain(from root: FSItem, to target: URL) -> [FSItem] {
        let rootComponents = root.url.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard targetComponents.count >= rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            return [root]
        }
        var chain = [root]
        var current = root
        for component in targetComponents[rootComponents.count...] {
            func match() -> FSItem? {
                current.folderChildren(includeHidden: showHiddenFiles)
                    .first { $0.url.lastPathComponent.caseInsensitiveCompare(component) == .orderedSame }
            }
            var next = match()
            if next == nil {
                // Cached children may predate a folder created outside the app
                // (e.g. cloud sync). Re-read this node once and retry before
                // giving up, so revealing a just-synced folder still lands.
                if current.refreshFolderChildren(includeHidden: showHiddenFiles) {
                    outlineView.reloadItem(current, reloadChildren: true)
                    next = match()
                }
            }
            guard let found = next else { break }
            chain.append(found)
            current = found
        }
        return chain
    }

    private static let cellID = NSUserInterfaceItemIdentifier("treeCell")

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellID

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = icon
        cell.addSubview(icon)

        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.font = .systemFont(ofSize: 13)
        cell.textField = text
        cell.addSubview(text)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

extension FolderTreeController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? FSItem else { return roots.count }
        return treeChildren(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? FSItem else { return roots[index] }
        return treeChildren(of: item)[index]
    }

    /// A tree node's children: its local folder children, plus — under the /Volumes
    /// root when S3 is connected — the AWS profile nodes. S3 nodes below a profile
    /// (buckets/prefixes) need async loading, which the sync tree can't do yet, so
    /// they aren't expanded here (see isItemExpandable); clicking a profile still
    /// browses its buckets in the right pane.
    private func treeChildren(of item: FSItem) -> [FSItem] {
        // S3 (non-file) nodes: async-loaded folder children, cached on the node.
        // Loaded lazily when the node is expanded (see itemWillExpand).
        if !item.url.isFileURL {
            return item.providerChildren ?? []
        }
        let local = item.folderChildren(includeHidden: showHiddenFiles)
        guard S3Mount.isVolumesRoot(item.url) else { return local }
        return local + s3ProfileNodes()
    }

    /// Stable S3 profile nodes, rebuilt only when the profile set changes so the
    /// outline view keeps a consistent identity per node.
    private func s3ProfileNodes() -> [FSItem] {
        let names = S3Mount.profileNames()
        if cachedS3ProfileNodes.map(\.name) != names {
            // Reuse existing node instances for names that persist, so a live
            // refresh (e.g. a profile added to a watched file) keeps already-expanded
            // profile subtrees; only genuinely new profiles get fresh nodes.
            let existing = Dictionary(cachedS3ProfileNodes.map { ($0.name, $0) },
                                      uniquingKeysWith: { first, _ in first })
            cachedS3ProfileNodes = names.map { existing[$0] ?? S3Mount.profileItem($0) }
        }
        return cachedS3ProfileNodes
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let fsItem = item as? FSItem else { return false }
        // S3 (non-file) nodes: their children load over the network on expand.
        // Optimistically expandable until loaded, then only if they really have
        // sub-folders (so a leaf prefix's triangle drops after the load).
        if !fsItem.url.isFileURL {
            if let loaded = fsItem.providerChildren { return !loaded.isEmpty }
            return true
        }
        guard fsItem.isExpandableInTree else { return false }
        if let known = fsItem.knownHasSubfolders(includeHidden: showHiddenFiles) {
            return known
        }
        // Unknown: show the triangle optimistically, confirm in the background,
        // and drop it later if the folder turns out to have no subfolders.
        scheduleHasSubfoldersCheck(for: fsItem)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fsItem = item as? FSItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView
            ?? Self.makeCell()
        cell.textField?.stringValue = fsItem.name
        cell.imageView?.image = fsItem.displayIcon
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FSItem else { return }
        onSelect?(item.url)
    }

    /// Let folders be dragged out of the tree (so you can drag one onto the
    /// Favorites pane). Carries the folder's file URL.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let fsItem = item as? FSItem else { return nil }
        return fsItem.url as NSURL
    }
}

// MARK: - Context menu

extension FolderTreeController {
    /// The folder under the right-clicked row, if any.
    private func clickedItem(forRow row: Int) -> FSItem? {
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FSItem
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let item = clickedItem(forRow: row) else { return nil }
        return FolderContextMenu.make(for: item.url, target: self,
                                      action: #selector(handleFolderMenu(_:)),
                                      newAction: #selector(handleFolderNew(_:)))
    }

    @objc private func handleFolderMenu(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? FolderMenuAction else { return }
        FolderContextMenu.perform(action,
            open: { [weak self] in self?.onSelect?($0) },
            command: { [weak self] in self?.onFolderCommand?($0, $1) })
    }

    @objc private func handleFolderNew(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? NewMenuChoice else { return }
        FolderContextMenu.performNew(choice) { [weak self] in self?.onFolderCommand?($0, $1) }
    }
}
