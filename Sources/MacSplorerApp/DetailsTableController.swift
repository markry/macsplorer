import AppKit
import MacSplorerCore

/// Drives the right-hand details table (`NSTableView`): the contents of one
/// folder shown as Name / Date Modified / Type / Size, sortable by column, with
/// file icons. Double-click opens files (default app) or navigates into folders.
final class DetailsTableController: NSObject {
    private let tableView: HoverTableView
    private(set) var folder: URL?
    private var items: [FSItem] = []

    /// User opened a folder (double-click) — coordinator should navigate to it.
    var onOpenFolder: ((URL) -> Void)?
    /// Fresh status-bar text (item / selection counts).
    var onStatus: ((String) -> Void)?

    private var renamingRow = -1
    private let watcher = DirectoryWatcher()

    /// Packages whose aggregate-size computation is in flight, to avoid
    /// scheduling the same walk twice.
    private var pendingSizeChecks = Set<ObjectIdentifier>()

    /// Whether hidden (dot) files are shown. Set, then call `reload`.
    var showHiddenFiles = false

    /// When true, a plain single click opens (web-style) and rows underline on
    /// hover; ⇧/⌘ clicks still just adjust the selection.
    var singleClickToOpen = false {
        didSet { tableView.hoverEnabled = singleClickToOpen }
    }

    init(tableView: HoverTableView) {
        self.tableView = tableView
        super.init()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.fileActions = self
        tableView.action = #selector(handleSingleClick)
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        configureSorting()
        NotificationCenter.default.addObserver(
            self, selector: #selector(folderDidChange(_:)),
            name: FolderChange.didChange, object: nil)
        // Live-refresh on external changes (Finder deletes, finished downloads…).
        watcher.onChange = { [weak self] in self?.reload() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Re-list when a file operation (in this or another window) changed the
    /// folder we're showing.
    @objc private func folderDidChange(_ note: Notification) {
        guard let folder else { return }
        let path = folder.standardizedFileURL.path
        if FolderChange.folders(from: note).contains(where: { $0.path == path }) {
            reload()
        }
    }

    func show(folder url: URL) {
        folder = url
        watcher.watch(url)
        items = FSItem.contents(of: url, includeHidden: showHiddenFiles)
        sortItems()
        tableView.reloadData()
        if !items.isEmpty { tableView.scrollRowToVisible(0) }
        emitStatus()
    }

    /// Re-list the current folder in place, preserving the selection by path
    /// (used after file changes / hidden-files toggle), unlike `show(folder:)`
    /// which is for navigating to a new folder.
    func reload() {
        // Don't yank the table out from under an in-progress inline rename — e.g.
        // the directory watcher firing for the folder we just created in would
        // otherwise reloadData and cancel the edit the instant it began.
        guard renamingRow < 0 else { return }
        guard let folder else { return }
        let selectedPaths = Set(tableView.selectedRowIndexes.filter { $0 < items.count }
            .map { items[$0].url.standardizedFileURL.path })
        items = FSItem.contents(of: folder, includeHidden: showHiddenFiles)
        sortItems()
        tableView.reloadData()
        if !selectedPaths.isEmpty {
            let rows = items.enumerated()
                .filter { selectedPaths.contains($0.element.url.standardizedFileURL.path) }
                .map(\.offset)
            if !rows.isEmpty {
                tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
            }
        }
        emitStatus()
    }

    // MARK: Sorting

    private func configureSorting() {
        for column in tableView.tableColumns {
            column.sortDescriptorPrototype =
                NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
    }

    private func sortItems() {
        guard let sort = tableView.sortDescriptors.first else { return }
        let key = sort.key ?? "name"
        items.sort { a, b in
            // Folders always group before files, regardless of column/direction.
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var result = Self.order(a, b, key: key)
            if result == .orderedSame {
                result = a.name.localizedStandardCompare(b.name)
            }
            if !sort.ascending { result = result.reversed }
            return result == .orderedAscending
        }
    }

    private static func order(_ a: FSItem, _ b: FSItem, key: String) -> ComparisonResult {
        switch key {
        case "dateModified": return compareOptional(a.modificationDate, b.modificationDate)
        case "size":         return compareOptional(a.displayByteSize, b.displayByteSize)
        case "type":         return (a.typeDescription ?? "")
                                    .localizedStandardCompare(b.typeDescription ?? "")
        default:             return a.name.localizedStandardCompare(b.name)
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

    // MARK: Cells

    private func makeCell(for id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id

        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        // Single-line keeps row heights uniform — no wrapping/shifting on hover.
        // Names truncate in the middle so the tail + extension stay visible
        // (Finder style); other columns truncate at the tail.
        text.usesSingleLineMode = true
        text.maximumNumberOfLines = 1
        text.lineBreakMode = (id.rawValue == "name") ? .byTruncatingMiddle : .byTruncatingTail
        text.font = .systemFont(ofSize: 13)
        cell.textField = text
        cell.addSubview(text)

        if id.rawValue == "name" {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = icon
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    // MARK: Actions

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        openItem(items[row])
    }

    /// Single click: open only in single-click mode, and only for a plain click
    /// — ⇧/⌘ clicks are selection gestures, so let the table handle those.
    @objc private func handleSingleClick() {
        guard singleClickToOpen else { return }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.shift) || modifiers.contains(.command) { return }
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        openItem(items[row])
    }

    /// Open the current selection (⌘O / File ▸ Open): a folder navigates in,
    /// files launch in their default apps.
    func openSelected() {
        let rows = tableView.selectedRowIndexes.filter { $0 < items.count }
        guard !rows.isEmpty else { return }
        for row in rows { openItem(items[row]) }
    }

    private func openItem(_ item: FSItem) {
        if item.isDirectory && !item.isPackage {
            onOpenFolder?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func emitStatus() {
        let count = items.count
        let selection = tableView.selectedRowIndexes
        if selection.isEmpty {
            onStatus?("\(count) item\(count == 1 ? "" : "s")")
        } else if selection.count == 1, let row = selection.first {
            let item = items[row]
            // Plain folders show no size; files and packages do.
            let showSize = !item.isDirectory || item.isPackage
            let size = showSize ? " · \(FSFormat.size(item.displayByteSize))" : ""
            onStatus?("\(count) items · 1 selected\(size)")
        } else {
            let total = selection.reduce(0) { $0 + (items[$1].displayByteSize ?? 0) }
            onStatus?("\(count) items · \(selection.count) selected · \(FSFormat.size(total))")
        }
    }

    /// Compute a package's aggregate size off the main thread, then fill in just
    /// that row's size cell. Mirrors the tree's background subfolder probe.
    private func scheduleSizeCheck(for item: FSItem) {
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
                let col = self.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
                guard col >= 0 else { return }
                self.tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                                          columnIndexes: IndexSet(integer: col))
            }
        }
    }
}

extension DetailsTableController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < items.count else { return nil }
        let item = items[row]
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? makeCell(for: column.identifier)
        switch column.identifier.rawValue {
        case "name":
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            // Reset any edit-mode appearance left on a reused cell.
            cell.textField?.isEditable = false
            cell.textField?.isBordered = false
            cell.textField?.drawsBackground = false
            if self.tableView.hoverEnabled && self.tableView.hoveredRow == row {
                // Carry the single-line middle-truncation through the attributed
                // (underlined) string too, so hovering can't make a name wrap.
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingMiddle
                cell.textField?.attributedStringValue = NSAttributedString(
                    string: item.name,
                    attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .paragraphStyle: paragraph])
            } else {
                cell.textField?.stringValue = item.name
            }
        case "dateModified":
            cell.textField?.stringValue = FSFormat.date(item.modificationDate)
        case "type":
            cell.textField?.stringValue = item.typeDescription ?? (item.isDirectory ? "Folder" : "")
        case "size":
            if item.needsPackageSize {
                cell.textField?.stringValue = ""   // fill in once computed
                scheduleSizeCheck(for: item)
            } else {
                cell.textField?.stringValue = FSFormat.size(item.displayByteSize)
            }
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortItems()
        tableView.reloadData()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        emitStatus()
    }
}

// MARK: - File-operation commands

extension DetailsTableController: HoverTableFileActions {
    var hasSelection: Bool { !tableView.selectedRowIndexes.isEmpty }
    var canPaste: Bool { Clipboard.shared.canPaste }
    var selectedFileURLs: [URL] { selectedItemURLs() }

    func copySelectedItems() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        Clipboard.shared.set(urls, operation: .copy)
    }

    func cutSelectedItems() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        Clipboard.shared.set(urls, operation: .cut)
    }

    func pasteIntoFolder() {
        guard let folder else { return }
        let (urls, move) = Clipboard.shared.pasteSource()
        guard !urls.isEmpty else { return }
        performTransfer(urls, into: folder, move: move, selectLanded: true)
        if move { Clipboard.shared.clearAfterMove() }
    }

    func trashSelectedItems() {
        let urls = selectedURLs()
        guard !urls.isEmpty, let folder else { return }
        for url in urls {
            do { _ = try FileOperations.moveToTrash(url) } catch { NSSound.beep() }
        }
        finishMutation(affected: [folder])
    }

    func renameSelectedItem() {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        beginRenameDeferred(named: items[row].url.lastPathComponent)
    }

    /// The reliable way to start an inline rename, used by every trigger (menu,
    /// keyboard, and post-creation).
    ///
    /// We schedule the edit to run **only in the default run-loop mode**. This is
    /// the crux of the menu flakiness: `DispatchQueue.main.async` is serviced even
    /// while a context menu's tracking run loop is still active, so the edit
    /// sometimes tried to start mid-teardown (and silently failed) and sometimes
    /// after — exactly "sometimes works, sometimes doesn't." `perform(inModes:
    /// [.default])` waits until the menu has fully closed. (The keyboard path is
    /// already in default mode, so it was always reliable.)
    ///
    /// Inside the block we focus the list (matching the keyboard path's state) and
    /// re-find the row by name, so a reload in between can't target the wrong row.
    private func beginRenameDeferred(named name: String) {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self,
                  let row = self.items.firstIndex(where: { $0.url.lastPathComponent == name })
            else { return }
            self.tableView.window?.makeFirstResponder(self.tableView)
            self.beginRename(row: row)
        }
    }

    /// Create a new folder in `directory` (the current folder if nil). When it
    /// lands in the visible folder, select it and start renaming.
    func makeNewFolder(in directory: URL? = nil) {
        guard let target = directory ?? folder else { return }
        showTargetThenCreate(in: target) {
            try FileOperations.newFolder(in: target).lastPathComponent
        }
    }

    /// Show `target` (navigating into it if it isn't already the visible folder),
    /// run `create` to make a new item there, then select it and begin inline
    /// rename. Centralizes the "create something + name it" flow.
    private func showTargetThenCreate(in target: URL, _ create: () throws -> String) {
        if !samePath(target, folder) { onOpenFolder?(target) } // make it visible first
        do {
            let name = try create()
            finishMutation(affected: [target], selecting: [name], renameFirst: true)
        } catch {
            NSSound.beep()
        }
    }

    private func selectedURLs() -> [URL] {
        tableView.selectedRowIndexes.filter { $0 < items.count }.map { items[$0].url }
    }

    /// Broadcast the affected folders (refreshing this + other windows + the
    /// tree), then select/begin-rename newly-created items in this folder.
    private func finishMutation(affected: Set<URL>, selecting names: [String] = [], renameFirst: Bool = false) {
        FolderChange.notify(Array(affected))
        guard !names.isEmpty else { return }
        let wanted = Set(names)
        let rows = items.enumerated()
            .filter { wanted.contains($0.element.url.lastPathComponent) }
            .map(\.offset)
        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        if renameFirst, let name = names.first { beginRenameDeferred(named: name) }
    }
}

// MARK: - In-place rename

extension DetailsTableController: NSTextFieldDelegate {
    func beginRename(row: Int) {
        guard row >= 0, row < items.count,
              let nameColumn = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" })
        else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        field.isEditable = true
        field.isBordered = true
        field.drawsBackground = true
        field.delegate = self
        field.stringValue = items[row].name // plain text, drop any hover underline
        renamingRow = row
        // Start editing through the table (caller has focused it). Fall back to
        // focusing the field directly, and if neither actually begins editing,
        // clear `renamingRow` so a failed attempt can't jam future renames.
        tableView.window?.makeFirstResponder(tableView)
        tableView.editColumn(nameColumn, row: row, with: nil, select: false)
        if field.currentEditor() == nil {
            tableView.window?.makeFirstResponder(field)
        }
        guard let editor = field.currentEditor() else {
            renamingRow = -1
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            return
        }
        // Select just the base name (excluding ".ext"), Finder-style, so typing
        // preserves the suffix. Dotfiles / extension-less names select all.
        let nsName = items[row].name as NSString
        let baseLength = (nsName.deletingPathExtension as NSString).length
        editor.selectedRange = (baseLength > 0 && baseLength < nsName.length)
            ? NSRange(location: 0, length: baseLength)
            : NSRange(location: 0, length: nsName.length)
    }

    /// Esc cancels the rename cleanly. The default field-editor abort wasn't
    /// reliably restoring the cell, so handle it: mark it canceled (so
    /// `controlTextDidEndEditing` no-ops), abort the editor, and reload on the
    /// next tick to drop the edit appearance.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renamingRow = -1
        control.abortEditing()
        let tv = tableView
        DispatchQueue.main.async { [weak self] in
            self?.reload()
            tv.window?.makeFirstResponder(tv)  // keep the list focused (blue, arrows work)
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard renamingRow >= 0, renamingRow < items.count else { return }
        let row = renamingRow
        renamingRow = -1
        let item = items[row]
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        let canceled = movement == NSTextMovement.cancel.rawValue
        let newName = (obj.object as? NSTextField)?.stringValue ?? item.name
        var renamed = false
        if !canceled, newName.trimmingCharacters(in: .whitespacesAndNewlines) != item.name {
            do {
                let dest = try FileOperations.rename(item.url, to: newName)
                finishMutation(affected: [item.url.deletingLastPathComponent()],
                               selecting: [dest.lastPathComponent])
                renamed = true
            } catch {
                NSSound.beep()
            }
        }
        if !renamed { reload() } // restore label appearance / original name
        // Return focus to the list so the selection stays active (blue) and
        // arrow/Return keys keep working after the edit.
        let tv = tableView
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
    }
}

// MARK: - Drag & drop

extension DetailsTableController {
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < items.count else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // The other side (Finder/another window) may have moved files out of
        // here, and the reported operation isn't always reliable (e.g. a
        // "Keep Both" rename on collision reports a copy), so refresh our folder
        // whenever a drag out of it ends.
        if let folder { FolderChange.notify([folder]) }
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let destination = dropDestination(forRow: row, operation: dropOperation) else { return [] }
        // Dropping into the current folder: highlight the whole list, not a row.
        if samePath(destination, folder) {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return dragOperation(for: info)
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let destination = dropDestination(forRow: row, operation: dropOperation) else { return false }
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }

        let move = dragOperation(for: info) == .move
        let selectLanded = samePath(destination, folder)
        // Defer so any collision prompt doesn't run inside the drop handler.
        DispatchQueue.main.async { [weak self] in
            self?.performTransfer(urls, into: destination, move: move, selectLanded: selectLanded)
        }
        return true
    }

    /// A drop targets a subfolder row (drop ON a folder) or the current folder.
    private func dropDestination(forRow row: Int, operation: NSTableView.DropOperation) -> URL? {
        if operation == .on, row >= 0, row < items.count,
           items[row].isDirectory, !items[row].isPackage {
            return items[row].url
        }
        return folder
    }

    /// Move by default; copy when ⌥ is held (or when move isn't offered).
    private func dragOperation(for info: NSDraggingInfo) -> NSDragOperation {
        let allowed = info.draggingSourceOperationMask
        if NSEvent.modifierFlags.contains(.option) { return allowed.contains(.copy) ? .copy : [] }
        if allowed.contains(.move) { return .move }
        return allowed.contains(.copy) ? .copy : []
    }

    private func isSelfOrDescendant(_ url: URL, of directory: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let dir = directory.standardizedFileURL.path
        return dir == target || dir.hasPrefix(target + "/")
    }

    private func samePath(_ a: URL?, _ b: URL?) -> Bool {
        a?.standardizedFileURL.path == b?.standardizedFileURL.path
    }
}

// MARK: - Transfer with collision handling

private extension DetailsTableController {
    enum CollisionChoice { case keepBoth, replace, stop }

    /// Copy or move `urls` into `destination`, resolving name collisions per the
    /// user's preference (silent keep-both, or a Finder-style prompt), then refresh.
    func performTransfer(_ urls: [URL], into destination: URL, move: Bool, selectLanded: Bool) {
        var landed: [String] = []
        var affected: Set<URL> = [destination]
        var applyToAll: CollisionChoice?
        let ask = Preferences.shared.promptOnCollision

        for url in urls {
            if isSelfOrDescendant(url, of: destination) { continue }
            let target = destination.appendingPathComponent(url.lastPathComponent)
            let sameParent = samePath(url.deletingLastPathComponent(), destination)
            let collides = !sameParent && FileManager.default.fileExists(atPath: target.path)

            var choice: CollisionChoice = .keepBoth
            if collides {
                if !ask {
                    choice = .keepBoth
                } else if let all = applyToAll {
                    choice = all
                } else {
                    let result = askCollision(name: url.lastPathComponent, in: destination,
                                              multiple: urls.count > 1)
                    if result.applyToAll { applyToAll = result.choice }
                    choice = result.choice
                }
            }
            if choice == .stop { break }

            do {
                switch choice {
                case .keepBoth:
                    let dest = move ? try FileOperations.move(url, into: destination)
                                    : try FileOperations.copy(url, into: destination)
                    landed.append(dest.lastPathComponent)
                case .replace:
                    _ = try? FileOperations.moveToTrash(target) // existing → Trash (recoverable)
                    let dest = move ? try FileOperations.move(url, to: target)
                                    : try FileOperations.copy(url, to: target)
                    landed.append(dest.lastPathComponent)
                case .stop:
                    break
                }
                if move { affected.insert(url.deletingLastPathComponent()) }
            } catch {
                NSSound.beep()
            }
        }
        finishMutation(affected: affected, selecting: selectLanded ? landed : [])
    }

    func askCollision(name: String, in destination: URL,
                      multiple: Bool) -> (choice: CollisionChoice, applyToAll: Bool) {
        let alert = NSAlert()
        alert.messageText = "An item named “\(name)” already exists in “\(destination.lastPathComponent)”."
        alert.informativeText = "Keep both items, replace the existing one, or stop?"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Stop")
        var checkbox: NSButton?
        if multiple {
            let box = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
            box.sizeToFit()
            alert.accessoryView = box
            checkbox = box
        }
        let response = alert.runModal()
        let applyToAll = checkbox?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.keepBoth, applyToAll)
        case .alertSecondButtonReturn: return (.replace, applyToAll)
        default: return (.stop, applyToAll)
        }
    }
}

// MARK: - Context menu + extra commands

extension DetailsTableController {
    func contextMenu(forClickedRow row: Int) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if row < 0 || row >= items.count {
            // Empty space → act on the current folder.
            if let folder { menu.addItem(newMenuItem(for: folder)) }
            add(menu, "Paste", #selector(ctxPaste(_:)), enabled: Clipboard.shared.canPaste)
            menu.addItem(.separator())
            add(menu, "Open in Terminal", #selector(ctxTerminal(_:)))
            add(menu, "Reveal in Finder", #selector(ctxReveal(_:)))
            add(menu, "Copy Path", #selector(ctxCopyPath(_:)))
            return menu
        }
        let item = items[row]
        let isFolder = item.isDirectory && !item.isPackage
        add(menu, "Open", #selector(ctxOpen(_:)))
        if isFolder {
            add(menu, "Open in New Window", #selector(ctxOpenInNewWindow(_:)))
            add(menu, "Open in Terminal", #selector(ctxTerminal(_:)))
            menu.addItem(newMenuItem(for: item.url))
        } else {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = OpenWith.submenu(for: item.url, target: self,
                                                action: #selector(ctxOpenWithApp(_:)))
            menu.addItem(openWith)
        }
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
        if isFolder, !Favorites.shared.contains(item.url) {
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

    // MARK: New ▸ submenu

    private enum NewKind {
        case folder
        case document(NewDocumentType)
        case internetShortcut
    }
    /// Boxed (kind, target folder) carried on each New ▸ item's representedObject.
    private final class NewAction {
        let kind: NewKind
        let directory: URL
        init(_ kind: NewKind, in directory: URL) { self.kind = kind; self.directory = directory }
    }

    /// A "New ▸" submenu that creates items in `directory`: Folder, the document
    /// types, and an Internet Shortcut from the clipboard URL.
    private func newMenuItem(for directory: URL) -> NSMenuItem {
        let item = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let folderIcon = NSImage(named: NSImage.folderName) ?? NSImage()
        addNew(submenu, "Folder", NewAction(.folder, in: directory), icon: folderIcon)
        submenu.addItem(.separator())
        for type in NewDocument.types {
            addNew(submenu, type.title, NewAction(.document(type), in: directory),
                   icon: NewDocument.icon(forExtension: type.ext))
        }
        submenu.addItem(.separator())
        let shortcut = addNew(submenu, "Internet Shortcut",
                              NewAction(.internetShortcut, in: directory),
                              icon: NewDocument.icon(forExtension: "url"))
        shortcut.isEnabled = NewDocument.clipboardURL() != nil
        shortcut.toolTip = shortcut.isEnabled
            ? nil : "Copy a web link to the clipboard first"

        item.submenu = submenu
        return item
    }

    @discardableResult
    private func addNew(_ menu: NSMenu, _ title: String, _ action: NewAction,
                        icon: NSImage) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ctxNew(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        menu.addItem(item)
        return item
    }

    @objc private func ctxNew(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? NewAction else { return }
        switch action.kind {
        case .folder: makeNewFolder(in: action.directory)
        case .document(let type): makeNewDocument(type, in: action.directory)
        case .internetShortcut: makeInternetShortcut(in: action.directory)
        }
    }

    /// Create an empty `untitled.<ext>` file and drop into inline rename.
    func makeNewDocument(_ type: NewDocumentType, in directory: URL? = nil) {
        guard let target = directory ?? folder else { return }
        showTargetThenCreate(in: target) {
            try FileOperations.newFile(
                in: target, named: "\(NewDocument.defaultBaseName).\(type.ext)").lastPathComponent
        }
    }

    /// Write the clipboard URL as a cross-platform `.url` Internet Shortcut.
    func makeInternetShortcut(in directory: URL? = nil) {
        guard let target = directory ?? folder,
              let urlString = NewDocument.clipboardURL() else { NSSound.beep(); return }
        showTargetThenCreate(in: target) {
            let data = NewDocument.internetShortcutData(for: urlString)
            return try FileOperations.newFile(
                in: target, named: "\(NewDocument.defaultBaseName).url", contents: data).lastPathComponent
        }
    }

    @objc private func ctxOpen(_ sender: Any?) { openSelected() }
    @objc private func ctxCut(_ sender: Any?) { cutSelectedItems() }
    @objc private func ctxCopy(_ sender: Any?) { copySelectedItems() }
    @objc private func ctxPaste(_ sender: Any?) { pasteIntoFolder() }
    @objc private func ctxDuplicate(_ sender: Any?) { duplicateSelectedItems() }
    @objc private func ctxRename(_ sender: Any?) { renameSelectedItem() }
    @objc private func ctxTrash(_ sender: Any?) { trashSelectedItems() }
    @objc private func ctxReveal(_ sender: Any?) { revealSelection() }
    @objc private func ctxCopyPath(_ sender: Any?) { copySelectionPaths() }
    @objc private func ctxTerminal(_ sender: Any?) { openSelectionInTerminal() }
    @objc private func ctxAddFavorite(_ sender: Any?) {
        if let url = singleSelectedFolderURL() { Favorites.shared.add(url) }
    }
    @objc private func ctxOpenInNewWindow(_ sender: Any?) {
        if let url = singleSelectedFolderURL() {
            (NSApp.delegate as? AppDelegate)?.openWindow(showing: url)
        }
    }
    @objc private func ctxOpenWithApp(_ sender: NSMenuItem) {
        let urls = selectedItemURLs()
        if let appURL = sender.representedObject as? URL {
            OpenWith.open(urls, with: appURL)
        } else {
            OpenWith.openWithOtherApp(urls) // "Other…"
        }
    }

    func duplicateSelectedItems() {
        let urls = selectedItemURLs()
        guard !urls.isEmpty, let folder else { return }
        var names: [String] = []
        for url in urls {
            do { names.append(try FileOperations.copy(url, into: folder).lastPathComponent) }
            catch { NSSound.beep() }
        }
        finishMutation(affected: [folder], selecting: names)
    }

    func revealSelection() {
        let urls = selectedItemURLs()
        if urls.isEmpty {
            if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func copySelectionPaths() {
        let urls = selectedItemURLs()
        let paths = urls.isEmpty ? (folder.map { [$0.path] } ?? []) : urls.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func openSelectionInTerminal() {
        guard let target = singleSelectedFolderURL() ?? folder else { return }
        Shell.openInTerminal(target)
    }

    private func selectedItemURLs() -> [URL] {
        tableView.selectedRowIndexes.filter { $0 < items.count }.map { items[$0].url }
    }

    private func singleSelectedFolderURL() -> URL? {
        let rows = tableView.selectedRowIndexes
        guard rows.count == 1, let row = rows.first, row < items.count else { return nil }
        let item = items[row]
        return (item.isDirectory && !item.isPackage) ? item.url : nil
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
