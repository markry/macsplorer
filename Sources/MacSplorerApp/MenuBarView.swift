import AppKit

/// A single top-level menu button (File, Edit, …) in the in-window menu bar. It
/// opens its menu on mouse-down (menu-bar feel); the parent `MenuBarView` drives
/// the actual popping so it can hand off between menus on hover.
final class MenuBarButton: NSButton {
    let popupMenu: NSMenu
    var onOpen: ((MenuBarButton) -> Void)?

    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init(title: String, image: NSImage? = nil, menu: NSMenu) {
        self.popupMenu = menu
        super.init(frame: .zero)
        if let image {
            self.image = image
            imagePosition = .imageOnly
            imageScaling = .scaleProportionallyDown
        } else {
            self.title = title
            contentTintColor = .labelColor
        }
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 13)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 18 // breathing room around the title
        return size
    }

    /// Open on mouse-down (not up), like a real menu bar.
    override func mouseDown(with event: NSEvent) { onOpen?(self) }

    /// Drawn highlighted while its menu is open or the pointer is over it.
    var isHighlightedTab = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlightedTab {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(isHighlightedTab ? 0.28 : 0.16).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}

/// An in-window menu bar: a left-flush row of buttons mirroring the app's
/// top-level menus, each popping the same menu the system menu bar would — so
/// the menus are reachable at the top of the window instead of the distant
/// screen menu bar. (The system menu bar still exists; macOS requires it.)
///
/// Supports hover-to-switch: while one menu is open, moving the pointer onto a
/// sibling button switches to that menu — matching real menu-bar behavior. Since
/// `NSMenu.popUp` runs a modal tracking loop (sibling hover events don't fire),
/// we poll the pointer with a timer in the common run-loop modes and, when it's
/// over a different button, cancel the open menu and pop the new one.
final class MenuBarView: NSView {
    static let height: CGFloat = 24

    private let stack = NSStackView()
    private var buttons: [MenuBarButton] = []
    private var pollTimer: Timer?
    private var openButton: MenuBarButton?
    private var pendingSwitch: MenuBarButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Build a button per top-level menu (those with a non-empty title + submenu).
    func setMenus(_ items: [NSMenuItem]) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        for (index, item) in items.enumerated() {
            guard let submenu = item.submenu else { continue }
            let button: MenuBarButton
            if index == 0 {
                // The application menu (About / Quit) has no usable title — show
                // it as the app's (folder) icon, the way the system menu bar uses
                // the app name there.
                let icon = (NSApp.applicationIconImage.copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 16, height: 16)
                button = MenuBarButton(title: "", image: icon, menu: submenu)
            } else {
                // Top-level items have no title of their own — the name lives on
                // the submenu (e.g. NSMenu(title: "File")).
                let name = submenu.title.isEmpty ? item.title : submenu.title
                guard !name.isEmpty else { continue }
                button = MenuBarButton(title: name, menu: submenu)
            }
            button.onOpen = { [weak self] in self?.open($0) }
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
    }

    /// Open `button`'s menu, then keep popping whichever button the pointer hands
    /// off to (hover-to-switch). Looped — not recursive — so a long hover session
    /// doesn't grow the stack.
    private func open(_ button: MenuBarButton) {
        var current = button
        while true {
            openButton = current
            current.isHighlightedTab = true
            startPolling()
            current.popupMenu.popUp(positioning: nil, at: menuAnchor(for: current), in: nil)
            stopPolling()
            current.isHighlightedTab = false
            openButton = nil
            if let next = pendingSwitch {
                pendingSwitch = nil
                current = next
                continue
            }
            break
        }
    }

    private func startPolling() {
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.pollPointer() }
        RunLoop.current.add(timer, forMode: .common) // fires during the menu's modal tracking
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Screen point at the button's left edge and the menu bar's bottom edge, so
    /// the menu drops cleanly *below* the whole bar (not overlapping the button).
    private func menuAnchor(for button: MenuBarButton) -> NSPoint {
        guard let window else { return .zero }
        let gap: CGFloat = 5 // breathing room so the menu doesn't touch the button
        let buttonLeftInWindow = button.convert(NSPoint.zero, to: nil).x
        let barBottomInWindow = convert(NSPoint.zero, to: nil).y
        return window.convertPoint(toScreen: NSPoint(x: buttonLeftInWindow, y: barBottomInWindow - gap))
    }

    private func pollPointer() {
        guard let openButton, let hovered = buttonUnderPointer(), hovered !== openButton else { return }
        pendingSwitch = hovered
        openButton.popupMenu.cancelTracking() // ends popUp; open() then pops `hovered`
    }

    /// The menu-bar button under the pointer right now, if any (hit-testing the
    /// window's content view, which works during the menu's modal tracking).
    private func buttonUnderPointer() -> MenuBarButton? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        var view = window.contentView?.hitTest(windowPoint)
        while let candidate = view {
            if let button = candidate as? MenuBarButton { return button }
            view = candidate.superview
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() // baseline
    }
}
