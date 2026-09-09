import AppKit
import MacSplorerCore
import MacSplorerS3

/// Manages the list of folders MacSplorer reads AWS `config`/`credentials` from —
/// letting the user absorb credential sets from non-standard locations (up to 10)
/// in addition to (or instead of) the standard `~/.aws`. Applying re-enumerates
/// profiles, refreshes the S3 tree, and warns about any profile name found in more
/// than one location (which is ignored until resolved).
final class S3CredentialsWindowController: NSWindowController,
                                           NSTableViewDataSource, NSTableViewDelegate {
    private static let maxLocations = 10

    private var paths: [String]
    private let tableView = NSTableView()
    private let removeButton = NSButton()
    private let addButton = NSButton()
    /// Called when the window closes so the owner can release this controller.
    var onClose: (() -> Void)?

    init() {
        paths = Preferences.shared.s3CredentialLocations
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "S3 Credential Locations"
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let info = NSTextField(wrappingLabelWithString:
            "Folders MacSplorer reads AWS config / credentials from, to list profiles. "
            + "Add non-standard locations (max \(Self.maxLocations)). If a profile name "
            + "appears in more than one location, the first is used and the rest ignored. "
            + "Give profiles distinct, meaningful names (e.g. “admin-work” vs "
            + "“admin-personal”) — MacSplorer can't infer meaning from a name. Names are "
            + "case-sensitive.")
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

        [info, scroll, addButton, removeButton, done].forEach { content.addSubview($0) }
        let pad: CGFloat = 16
        NSLayoutConstraint.activate([
            info.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            scroll.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),

            addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            done.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ])
        updateButtons()
    }

    private func updateButtons() {
        removeButton.isEnabled = tableView.selectedRow >= 0
        addButton.isEnabled = paths.count < Self.maxLocations
    }

    // MARK: Actions

    @objc private func addLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder containing AWS config and/or credentials files."
        // Default to the standard ~/.aws for convenience (Cmd-Shift-. shows dotfolders).
        panel.directoryURL = AWSProfiles.defaultLocation
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let path = url.path
            guard self.paths.count < Self.maxLocations,
                  !self.paths.contains(path) else { return }
            self.paths.append(path)
            self.tableView.reloadData()
            self.updateButtons()
        }
    }

    @objc private func removeLocation() {
        let row = tableView.selectedRow
        guard paths.indices.contains(row) else { return }
        paths.remove(at: row)
        tableView.reloadData()
        updateButtons()
    }

    /// Persist, re-enumerate, refresh /Volumes, then warn about any newly-introduced
    /// cross-location profile-name conflict (same policy + modal as the live watcher).
    @objc private func applyAndClose() {
        Preferences.shared.s3CredentialLocations = paths
        S3Mount.applyCredentialLocations()
        FolderChange.notify([S3Mount.volumesURL])
        window?.close()
        S3ConflictMonitor.check()
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
        let path = paths[row]
        cell.textField?.stringValue = path
        cell.textField?.textColor = path == AWSProfiles.defaultLocation.path
            ? .secondaryLabelColor : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}

extension S3CredentialsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { onClose?() }
}
