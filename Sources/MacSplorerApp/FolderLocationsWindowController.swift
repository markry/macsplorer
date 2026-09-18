import AppKit
import MacSplorerCore

/// Edits one provider's list of credential folders — the screen behind
/// **File ▸ Connect to External Files ▸ …**.
///
/// Every provider needs the same thing (a short, ordered list of folders), so one
/// window serves them all, described by a `ProviderLocations` the provider registers.
/// Credentials often live in dot-folders, which the system's open panel hides until
/// you know to press ⌘⇧. — so the list also accepts a folder **dropped** on it, and
/// offers **Add Current Folder**, which takes whatever the front window is browsing.
/// MacSplorer shows hidden folders itself, so that path never hits the problem.
final class FolderLocationsWindowController: NSWindowController,
                                            NSTableViewDataSource, NSTableViewDelegate {
    private static let maxLocations = 10

    private let locations: ProviderLocations
    /// The folder the frontmost window is browsing, for "Add Current Folder".
    private let currentFolder: () -> URL?

    private var paths: [String]
    private let tableView = FolderDropTableView()
    private let addButton = NSButton()
    private let addCurrentButton = NSButton()
    private let removeButton = NSButton()
    private var enabledCheckbox: NSButton?

    var onClose: (() -> Void)?

    init(locations: ProviderLocations, currentFolder: @escaping () -> URL?) {
        self.locations = locations
        self.currentFolder = currentFolder
        self.paths = UserDefaults.standard.stringArray(forKey: locations.defaultsKey) ?? []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = locations.windowTitle
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let info = NSTextField(wrappingLabelWithString: locations.explanation)
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("path"))
        column.title = "Folder"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.onDropFolders = { [weak self] urls in self?.add(urls) }
        tableView.registerForDraggedTypes([.fileURL])

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = "Add…"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addLocation)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        addCurrentButton.title = "Add Current Folder"
        addCurrentButton.bezelStyle = .rounded
        addCurrentButton.target = self
        addCurrentButton.action = #selector(addCurrentFolder)
        addCurrentButton.translatesAutoresizingMaskIntoConstraints = false

        removeButton.title = "Remove"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeLocation)
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton()
        done.title = "Done"
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.target = self
        done.action = #selector(applyAndClose)
        done.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [info, scroll, addButton, addCurrentButton, removeButton, done]

        // The optional per-provider switch (S3 uses it to hide its profiles without
        // discarding the folder list).
        if let toggleTitle = locations.toggleTitle {
            let box = NSButton(checkboxWithTitle: toggleTitle, target: self,
                               action: #selector(toggleEnabled))
            box.state = (locations.isEnabled?() ?? true) ? .on : .off
            box.translatesAutoresizingMaskIntoConstraints = false
            enabledCheckbox = box
            views.append(box)
        }

        views.forEach { content.addSubview($0) }
        let pad: CGFloat = 16
        var constraints: [NSLayoutConstraint] = [
            info.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            scroll.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            addCurrentButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            addCurrentButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addCurrentButton.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            done.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ]
        if let box = enabledCheckbox {
            constraints += [
                box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
                box.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),
                scroll.bottomAnchor.constraint(equalTo: box.topAnchor, constant: -10),
            ]
        } else {
            constraints.append(scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12))
        }
        NSLayoutConstraint.activate(constraints)
        updateButtons()
        updateCurrentFolderTitle()
    }

    private func updateButtons() {
        removeButton.isEnabled = tableView.selectedRow >= 0
        addButton.isEnabled = paths.count < Self.maxLocations
        let folder = currentFolder()
        addCurrentButton.isEnabled = paths.count < Self.maxLocations
            && folder != nil
            && !paths.contains(folder!.path)
    }

    /// Name the folder on the button, so it's clear what will be added — and obvious
    /// when it's the wrong one.
    private func updateCurrentFolderTitle() {
        guard let folder = currentFolder() else {
            addCurrentButton.title = "Add Current Folder"
            return
        }
        addCurrentButton.title = "Add “\(folder.lastPathComponent)”"
    }

    /// Add folders, ignoring duplicates, anything that isn't a folder, and anything
    /// past the limit.
    private func add(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard paths.count < Self.maxLocations,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !paths.contains(url.path) else { continue }
            paths.append(url.path)
        }
        tableView.reloadData()
        updateButtons()
    }

    // MARK: Actions

    @objc private func addLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = locations.explanation
        panel.showsHiddenFiles = true   // credentials usually live in a dot-folder
        panel.directoryURL = locations.suggestedFolder
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.add([url])
        }
    }

    /// Take the folder the front window is browsing — the way out of hunting for a
    /// hidden folder in the system's open panel.
    @objc private func addCurrentFolder() {
        guard let folder = currentFolder() else { NSSound.beep(); return }
        add([folder])
    }

    @objc private func removeLocation() {
        let row = tableView.selectedRow
        guard paths.indices.contains(row) else { return }
        paths.remove(at: row)
        tableView.reloadData()
        updateButtons()
    }

    @objc private func toggleEnabled() {
        locations.setEnabled?(enabledCheckbox?.state == .on)
        applyAndRefresh()
    }

    /// Let the provider react, then refresh /Volumes so whatever it now exposes
    /// appears or disappears at once. The refresh lives here because posting change
    /// notifications is the app's job, not a provider module's.
    private func applyAndRefresh() {
        locations.apply()
        FolderChange.notify([URL(fileURLWithPath: "/Volumes")])
    }

    @objc private func applyAndClose() {
        UserDefaults.standard.set(paths, forKey: locations.defaultsKey)
        // Adding a folder means wanting to see what's in it, so switch the provider on
        // rather than leaving the user to find a separate control.
        if !paths.isEmpty, locations.isEnabled?() == false {
            locations.setEnabled?(true)
            enabledCheckbox?.state = .on
        }
        applyAndRefresh()
        window?.close()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { paths.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            c.identifier = id
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = (paths[row] as NSString).abbreviatingWithTildeInPath
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}

extension FolderLocationsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { onClose?() }

    /// Coming back from the browser window, the current folder may have changed —
    /// re-check, so "Add Current Folder" reflects wherever they just navigated.
    func windowDidBecomeKey(_ notification: Notification) {
        updateButtons()
        updateCurrentFolderTitle()
    }
}

/// A table that accepts folders dropped onto it, so a folder can be dragged in from
/// MacSplorer itself (or the Finder) instead of hunted for in an open panel.
final class FolderDropTableView: NSTableView {
    var onDropFolders: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        folders(in: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        folders(in: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = folders(in: sender)
        guard !urls.isEmpty else { return false }
        onDropFolders?(urls)
        return true
    }

    private func folders(in info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}
