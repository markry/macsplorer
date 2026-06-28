import AppKit

/// The breadcrumb face of the address bar: the current folder's path rendered as
/// clickable folder buttons separated by `›`, Windows-Explorer-style. Clicking a
/// segment jumps to that ancestor; clicking the empty area switches the bar into
/// the editable text field (handled by the host). Styled to match the rounded
/// text field so the swap between the two is seamless.
final class PathBarView: NSView {
    /// Navigate to this ancestor folder (a segment was clicked).
    var onSegment: ((URL) -> Void)?
    /// The user clicked the bar (not a segment) — switch to the editable field.
    var onActivateEdit: (() -> Void)?

    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6

        stack.orientation = .horizontal
        stack.spacing = 1
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // Pinned leading so the *ancestors* (the jump-up targets) stay visible;
            // a very deep current folder clips on the right instead.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    func setURL(_ url: URL?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else { return }
        let segs = segments(for: url, home: FileManager.default.homeDirectoryForCurrentUser)
        for (index, segment) in segs.enumerated() {
            if index > 0 { stack.addArrangedSubview(makeSeparator()) }
            // The home root shows a little house icon rather than a bare "~".
            let symbol = (segment.title == "~") ? "house.fill" : nil
            stack.addArrangedSubview(makeButton(title: segment.title, symbol: symbol, url: segment.url))
        }
    }

    /// Clicking the bar's empty area (not a button) enters edit mode.
    override func mouseDown(with event: NSEvent) {
        onActivateEdit?()
    }

    // MARK: Building blocks

    private func segments(for url: URL, home: URL) -> [(title: String, url: URL)] {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        var result: [(String, URL)] = []
        if path == homePath || path.hasPrefix(homePath + "/") {
            result.append(("~", home))
            var current = home
            for component in path.dropFirst(homePath.count).split(separator: "/").map(String.init) {
                current.appendPathComponent(component)
                result.append((component, current))
            }
        } else {
            let root = URL(fileURLWithPath: "/")
            let rootName = FileManager.default.displayName(atPath: "/")
            result.append((rootName.isEmpty ? "/" : rootName, root))
            var current = root
            for component in path.split(separator: "/").map(String.init) {
                current.appendPathComponent(component)
                result.append((component, current))
            }
        }
        return result
    }

    private func makeButton(title: String, symbol: String? = nil, url: URL) -> NSButton {
        let button = SegmentButton(title: title, target: self, action: #selector(segmentClicked(_:)))
        button.url = url
        button.bezelStyle = .recessed
        button.setButtonType(.momentaryPushIn)
        button.isBordered = true
        button.showsBorderOnlyWhileMouseInside = true
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .labelColor
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)) {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Home"
        }
        return button
    }

    private func makeSeparator() -> NSView {
        let label = NSTextField(labelWithString: "›")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        return label
    }

    @objc private func segmentClicked(_ sender: SegmentButton) {
        guard let url = sender.url else { return }
        onSegment?(url)
    }
}

/// An `NSButton` that carries the folder URL it navigates to.
private final class SegmentButton: NSButton {
    var url: URL?
}
