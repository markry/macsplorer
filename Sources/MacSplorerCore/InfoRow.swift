import Foundation

/// One extra row a provider adds to Get Info: a label, plain text, colored chips,
/// or text followed by chips.
public struct InfoRow: Sendable, Equatable {
    public let label: String
    public let value: String?
    /// Shown after the value, wrapping onto further lines when there are many.
    public let chips: [InfoChip]

    public init(label: String, value: String? = nil, chips: [InfoChip] = []) {
        self.label = label
        self.value = value
        self.chips = chips
    }
}

/// A rounded label in a Get Info row, the way Finder shows colored tags.
public struct InfoChip: Sendable, Equatable {
    public let text: String
    /// A hex color, `#rgb`, `#rrggbb` or `#rrggbbaa` (the `#` optional). Nil, or a
    /// color that doesn't parse, gets the default chip style.
    public let color: String?
    /// Shown as a tooltip, e.g. where the tag came from.
    public let detail: String?

    public init(text: String, color: String? = nil, detail: String? = nil) {
        self.text = text
        self.color = color
        self.detail = detail
    }

    /// The color as red, green, blue and alpha in 0…1, or nil when there is none or
    /// it doesn't parse.
    public var rgba: (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard var hex = color?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        func channel(_ offset: UInt64) -> Double { Double((value >> (offset + shift)) & 0xff) / 255 }
        return (channel(16), channel(8), channel(0), hasAlpha ? Double(value & 0xff) / 255 : 1)
    }

    /// Whether dark text reads better than light on this chip's color (WCAG
    /// relative luminance). Nil without a color.
    public var prefersDarkText: Bool? {
        guard let c = rgba else { return nil }
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        // Black text's contrast beats white's above about 0.179.
        return luminance > 0.179
    }
}
