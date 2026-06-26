import AppKit
import MacSplorerCore

/// The main MacSplorer window: a copyable path/address bar on top, a two-pane
/// split (folder tree | details table) in the middle, and a status bar below.
///
/// This first checkpoint wires the full layout and controls but no data — the
/// filesystem model gets plugged into these data sources next.
final class MainWindowController: NSWindowController {

    private let addressField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let splitView = NSSplitView()
    private let outlineView = NSOutlineView()   // left: folder tree
    private let tableView = NSTableView()        // right: details

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacSplorer"
        window.minSize = NSSize(width: 680, height: 380)
        window.setFrameAutosaveName("MacSplorerMainWindow")
        window.center()
        self.init(window: window)
        buildLayout()
    }

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        configureAddressField()
        configureStatusLabel()
        let leftScroll = makeFolderTree()
        let rightScroll = makeDetailsTable()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(leftScroll)
        splitView.addArrangedSubview(rightScroll)

        contentView.addSubview(addressField)
        contentView.addSubview(splitView)
        contentView.addSubview(statusLabel)

        let pad: CGFloat = 8
        let leftWidth = leftScroll.widthAnchor.constraint(equalToConstant: 240)
        leftWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            addressField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: pad),
            addressField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            addressField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),

            splitView.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: pad),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: splitView.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            leftWidth,
            leftScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    private func configureAddressField() {
        addressField.stringValue = FileManager.default.homeDirectoryForCurrentUser.path
        addressField.isEditable = true
        addressField.isSelectable = true
        addressField.isBordered = true
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: 13)
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.placeholderString = "Path"
        addressField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureStatusLabel() {
        statusLabel.stringValue = "MacSplorer \(MacSplorer.version) — ready"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeFolderTree() -> NSScrollView {
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func makeDetailsTable() -> NSScrollView {
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("name", "Name", 300),
            ("dateModified", "Date Modified", 170),
            ("type", "Type", 130),
            ("size", "Size", 90),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 48
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.autosaveName = "MacSplorerDetailsTable"
        tableView.autosaveTableColumns = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }
}

// MARK: - Folder tree data (placeholder: empty until the model is wired)

extension MainWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { NSObject() }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
}

// MARK: - Details table data (placeholder: empty until the model is wired)

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 0 }
}
