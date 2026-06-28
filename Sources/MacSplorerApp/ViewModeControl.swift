import AppKit

/// The always-visible cluster of four small icon buttons in the status bar:
/// List, then Icon-Small / Icon-Medium / Icon-Large. Clicking any of the three
/// grid buttons switches to the icon grid *at that size* in one move; List
/// switches back. The active button stays pressed (recessed) — non-modal, so the
/// current view and size are visible at a glance.
final class ViewModeControl: NSView {
    enum Mode: Equatable {
        case list
        case icon(IconSize)
    }

    var onSelect: ((Mode) -> Void)?

    private var entries: [(mode: Mode, button: NSButton)] = []

    init() {
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let specs: [(Mode, String, String, String)] = [
            (.list,         "list.bullet",          "List",         "List"),
            (.icon(.small), "square.grid.3x3.fill", "Small icons",  "S"),
            (.icon(.large), "square.grid.2x2.fill", "Large icons",  "L"),
        ]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        for (mode, symbol, tip, fallback) in specs {
            let button = NSButton()
            button.bezelStyle = .recessed
            button.setButtonType(.pushOnPushOff)
            button.isBordered = true
            button.showsBorderOnlyWhileMouseInside = true
            button.imagePosition = .imageOnly
            button.toolTip = tip
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
                button.image = image
            } else {
                button.title = fallback
                button.imagePosition = .noImage
            }
            button.target = self
            button.action = #selector(buttonTapped(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            stack.addArrangedSubview(button)
            entries.append((mode, button))
        }
    }

    /// Highlight the button matching the current view (icon size matched too).
    func setActive(_ mode: Mode) {
        for entry in entries { entry.button.state = (entry.mode == mode) ? .on : .off }
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard let mode = entries.first(where: { $0.button === sender })?.mode else { return }
        // Re-assert the pressed state so a second click on the active button can't
        // toggle it off (it stays selected).
        setActive(mode)
        onSelect?(mode)
    }
}
