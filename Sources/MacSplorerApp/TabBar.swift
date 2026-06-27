import AppKit

/// An appearance-aware solid gray (distinct values for light / dark mode), so
/// the tab strip reads correctly in both.
private func tabGray(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: isDark ? dark : light, alpha: 1)
    }
}

/// A single browser-style tab: a rectangle with rounded top corners, a
/// truncating title, and a close (✕) button that appears on hover (always on
/// the active tab). Reports clicks (select) and close requests upward.
final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    var isActive = false { didSet { needsDisplay = true; updateCloseVisibility() } }
    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue; toolTip = newValue }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    // Active tab is a very light gray; the rest are a darker gray (hover sits
    // between). The strip background (in TabBarView) is darker still, so tabs
    // read as raised surfaces.
    private static let activeFill = tabGray(0.96, 0.34)
    private static let inactiveFill = tabGray(0.86, 0.22)
    private static let hoverFill = tabGray(0.91, 0.28)

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.stringValue = title
        toolTip = title
        addSubview(titleLabel)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)

        updateCloseVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func closeClicked() { onClose?() }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    private func updateCloseVisibility() { closeButton.isHidden = !(hovering || isActive) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true; updateCloseVisibility(); needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false; updateCloseVisibility(); needsDisplay = true
    }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 16
        closeButton.frame = NSRect(x: bounds.maxX - closeSize - 5,
                                   y: (bounds.height - closeSize) / 2,
                                   width: closeSize, height: closeSize)
        let labelLeft: CGFloat = 10
        let labelRight = bounds.maxX - closeSize - 6
        titleLabel.frame = NSRect(x: labelLeft, y: (bounds.height - 16) / 2 - 1,
                                  width: max(0, labelRight - labelLeft), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = Self.topRoundedPath(in: bounds.insetBy(dx: 0.5, dy: 0), radius: 7)
        let fill = isActive ? Self.activeFill : (hovering ? Self.hoverFill : Self.inactiveFill)
        fill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// An open path tracing the left side, rounded top corners, and right side
    /// (no bottom edge — so `fill()` closes it but `stroke()` leaves the bottom
    /// open to merge with the bar's baseline).
    static func topRoundedPath(in rect: NSRect, radius r: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - r))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
                       radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
                       radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A left-flush, browser-style tab strip with a "+" button after the last tab.
/// Tabs shrink to fit (down to a minimum) as more are added.
final class TabBarView: NSView {
    static let height: CGFloat = 30

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private var items: [TabItemView] = []
    private let plusButton = NSButton()

    private let leftInset: CGFloat = 6
    private let minTabWidth: CGFloat = 70
    private let maxTabWidth: CGFloat = 180
    private let plusWidth: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        plusButton.isBordered = false
        plusButton.bezelStyle = .regularSquare
        plusButton.imagePosition = .imageOnly
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        plusButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.toolTip = "New tab"
        plusButton.target = self
        plusButton.action = #selector(plusClicked)
        addSubview(plusButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func plusClicked() { onNewTab?() }

    /// Update the strip to `titles` with `active` highlighted, rebuilding the tab
    /// views only when the count changes.
    func setTabs(titles: [String], active: Int) {
        if items.count != titles.count { rebuild(count: titles.count) }
        for (i, title) in titles.enumerated() {
            items[i].title = title
            items[i].isActive = (i == active)
        }
        needsLayout = true
        needsDisplay = true
    }

    private func rebuild(count: Int) {
        items.forEach { $0.removeFromSuperview() }
        items = (0..<count).map { index in
            let item = TabItemView(title: "")
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            addSubview(item, positioned: .below, relativeTo: plusButton)
            return item
        }
    }

    override func layout() {
        super.layout()
        let count = items.count
        let avail = bounds.width - leftInset - plusWidth - 6
        var tabW = maxTabWidth
        if count > 0 { tabW = min(maxTabWidth, max(minTabWidth, avail / CGFloat(count))) }
        var x = leftInset
        for item in items {
            item.frame = NSRect(x: x, y: 0, width: tabW, height: bounds.height)
            x += tabW
        }
        plusButton.frame = NSRect(x: x + 3, y: (bounds.height - plusWidth) / 2,
                                  width: plusWidth, height: plusWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Strip background: darker than the (inactive) tabs, so tabs sit proud.
        tabGray(0.70, 0.16).setFill()
        bounds.fill()
        // Baseline hairline along the bottom; opaque tabs draw over it, so it
        // shows only between/around tabs (the active tab merges with the content).
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
