import AppKit
import UniformTypeIdentifiers
import MacSplorerCore

extension FSItem {
    /// A display icon that works for both on-disk items and provider (S3) items
    /// whose URL isn't a real local file. Local items keep the exact old behavior
    /// (`icon(forFile:)`, which reflects custom/bundle icons); a remote item has no
    /// file to query, so it falls back to a folder icon or the icon for its
    /// extension's UTType.
    var displayIcon: NSImage {
        if url.isFileURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if isDirectory {
            return FSItem.cloudyFolderIcon
        }
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// A distinct folder icon for the S3 (cloud) namespace. macOS folder icons are
    /// already blue, so a blue tint on one is invisible — this is a flat, **pale**
    /// blue `folder.fill` (clearly different from the system folder at any size,
    /// even 16 px) with a small white **cloud** badge (the "online, not-local"
    /// semantics). Built once and reused for every S3 folder (profile/bucket/prefix).
    static let cloudyFolderIcon: NSImage = {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        if let folder = tintedSymbol("folder.fill", pointSize: 220, weight: .regular,
                                     color: NSColor(srgbRed: 0.55, green: 0.78, blue: 0.97, alpha: 1)) {
            let h = size.width * (folder.size.height / folder.size.width)
            folder.draw(in: NSRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h))
        } else {
            NSWorkspace.shared.icon(for: .folder).draw(in: NSRect(origin: .zero, size: size))
        }
        // A white cloud with a soft dark edge, lower-right.
        if let cloud = tintedSymbol("cloud.fill", pointSize: 130, weight: .bold, color: .white),
           let edge = tintedSymbol("cloud.fill", pointSize: 130, weight: .bold,
                                   color: NSColor(white: 0.35, alpha: 1)) {
            let bw = size.width * 0.5
            let bh = bw * (cloud.size.height / cloud.size.width)
            let x = size.width - bw - 6, y: CGFloat = 20
            edge.draw(in: NSRect(x: x, y: y - 1.5, width: bw, height: bh))
            cloud.draw(in: NSRect(x: x, y: y, width: bw, height: bh))
        }
        image.unlockFocus()
        return image
    }()

    /// A symbol image flattened to a single tint color (SF symbols tint via the
    /// drawing context, so we bake the color into a bitmap for compositing).
    private static func tintedSymbol(_ name: String, pointSize: CGFloat,
                                     weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let img = NSImage(size: symbol.size)
        img.lockFocus()
        let r = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}
