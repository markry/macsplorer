import AppKit

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
        case #selector(cut(_:)), #selector(copy(_:)):
            return selectedFolderURL?() != nil
        case #selector(paste(_:)):
            return selectedFolderURL?() != nil && canPaste?() == true
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
