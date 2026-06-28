import AppKit
import Quartz

/// An `NSTableView` that implements Windows-style "point to select" when
/// `hoverEnabled` is on (single-click-to-open mode).
///
/// The row under the pointer is underlined immediately (a one-click action
/// awaits), but the *selection* only moves once the pointer has **rested** on a
/// row for `selectionDwell` seconds. Every selection change goes through that
/// same dwell gate:
///   - plain rest → select just that row;
///   - ⇧ rest → extend the range from the anchor;
///   - ⌘ rest → add that row to the selection.
/// Because nothing changes until the pointer settles, sliding across rows (even
/// with ⇧/⌘ down) doesn't thrash the selection, and an existing selection isn't
/// abandoned until you've dwelled on a new target. A plain click still opens
/// immediately. With `hoverEnabled` off it's a plain table (click to select).
///
/// It also vends the file-operation commands (Cut/Copy/Paste/Rename/Move-to-
/// Trash) to its `fileActions` delegate via the responder chain, so ⌘C/⌘V act
/// on the address bar's text when that's focused instead of on files.
protocol HoverTableFileActions: AnyObject {
    func copySelectedItems()
    func cutSelectedItems()
    func pasteIntoFolder()
    func renameSelectedItem()
    func trashSelectedItems()
    func duplicateSelectedItems()
    var hasSelection: Bool { get }
    var canPaste: Bool { get }
    /// URLs of the currently selected rows (for Quick Look).
    var selectedFileURLs: [URL] { get }
    /// Build the right-click menu for the clicked row (or -1 for empty space).
    func contextMenu(forClickedRow row: Int) -> NSMenu?
}

final class HoverTableView: NSTableView, NSMenuItemValidation {
    weak var fileActions: HoverTableFileActions?

    /// How long the pointer must rest on a row before the selection moves to it.
    /// ~0.5s matches Windows; tunable.
    var selectionDwell: TimeInterval = 0.5

    var hoverEnabled = false {
        didSet { if !hoverEnabled { cancelDwell(); setHoveredRow(-1) } }
    }
    private(set) var hoveredRow = -1
    private var selectionAnchor = -1
    private var hoverTrackingArea: NSTrackingArea?

    private var dwellTimer: Timer?
    private var dwellRow = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard hoverEnabled else { return }
        // While a cell is being edited (inline rename), do nothing on hover: the
        // per-cell reload that draws the hover underline would destroy the active
        // field editor (this is what made menu-triggered renames die the instant
        // the mouse moved, while keyboard renames — no movement — survived).
        if window?.firstResponder is NSText { return }
        let row = row(at: convert(event.locationInWindow, from: nil))
        setHoveredRow(row)          // underline tracks the pointer immediately
        scheduleSelectionDwell(row) // selection waits for the pointer to settle
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        cancelDwell()
        setHoveredRow(-1) // clear the underline; leave the selection as-is
    }

    private func scheduleSelectionDwell(_ row: Int) {
        guard row >= 0 && row < numberOfRows else { cancelDwell(); return }
        if row == dwellRow { return } // already counting down on / committed to this row
        dwellTimer?.invalidate()
        dwellRow = row
        dwellTimer = Timer.scheduledTimer(withTimeInterval: selectionDwell, repeats: false) {
            [weak self] _ in self?.commitSelection(row)
        }
    }

    /// Apply the selection op for the rested-on row, using whatever modifiers are
    /// held at this moment. `dwellRow` stays set so we don't re-commit until the
    /// pointer moves to a different row.
    private func commitSelection(_ row: Int) {
        dwellTimer?.invalidate()
        dwellTimer = nil
        // Never change the selection while a cell is being edited (inline rename):
        // a selection change ends the field-editor session the instant it starts.
        // The field editor is an NSText, so its presence as first responder means
        // "editing in progress."
        if window?.firstResponder is NSText { return }
        guard hoverEnabled, hoveredRow == row, row >= 0, row < numberOfRows else { return }
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            let anchor = (selectionAnchor >= 0 && selectionAnchor < numberOfRows) ? selectionAnchor : row
            selectRowIndexes(IndexSet(integersIn: min(anchor, row)...max(anchor, row)),
                             byExtendingSelection: false)
        } else if modifiers.contains(.command) {
            var selection = selectedRowIndexes
            selection.insert(row)
            selectRowIndexes(selection, byExtendingSelection: false)
            selectionAnchor = row
        } else {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectionAnchor = row
        }
        // A hover-commit should *focus* the list so the selection is active
        // (blue) and the keyboard (Return to rename, arrows) works — without
        // yanking focus out of an active text edit (the address bar / an inline
        // rename), whose field editor is an NSText.
        if let window, !(window.firstResponder is NSText), window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwellRow = -1
    }

    /// Refresh just the name cell of the old + new hovered rows so the underline
    /// follows the mouse (cheap: one column, at most two rows).
    private func setHoveredRow(_ newRow: Int) {
        guard newRow != hoveredRow else { return }
        // Never reload cells while editing — it would tear down the field editor.
        // (Covers the mouseExited path too.)
        if window?.firstResponder is NSText { return }
        let previous = hoveredRow
        hoveredRow = newRow
        guard let nameColumn = tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" })
        else { return }
        let columns = IndexSet(integer: nameColumn)
        for row in [previous, newRow] where row >= 0 && row < numberOfRows {
            reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: columns)
        }
    }

    // MARK: File-operation commands (responder-chain targets)

    @objc func copy(_ sender: Any?) { fileActions?.copySelectedItems() }
    @objc func cut(_ sender: Any?) { fileActions?.cutSelectedItems() }
    @objc func paste(_ sender: Any?) { fileActions?.pasteIntoFolder() }
    @objc func renameItem(_ sender: Any?) { fileActions?.renameSelectedItem() }
    @objc func moveToTrash(_ sender: Any?) { fileActions?.trashSelectedItems() }
    @objc func duplicate(_ sender: Any?) { fileActions?.duplicateSelectedItems() }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty {
            fileActions?.renameSelectedItem()        // Return / keypad Enter
        } else if (event.keyCode == 51 || event.keyCode == 117),
                  modifiers.isEmpty || modifiers == .command {
            // Delete (⌫) / Forward-Delete, with or without ⌘ → Trash the
            // selection (Explorer-style, plus the Mac ⌘⌫ convention).
            fileActions?.trashSelectedItems()
        } else if event.keyCode == 49, modifiers.isEmpty {
            toggleQuickLook()                         // Space
        } else {
            super.keyDown(with: event)
            // Keep an open Quick Look panel in sync with arrow-key navigation.
            if let panel = QLPreviewPanel.shared(), panel.isVisible,
               panel.dataSource === self {
                panel.reloadData()
            }
        }
    }

    // MARK: Quick Look (spacebar)

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(renameItem(_:)),
             #selector(moveToTrash(_:)), #selector(duplicate(_:)):
            return fileActions?.hasSelection ?? false
        case #selector(paste(_:)):
            return fileActions?.canPaste ?? false
        default:
            return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        // Right-clicking an unselected row selects just it; right-clicking empty
        // space clears the selection (so commands act on the current folder).
        if clicked >= 0 {
            if !selectedRowIndexes.contains(clicked) {
                selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
        } else {
            deselectAll(nil)
        }
        return fileActions?.contextMenu(forClickedRow: clicked)
    }
}

extension HoverTableView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        fileActions?.selectedFileURLs.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = fileActions?.selectedFileURLs ?? []
        guard index >= 0 && index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// Let the panel's arrow keys / Esc fall back to the table so navigation and
    /// dismissing both feel native.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown {
            keyDown(with: event)
            return true
        }
        return false
    }
}
