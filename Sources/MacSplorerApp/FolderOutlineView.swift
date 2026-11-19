import AppKit
import MacSplorerCore

/// An `NSOutlineView` that vends a context menu for the right-clicked row
/// (selecting it first, Finder-style).
final class FolderOutlineView: NSOutlineView, NSMenuItemValidation {
    var onContextMenu: ((Int) -> NSMenu?)?

    /// Editing commands for the folder selected here. Without these, ⌘X/⌘C/⌘V did
    /// nothing at all while the tree had focus — or worse, were caught further along
    /// the responder chain and silently acted on the OTHER pane's selection, so a cut
    /// took a file the user wasn't looking at.
    var onCut: ((URL) -> Void)?
    var onCopy: ((URL) -> Void)?
    var onPaste: ((URL) -> Void)?
    /// Whether there is anything to paste (for menu validation).
    var canPaste: (() -> Bool)?
    /// The folder currently selected in the tree.
    var selectedFolderURL: (() -> URL?)?

    /// Tab / Shift-Tab moves focus between the window's main panes.
    var onTab: ((Bool) -> Void)?

    // MARK: Horizontal scrolling

    /// The single column is sized to the widest visible row (never narrower than the
    /// pane), so deep folders and long names scroll sideways, as in Explorer, rather
    /// than being cut off. Re-fitted on every reload, expand, collapse and resize.
    func fitColumnToContent() {
        guard let column = outlineTableColumn ?? tableColumns.first,
              let clip = enclosingScrollView?.contentView else { return }
        let font = NSFont.systemFont(ofSize: 13)
        var needed: CGFloat = 0
        for row in 0..<numberOfRows {
            guard let item = item(atRow: row) as? FSItem else { continue }
            // Where the row's cell starts (indentation and disclosure triangle), then
            // the cell's icon, gap, text and margins.
            let start = frameOfCell(atColumn: 0, row: row).minX
            let text = (item.name as NSString).size(withAttributes: [.font: font]).width
            needed = max(needed, start + 2 + 16 + 4 + ceil(text) + 2 + 12)
        }
        let width = max(clip.bounds.width, needed)
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    private var fitScheduled = false

    /// Fit once the current burst of changes has settled.
    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.fitScheduled = false
            self?.fitColumnToContent()
        }
    }

    override func reloadData() {
        super.reloadData()
        scheduleFit()
    }

    override func reloadItem(_ item: Any?, reloadChildren: Bool) {
        super.reloadItem(item, reloadChildren: reloadChildren)
        scheduleFit()
    }

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        super.expandItem(item, expandChildren: expandChildren)
        scheduleFit()
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        super.collapseItem(item, collapseChildren: collapseChildren)
        scheduleFit()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func clipResized() { scheduleFit() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, let onTab {
            onTab(event.modifierFlags.contains(.shift))
            return
        }
        super.keyDown(with: event)
    }

    @objc func cut(_ sender: Any?) {
        guard let url = selectedFolderURL?() else { NSSound.beep(); return }
        onCut?(url)
    }

    @objc func copy(_ sender: Any?) {
        guard let url = selectedFolderURL?() else { NSSound.beep(); return }
        onCopy?(url)
    }

    @objc func paste(_ sender: Any?) {
        guard let url = selectedFolderURL?() else { NSSound.beep(); return }
        onPaste?(url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return selectedFolderURL?() != nil
        case #selector(cut(_:)):
            return selectedFolderURL?().map { LocationPermissions.canRemove($0) } ?? false
        case #selector(paste(_:)):
            guard let url = selectedFolderURL?() else { return false }
            return LocationPermissions.canAdd(into: url) && canPaste?() == true
        default:
            return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0 && selectedRow != clicked {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return onContextMenu?(clicked)
    }
}
