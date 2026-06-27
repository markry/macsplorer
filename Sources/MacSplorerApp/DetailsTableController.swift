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
        case "size":         return compareOptional(a.byteSize, b.byteSize)
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
            let size = item.isDirectory ? "" : " · \(FSFormat.size(item.byteSize))"
            onStatus?("\(count) items · 1 selected\(size)")
        } else {
            let total = selection.reduce(0) { $0 + (items[$1].byteSize ?? 0) }
            onStatus?("\(count) items · \(selection.count) selected · \(FSFormat.size(total))")
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
            cell.textField?.stringValue = FSFormat.size(item.byteSize)
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
        beginRename(row: tableView.selectedRow)
    }

    /// Create a new folder in the current directory, then start renaming it.
    func makeNewFolder() {
        guard let folder else { return }
        do {
            let url = try FileOperations.newFolder(in: folder)
            finishMutation(affected: [folder], selecting: [url.lastPathComponent], renameFirst: true)
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
        if renameFirst, let first = rows.first { beginRename(row: first) }
    }
}

// MARK: - In-place rename

extension DetailsTableController: NSTextFieldDelegate {
    func beginRename(row: Int) {
        guard row >= 0, row < items.count,
              let nameColumn = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" })
        else { return }
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renamingRow = row
        field.isEditable = true
        field.isBordered = true
        field.drawsBackground = true
        field.delegate = self
        field.stringValue = items[row].name // plain text, drop any hover underline
        tableView.editColumn(nameColumn, row: row, with: nil, select: false)
        // Select just the base name (excluding ".ext"), Finder-style, so typing
        // preserves the suffix. Dotfiles / extension-less names select all.
        if let editor = field.currentEditor() {
            let nsName = items[row].name as NSString
            let baseLength = (nsName.deletingPathExtension as NSString).length
            editor.selectedRange = (baseLength > 0 && baseLength < nsName.length)
                ? NSRange(location: 0, length: baseLength)
                : NSRange(location: 0, length: nsName.length)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard renamingRow >= 0, renamingRow < items.count else { return }
        let row = renamingRow
        renamingRow = -1
        let item = items[row]
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        let canceled = movement == NSTextMovement.cancel.rawValue
        let newName = (obj.object as? NSTextField)?.stringValue ?? item.name
        if !canceled, newName.trimmingCharacters(in: .whitespacesAndNewlines) != item.name {
            do {
                let dest = try FileOperations.rename(item.url, to: newName)
                finishMutation(affected: [item.url.deletingLastPathComponent()],
                               selecting: [dest.lastPathComponent])
                return
            } catch {
                NSSound.beep()
            }
        }
        reload() // restore label appearance / original name
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

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
