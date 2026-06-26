import AppKit

/// Tracks a copy/cut of file URLs for paste, mirrored to the system pasteboard
/// so copies interoperate with Finder (copy in MacSplorer, paste in Finder, and
/// vice-versa). "Cut = move on paste" is MacSplorer/Explorer behavior we track
/// ourselves, since macOS has no native cut-file pasteboard flavor.
final class Clipboard {
    static let shared = Clipboard()

    enum Operation { case copy, cut }

    private(set) var urls: [URL] = []
    private(set) var operation: Operation = .copy
    private var writtenChangeCount = -1

    private static let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] =
        [.urlReadingFileURLsOnly: true]

    func set(_ urls: [URL], operation: Operation) {
        self.urls = urls
        self.operation = operation
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        writtenChangeCount = pasteboard.changeCount
    }

    /// Is our copy/cut still the current pasteboard owner?
    private var isCurrent: Bool {
        !urls.isEmpty && NSPasteboard.general.changeCount == writtenChangeCount
    }

    var canPaste: Bool {
        if isCurrent { return true }
        return NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                                  options: Self.fileURLOptions)
    }

    /// The URLs to paste and whether to move them. If the system pasteboard has
    /// been superseded since our copy/cut (e.g. a Finder copy), use that as a
    /// COPY; otherwise honor our recorded copy/cut.
    func pasteSource() -> (urls: [URL], move: Bool) {
        if isCurrent { return (urls, operation == .cut) }
        let external = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                        options: Self.fileURLOptions) as? [URL] ?? []
        return (external, false)
    }

    /// Clear our record after a cut+paste move so a second paste doesn't re-move.
    func clearAfterMove() {
        urls = []
        writtenChangeCount = -1
    }
}
