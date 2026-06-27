import AppKit
import MacSplorerCore

/// Drives the left-hand folder tree (`NSOutlineView`): folders only, lazily
/// expanded, rooted at Home and the startup volume. Reports the selected
/// folder's URL via `onSelect`.
final class FolderTreeController: NSObject {
    private let outlineView: NSOutlineView
    private let roots: [FSItem]

    /// Called when the user selects a folder in the tree.
    var onSelect: ((URL) -> Void)?

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
        DispatchQueue.global(qos: .utility).async {
            let hasSubfolders = FSItem.directoryHasSubfolders(at: url, includeHidden: includeHidden)
            DispatchQueue.main.async { [weak self] in
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

    init(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        self.roots = [
            FSItem(url: FileManager.default.homeDirectoryForCurrentUser),
            FSItem(url: URL(fileURLWithPath: "/")),
        ]
        super.init()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.reloadData()
        NotificationCenter.default.addObserver(
            self, selector: #selector(folderDidChange(_:)),
            name: FolderChange.didChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func folderDidChange(_ note: Notification) {
        for folder in FolderChange.folders(from: note) {
            refreshSubtree(at: folder)
        }
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
            guard let next = current.folderChildren(includeHidden: showHiddenFiles)
                .first(where: { $0.url.lastPathComponent == component }) else { break }
            chain.append(next)
            current = next
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
        return item.folderChildren(includeHidden: showHiddenFiles).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? FSItem else { return roots[index] }
        return item.folderChildren(includeHidden: showHiddenFiles)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let fsItem = item as? FSItem, fsItem.isExpandableInTree else { return false }
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
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: fsItem.url.path)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FSItem else { return }
        onSelect?(item.url)
    }
}
