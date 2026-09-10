import AppKit
import MacSplorerCore
import MacSplorerS3

/// One tab's worth of browsing: a copyable path/address bar (the FAB) on top, a
/// two-pane split (folder tree | details table), and a status bar below. It
/// coordinates the two pane controllers and address-bar navigation. The hosting
/// `MainWindowController` stacks one of these under the tab strip at a time.
final class BrowserPaneController: NSViewController, NSTextFieldDelegate, NSSplitViewDelegate {

    private let addressField = AddressTextField()
    private let pathBar = PathBarView()

    // Browser-style back/forward: two chevrons left of the address bar, driving a
    // per-tab history of visited folders. `historyIndex` points at the current
    // entry; going back/forward moves within it, navigating fresh truncates the
    // forward tail. `isNavigatingHistory` stops back/forward from re-recording.
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private var history: [URL] = []
    private var historyIndex = -1
    private var isNavigatingHistory = false
    private var addressFieldEditor: AddressFieldEditor?
    private let statusLabel = NSTextField(labelWithString: "")
    /// Spinner shown at the leading edge of the status bar while a remote (S3)
    /// folder is loading — feedback that a network read is in flight.
    private let loadSpinner = NSProgressIndicator()
    private let statusStack = NSStackView()
    private let viewModeControl = ViewModeControl()

    // Folder-size scan (occasional, background) — status-bar feedback + Stop.
    private let scanSpinner = NSProgressIndicator()
    private let scanStopButton = NSButton()
    private let scanControls = NSStackView()
    private var activeScan: FolderSizeScanner?
    private var scanProgressTimer: Timer?
    private var scanStartDate: Date?
    private let splitView = NSSplitView()
    private let favoritesSplit = FavoritesSplitView()
    private let outlineView = FolderOutlineView()
    private let tableView = HoverTableView()
    private let terminalButton = NSButton()

    /// The right pane's swappable host (details table or icon grid live inside).
    private let rightContainer = NSView()
    private var detailsScroll: NSScrollView!

    /// The shared model + commands for this tab; both views present it.
    private let contents = FolderContents()
    private var treeController: FolderTreeController!
    private var detailsController: DetailsTableController!
    /// Built lazily the first time the icon view is shown.
    private var iconController: IconViewController?
    private let favoritesController = FavoritesController()

    /// Right-pane view ("list"/"icon") + icon size are per-window state — changing
    /// one window doesn't disturb others. Seeded from the persisted default.
    private var viewMode = Preferences.shared.rightPaneView
    private var iconSize = Preferences.shared.iconSize

    private let initialFolder: URL?

    /// The folder this tab is currently showing.
    var currentFolder: URL? { contents.folder }

    /// Fired when the shown folder changes, so the host can retitle the tab/window.
    var onTitleChange: ((String) -> Void)?

    init(initialFolder: URL? = nil) {
        self.initialFolder = initialFolder
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Host-facing commands

    /// Route a folder context-menu command (from the tree or Favorites) to the
    /// shared model.
    private func handleFolderCommand(_ command: FolderCommand, url: URL) {
        switch command {
        case .cut: contents.cutFolder(url)
        case .copy: contents.copyFolder(url)
        case .duplicate: contents.duplicateFolder(url)
        case .trash: contents.trashFolder(url)
        case .rename: contents.renameFolder(url)
        case .newFolder: contents.makeNewFolder(in: url)
        case .newDocument(let type): contents.makeNewDocument(type, in: url)
        case .internetShortcut: contents.makeInternetShortcut(in: url)
        }
    }

    func openSelection() { contents.openSelected() }
    func makeNewFolder() { contents.makeNewFolder() }
    func makeNewDocument(_ type: NewDocumentType) { contents.makeNewDocument(type) }
    func makeInternetShortcut() { contents.makeInternetShortcut() }

    /// Rebuild the details-pane columns from the persisted visible set (after the
    /// user toggles a column on/off).
    func rebuildDetailsColumns() { detailsController.rebuildColumns() }

    var currentViewMode: String { viewMode }
    var currentIconSize: String { iconSize }

    /// Set this window's right-pane view + size, persisting it as the default for
    /// newly-opened windows (without disturbing other open windows).
    func setViewMode(_ mode: String, iconSize size: String?) {
        viewMode = mode
        if let size { iconSize = size }
        Preferences.shared.rightPaneView = mode
        if let size { Preferences.shared.iconSize = size }
        applyViewMode()
    }

    /// Switch the right pane between the details list and the icon grid (and apply
    /// the chosen icon size) per this window's `viewMode` / `iconSize`.
    func applyViewMode() {
        let size = IconSize(rawValue: iconSize) ?? .large
        if viewMode == "icon" {
            let controller = iconController ?? {
                let made = IconViewController(contents: contents)
                made.onTab = { [weak self] back in self?.advanceFocus(from: .right, backward: back) }
                iconController = made
                return made
            }()
            controller.setSize(size)
            showRightView(controller.scrollView)
            controller.activate()
            viewModeControl.setActive(.icon(size))
        } else {
            showRightView(detailsScroll)
            detailsController.activate()
            viewModeControl.setActive(.list)
        }
    }

    private func showRightView(_ view: NSView) {
        guard view.superview !== rightContainer || rightContainer.subviews.count != 1 else {
            // Already the lone child — still re-pin in case size class changed.
            return
        }
        rightContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
        ])
    }

    func applyPreferences() {
        let prefs = Preferences.shared
        treeController.showHiddenFiles = prefs.showHiddenFiles
        contents.showHiddenFiles = prefs.showHiddenFiles
        contents.singleClickToOpen = prefs.singleClickToOpen
        contents.showUpItem = prefs.showParentItem
        detailsController.singleClickToOpen = prefs.singleClickToOpen
        contents.reload()
        treeController.applyRootPreferences(revealing: contents.folder)
        treeController.refresh(revealing: contents.folder)
        applyFavoritesVisibility()
    }

    /// Show or hide the pinned Favorites pane per the preference. Hiding
    /// *collapses* the split pane (which removes the pane and its divider) — just
    /// hiding the view leaves a blank gap. Showing restores it to its fitted size.
    private func applyFavoritesVisibility() {
        let show = Preferences.shared.showFavorites
        guard favoritesSplit.bounds.height > 0 else {
            // Before layout — the initial fit in viewDidLayout will finalize this.
            favoritesController.view.isHidden = !show
            return
        }
        if show {
            favoritesController.view.isHidden = false
            refitFavoritesPane()
        } else {
            favoritesSplit.setPosition(0, ofDividerAt: 0) // collapse: hides pane + divider
        }
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

    /// Put keyboard focus in the address field (used when a new tab opens). Enters
    /// edit mode first, since the field is hidden behind the breadcrumb otherwise.
    func focusAddressField() {
        beginAddressEditing()
    }

    /// Give the folder tree keyboard focus so its selection renders active
    /// (blue) and arrow keys work — used when the window first opens, otherwise
    /// everything shows the gray, unfocused selection until you click.
    func takeInitialFocus() {
        view.window?.makeFirstResponder(outlineView)
    }

    // MARK: - Navigation

    /// A stable identity for a location so re-navigating to the same place is a
    /// no-op. File URLs compare by standardized path (case/symlink-tolerant); a
    /// remote URL (s3://…) compares by full string, since two different profiles
    /// or buckets can share a path component and must not be treated as identical.
    private func locationKey(_ url: URL?) -> String? {
        guard let url else { return nil }
        return isLocal(url) ? url.standardizedFileURL.path : url.absoluteString
    }

    /// Local = a file URL or a bare path (no scheme); anything with a non-file
    /// scheme (s3://) is a remote provider location.
    private func isLocal(_ url: URL) -> Bool { url.isFileURL || url.scheme == nil }

    /// The editable address-field text for `url`. Local: the plain path. S3: the
    /// real S3 URI `s3://bucket/key` at bucket level or deeper (a genuine URI AWS
    /// tools accept); `/Volumes/profile` at the profile level, where no S3 URI
    /// exists yet. (The breadcrumb chips, shown when not editing, are separate.)
    private func addressString(for url: URL) -> String {
        guard !isLocal(url) else { return url.path }
        switch S3Location.parse(url) {
        case .prefix(_, let bucket, let key): return "s3://\(bucket)/\(key)"
        case .profile(let profile):           return "\(S3Mount.volumesURL.path)/\(profile)"
        case .root, .none:                     return S3Mount.volumesURL.path
        }
    }

    /// The window/tab title for `url` — the last meaningful segment (prefix or
    /// bucket), else the profile (host), else the scheme ("S3") for the root.
    private func locationTitle(for url: URL) -> String {
        if !isLocal(url) {
            let segments = url.pathComponents.filter { $0 != "/" }
            if let last = segments.last { return last }
            if let host = url.host, !host.isEmpty { return host }
            return url.scheme?.uppercased() ?? "MacSplorer"
        }
        let name = url.lastPathComponent
        return name.isEmpty ? "MacSplorer" : name
    }

    /// Update the details table + address bar + title for `url`. Idempotent, so
    /// the tree-reveal round-trip can call back in without reloading or looping.
    private func showFolder(_ url: URL) {
        guard locationKey(contents.folder) != locationKey(url) else { return }
        contents.show(folder: url)
        addressField.stringValue = addressString(for: url)
        pathBar.setURL(url)
        updateTerminalButton()
        onTitleChange?(locationTitle(for: url))
        recordHistory(url)
    }

    // MARK: - Back / Forward history

    /// Append `url` as the new current entry (unless we're moving through history),
    /// dropping any forward entries — the browser convention.
    private func recordHistory(_ url: URL) {
        guard !isNavigatingHistory else { return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(url)
        historyIndex = history.count - 1
        updateHistoryButtons()
    }

    @objc private func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        navigateThroughHistory(to: history[historyIndex])
    }

    @objc private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        navigateThroughHistory(to: history[historyIndex])
    }

    private func navigateThroughHistory(to url: URL) {
        isNavigatingHistory = true
        navigate(to: url)
        isNavigatingHistory = false
        updateHistoryButtons()
    }

    private func updateHistoryButtons() {
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex < history.count - 1
    }

    /// External navigation (address bar, double-click in the details pane): show
    /// the folder AND reveal/select it in the left tree so the tree tracks the
    /// current location.
    func navigate(to url: URL) {
        showFolder(url)
        // The left tree is local-only for now; revealing a remote (s3://) location
        // would spuriously match the "/" root by path prefix. Skip it.
        if isLocal(url) { treeController.reveal(url) }
    }

    /// The AWS profile of the current S3 location, if we're in one.
    private func currentS3Profile() -> String? {
        guard let folder = contents.folder else { return nil }
        switch S3Location.parse(folder) {
        case .profile(let profile):      return profile
        case .prefix(let profile, _, _): return profile
        default:                         return nil
        }
    }

    /// If `path` is `/Volumes/<name>` and <name> is a connected S3 profile, returns
    /// that name — so typing the profile-level address navigates back into S3.
    private func s3ProfileFromVolumesPath(_ path: String) -> String? {
        let trimmed = (path.count > 1 && path.hasSuffix("/")) ? String(path.dropLast()) : path
        let prefix = S3Mount.volumesURL.path + "/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let name = String(trimmed.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/"), S3Mount.profileNames().contains(name) else { return nil }
        return name
    }

    @objc private func addressEntered() {
        let entered = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        // A real S3 URI (s3://bucket/key): reattach the active profile → the internal
        // s3://profile/bucket/key. Needs an S3 context to know which profile.
        if entered.lowercased().hasPrefix("s3://") {
            guard let profile = currentS3Profile(),
                  let url = S3Location.url(fromUserURI: entered, profile: profile) else {
                NSSound.beep(); return
            }
            navigate(to: url)
            setAddress(addressString(for: url), cursorAtEnd: true)
            return
        }
        // /Volumes/<profile> for a connected S3 profile → that profile's S3 root.
        if let profile = s3ProfileFromVolumesPath(entered) {
            let url = S3Location.url(profile: profile)
            navigate(to: url)
            setAddress(addressString(for: url), cursorAtEnd: true)
            return
        }
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

    /// When focus genuinely leaves the address field, flip back to the breadcrumb.
    /// Deferred + re-checked because Enter navigates and *re-focuses* the field
    /// (we stay in edit mode then); only a real blur should switch.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === addressField else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.addressField.currentEditor() == nil else { return }
            self.setEditing(false)
            self.pathBar.setURL(self.contents.folder)
        }
    }

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
        // Tab reaches here only when no completion is consuming it (nothing left to
        // resolve) — so it advances to the next pane instead of re-descending.
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            advanceFocus(from: .fab, backward: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            advanceFocus(from: .fab, backward: true)
            return true
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
        detailsController = DetailsTableController(tableView: tableView, contents: contents)

        // Tree click: just show the folder (the tree is already there — don't
        // re-reveal, which would loop). Double-click in details: navigate +
        // reveal so the tree follows.
        treeController.onSelect = { [weak self] url in self?.showFolder(url) }
        // Clicking a Favorite (in the pinned pane above) jumps there: show it AND
        // expand/reveal it in the tree below.
        favoritesController.onSelect = { [weak self] url in self?.navigate(to: url) }
        // Folder commands from the tree AND the Favorites pane route to the shared
        // model, which owns the file-op implementations — so every folder menu
        // (left tree, Favorites, right pane) behaves identically.
        treeController.onFolderCommand = { [weak self] command, url in
            self?.handleFolderCommand(command, url: url)
        }
        favoritesController.onFolderCommand = { [weak self] command, url in
            self?.handleFolderCommand(command, url: url)
        }
        // Let a drop *onto* a favorite row copy/move into that folder, using the
        // same transfer machinery as the file list.
        favoritesController.contents = contents
        contents.onOpenFolder = { [weak self] url in self?.navigate(to: url) }
        contents.onStatus = { [weak self] status in
            self?.statusLabel.stringValue = status
        }
        contents.onSelectionChanged = { [weak self] in self?.refreshPathBarForSelection() }
        contents.onLoadingChanged = { [weak self] loading in
            guard let self else { return }
            self.loadSpinner.isHidden = !loading
            if loading { self.loadSpinner.startAnimation(nil) }
            else { self.loadSpinner.stopAnimation(nil) }
        }

        addressField.target = self
        addressField.action = #selector(addressEntered)
        // Breadcrumb: a segment click jumps to that ancestor; a click on the bar's
        // empty area switches to the editable field (Explorer-style).
        pathBar.onSegment = { [weak self] url in self?.navigate(to: url) }
        pathBar.onActivateEdit = { [weak self] in self?.beginAddressEditing() }
        // Tab cycles focus between the main panes.
        tableView.onTab = { [weak self] back in self?.advanceFocus(from: .right, backward: back) }
        outlineView.onTab = { [weak self] back in self?.advanceFocus(from: .tree, backward: back) }
        favoritesController.onTab = { [weak self] back in self?.advanceFocus(from: .favorites, backward: back) }
        // View mode is per-window: apply to this window's tabs only.
        viewModeControl.onSelect = { [weak self] mode in
            guard let self,
                  let windowController = self.view.window?.windowController as? MainWindowController
            else { return }
            switch mode {
            case .list: windowController.setViewMode("list", iconSize: nil)
            case .icon(let size): windowController.setViewMode("icon", iconSize: size.rawValue)
            }
        }

        let prefs = Preferences.shared
        treeController.showHiddenFiles = prefs.showHiddenFiles
        contents.showHiddenFiles = prefs.showHiddenFiles
        contents.singleClickToOpen = prefs.singleClickToOpen
        contents.showUpItem = prefs.showParentItem
        detailsController.singleClickToOpen = prefs.singleClickToOpen

        // Install the active right-pane view (list/icon) before the first
        // navigation, so the model has a presenter to reload into.
        applyViewMode()

        // Selecting Home fires onSelect → navigate, populating the pane.
        treeController.selectHome()
        if let initialFolder { navigate(to: initialFolder) }

        // Start in breadcrumb mode showing the current folder.
        setEditing(false)
        pathBar.setURL(contents.folder)
    }

    // MARK: Tab cycling between the main panes

    private enum Pane { case fab, right, tree, favorites }

    /// Tab moves through FAB → right pane → tree → Favorites → back to FAB (and
    /// Shift-Tab reverses). Favorites is skipped when its pane is hidden.
    private func advanceFocus(from pane: Pane, backward: Bool) {
        var order: [Pane] = [.fab, .right, .tree]
        if Preferences.shared.showFavorites { order.append(.favorites) }
        guard let index = order.firstIndex(of: pane) else { return }
        let count = order.count
        let next = backward ? (index - 1 + count) % count : (index + 1) % count
        focusPane(order[next])
    }

    private func focusPane(_ pane: Pane) {
        switch pane {
        case .fab:
            beginAddressEditing()
        case .right:
            if viewMode == "icon", let icon = iconController {
                view.window?.makeFirstResponder(icon.keyView)
                icon.ensureSelection()
            } else {
                view.window?.makeFirstResponder(tableView)
                if tableView.selectedRow < 0, let first = contents.firstSelectableIndex {
                    tableView.selectRowIndexes([first], byExtendingSelection: false)
                }
            }
        case .tree:
            view.window?.makeFirstResponder(outlineView)
            ensureRowSelection(outlineView)
        case .favorites:
            view.window?.makeFirstResponder(favoritesController.keyView)
            favoritesController.ensureSelection()
        }
    }

    /// Give a table/outline a hard selection (first row) if it has none, so Tab
    /// leaves the keyboard immediately usable.
    private func ensureRowSelection(_ tableView: NSTableView) {
        if tableView.selectedRow < 0 && tableView.numberOfRows > 0 {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    /// Swap the address area between the editable field and the breadcrumb.
    private func setEditing(_ editing: Bool) {
        addressField.isHidden = !editing
        pathBar.isHidden = editing
    }

    /// Reflect the current selection in the breadcrumb: when exactly one item is
    /// highlighted, show its full path with the name as a dimmed leaf — so the path
    /// on screen always matches what ⌘C copies. None / multi-selection falls back to
    /// the current folder. Skipped while the editable field is showing.
    private func refreshPathBarForSelection() {
        guard !pathBar.isHidden else { return }
        let selected = contents.selectedURLs()
        if selected.count == 1 {
            pathBar.setURL(selected[0], previewLeaf: true)
        } else {
            pathBar.setURL(contents.folder)
        }
    }

    /// Enter edit mode: reveal the field with the full real path, a trailing "/"
    /// appended and the cursor placed after it — so you can immediately keep
    /// typing the next segment, just like descending with the FAB.
    private func beginAddressEditing() {
        setEditing(true)
        let base = contents.folder.map(addressString(for:)) ?? addressField.stringValue
        let text = base.hasSuffix("/") ? base : base + "/"
        addressField.stringValue = text
        updateTerminalButton()
        view.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectedRange =
            NSRange(location: (text as NSString).length, length: 0)
    }

    // MARK: - Layout

    override func loadView() {
        let root = NSView()

        configureAddressField()
        configureTerminalButton()
        configureStatusLabel()
        let leftPane = makeLeftPane()
        detailsScroll = makeDetailsTable()
        rightContainer.translatesAutoresizingMaskIntoConstraints = false
        viewModeControl.translatesAutoresizingMaskIntoConstraints = false

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightContainer)

        pathBar.translatesAutoresizingMaskIntoConstraints = false
        configureScanControls()
        configureHistoryButtons()
        root.addSubview(backButton)
        root.addSubview(forwardButton)
        root.addSubview(addressField)
        root.addSubview(pathBar)
        root.addSubview(terminalButton)
        root.addSubview(splitView)
        loadSpinner.style = .spinning
        loadSpinner.controlSize = .small
        loadSpinner.isDisplayedWhenStopped = false
        loadSpinner.isHidden = true
        loadSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.spacing = 5
        statusStack.alignment = .centerY
        statusStack.detachesHiddenViews = true   // collapse the spinner when hidden
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.addArrangedSubview(loadSpinner)
        statusStack.addArrangedSubview(statusLabel)
        root.addSubview(statusStack)
        root.addSubview(scanControls)
        root.addSubview(viewModeControl)

        let pad: CGFloat = 8
        let leftWidth = leftPane.widthAnchor.constraint(equalToConstant: 240)
        leftWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            // Back / forward chevrons at the leading edge, then the address field.
            backButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            backButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 24),

            addressField.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            addressField.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 6),
            addressField.trailingAnchor.constraint(equalTo: terminalButton.leadingAnchor, constant: -6),

            terminalButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            terminalButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            // The breadcrumb occupies the exact same rect as the editable field;
            // exactly one of the two is visible at a time.
            pathBar.topAnchor.constraint(equalTo: addressField.topAnchor),
            pathBar.bottomAnchor.constraint(equalTo: addressField.bottomAnchor),
            pathBar.leadingAnchor.constraint(equalTo: addressField.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: addressField.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: pad),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            statusStack.topAnchor.constraint(equalTo: splitView.bottomAnchor, constant: 4),
            statusStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: scanControls.leadingAnchor, constant: -8),
            statusStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),

            // Scan spinner + Stop sit just left of the view switch (collapsed when
            // idle — the stack drops its hidden subviews).
            scanControls.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            scanControls.trailingAnchor.constraint(equalTo: viewModeControl.leadingAnchor, constant: -8),

            // The three-icon view switch sits at the right end of the status bar.
            viewModeControl.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            viewModeControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            viewModeControl.heightAnchor.constraint(equalToConstant: 22),

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
            applyFavoritesVisibility() // fit if shown, collapse if hidden
        }
    }

    // MARK: NSSplitViewDelegate (Favorites pane sizing)

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        // Only the Favorites pane (top) collapses — used to hide it cleanly.
        splitView === favoritesSplit && subview === favoritesController.view
    }

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
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        // Let the label truncate the long "Scanning… …/path" text instead of
        // forcing the window wider.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureHistoryButtons() {
        func configure(_ button: NSButton, symbol: String, tip: String,
                       action: Selector, key: String) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = tip
            button.keyEquivalent = key                       // ⌘[ / ⌘] — the macOS convention
            button.keyEquivalentModifierMask = [.command]
            button.isEnabled = false                         // enabled by updateHistoryButtons
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        configure(backButton, symbol: "chevron.left", tip: "Back", action: #selector(goBack), key: "[")
        configure(forwardButton, symbol: "chevron.right", tip: "Forward", action: #selector(goForward), key: "]")
    }

    private func configureScanControls() {
        scanSpinner.style = .spinning
        scanSpinner.controlSize = .small
        scanSpinner.isDisplayedWhenStopped = false
        scanSpinner.isHidden = true

        scanStopButton.title = "Stop"
        scanStopButton.bezelStyle = .rounded
        scanStopButton.controlSize = .small
        scanStopButton.font = .systemFont(ofSize: 11)
        scanStopButton.target = self
        scanStopButton.action = #selector(cancelSizeScan)
        scanStopButton.isHidden = true

        scanControls.orientation = .horizontal
        scanControls.spacing = 6
        scanControls.translatesAutoresizingMaskIntoConstraints = false
        scanControls.addArrangedSubview(scanSpinner)
        scanControls.addArrangedSubview(scanStopButton)
    }

    // MARK: - Folder-size scan

    /// Kick off a background size scan rooted at `root` (or this window's current
    /// folder when nil — the File-menu / status-bar entry point).
    func startSizeScan(root: URL? = nil) {
        guard activeScan == nil else { NSSound.beep(); return }   // one at a time
        guard let folder = root ?? contents.folder else { NSSound.beep(); return }
        let scanner = FolderSizeScanner()
        activeScan = scanner
        scanStartDate = Date()
        scanSpinner.isHidden = false
        scanSpinner.startAnimation(nil)
        scanStopButton.isHidden = false
        statusLabel.stringValue = "Scanning…"
        scanProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateScanStatus()
        }
        scanner.scan(root: folder,
                     skipCloudLocations: Preferences.shared.skipCloudInSizeScan) { [weak self] node in
            self?.finishScan(node)
        }
    }

    @objc private func cancelSizeScan() {
        activeScan?.cancel()   // completion fires with nil → finishScan tears down
    }

    /// Get Info on the right pane's selection — or, if nothing is selected, the
    /// current folder itself (so ⌘I always shows *something* useful).
    func getInfoForSelection() {
        let urls = contents.selectedURLs()
        let targets = urls.isEmpty ? [contents.folder].compactMap { $0 } : urls
        guard !targets.isEmpty else { NSSound.beep(); return }
        for url in targets { (NSApp.delegate as? AppDelegate)?.presentGetInfo(for: url) }
    }

    private func updateScanStatus() {
        guard let scanner = activeScan, let start = scanStartDate else { return }
        let progress = scanner.progress()
        let elapsed = max(0.001, Date().timeIntervalSince(start))
        let rate = FSFormat.size(Int64(Double(progress.bytes) / elapsed)) + "/s"
        let path = (progress.currentPath as NSString).abbreviatingWithTildeInPath
        statusLabel.stringValue =
            "Scanning… \(progress.files) files · \(FSFormat.size(progress.bytes)) · \(rate) · \(path)"
    }

    private func finishScan(_ node: SizeNode?) {
        scanProgressTimer?.invalidate()
        scanProgressTimer = nil
        scanSpinner.stopAnimation(nil)
        scanSpinner.isHidden = true
        scanStopButton.isHidden = true
        activeScan = nil
        contents.emitStatus()   // restore the normal item/selection status
        guard let node else { return }   // cancelled
        (NSApp.delegate as? AppDelegate)?.presentScanResults(node) { [weak self] url in
            guard let self else { return }
            self.navigate(to: url)
            self.view.window?.makeKeyAndOrderFront(nil)
        }
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
        // Don't re-expand a hidden pane (e.g. when favorites change while hidden).
        guard favoritesSplit.bounds.height > 0, Preferences.shared.showFavorites else { return }
        favoritesController.view.isHidden = false
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
        // Columns themselves are installed by DetailsTableController from the
        // persisted visible-column set (it owns add/remove + width/order saving).
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }
}
