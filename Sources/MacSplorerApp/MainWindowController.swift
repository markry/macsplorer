import AppKit
import MacSplorerCore

/// The main MacSplorer window: a copyable path/address bar on top, a two-pane
/// split (folder tree | details table), and a status bar below. It coordinates
/// the two pane controllers and address-bar navigation.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    private let addressField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let splitView = NSSplitView()
    private let outlineView = NSOutlineView()
    private let tableView = HoverTableView()
    private let terminalButton = NSButton()

    private var treeController: FolderTreeController!
    private var detailsController: DetailsTableController!

    /// Invoked when this window closes, so the app can release its controller.
    var onClose: (() -> Void)?

    /// Re-read persisted preferences into both panes. Called on every open
    /// window when a preference toggles, so all windows stay in sync.
    func applyPreferences() {
        let prefs = Preferences.shared
        treeController.showHiddenFiles = prefs.showHiddenFiles
        detailsController.showHiddenFiles = prefs.showHiddenFiles
        detailsController.singleClickToOpen = prefs.singleClickToOpen
        detailsController.reload()
        treeController.refresh(revealing: detailsController.folder)
    }

    /// Open the current details selection (File ▸ Open / ⌘O).
    func openSelection() {
        detailsController.openSelected()
    }

    /// Create a new folder in the current directory (File ▸ New Folder).
    func makeNewFolder() {
        detailsController.makeNewFolder()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
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
        window.center()
        self.init(window: window)
        window.delegate = self
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
        updateTerminalButton()
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
        let raw = (addressField.stringValue as NSString).expandingTildeInPath
        let trimmed = (raw.count > 1 && raw.hasSuffix("/")) ? String(raw.dropLast()) : raw
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory) else {
            NSSound.beep()
            return
        }
        let url = URL(fileURLWithPath: caseCorrectedPath(trimmed))
        if isDirectory.boolValue {
            navigate(to: url)
            // Append "/" and leave the cursor at the end (no select-all) so you
            // can keep typing the next segment — rapid keyboard traversal.
            setAddress(url.path.hasSuffix("/") ? url.path : url.path + "/", cursorAtEnd: true)
        } else {
            // A file path: open it (Finder convention, not rename) and show its
            // folder for context.
            navigate(to: url.deletingLastPathComponent())
            NSWorkspace.shared.open(url)
            setAddress(url.path, cursorAtEnd: true)
        }
    }

    /// Correct the casing of `path` to match what's actually on disk (the volume
    /// is case-insensitive but case-preserving), component by component, without
    /// resolving symlinks — so a path you paste elsewhere matches the real names
    /// while friendly symlink names (e.g. ~/OneDrive) are preserved.
    private func caseCorrectedPath(_ path: String) -> String {
        var corrected = URL(fileURLWithPath: "/")
        for component in URL(fileURLWithPath: path).pathComponents.dropFirst() {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: corrected.path)) ?? []
            let match = entries.first { $0.caseInsensitiveCompare(component) == .orderedSame }
            corrected.appendPathComponent(match ?? component)
        }
        return corrected.path
    }

    /// Set the address field text, keeping focus with the cursor at the end.
    private func setAddress(_ text: String, cursorAtEnd: Bool) {
        addressField.stringValue = text
        updateTerminalButton()
        guard cursorAtEnd else { return }
        window?.makeFirstResponder(addressField)
        if let editor = addressField.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    @objc func openInTerminal() {
        let path = (addressField.stringValue as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { NSSound.beep(); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }

    /// Whether the address field currently holds a real folder (drives the
    /// Terminal button + menu item enablement).
    var canOpenInTerminal: Bool { terminalButton.isEnabled }

    /// Enable the Terminal button only when the field holds a real folder path.
    private func updateTerminalButton() {
        let path = (addressField.stringValue as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        terminalButton.isEnabled =
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === addressField { updateTerminalButton() }
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

        // Apply persisted preferences before the first load.
        let prefs = Preferences.shared
        treeController.showHiddenFiles = prefs.showHiddenFiles
        detailsController.showHiddenFiles = prefs.showHiddenFiles
        detailsController.singleClickToOpen = prefs.singleClickToOpen

        // Selecting Home fires onSelect → navigate, populating the details pane.
        treeController.selectHome()
    }

    // MARK: Layout

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        configureAddressField()
        configureTerminalButton()
        configureStatusLabel()
        let leftScroll = makeFolderTree()
        let rightScroll = makeDetailsTable()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(leftScroll)
        splitView.addArrangedSubview(rightScroll)

        contentView.addSubview(addressField)
        contentView.addSubview(terminalButton)
        contentView.addSubview(splitView)
        contentView.addSubview(statusLabel)

        let pad: CGFloat = 8
        let leftWidth = leftScroll.widthAnchor.constraint(equalToConstant: 240)
        leftWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            addressField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: pad),
            addressField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            addressField.trailingAnchor.constraint(equalTo: terminalButton.leadingAnchor, constant: -6),

            terminalButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            terminalButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),

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
        addressField.delegate = self
        addressField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureTerminalButton() {
        terminalButton.translatesAutoresizingMaskIntoConstraints = false
        terminalButton.bezelStyle = .texturedRounded
        terminalButton.image = NSImage(systemSymbolName: "terminal",
                                        accessibilityDescription: "Open in Terminal")
        terminalButton.imagePosition = .imageOnly
        terminalButton.target = self
        terminalButton.action = #selector(openInTerminal)
        terminalButton.toolTip = "Open this folder in Terminal"
        terminalButton.setContentHuggingPriority(.required, for: .horizontal)
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
