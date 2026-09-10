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
    /// File-operation commands from the context menu, routed to the shared model
    /// (same handler as the tree) so the menu is fully functional.
    var onFolderCommand: ((FolderCommand, URL) -> Void)?
    /// The pane's shared model, which owns the transfer machinery (collision
    /// prompts, ⌥-copy, the right-drag menu, promised files). Set by the host so a
    /// drop *onto* a favorite behaves exactly like a drop onto a folder in the
    /// file list. Weak: the model outlives nothing here and owns no reference back.
    weak var contents: FolderContents?

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
        // Navigate on the click action too, not just selection *changes*: clicking
        // an already-selected favorite (e.g. you clicked "Code", browsed elsewhere
        // via the tree — which leaves this list's highlight on "Code" — then clicked
        // "Code" again) fires no selectionDidChange, so it would otherwise do
        // nothing. This fires on every click; the redundant call on a fresh click is
        // a harmless no-op since navigate/showFolder are idempotent.
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.onContextMenu = { [weak self] row in self?.contextMenu(forRow: row) }
        // Promise types too, so a drag out of Outlook/Mail/Photos can land in a
        // favorite the same way it lands in the file list.
        tableView.registerForDraggedTypes([.fileURL] + FolderContents.promiseDragTypes)
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
        return FolderContextMenu.make(for: favorites[row], target: self,
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

extension FavoritesController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { favorites.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < favorites.count else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView
            ?? makeCell()
        let url = favorites[row]
        cell.textField?.stringValue = Self.favoriteLabel(url)
        cell.imageView?.image = url.isFileURL
            ? NSWorkspace.shared.icon(forFile: url.path)
            : FSItem.cloudyFolderIcon   // S3 (profile/bucket/prefix) favorites
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < favorites.count else { return }
        onSelect?(favorites[row])
    }

    /// A click on a favorite row — fires even when the row was already selected,
    /// so re-clicking a favorite always re-navigates (unlike selectionDidChange).
    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < favorites.count else { return }
        onSelect?(favorites[row])
    }

    // Drag a favorite to reorder.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < favorites.count else { return nil }
        return favorites[row] as NSURL
    }

    // Two drop targets, distinguished the way Finder's sidebar does it (and drawn
    // for free by AppKit — a row highlight vs. an insertion line):
    //   ON a row      → copy/move the dragged items INTO that folder
    //   BETWEEN rows  → add/reorder favorites
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on, !isReorderDrag(info), let _ = dropTarget(forRow: row) {
            if let operation = contents?.dragOperation(for: info), operation != [] { return operation }
            // Promised files (Outlook/Mail/Photos/…) are always copied in.
            let promises = contents?.promiseReceivers(from: info) ?? []
            if !promises.isEmpty { return .copy }
            return []
        }
        // Insert-between only means something for folders — they're the only thing
        // that can BE a favorite. A file dragged here has no such meaning, so reject
        // it rather than snapping it onto a neighbouring row: a mis-aimed drop that
        // silently *moved* a file into the wrong folder is worth designing out.
        guard !draggedFolderURLs(info).isEmpty else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .generic
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if dropOperation == .on, !isReorderDrag(info), let destination = dropTarget(forRow: row) {
            return drop(info, into: destination)
        }
        let urls = draggedFolderURLs(info)
        guard !urls.isEmpty else { return false }
        var index = row
        for url in urls {
            Favorites.shared.insert(url, at: index)
            index += 1
        }
        return true
    }

    /// A drag that started in this list is a *reorder*, so it never targets a row.
    /// Otherwise a slightly-low drop while reordering would silently move one
    /// favorite folder inside another — a real filesystem move. You can still move
    /// a folder into a favorite by dragging it from the file list.
    private func isReorderDrag(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSTableView) === tableView
    }

    /// The favorite at `row`, if it can accept a drop. S3 favorites are read-only,
    /// so they're refused up front (no drop highlight) instead of accepting the
    /// drop and then failing with an error alert.
    private func dropTarget(forRow row: Int) -> URL? {
        guard row >= 0, row < favorites.count else { return nil }
        let url = favorites[row]
        return url.isFileURL ? url : nil
    }

    /// Copy/move the dragged items into `destination` via the shared model, so a
    /// drop here gets the same collision prompts, ⌥-copy, right-drag Copy/Move
    /// menu, and promised-file support as a drop in the file list.
    private func drop(_ info: NSDraggingInfo, into destination: URL) -> Bool {
        guard let contents else { return false }
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            // A right-button drag asks the user copy vs move on drop.
            if RightDragSource.shared.isActive {
                let point = tableView.convert(info.draggingLocation, from: nil)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    contents.showRightDropMenu(urls: urls, into: destination,
                                               at: point, in: self.tableView)
                }
                return true
            }
            let move = contents.dragOperation(for: info) == .move
            // Select what landed only if the favorite happens to be the folder the
            // pane is already showing.
            let selectLanded = contents.samePath(destination, contents.folder)
            DispatchQueue.main.async {
                contents.performTransfer(urls, into: destination,
                                         move: move, selectLanded: selectLanded)
            }
            return true
        }
        // No file URLs — accept promised files (Outlook, Mail, Photos, …).
        let receivers = contents.promiseReceivers(from: info)
        guard !receivers.isEmpty else { return false }
        contents.receivePromisedFiles(receivers, into: destination)
        return true
    }

    private func draggedFolderURLs(_ info: NSDraggingInfo) -> [URL] {
        // Not file-URLs-only: an S3 node dragged from the tree/details carries an
        // s3:// URL, which the file-only option would drop.
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.filter { url in
            if url.isFileURL {
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            // Remote (S3) locations are always folders in our model.
            return url.scheme != nil
        }
    }

    /// A favorite's display name. For an S3 profile URL (`s3://profile/`) the last
    /// path component is empty, so fall back to the host (the profile name).
    private static func favoriteLabel(_ url: URL) -> String {
        if !url.isFileURL, url.scheme != nil {
            let segments = url.pathComponents.filter { $0 != "/" }
            if let last = segments.last { return last }
            if let host = url.host, !host.isEmpty { return host }
        }
        return url.lastPathComponent
    }
}
