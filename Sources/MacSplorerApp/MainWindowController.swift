import AppKit
import MacSplorerCore

/// The main MacSplorer window: a copyable path/address bar on top, a two-pane
/// split (folder tree | details table), and a status bar below. It coordinates
/// the two pane controllers and address-bar navigation.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    private let addressField = AddressTextField()
    private var addressFieldEditor: AddressFieldEditor?
    private let statusLabel = NSTextField(labelWithString: "")
    private let splitView = NSSplitView()
    private let outlineView = FolderOutlineView()
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

    /// Drives the tab bar's "+" button: add a new tab to this window.
    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openWindow(tabbedInto: window)
    }

    /// Vend a custom field editor for the address field so we can navigate when a
    /// completion is committed with Return (not just fill the field).
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard (client as AnyObject?) === addressField else { return nil }
        if addressFieldEditor == nil {
            let editor = AddressFieldEditor()
            editor.isFieldEditor = true
            editor.onCommit = { [weak self] movement in
                guard movement == NSTextMovement.return.rawValue else { return }
                // Defer so the completion machinery finishes inserting first.
                DispatchQueue.main.async { self?.addressEntered() }
            }
            addressFieldEditor = editor
        }
        return addressFieldEditor
    }

    private var initialFolder: URL?

    convenience init(initialFolder: URL? = nil) {
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
        self.initialFolder = initialFolder
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
        Shell.openInTerminal(URL(fileURLWithPath: path))
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

    /// Guards against re-entrancy when `complete(_:)` mutates the field.
    private var isCompleting = false
    /// Whether the change being handled came from a delete (backspace). On a
    /// delete we still show the matches, but don't inline-fill — otherwise the
    /// re-added suffix would fight the deletion.
    private var lastEditWasDelete = false

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === addressField else { return }
        updateTerminalButton()
        guard !isCompleting else { return }
        isCompleting = true
        addressField.currentEditor()?.complete(nil)
        isCompleting = false
        lastEditWasDelete = false // consumed; next change defaults to typing
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.deleteBackward(_:))
            || commandSelector == #selector(NSResponder.deleteForward(_:)) {
            lastEditWasDelete = true
        }
        return false
    }

    /// Type-ahead: complete the path segment under the cursor against the real
    /// directory contents. We derive the segment from the last "/" ourselves
    /// (rather than the field editor's word range) so names with dots — e.g.
    /// `report.txt` — complete correctly, and we suffix folders with "/" so you
    /// can keep traversing.
    func control(_ control: NSControl, textView: NSTextView,
                 completions words: [String], forPartialWordRange charRange: NSRange,
                 indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        index.pointee = -1 // default: don't inline-fill; just show the list
        let text = textView.string as NSString
        let end = charRange.location + charRange.length
        let head = text.substring(to: end) as NSString
        let slash = head.range(of: "/", options: .backwards).location
        guard slash != NSNotFound else { return [] }

        let dirStart = slash + 1
        // The field editor's word range can start before our path segment (e.g.
        // just after typing a "/"); skip completion that instant rather than
        // dropping a negative number of chars below.
        guard charRange.location >= dirStart, end >= dirStart else { return [] }
        let typedDir = text.substring(to: dirStart)        // as typed (may hold "~")
        let dirPath = (typedDir as NSString).expandingTildeInPath
        let partial = text.substring(with: NSRange(location: dirStart, length: end - dirStart))
        let leadingLen = charRange.location - dirStart

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else {
            return []
        }
        let showHidden = Preferences.shared.showHiddenFiles
        let lowerPartial = partial.lowercased()
        // Each match's "display" is the full entry name, folders suffixed "/".
        let displays = entries
            .filter { name in
                (showHidden || !name.hasPrefix(".")) && name.lowercased().hasPrefix(lowerPartial)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name -> String in
                var entryIsDir: ObjCBool = false
                let full = (dirPath as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: full, isDirectory: &entryIsDir)
                return entryIsDir.boolValue ? name + "/" : name
            }

        // Exactly one match → pre-select it so the field inline-completes: the
        // not-yet-typed remainder appears selected, and Tab/Enter act on it
        // without arrowing down a one-item list. Skip the inline-fill while
        // deleting, so the re-added suffix doesn't fight backspacing — the
        // popover still shows the match for context.
        if displays.count == 1 && !lastEditWasDelete {
            index.pointee = 0
        }
        // Each item replaces only `charRange`, so keep the already-typed leading
        // chars of the segment.
        return displays.map { String($0.dropFirst(min(leadingLen, $0.count))) }
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
        if let initialFolder { navigate(to: initialFolder) }
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
