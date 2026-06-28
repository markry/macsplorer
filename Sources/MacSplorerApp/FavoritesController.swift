import AppKit
import MacSplorerCore

/// A vertical split whose top pane (Favorites) is resizable by dragging the
/// divider. Reports a *user* drag (vs. programmatic/window resize) so the host
/// can stop auto-fitting the height and remember the user's choice.
final class FavoritesSplitView: NSSplitView {
    var onUserDividerDrag: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let before = arrangedSubviews.first?.frame.height
        super.mouseDown(with: event) // runs the divider-drag tracking loop
        if let before, let after = arrangedSubviews.first?.frame.height,
           abs(before - after) > 0.5 {
            onUserDividerDrag?()
        }
    }
}

/// A table that vends a per-row context menu (selecting the clicked row first).
final class FavoritesTableView: NSTableView {
    var onContextMenu: ((Int) -> NSMenu?)?
    var onTab: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, let onTab {
            onTab(event.modifierFlags.contains(.shift))
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0 && selectedRow != clicked {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return onContextMenu?(clicked)
    }
}

/// Drives the pinned "Favorites" list at the top of the left pane — a flat,
/// always-visible list of pinned folders that doesn't scroll away with the
/// folder tree below it. Sizes to its contents (capped, then scrolls within).
final class FavoritesController: NSObject {
    /// Click a favorite → navigate there (the coordinator also reveals it in the
    /// tree below).
    var onSelect: ((URL) -> Void)?

    let view = NSView()
    /// Fired when the favorites count changes, so the host can re-fit the
    /// (resizable) pane height.
    var onCountChanged: ((Int) -> Void)?

    /// The view to focus for this pane (Tab cycling), and the Tab passthrough.
    var keyView: NSView { tableView }
    var onTab: ((Bool) -> Void)? {
        get { tableView.onTab }
        set { tableView.onTab = newValue }
    }

    /// Give the list a hard selection (first row) if it has none — so arriving via
    /// Tab leaves the keyboard immediately usable.
    func ensureSelection() {
        if tableView.selectedRow < 0 && tableView.numberOfRows > 0 {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    private let tableView = FavoritesTableView()
    private var favorites: [URL] = []
    private var clickedURL: URL?

    static let rowHeight: CGFloat = 22
    /// Space above the list (the "Favorites" header + gaps).
    static let headerArea: CGFloat = 24

    /// The pane height that shows `rows` favorites — clamped to the actual count
    /// (min one row of drop area). Used for the default fit and the minimum size.
    func preferredHeight(rows: Int) -> CGFloat {
        let n = min(max(favorites.count, 1), max(rows, 1))
        return Self.headerArea + CGFloat(n) * Self.rowHeight + 6
    }

    override init() {
        super.init()
        buildView()
        favorites = Favorites.shared.folders()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onContextMenu = { [weak self] row in self?.contextMenu(forRow: row) }
        tableView.registerForDraggedTypes([.fileURL])
        tableView.reloadData()
        NotificationCenter.default.addObserver(
            self, selector: #selector(favoritesDidChange), name: Favorites.didChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func favoritesDidChange() {
        favorites = Favorites.shared.folders()
        tableView.reloadData()
        onCountChanged?(favorites.count)
    }

    // MARK: Layout

    private func buildView() {
        let star = NSImageView()
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        star.contentTintColor = .systemYellow
        star.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Favorites")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(star)
        view.addSubview(header)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            star.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            star.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 11),
            star.heightAnchor.constraint(equalToConstant: 11),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: star.trailingAnchor, constant: 5),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private static let cellID = NSUserInterfaceItemIdentifier("favCell")
    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellID
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
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Context menu

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < favorites.count else { return nil }
        clickedURL = favorites[row]
        let menu = NSMenu()
        menu.autoenablesItems = false
        add(menu, "Open", #selector(favOpen(_:)))
        add(menu, "Open in New Window", #selector(favOpenInNewWindow(_:)))
        add(menu, "Open in Terminal", #selector(favTerminal(_:)))
        menu.addItem(.separator())
        add(menu, "Reveal in Finder", #selector(favReveal(_:)))
        add(menu, "Copy Path", #selector(favCopyPath(_:)))
        menu.addItem(.separator())
        add(menu, "Remove from Favorites", #selector(favRemove(_:)))
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func favOpen(_ sender: Any?) { if let url = clickedURL { onSelect?(url) } }
    @objc private func favOpenInNewWindow(_ sender: Any?) {
        if let url = clickedURL { (NSApp.delegate as? AppDelegate)?.openWindow(showing: url) }
    }
    @objc private func favTerminal(_ sender: Any?) { if let url = clickedURL { Shell.openInTerminal(url) } }
    @objc private func favReveal(_ sender: Any?) {
        if let url = clickedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    @objc private func favCopyPath(_ sender: Any?) {
        guard let url = clickedURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
    @objc private func favRemove(_ sender: Any?) { if let url = clickedURL { Favorites.shared.remove(url) } }
}

extension FavoritesController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { favorites.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < favorites.count else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView
            ?? makeCell()
        let url = favorites[row]
        cell.textField?.stringValue = url.lastPathComponent
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < favorites.count else { return }
        onSelect?(favorites[row])
    }

    // Drag a favorite to reorder.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < favorites.count else { return nil }
        return favorites[row] as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !draggedFolderURLs(info).isEmpty else { return [] }
        tableView.setDropRow(row, dropOperation: .above) // always insert between rows
        return .generic
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = draggedFolderURLs(info)
        guard !urls.isEmpty else { return false }
        var index = row
        for url in urls {
            Favorites.shared.insert(url, at: index)
            index += 1
        }
        return true
    }

    private func draggedFolderURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
