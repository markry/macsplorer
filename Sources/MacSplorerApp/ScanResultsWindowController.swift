import AppKit
import MacSplorerCore

/// A window showing the result of a folder-size scan: an indented outline of
/// folders with their size-on-disk and share of the scanned total, biggest
/// first. Double-click a row to jump the originating window there.
final class ScanResultsWindowController: NSWindowController, NSWindowDelegate,
                                          NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let root: SizeNode
    private let outlineView = NSOutlineView()

    /// Navigate the originating window to a folder (double-click).
    var onOpenFolder: ((URL) -> Void)?
    /// Fired when this window closes, so the owner can release it.
    var onClose: (() -> Void)?

    init(root: SizeNode) {
        self.root = root
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Folder Sizes — \(root.name)  (\(FSFormat.size(root.totalSize)))"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildLayout()
        outlineView.reloadData()
        outlineView.expandItem(root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func buildLayout() {
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Folder"
        nameColumn.width = 420
        nameColumn.minWidth = 200
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 110
        sizeColumn.minWidth = 80
        outlineView.addTableColumn(sizeColumn)

        let percentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("percent"))
        percentColumn.title = "% of Total"
        percentColumn.width = 90
        percentColumn.minWidth = 70
        outlineView.addTableColumn(percentColumn)

        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.indentationPerLevel = 14

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(scroll)
        if let content = window?.contentView {
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: content.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    @objc private func handleDoubleClick() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SizeNode else { return }
        onOpenFolder?(node.url)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return 1 } // the scanned root sits at the top
        return (item as? SizeNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return root }
        return (item as! SizeNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SizeNode)?.children.isEmpty ?? true)
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let column = tableColumn, let node = item as? SizeNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? makeCell(for: column.identifier)
        switch column.identifier.rawValue {
        case "name":
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
            cell.textField?.stringValue = node.name
        case "size":
            cell.textField?.stringValue = FSFormat.size(node.totalSize)
        case "percent":
            let share = root.totalSize > 0 ? Double(node.totalSize) / Double(root.totalSize) * 100 : 0
            cell.textField?.stringValue = String(format: "%.1f%%", share)
        default:
            break
        }
        return cell
    }

    private func makeCell(for id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.usesSingleLineMode = true
        text.lineBreakMode = .byTruncatingMiddle
        text.font = .systemFont(ofSize: 12)
        if id.rawValue != "name" { text.alignment = .right }
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
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }
}
