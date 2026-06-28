import AppKit
import MacSplorerCore

/// One tab's worth of browsing: a copyable path/address bar (the FAB) on top, a
/// two-pane split (folder tree | details table), and a status bar below. It
/// coordinates the two pane controllers and address-bar navigation. The hosting
/// `MainWindowController` stacks one of these under the tab strip at a time.
final class BrowserPaneController: NSViewController, NSTextFieldDelegate, NSSplitViewDelegate {

    private let addressField = AddressTextField()
    private var addressFieldEditor: AddressFieldEditor?
    private let statusLabel = NSTextField(labelWithString: "")
    private let splitView = NSSplitView()
    private let favoritesSplit = FavoritesSplitView()
    private let outlineView = FolderOutlineView()
    private let tableView = HoverTableView()
    private let terminalButton = NSButton()

    private var treeController: FolderTreeController!
    private var detailsController: DetailsTableController!
    private let favoritesController = FavoritesController()

    private let initialFolder: URL?

    /// The folder this tab is currently showing.
    var currentFolder: URL? { detailsController?.folder }

    /// Fired when the shown folder changes, so the host can retitle the tab/window.
    var onTitleChange: ((String) -> Void)?

    init(initialFolder: URL? = nil) {
        self.initialFolder = initialFolder
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Host-facing commands

    func openSelection() { detailsController.openSelected() }
    func makeNewFolder() { detailsController.makeNewFolder() }

    func applyPreferences() {
        let prefs = Preferences.shared
        treeController.showHiddenFiles = prefs.showHiddenFiles
        detailsController.showHiddenFiles = prefs.showHiddenFiles
        detailsController.singleClickToOpen = prefs.singleClickToOpen
        detailsController.reload()
        treeController.refresh(revealing: detailsController.folder)
        applyFavoritesVisibility()
    }

    /// Show or hide the pinned Favorites pane per the preference (re-fitting its
    /// height when shown).
    private func applyFavoritesVisibility() {
        let show = Preferences.shared.showFavorites
        favoritesController.view.isHidden = !show
        if show { refitFavoritesPane() }
    }

    /// Whether the address field holds a real folder (drives the Terminal
    /// button + the File ▸ Open in Terminal menu item).
    var canOpenInTerminal: Bool { terminalButton.isEnabled }

    /// Vend this tab's field editor if `client` is its address field — the host
    /// window delegate routes `windowWillReturnFieldEditor` here.
    func fieldEditor(forClient client: Any?) -> AddressFieldEditor? {
        guard (client as AnyObject?) === addressField else { return nil }
        if addressFieldEditor == nil {
            let editor = AddressFieldEditor()
            editor.isFieldEditor = true
            editor.allowsUndo = true  // enable ⌘Z / ⌘⇧Z in the FAB
            editor.onCommit = { [weak self] movement in
                guard movement == NSTextMovement.return.rawValue
                    || movement == NSTextMovement.tab.rawValue else { return }
                // Defer so the completion machinery finishes inserting first.
                DispatchQueue.main.async { self?.addressEntered() }
            }
            addressFieldEditor = editor
        }
        return addressFieldEditor
    }

    /// Put keyboard focus in the address field (used when a new tab opens).
    func focusAddressField() {
        view.window?.makeFirstResponder(addressField)
    }

    /// Give the folder tree keyboard focus so its selection renders active
    /// (blue) and arrow keys work — used when the window first opens, otherwise
    /// everything shows the gray, unfocused selection until you click.
    func takeInitialFocus() {
        view.window?.makeFirstResponder(outlineView)
    }

    // MARK: - Navigation

    /// Update the details table + address bar + title for `url`. Idempotent, so
    /// the tree-reveal round-trip can call back in without reloading or looping.
    private func showFolder(_ url: URL) {
        guard detailsController.folder?.standardizedFileURL.path != url.standardizedFileURL.path
        else { return }
        detailsController.show(folder: url)
        addressField.stringValue = url.path
        updateTerminalButton()
        let name = url.lastPathComponent
        onTitleChange?(name.isEmpty ? "MacSplorer" : name)
    }

    /// External navigation (address bar, double-click in the details pane): show
    /// the folder AND reveal/select it in the left tree so the tree tracks the
    /// current location.
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
        view.window?.makeFirstResponder(addressField)
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

    /// Enable the Terminal button only when the field holds a real folder path.
    private func updateTerminalButton() {
        let path = (addressField.stringValue as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        terminalButton.isEnabled =
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Address-bar completion (FAB type-ahead)

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

    // MARK: - Setup

    private func wireControllers() {
        treeController = FolderTreeController(outlineView: outlineView)
        detailsController = DetailsTableController(tableView: tableView)

        // Tree click: just show the folder (the tree is already there — don't
        // re-reveal, which would loop). Double-click in details: navigate +
        // reveal so the tree follows.
        treeController.onSelect = { [weak self] url in self?.showFolder(url) }
        // Clicking a Favorite (in the pinned pane above) jumps there: show it AND
        // expand/reveal it in the tree below.
        favoritesController.onSelect = { [weak self] url in self?.navigate(to: url) }
        // Tree folder commands route to the details pane, which owns the file-op
        // implementations — so the left and right folder menus behave identically.
        treeController.onFolderCommand = { [weak self] command, url in
            guard let self else { return }
            switch command {
            case .cut: self.detailsController.cutFolder(url)
            case .copy: self.detailsController.copyFolder(url)
            case .duplicate: self.detailsController.duplicateFolder(url)
            case .trash: self.detailsController.trashFolder(url)
            case .rename: self.detailsController.renameFolder(url)
            case .newFolder: self.detailsController.makeNewFolder(in: url)
            case .newDocument(let type): self.detailsController.makeNewDocument(type, in: url)
            case .internetShortcut: self.detailsController.makeInternetShortcut(in: url)
            }
        }
        detailsController.onOpenFolder = { [weak self] url in self?.navigate(to: url) }
        detailsController.onStatus = { [weak self] status in
            self?.statusLabel.stringValue = status
        }

        addressField.target = self
        addressField.action = #selector(addressEntered)

        let prefs = Preferences.shared
        treeController.showHiddenFiles = prefs.showHiddenFiles
        detailsController.showHiddenFiles = prefs.showHiddenFiles
        detailsController.singleClickToOpen = prefs.singleClickToOpen

        // Selecting Home fires onSelect → navigate, populating the details pane.
        treeController.selectHome()
        if let initialFolder { navigate(to: initialFolder) }
    }

    // MARK: - Layout

    override func loadView() {
        let root = NSView()

        configureAddressField()
        configureTerminalButton()
        configureStatusLabel()
        let leftPane = makeLeftPane()
        let rightScroll = makeDetailsTable()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightScroll)

        root.addSubview(addressField)
        root.addSubview(terminalButton)
        root.addSubview(splitView)
        root.addSubview(statusLabel)

        let pad: CGFloat = 8
        let leftWidth = leftPane.widthAnchor.constraint(equalToConstant: 240)
        leftWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            addressField.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            addressField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            addressField.trailingAnchor.constraint(equalTo: terminalButton.leadingAnchor, constant: -6),

            terminalButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            terminalButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            splitView.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: pad),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: splitView.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),

            leftWidth,
            leftPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        wireControllers()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Once the split has a real size, set the initial Favorites pane height.
        if !didInitialFavoritesFit, favoritesSplit.bounds.height > 0 {
            didInitialFavoritesFit = true
            refitFavoritesPane()
        }
    }

    // MARK: NSSplitViewDelegate (Favorites pane sizing)

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === favoritesSplit else { return proposedMin }
        return favoritesController.preferredHeight(rows: 1) // at least the header + one row
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === favoritesSplit else { return proposedMax }
        return max(favoritesController.preferredHeight(rows: 1),
                   splitView.bounds.height - 120) // keep the tree at least ~120pt
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

    /// Default number of favorites the pane grows to fit before scrolling.
    private static let defaultFavoriteRows = 6
    /// User-chosen pane height (nil = auto-fit). Persisted across launches.
    private var userFavoritesHeight: CGFloat?
    private var didInitialFavoritesFit = false

    /// The left pane: the pinned Favorites list on top and the folder tree below,
    /// split by a draggable divider. The Favorites pane defaults to fitting up to
    /// `defaultFavoriteRows` favorites (then scrolls), but the user can drag the
    /// divider taller; that choice sticks and persists.
    private func makeLeftPane() -> NSView {
        let saved = Preferences.shared.favoritesPaneHeight
        userFavoritesHeight = saved > 0 ? CGFloat(saved) : nil

        favoritesSplit.isVertical = false        // stacked vertically
        favoritesSplit.dividerStyle = .thin
        favoritesSplit.delegate = self
        favoritesSplit.translatesAutoresizingMaskIntoConstraints = false
        favoritesSplit.addArrangedSubview(favoritesController.view)
        favoritesSplit.addArrangedSubview(makeFolderTree())
        // Favorites keeps its height on window resize; the tree absorbs it.
        favoritesSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        favoritesSplit.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        favoritesSplit.onUserDividerDrag = { [weak self] in
            guard let self else { return }
            let height = self.favoritesController.view.frame.height
            self.userFavoritesHeight = height
            Preferences.shared.favoritesPaneHeight = Double(height)
        }
        favoritesController.onCountChanged = { [weak self] _ in self?.refitFavoritesPane() }
        favoritesController.view.isHidden = !Preferences.shared.showFavorites
        return favoritesSplit
    }

    /// Position the divider: the user's chosen height if set, else fit up to
    /// `defaultFavoriteRows` favorites.
    private func refitFavoritesPane() {
        guard favoritesSplit.bounds.height > 0 else { return }
        let target = userFavoritesHeight
            ?? favoritesController.preferredHeight(rows: Self.defaultFavoriteRows)
        favoritesSplit.setPosition(target, ofDividerAt: 0)
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
