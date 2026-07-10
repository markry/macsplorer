import AppKit
import MacSplorerCore

/// A simple horizontal used/free capacity bar (used portion filled, remainder
/// track) for the volume Get Info panel.
private final class CapacityBarView: NSView {
    var fraction: Double = 0 { didSet { needsLayout = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 10) }

    private let track = CALayer()
    private let fill = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.cornerRadius = 5
        fill.cornerRadius = 5
        track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        let clamped = max(0, min(1, fraction))
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
    }
}

/// A Finder-style "Get Info" panel for a single item. Adapts to what the item is:
///   - Volume  → capacity / used / available (with a bar) + format.
///   - Folder  → immediate item count + a "Calculate" button that walks the tree
///               (reusing FolderSizeScanner) to fill in the total size.
///   - File    → size on disk.
/// Plus the common name / kind / location / created / modified for all three.
final class GetInfoWindowController: NSWindowController, NSWindowDelegate {
    private let url: URL
    /// Fired when this window closes, so the owner can release it.
    var onClose: (() -> Void)?

    private var scanner: FolderSizeScanner?
    private var sizeValueLabel: NSTextField?
    private var itemsValueLabel: NSTextField?
    private var calcButton: NSButton?

    private static let keys: Set<URLResourceKey> = [
        .localizedNameKey, .localizedTypeDescriptionKey,
        .creationDateKey, .contentModificationDateKey,
        .isDirectoryKey, .isPackageKey,
        .fileSizeKey, .totalFileAllocatedSizeKey,
        .volumeIsRootFileSystemKey, .volumeURLKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    init(url: URL) {
        self.url = url
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "\(url.lastPathComponent) Info"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        scanner?.cancel()
        onClose?()
    }

    // MARK: - Layout

    private func buildLayout() {
        let values = try? url.resourceValues(forKeys: Self.keys)
        let isVolume = isVolume(values)
        let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)

        // Header: large icon + name + kind.
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: values?.localizedName ?? url.lastPathComponent)
        name.font = .boldSystemFont(ofSize: 15)
        name.lineBreakMode = .byTruncatingMiddle

        let kindText = isVolume
            ? (values?.volumeLocalizedFormatDescription.map { "Volume — \($0)" } ?? "Volume")
            : (values?.localizedTypeDescription ?? "")
        let kind = NSTextField(labelWithString: kindText)
        kind.font = .systemFont(ofSize: 11)
        kind.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [name, kind])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1

        let header = NSStackView(views: [icon, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        // Detail grid.
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        if isVolume {
            addVolumeRows(to: grid, values: values)
        } else {
            addRow(grid, "Where:", whereLabel(of: url))
            if isFolder {
                let items = valueLabel(immediateItemCountText())
                itemsValueLabel = items
                addRow(grid, "Items:", items)
                addFolderSizeRow(to: grid)
            } else {
                addRow(grid, "Size:", fileSizeText(values))
            }
        }
        if let created = values?.creationDate {
            addRow(grid, "Created:", valueLabel(FSFormat.date(created)))
        }
        if let modified = values?.contentModificationDate {
            addRow(grid, "Modified:", valueLabel(FSFormat.date(modified)))
        }

        let content = NSStackView(views: [header, NSBox.separator, grid])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)

        guard let root = window?.contentView else { return }
        root.addSubview(content)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func addVolumeRows(to grid: NSGridView, values: URLResourceValues?) {
        let capacity = Int64(values?.volumeTotalCapacity ?? 0)
        // "…ForImportantUsage" reflects what's really free to the user (counts
        // purgeable space); fall back to the plain available key if it's absent.
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? Int64(values?.volumeAvailableCapacity ?? 0)
        let used = max(0, capacity - available)

        addRow(grid, "Capacity:", valueLabel(FSFormat.size(capacity)))
        addRow(grid, "Available:", valueLabel(FSFormat.size(available)))
        addRow(grid, "Used:", valueLabel(FSFormat.size(used)))

        let bar = CapacityBarView()
        bar.fraction = capacity > 0 ? Double(used) / Double(capacity) : 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 210).isActive = true
        addRow(grid, "", bar)
    }

    /// A "Size:" row for a folder: initially blank with a Calculate button that
    /// kicks off the recursive size walk, then shows the total.
    private func addFolderSizeRow(to grid: NSGridView) {
        let size = valueLabel("—")
        sizeValueLabel = size
        let button = NSButton(title: "Calculate", target: self, action: #selector(calculate))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        calcButton = button
        let stack = NSStackView(views: [size, button])
        stack.orientation = .horizontal
        stack.spacing = 8
        addRow(grid, "Total Size:", stack)
    }

    @objc private func calculate() {
        calcButton?.isEnabled = false
        calcButton?.title = "Calculating…"
        let scanner = FolderSizeScanner()
        self.scanner = scanner
        // Don't skip cloud mounts for an explicit, single-folder Get Info — the
        // user asked about *this* folder.
        scanner.scan(root: url, skipCloudLocations: false) { [weak self] node in
            guard let self else { return }
            self.scanner = nil
            guard let node else { return }   // cancelled (window closed)
            self.sizeValueLabel?.stringValue = FSFormat.size(node.totalSize)
            self.calcButton?.isHidden = true
        }
    }

    // MARK: - Helpers

    /// Whether to present this item as a volume (show capacity/used/free). True
    /// for the root filesystem, anything directly under /Volumes (what the tree's
    /// Volumes root lists — including the "Macintosh HD" firmlink), and any genuine
    /// mount point. Capacity is then read from the *containing* volume, which is
    /// correct in every case: a firmlink like /Volumes/Macintosh HD reports the "/"
    /// volume's stats; a DMG at /Volumes/Foo reports its own.
    private func isVolume(_ values: URLResourceValues?) -> Bool {
        let path = url.standardizedFileURL.path
        if path == "/" { return true }
        if url.deletingLastPathComponent().standardizedFileURL.path == "/Volumes" { return true }
        if let volume = values?.volume,
           volume.standardizedFileURL == url.standardizedFileURL { return true }
        return false
    }

    private func immediateItemCountText() -> String {
        let n = FSItem.contents(of: url, includeHidden: Preferences.shared.showHiddenFiles).count
        return n == 1 ? "1 item" : "\(n) items"
    }

    private func fileSizeText(_ values: URLResourceValues?) -> NSTextField {
        let bytes = values?.fileSize ?? values?.totalFileAllocatedSize
        return valueLabel(bytes.map { FSFormat.size(Int64($0)) } ?? "—")
    }

    /// Finder-style "Where": the parent folder path, home abbreviated to ~.
    private func whereLabel(of url: URL) -> NSTextField {
        let parent = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = parent == home ? "~"
            : parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count)
            : parent
        let label = valueLabel(shown)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = parent
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        return label
    }

    private func valueLabel(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: 11)
        field.isSelectable = true
        return field
    }

    private func addRow(_ grid: NSGridView, _ label: String, _ value: NSView) {
        let key = NSTextField(labelWithString: label)
        key.font = .systemFont(ofSize: 11, weight: .semibold)
        key.textColor = .secondaryLabelColor
        grid.addRow(with: [key, value])
    }

    private func addRow(_ grid: NSGridView, _ label: String, _ value: NSTextField) {
        addRow(grid, label, value as NSView)
    }
}

private extension NSBox {
    /// A thin horizontal separator line for stacking between sections.
    static var separator: NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return box
    }
}
