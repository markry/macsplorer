import AppKit
import MacSplorerCore

/// Presents a `FolderContents` as the details table (`NSTableView`): configurable
/// columns (Name / dates / Type / Size), sortable, with file icons and inline
/// rename. The model + all file-operation logic lives in `FolderContents`; this
/// class is the table-specific view layer.
final class DetailsTableController: NSObject, FolderContentsPresenter {
    private let tableView: HoverTableView
    private let contents: FolderContents

    private var renamingRow = -1

    /// Mirrors the open-on-single-click preference: drives hover underlining here
    /// and is read by the click handlers below.
    var singleClickToOpen = false {
        didSet { tableView.hoverEnabled = singleClickToOpen }
    }

    init(tableView: HoverTableView, contents: FolderContents) {
        self.tableView = tableView
        self.contents = contents
        super.init()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.fileActions = self
        tableView.action = #selector(handleSingleClick)
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.registerForDraggedTypes([.fileURL] + FolderContents.promiseDragTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        let header = ResizingHeaderView()
        header.onDoubleClickRightEdge = { [weak self] column in self?.sizeColumnToFit(column) }
        tableView.headerView = header
        rebuildColumns()
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnGeometryChanged(_:)),
            name: NSTableView.columnDidResizeNotification, object: tableView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnGeometryChanged(_:)),
            name: NSTableView.columnDidMoveNotification, object: tableView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: FolderContentsPresenter

    var selectedIndexes: IndexSet { tableView.selectedRowIndexes }

    func selectItems(at indexes: IndexSet) {
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    func reloadContents() { tableView.reloadData() }

    func reloadItem(at index: Int) {
        guard index < tableView.numberOfRows, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    func scrollToTop() { if tableView.numberOfRows > 0 { tableView.scrollRowToVisible(0) } }

    /// Called when this view becomes the active presenter, or preferences change.
    func activate() {
        contents.presenter = self
        tableView.hoverEnabled = singleClickToOpen
        // Keep the header's sort arrow in sync with the model's sort.
        tableView.sortDescriptors = [NSSortDescriptor(key: contents.sortKey,
                                                       ascending: contents.sortAscending)]
        tableView.reloadData()
    }

    // MARK: Columns

    /// (Re)build columns from `Preferences.detailsColumns`, restoring saved widths
    /// and preserving the active sort where possible.
    func rebuildColumns() {
        persistColumnGeometry()
        let priorSort = tableView.sortDescriptors.first
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }

        let widths = Preferences.shared.detailsColumnWidths
        for id in Preferences.shared.detailsColumns {
            guard let spec = DetailsColumnSpec.spec(id: id) else { continue }
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = spec.title
            column.minWidth = spec.minWidth
            column.width = widths[id].map { CGFloat($0) } ?? spec.defaultWidth
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            tableView.addTableColumn(column)
        }
        tableView.headerView?.menu = headerMenu

        if let priorSort,
           tableView.tableColumns.contains(where: { $0.identifier.rawValue == priorSort.key }) {
            tableView.sortDescriptors = [priorSort]
        } else {
            tableView.sortDescriptors = [NSSortDescriptor(key: contents.sortKey,
                                                          ascending: contents.sortAscending)]
        }
        tableView.reloadData()
    }

    private var fixingColumnOrder = false

    @objc private func columnGeometryChanged(_ note: Notification) {
        persistColumnGeometry()
        guard note.name == NSTableView.columnDidMoveNotification, !fixingColumnOrder else { return }
        // Columns reorder freely by dragging the header; we only insist that Name
        // stays first — if a drag displaced it, slide it back to slot 0.
        if let nameIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }),
           nameIndex != 0 {
            fixingColumnOrder = true
            tableView.moveColumn(nameIndex, toColumn: 0)
            fixingColumnOrder = false
        }
        Preferences.shared.detailsColumns = tableView.tableColumns.map { $0.identifier.rawValue }
    }

    private func persistColumnGeometry() {
        guard !tableView.tableColumns.isEmpty else { return }
        var widths = Preferences.shared.detailsColumnWidths
        for column in tableView.tableColumns {
            widths[column.identifier.rawValue] = Double(column.width)
        }
        Preferences.shared.detailsColumnWidths = widths
    }

    private lazy var headerMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    @objc private func toggleHeaderColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.toggleDetailsColumn(id)
    }

    /// Grow/shrink a column to just fit its widest cell (double-click its right
    /// divider, spreadsheet-style). Measures every row's text in that column.
    func sizeColumnToFit(_ columnIndex: Int) {
        guard tableView.tableColumns.indices.contains(columnIndex) else { return }
        let column = tableView.tableColumns[columnIndex]
        let id = column.identifier.rawValue
        let cellFont = NSFont.systemFont(ofSize: 13)
        var maxWidth = (column.title as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width + 16
        for item in contents.items {
            var width = (cellText(for: item, columnId: id) as NSString)
                .size(withAttributes: [.font: cellFont]).width
            if id == "name" { width += 22 }   // file icon (16) + leading/gap
            maxWidth = max(maxWidth, width)
        }
        column.width = min(max(ceil(maxWidth) + 12, column.minWidth), 1200)
        persistColumnGeometry()
    }

    /// The plain text a column shows for an item — shared by the cells and the
    /// fit-to-content measurement so they always agree.
    private func cellText(for item: FSItem, columnId: String) -> String {
        switch columnId {
        case "name":           return item.name
        case "dateModified":   return FSFormat.date(item.modificationDate)
        case "dateCreated":    return FSFormat.date(item.creationDate)
        case "dateAdded":      return FSFormat.date(item.addedToDirectoryDate)
        case "dateLastOpened": return FSFormat.date(item.lastOpenedDate)
        case "type":           return item.typeDescription ?? (item.isDirectory ? "Folder" : "")
        case "size":           return item.needsPackageSize ? "" : FSFormat.size(item.displayByteSize)
        default:               return ""
        }
    }

    // MARK: Cells

    private func makeCell(for id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id

        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
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

    // MARK: Click actions

    @objc private func handleDoubleClick() {
        contents.openItem(at: tableView.clickedRow)
    }

    @objc private func handleSingleClick() {
        guard singleClickToOpen else { return }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.shift) || modifiers.contains(.command) { return }
        contents.openItem(at: tableView.clickedRow)
    }

    // Host-facing command kept for the responder path.
    func openSelected() { contents.openSelected() }
}

// MARK: - Table data source / delegate

extension DetailsTableController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { contents.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let item = contents.item(at: row) else { return nil }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? makeCell(for: column.identifier)
        if item.isParentLink {
            if column.identifier.rawValue == "name" {
                cell.imageView?.image = NSImage(systemSymbolName: "arrow.turn.up.left",
                                                accessibilityDescription: "Parent folder")
                cell.textField?.isEditable = false
                cell.textField?.isBordered = false
                cell.textField?.drawsBackground = false
                cell.textField?.stringValue = ".."
            } else {
                cell.textField?.stringValue = ""
            }
            return cell
        }
        switch column.identifier.rawValue {
        case "name":
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.textField?.isEditable = false
            cell.textField?.isBordered = false
            cell.textField?.drawsBackground = false
            if self.tableView.hoverEnabled && self.tableView.hoveredRow == row {
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
        case "dateCreated":
            cell.textField?.stringValue = FSFormat.date(item.creationDate)
        case "dateAdded":
            cell.textField?.stringValue = FSFormat.date(item.addedToDirectoryDate)
        case "dateLastOpened":
            cell.textField?.stringValue = FSFormat.date(item.lastOpenedDate)
        case "type":
            cell.textField?.stringValue = item.typeDescription ?? (item.isDirectory ? "Folder" : "")
        case "size":
            if item.needsPackageSize {
                cell.textField?.stringValue = ""
                contents.scheduleSizeCheck(for: item)
            } else {
                cell.textField?.stringValue = FSFormat.size(item.displayByteSize)
            }
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = tableView.sortDescriptors.first else { return }
        contents.setSort(key: sort.key ?? "name", ascending: sort.ascending)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        contents.emitStatus()
    }
}

// MARK: - Header column-picker menu

extension DetailsTableController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === headerMenu else { return }
        menu.removeAllItems()
        let visible = Set(Preferences.shared.detailsColumns)
        for spec in DetailsColumnSpec.toggleable {
            let item = NSMenuItem(title: spec.title,
                                  action: #selector(toggleHeaderColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec.id
            item.state = visible.contains(spec.id) ? .on : .off
            menu.addItem(item)
        }
    }
}

// MARK: - File-operation commands (responder chain → FolderContents)

extension DetailsTableController: HoverTableFileActions {
    var hasSelection: Bool { contents.hasSelection }
    var canPaste: Bool { contents.canPaste }
    var selectedFileURLs: [URL] { contents.selectedFileURLs }

    func copySelectedItems() { contents.copySelectedItems() }
    func cutSelectedItems() { contents.cutSelectedItems() }
    func pasteIntoFolder() { contents.pasteIntoFolder() }
    func trashSelectedItems() { contents.trashSelectedItems() }
    func duplicateSelectedItems() { contents.duplicateSelectedItems() }
    func renameSelectedItem() { contents.renameSelectedItem() }

    func contextMenu(forClickedRow row: Int) -> NSMenu? {
        if contents.item(at: row)?.isParentLink == true { return nil }
        return contents.contextMenu(clickedIndex: row, target: contents)
    }
}

// MARK: - Inline rename (in the name cell)

extension DetailsTableController: NSTextFieldDelegate {
    func beginRename(at row: Int) {
        guard contents.item(at: row) != nil,
              let nameColumn = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" })
        else { return }
        tableView.window?.makeFirstResponder(tableView)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField, let item = contents.item(at: row) else { return }
        field.isEditable = true
        field.isBordered = true
        field.drawsBackground = true
        field.delegate = self
        field.stringValue = item.name
        renamingRow = row
        contents.isRenaming = true
        tableView.editColumn(nameColumn, row: row, with: nil, select: false)
        if field.currentEditor() == nil {
            tableView.window?.makeFirstResponder(field)
        }
        guard let editor = field.currentEditor() else {
            renamingRow = -1
            contents.isRenaming = false
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            return
        }
        let nsName = item.name as NSString
        let baseLength = (nsName.deletingPathExtension as NSString).length
        editor.selectedRange = (baseLength > 0 && baseLength < nsName.length)
            ? NSRange(location: 0, length: baseLength)
            : NSRange(location: 0, length: nsName.length)
    }

    /// Esc cancels the rename cleanly.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renamingRow = -1
        contents.isRenaming = false
        control.abortEditing()
        let tv = tableView
        DispatchQueue.main.async { [weak self] in
            self?.contents.reload()
            tv.window?.makeFirstResponder(tv)
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard renamingRow >= 0 else { return }
        let row = renamingRow
        renamingRow = -1
        contents.isRenaming = false
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        let canceled = movement == NSTextMovement.cancel.rawValue
        let newName = (obj.object as? NSTextField)?.stringValue ?? ""
        var renamed = false
        if !canceled { renamed = contents.commitRename(at: row, to: newName) }
        if !renamed { contents.reload() }
        let tv = tableView
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
    }
}

// MARK: - Drag & drop

extension DetailsTableController {
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let item = contents.item(at: row), !item.isParentLink else { return nil }
        return item.url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let folder = contents.folder { FolderChange.notify([folder]) }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let destination = dropDestination(forRow: row, operation: dropOperation) else { return [] }
        if contents.samePath(destination, contents.folder) {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        let operation = contents.dragOperation(for: info)
        if operation != [] { return operation }
        // Promised files (Outlook/Mail/Photos/…) are always copied in.
        return contents.promiseReceivers(from: info).isEmpty ? [] : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let destination = dropDestination(forRow: row, operation: dropOperation) else { return false }
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            // A right-button drag asks the user copy vs move on drop.
            if RightDragSource.shared.isActive {
                let point = tableView.convert(info.draggingLocation, from: nil)
                DispatchQueue.main.async { [weak self] in
                    self?.contents.showRightDropMenu(urls: urls, into: destination, at: point, in: tableView)
                }
                return true
            }
            let move = contents.dragOperation(for: info) == .move
            let selectLanded = contents.samePath(destination, contents.folder)
            DispatchQueue.main.async { [weak self] in
                self?.contents.performTransfer(urls, into: destination, move: move, selectLanded: selectLanded)
            }
            return true
        }
        // No file URLs — accept promised files (Outlook, Mail, Photos, …).
        let receivers = contents.promiseReceivers(from: info)
        guard !receivers.isEmpty else { return false }
        contents.receivePromisedFiles(receivers, into: destination)
        return true
    }

    private func dropDestination(forRow row: Int, operation: NSTableView.DropOperation) -> URL? {
        if operation == .on, let item = contents.item(at: row), item.isDirectory, !item.isPackage {
            return item.url
        }
        return contents.folder
    }
}

/// A header view that reports a double-click on a column's right divider, so the
/// column can size itself to fit its content (spreadsheet-style).
final class ResizingHeaderView: NSTableHeaderView {
    var onDoubleClickRightEdge: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let column = columnAtRightEdge(point) {
                onDoubleClickRightEdge?(column)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func columnAtRightEdge(_ point: NSPoint) -> Int? {
        guard let tableView else { return nil }
        let tolerance: CGFloat = 5
        for index in 0..<tableView.numberOfColumns where abs(point.x - headerRect(ofColumn: index).maxX) <= tolerance {
            return index
        }
        return nil
    }
}
