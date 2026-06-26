import AppKit

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
final class HoverTableView: NSTableView {
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
        let previous = hoveredRow
        hoveredRow = newRow
        guard let nameColumn = tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" })
        else { return }
        let columns = IndexSet(integer: nameColumn)
        for row in [previous, newRow] where row >= 0 && row < numberOfRows {
            reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: columns)
        }
    }
}
