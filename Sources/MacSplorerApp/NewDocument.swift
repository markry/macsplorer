import AppKit
import UniformTypeIdentifiers

/// A document type offered by the "New ▸" context submenu.
struct NewDocumentType {
    let title: String   // menu label, e.g. "Word Document"
    let ext: String     // extension without the dot, e.g. "docx"
}

enum NewDocument {
    /// The default set shown in New ▸ (configurable later). Empty files with the
    /// right extension — every one of these opens fine empty in its default app.
    static let types: [NewDocumentType] = [
        NewDocumentType(title: "Text Document", ext: "txt"),
        NewDocumentType(title: "Markdown Document", ext: "md"),
        NewDocumentType(title: "Rich Text Document", ext: "rtf"),
        NewDocumentType(title: "CSV Document", ext: "csv"),
        NewDocumentType(title: "Word Document", ext: "docx"),
        // Excel rejects a 0-byte .xlsx (stricter than Word/PowerPoint), so it's
        // intentionally not offered as an empty-file "New" type.
        NewDocumentType(title: "PowerPoint Presentation", ext: "pptx"),
    ]

    /// The default base name for a freshly created document (before rename).
    static let defaultBaseName = "untitled"

    /// Cross-platform Windows `.url` Internet Shortcut bytes (CRLF line endings),
    /// matching what Windows Explorer writes — so the file is byte-compatible and
    /// opens in a browser on macOS and in the Parallels Windows VM alike.
    static func internetShortcutData(for url: String) -> Data {
        let lines = [
            "[{000214A0-0000-0000-C000-000000000046}]",
            "Prop3=19,11",
            "[InternetShortcut]",
            "IDList=",
            "URL=\(url)",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// The http(s) URL currently on the clipboard, if any — prefer a real URL on
    /// the pasteboard, else a string that parses as one.
    static func clipboardURL() -> String? {
        let pasteboard = NSPasteboard.general
        if let url = NSURL(from: pasteboard) as URL?, isWebURL(url) {
            return url.absoluteString
        }
        if let string = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: string), isWebURL(url) {
            return string
        }
        return nil
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// A 16×16 document icon for `ext`, for the submenu items.
    static func icon(forExtension ext: String) -> NSImage {
        let image: NSImage
        if let type = UTType(filenameExtension: ext) {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(for: .data)
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
