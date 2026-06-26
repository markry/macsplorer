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
        tableView.action = #selector(handleSingleClick)
        tableView.doubleAction = #selector(handleDoubleClick)
        configureSorting()
    }

    func show(folder url: URL) {
        folder = url
        items = FSItem.contents(of: url, includeHidden: showHiddenFiles)
        sortItems()
        tableView.reloadData()
        if !items.isEmpty { tableView.scrollRowToVisible(0) }
        emitStatus()
    }

    /// Re-list the current folder (e.g. after toggling hidden files).
    func reload() {
        if let folder { show(folder: folder) }
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

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
