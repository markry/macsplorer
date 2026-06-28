import AppKit

/// An `NSOutlineView` that vends a context menu for the right-clicked row
/// (selecting it first, Finder-style).
final class FolderOutlineView: NSOutlineView {
    var onContextMenu: ((Int) -> NSMenu?)?

    /// Tab / Shift-Tab moves focus between the window's main panes.
    var onTab: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, let onTab {
            onTab(event.modifierFlags.contains(.shift))
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0 && selectedRow != clicked {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return onContextMenu?(clicked)
    }
}
