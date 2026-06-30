import AppKit

/// Drag source for the Windows-Explorer-style **right-button drag**: it offers
/// both copy and move, and flags the drag as right-initiated (`isActive`) so the
/// drop target presents a Copy/Move menu instead of silently performing the
/// default. Stateless singleton; retained for the app's lifetime.
final class RightDragSource: NSObject, NSDraggingSource {
    static let shared = RightDragSource()

    /// True while a right-button drag started here is in flight — the drop target
    /// reads this to decide whether to show the Copy/Move menu.
    private(set) var isActive = false

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isActive = false
    }

    fileprivate func markActive() { isActive = true }
}

extension NSView {
    /// After a right-mouse-down, block until the button is dragged past `threshold`
    /// (→ returns the drag event) or released without moving (→ nil) — tells a
    /// right-*click* (show the menu) apart from a right-*drag*.
    func waitForRightDrag(start: NSEvent, threshold: CGFloat = 4) -> NSEvent? {
        let origin = start.locationInWindow
        while let next = window?.nextEvent(matching: [.rightMouseDragged, .rightMouseUp]) {
            if next.type == .rightMouseUp { return nil }
            let p = next.locationInWindow
            if abs(p.x - origin.x) > threshold || abs(p.y - origin.y) > threshold { return next }
        }
        return nil
    }

    /// Begin a right-button drag of `urls`, triggered by `event` (a right-mouse
    /// drag). The drop target decides copy vs move via its menu.
    func beginRightDrag(of urls: [URL], with event: NSEvent) {
        guard !urls.isEmpty else { return }
        let origin = convert(event.locationInWindow, from: nil)
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            item.setDraggingFrame(NSRect(x: origin.x - 16, y: origin.y - 16, width: 32, height: 32),
                                  contents: icon)
            return item
        }
        RightDragSource.shared.markActive()
        let session = beginDraggingSession(with: items, event: event, source: RightDragSource.shared)
        session.draggingFormation = .stack
    }
}
