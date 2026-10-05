import AppKit

/// Tracks a copy/cut of file URLs for paste, mirrored to the system pasteboard
/// so copies interoperate with Finder (copy in MacSplorer, paste in Finder, and
/// vice-versa). "Cut = move on paste" is MacSplorer/Explorer behavior we track
/// ourselves, since macOS has no native cut-file pasteboard flavor.
final class Clipboard {
    static let shared = Clipboard()

    /// Posted when the clipboard changes, so views can redraw cut items dimmed.
    static let didChange = Notification.Name("net.ryland.macsplorer.clipboardDidChange")

    enum Operation { case copy, cut }

    private(set) var urls: [URL] = []
    private(set) var operation: Operation = .copy
    private var writtenChangeCount = -1

    private static let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] =
        [.urlReadingFileURLsOnly: true]

    /// Marks the pasteboard's contents as ours, and says whether it was a cut.
    ///
    /// Ownership can't be judged by `changeCount` alone: Universal Clipboard,
    /// clipboard managers and other apps all bump it, sometimes while leaving our
    /// data in place. Treating that as "someone else's data" silently downgraded a
    /// cut to a copy, so files were copied when the user had asked for a move. The
    /// marker travels with the data, so it stays true whatever the counter does.
    private static let operationType =
        NSPasteboard.PasteboardType("net.ryland.macsplorer.clipboard-operation")

    /// `localCopies` maps a remote URL to a already-downloaded file, so the rewrite
    /// after a background fetch can offer real files. `fetchRemote` is false on that
    /// rewrite, so a download that failed can't send it round again.
    func set(_ urls: [URL], operation: Operation,
             localCopies: [URL: URL] = [:], fetchRemote: Bool = true) {
        self.urls = urls
        self.operation = operation
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Local files carry BOTH flavors, the way Finder's own copy does:
        //   • the file-URL flavor, so Finder / MacSplorer paste it as a file
        //     operation (copy/move); and
        //   • a plain-text POSIX path, so a terminal, editor, or Claude prompt paste
        //     yields a clean path.
        // `writeObjects([NSURL])` alone offers only a file:// URL for the text flavor,
        // which text targets mishandle or reject.
        //
        // A file held by a remote provider has no local path to offer, and pasting its
        // URL as text leaves the Finder trying to open a scheme it doesn't know. So it
        // goes on the pasteboard as a *promise*: paste it anywhere and the bytes are
        // fetched then. When this session already downloaded it, the real copy is
        // offered directly, which saves the round trip.
        let writers: [NSPasteboardWriting] = urls.map { url in
            if url.isFileURL {
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                item.setString(url.path, forType: .string)
                item.setString(operation == .cut ? "cut" : "copy", forType: Self.operationType)
                return item
            }
            if let cached = localCopies[url] {
                let item = NSPasteboardItem()
                item.setString(cached.absoluteString, forType: .fileURL)
                item.setString(url.absoluteString, forType: .string)
                item.setString(operation == .cut ? "cut" : "copy", forType: Self.operationType)
                return item
            }
            if let promise = RemoteFilePromiseDelegate.promiseProvider(url: url,
                                                                       name: url.lastPathComponent) {
                return promise
            }
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .string)
            return item
        }
        pasteboard.writeObjects(writers)
        writtenChangeCount = pasteboard.changeCount

        // A promise isn't enough for every target — the Finder leaves Paste greyed
        // out until something pasteable exists — so fetch anything not already local
        // and re-offer it as a real file once it lands.
        let pending = urls.filter { !$0.isFileURL }
        if fetchRemote && !pending.isEmpty { materialize(pending) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Whether `url` is waiting to be moved by the next paste — what the views draw
    /// dimmed. Without this, ⌘X produced no visible change at all and read as a
    /// command that had simply failed.
    func isCut(_ url: URL) -> Bool {
        operation == .cut && isCurrent
            && urls.contains { $0.standardizedFileURL == url.standardizedFileURL }
    }

    /// Download remote items in the background, then rewrite the pasteboard so they
    /// are offered as files. Gives up if another copy has taken the pasteboard since.
    private func materialize(_ urls: [URL]) {
        Task { @MainActor in
            var copies: [URL: URL] = [:]
            for url in urls {
                if let local = try? await RemoteFileCache.shared.localFile(for: url) {
                    copies[url] = local
                }
            }
            guard !copies.isEmpty, !self.urls.isEmpty,
                  NSPasteboard.general.changeCount == writtenChangeCount else { return }
            set(self.urls, operation: operation, localCopies: copies, fetchRemote: false)
        }
    }

    /// Is our copy/cut still what the pasteboard holds?
    ///
    /// The counter is the fast path; the marker is the truthful one, and covers the
    /// case where something else touched the pasteboard without replacing what we
    /// put there. Anything that really does replace the contents removes the marker
    /// with them, so foreign data is still recognised as foreign.
    private var isCurrent: Bool {
        guard !urls.isEmpty else { return false }
        if NSPasteboard.general.changeCount == writtenChangeCount { return true }
        return NSPasteboard.general.data(forType: Self.operationType) != nil
    }

    /// The operation the pasteboard itself says it carries, when it is ours.
    private var markedOperation: Operation? {
        guard let marker = NSPasteboard.general.string(forType: Self.operationType) else { return nil }
        return marker == "cut" ? .cut : .copy
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
        if isCurrent { return (urls, (markedOperation ?? operation) == .cut) }
        let external = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                        options: Self.fileURLOptions) as? [URL] ?? []
        return (external, false)
    }

    /// Clear our record after a cut+paste move so a second paste doesn't re-move.
    func clearAfterMove() {
        // Clear the system pasteboard as well, when it is still the one we wrote:
        // the sources have just been moved away, so leaving their old paths on it
        // means a second ⌘V retries a transfer whose files are gone — which, with
        // "Replace", trashed the copy that had just arrived at the destination.
        if NSPasteboard.general.changeCount == writtenChangeCount
            || NSPasteboard.general.data(forType: Self.operationType) != nil {
            NSPasteboard.general.clearContents()
        }
        urls = []
        writtenChangeCount = -1
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
