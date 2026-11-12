import AppKit
import MacSplorerCore

/// A row of rounded chips for Get Info (a provider's tags, say), wrapping onto
/// further lines within `maxWidth`. Each chip takes its provider-given color, with
/// black or white text chosen for contrast; a chip without a usable color gets a
/// neutral style that follows light and dark mode.
final class InfoChipsView: NSView {
    private let chips: [InfoChip]
    /// The width chips wrap within; changing it re-flows them.
    var maxWidth: CGFloat {
        didSet {
            guard maxWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    private var chipViews: [ChipView] = []
    private let spacing: CGFloat = 4

    init(chips: [InfoChip], maxWidth: CGFloat = 240) {
        self.chips = chips
        self.maxWidth = maxWidth
        super.init(frame: .zero)
        chipViews = chips.map(ChipView.init)
        chipViews.forEach(addSubview)
        translatesAutoresizingMaskIntoConstraints = false
        layoutChips()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { arrangement().size }

    override func layout() {
        super.layout()
        layoutChips()
    }

    private func layoutChips() {
        let (frames, _) = arrangement()
        for (view, frame) in zip(chipViews, frames) { view.frame = frame }
    }

    /// Chip frames, left to right, wrapping at `maxWidth`.
    private func arrangement() -> (frames: [NSRect], size: NSSize) {
        var frames: [NSRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in chipViews {
            let size = view.fittingSize
            let width = min(size.width, maxWidth)
            if x > 0 && x + width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(NSRect(x: x, y: y, width: width, height: size.height))
            x += width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, NSSize(width: widest, height: y + lineHeight))
    }
}

/// One chip: padded text on a rounded, filled background.
private final class ChipView: NSView {
    private let label: NSTextField
    private let chip: InfoChip

    init(_ chip: InfoChip) {
        self.chip = chip
        label = NSTextField(labelWithString: chip.text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        toolTip = chip.detail
        addSubview(label)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private let padding = NSEdgeInsets(top: 1, left: 7, bottom: 1, right: 7)

    override var fittingSize: NSSize {
        let text = label.fittingSize
        return NSSize(width: ceil(text.width) + padding.left + padding.right,
                      height: ceil(text.height) + padding.top + padding.bottom)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.frame = NSRect(x: padding.left, y: padding.bottom,
                             width: bounds.width - padding.left - padding.right,
                             height: bounds.height - padding.top - padding.bottom)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        if let c = chip.rgba, let dark = chip.prefersDarkText {
            layer?.backgroundColor = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha).cgColor
            label.textColor = dark ? .black : .white
        } else {
            // Resolve the dynamic color for this view's appearance before handing
            // the layer a CGColor, so it follows light and dark mode.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            }
            label.textColor = .labelColor
        }
    }
}
