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
    private let roots: [FSItem]

    /// Called when the user selects a folder in the tree.
    var onSelect: ((URL) -> Void)?

    /// Called when the user clicks a Favorite — navigate AND reveal it in the
    /// hierarchy below (a true "jump there"), unlike a plain tree click.
    var onSelectFavorite: ((URL) -> Void)?

    /// Routes a folder file-operation chosen in the tree's context menu to the
    /// details pane, which owns the implementations — so the left and right
    /// folder menus are identical.
    var onFolderCommand: ((FolderCommand, URL) -> Void)?

    /// Whether hidden (dot) folders are shown. Set, then call `refresh`.
    var showHiddenFiles = false

    /// Items whose subfolder-check is currently running, to avoid duplicate work.
    private var pendingSubfolderChecks = Set<ObjectIdentifier>()

    /// The folder the context menu was opened on (the right-clicked row).
    private var clickedFolder: FSItem?

    /// The virtual "Favorites" root (row 0) and its current children (favorite
    /// folders, rendered as leaves — never expandable here).
    private let favoritesRoot = FavoritesRoot()
    private var favoriteItems: [FSItem] = []
    private var favoriteItemIDs = Set<ObjectIdentifier>()

    private func isFavoriteItem(_ item: FSItem) -> Bool {
        favoriteItemIDs.contains(ObjectIdentifier(item))
    }

    private static let favoritesIcon = NSImage(
        systemSymbolName: "star.fill", accessibilityDescription: "Favorites")

    private func rebuildFavoriteItems() {
        favoriteItems = Favorites.shared.folders().map { FSItem(url: $0) }
        favoriteItemIDs = Set(favoriteItems.map { ObjectIdentifier($0) })
    }

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

    init(outlineView: FolderOutlineView) {
        self.outlineView = outlineView
        self.roots = [
            FSItem(url: FileManager.default.homeDirectoryForCurrentUser),
            FSItem(url: URL(fileURLWithPath: "/")),
        ]
        super.init()
        rebuildFavoriteItems()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.onContextMenu = { [weak self] row in self?.contextMenu(forRow: row) }
        outlineView.reloadData()
        if !favoriteItems.isEmpty { outlineView.expandItem(favoritesRoot) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(folderDidChange(_:)),
            name: FolderChange.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(favoritesDidChange(_:)),
            name: Favorites.didChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func folderDidChange(_ note: Notification) {
        for folder in FolderChange.folders(from: note) {
            refreshSubtree(at: folder)
        }
    }

    /// Rebuild just the Favorites subtree (the rest of the tree keeps its state),
    /// and keep it expanded while it has contents.
    @objc private func favoritesDidChange(_ note: Notification) {
        rebuildFavoriteItems()
        outlineView.reloadItem(favoritesRoot, reloadChildren: true)
        if !favoriteItems.isEmpty { outlineView.expandItem(favoritesRoot) }
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
                .first(where: { $0.url.lastPathComponent.caseInsensitiveCompare(component) == .orderedSame })
            else { break }
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
        guard let item else { return 1 + roots.count }  // Favorites + Home + disk
        if item is FavoritesRoot { return favoriteItems.count }
        guard let fsItem = item as? FSItem else { return 0 }
        if isFavoriteItem(fsItem) { return 0 }           // favorites are flat leaves
        return fsItem.folderChildren(includeHidden: showHiddenFiles).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return index == 0 ? favoritesRoot : roots[index - 1] }
        if item is FavoritesRoot { return favoriteItems[index] }
        let fsItem = item as! FSItem
        return fsItem.folderChildren(includeHidden: showHiddenFiles)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is FavoritesRoot { return !favoriteItems.isEmpty }
        guard let fsItem = item as? FSItem, !isFavoriteItem(fsItem),
              fsItem.isExpandableInTree else { return false }
        if let known = fsItem.knownHasSubfolders(includeHidden: showHiddenFiles) {
            return known
        }
        // Unknown: show the triangle optimistically, confirm in the background,
        // and drop it later if the folder turns out to have no subfolders.
        scheduleHasSubfoldersCheck(for: fsItem)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView
            ?? Self.makeCell()
        if item is FavoritesRoot {
            cell.textField?.stringValue = "Favorites"
            cell.imageView?.image = Self.favoritesIcon
            cell.imageView?.contentTintColor = .systemYellow
            return cell
        }
        guard let fsItem = item as? FSItem else { return nil }
        cell.textField?.stringValue = fsItem.name
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: fsItem.url.path)
        cell.imageView?.contentTintColor = nil
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if item is FavoritesRoot { return }              // header row — no navigation
        guard let fsItem = item as? FSItem else { return }
        if isFavoriteItem(fsItem) {
            onSelectFavorite?(fsItem.url)                // navigate + reveal below
        } else {
            onSelect?(fsItem.url)
        }
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
        guard let item = clickedItem(forRow: row) else { return nil } // nil for Favorites header
        clickedFolder = item
        let menu = NSMenu()
        menu.autoenablesItems = false
        add(menu, "Open", #selector(ctxOpen(_:)))
        add(menu, "Open in New Window", #selector(ctxOpenInNewWindow(_:)))
        add(menu, "Open in Terminal", #selector(ctxTerminal(_:)))

        if isFavoriteItem(item) {
            // Favorites keep the short menu (they're shortcuts, not the folder).
            menu.addItem(.separator())
            add(menu, "Reveal in Finder", #selector(ctxReveal(_:)))
            add(menu, "Copy Path", #selector(ctxCopyPath(_:)))
            menu.addItem(.separator())
            add(menu, "Remove from Favorites", #selector(ctxRemoveFavorite(_:)))
            return menu
        }

        // Regular folder → the full menu, identical to the details pane's.
        menu.addItem(NewDocument.submenuItem(for: item.url, target: self,
                                             action: #selector(ctxNew(_:))))
        menu.addItem(.separator())
        add(menu, "Cut", #selector(ctxCut(_:)))
        add(menu, "Copy", #selector(ctxCopy(_:)))
        add(menu, "Duplicate", #selector(ctxDuplicate(_:)))
        menu.addItem(.separator())
        add(menu, "Rename", #selector(ctxRename(_:)))
        add(menu, "Move to Trash", #selector(ctxTrash(_:)))
        menu.addItem(.separator())
        add(menu, "Reveal in Finder", #selector(ctxReveal(_:)))
        add(menu, "Copy Path", #selector(ctxCopyPath(_:)))
        if !Favorites.shared.contains(item.url) {
            menu.addItem(.separator())
            add(menu, "Add to Favorites", #selector(ctxAddFavorite(_:)))
        }
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, enabled: Bool = true) {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.isEnabled = enabled
        menu.addItem(menuItem)
    }

    @objc private func ctxOpen(_ sender: Any?) {
        guard let folder = clickedFolder else { return }
        if isFavoriteItem(folder) { onSelectFavorite?(folder.url) } else { onSelect?(folder.url) }
    }

    @objc private func ctxAddFavorite(_ sender: Any?) {
        guard let folder = clickedFolder else { return }
        Favorites.shared.add(folder.url)
    }

    @objc private func ctxRemoveFavorite(_ sender: Any?) {
        guard let folder = clickedFolder else { return }
        Favorites.shared.remove(folder.url)
    }

    @objc private func ctxOpenInNewWindow(_ sender: Any?) {
        guard let folder = clickedFolder else { return }
        (NSApp.delegate as? AppDelegate)?.openWindow(showing: folder.url)
    }

    @objc private func ctxTerminal(_ sender: Any?) {
        guard let folder = clickedFolder else { return }
        Shell.openInTerminal(folder.url)
    }

    // File operations route to the details pane (which owns the implementations).
    @objc private func ctxCut(_ sender: Any?) { sendCommand(.cut) }
    @objc private func ctxCopy(_ sender: Any?) { sendCommand(.copy) }
    @objc private func ctxDuplicate(_ sender: Any?) { sendCommand(.duplicate) }
    @objc private func ctxRename(_ sender: Any?) { sendCommand(.rename) }
    @objc private func ctxTrash(_ sender: Any?) { sendCommand(.trash) }

    @objc private func ctxNew(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? NewMenuChoice else { return }
        switch choice.kind {
        case .folder: onFolderCommand?(.newFolder, choice.directory)
        case .document(let type): onFolderCommand?(.newDocument(type), choice.directory)
        case .internetShortcut: onFolderCommand?(.internetShortcut, choice.directory)
        }
    }

    private func sendCommand(_ command: FolderCommand) {
        guard let folder = clickedFolder else { return }
        onFolderCommand?(command, folder.url)
    }

    @objc private func ctxReveal(_ sender: Any?) {
        guard let folder = clickedFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }

    @objc private func ctxCopyPath(_ sender: Any?) {
        guard let folder = clickedFolder else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folder.url.path, forType: .string)
    }
}
