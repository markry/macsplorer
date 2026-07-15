import AppKit

/// Overlays a small "download from cloud" glyph onto a file icon to mark an
/// online-only File Provider placeholder (OneDrive/iCloud), the way Finder shows
/// a cloud badge next to files whose contents aren't on disk yet.
enum CloudBadge {
    /// Returns `base` with a cloud-download badge composited into its lower-right
    /// corner. The badge is sized relative to the icon so it reads at both the
    /// 16pt details-row size and the larger icon-view tiles.
    static func badged(_ base: NSImage) -> NSImage {
        let size = base.size
        guard size.width > 0, size.height > 0 else { return base }

        // Keep the badge legible at the 16pt details size (where it's ~9pt, over
        // half the icon) without letting it dominate the large icon-view tiles
        // (capped so it stays a corner accent).
        let badgeEdge = max(9, min(size.width * 0.42, 40))
        let config = NSImage.SymbolConfiguration(pointSize: badgeEdge, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .systemBlue))
        guard let glyph = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                  accessibilityDescription: "Online only — not downloaded")?
            .withSymbolConfiguration(config) else { return base }

        let result = NSImage(size: size)
        result.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))

        // Sit the badge in the lower-right corner, nudged to overlap the edge
        // slightly like a Finder badge.
        let badgeRect = NSRect(x: size.width - badgeEdge,
                               y: 0,
                               width: badgeEdge,
                               height: badgeEdge)

        // Fill a white disc behind the glyph: the ".fill" circle shows the arrow
        // as a knockout, so this makes the arrow read as white over any icon.
        NSColor.white.setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: 1, dy: 1)).fill()
        glyph.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])

        result.unlockFocus()
        result.accessibilityDescription = "Online only — not downloaded"
        return result
    }
}
