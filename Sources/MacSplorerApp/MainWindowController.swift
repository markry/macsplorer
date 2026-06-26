import AppKit
import MacSplorerCore

/// The main MacSplorer window: a copyable path/address bar on top, a two-pane
/// split (folder tree | details table), and a status bar below. It coordinates
/// the two pane controllers and address-bar navigation.
final class MainWindowController: NSWindowController {

    private let addressField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let splitView = NSSplitView()
    private let outlineView = NSOutlineView()
    private let tableView = NSTableView()

    private var treeController: FolderTreeController!
    private var detailsController: DetailsTableController!

    private(set) var showHiddenFiles = false

    /// Toggle hidden (dot) files in both panes, keeping the current location.
    func toggleShowHiddenFiles() {
        showHiddenFiles.toggle()
        treeController.showHiddenFiles = showHiddenFiles
        detailsController.showHiddenFiles = showHiddenFiles
        detailsController.reload()
        treeController.refresh(revealing: detailsController.folder)
    }

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
        wireControllers()
    }

    // MARK: Navigation

    /// Update the details table + address bar + title for `url`. Idempotent, so
    /// the tree-reveal round-trip can call back in without reloading or looping.
    private func showFolder(_ url: URL) {
        guard detailsController.folder?.standardizedFileURL.path != url.standardizedFileURL.path
        else { return }
        detailsController.show(folder: url)
        addressField.stringValue = url.path
        let name = url.lastPathComponent
        window?.title = name.isEmpty ? "MacSplorer" : name
    }

    /// External navigation (address bar, double-click in the details pane):
    /// show the folder AND reveal/select it in the left tree so the tree tracks
    /// the current location.
    func navigate(to url: URL) {
        showFolder(url)
        treeController.reveal(url)
    }

    @objc private func addressEntered() {
        let path = (addressField.stringValue as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            navigate(to: URL(fileURLWithPath: path))
        } else {
            NSSound.beep()
        }
    }

    private func wireControllers() {
        treeController = FolderTreeController(outlineView: outlineView)
        detailsController = DetailsTableController(tableView: tableView)

        // Tree click: just show the folder (the tree is already there — don't
        // re-reveal, which would loop). Double-click in details: navigate +
        // reveal so the tree follows.
        treeController.onSelect = { [weak self] url in self?.showFolder(url) }
        detailsController.onOpenFolder = { [weak self] url in self?.navigate(to: url) }
        detailsController.onStatus = { [weak self] status in
            self?.statusLabel.stringValue = status
        }

        addressField.target = self
        addressField.action = #selector(addressEntered)

        // Selecting Home fires onSelect → navigate, populating the details pane.
        treeController.selectHome()
    }

    // MARK: Layout

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
        statusLabel.stringValue = "MacSplorer \(MacSplorer.version)"
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
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
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
