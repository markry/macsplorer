import AppKit
import MacSplorerCore

/// Deleting from a remote provider, where there is no Trash to fall back on.
///
/// The local Finder gesture is forgiving — Move to Trash is undoable — so removing
/// something from S3 with the same keystroke deserves a decision rather than a
/// silent permanent delete. The dialog offers two honest options: bring the bytes
/// down to the local Trash first, or delete outright.
///
/// Both can run long, so both report progress and can be stopped. Neither pretends
/// to know how much work there is: a bounded peek (one listing page) gives an exact
/// count for small folders and "more than 1,000 objects" for large ones, which is
/// all that can be known quickly — counting a big prefix in full can take minutes.
@MainActor
enum RemoteDelete {
    enum Choice {
        case copyToTrash
        case deleteOutright
    }

    /// How far the pre-flight peek looks. One S3 listing page: a single round trip,
    /// measured at well under a second even when it comes back full.
    static let peekLimit = 1000

    /// Ask what to do. Returns nil when the user cancels, or when we couldn't find
    /// out what is there — a delete dialog that can't describe what it would delete
    /// has nothing to offer, and guessing is worse than stopping.
    static func confirm(_ urls: [URL]) async -> Choice? {
        let summary: String
        do {
            summary = try await peek(urls)
        } catch {
            let alert = NSAlert()
            alert.messageText = urls.count == 1
                ? "Couldn\u{2019}t check what\u{2019}s in \u{201C}\(urls[0].lastPathComponent)\u{201D}."
                : "Couldn\u{2019}t check what would be deleted."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? "Delete \u{201C}\(urls[0].lastPathComponent)\u{201D}?"
            : "Delete \(urls.count) items?"
        alert.informativeText = summary
        alert.addButton(withTitle: "Copy to Local Trash")
        alert.addButton(withTitle: "Full Deletion")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .copyToTrash
        case .alertSecondButtonReturn: return .deleteOutright
        default:                       return nil
        }
    }

    /// What the dialog says about the size of the job. Throws rather than reporting
    /// a number it doesn't have: the first version swallowed peek failures with
    /// `try?`, so a bucket (which it couldn't count) was announced as "0 objects"
    /// and the default button then quietly downloaded the whole thing.
    private static func peek(_ urls: [URL]) async throws -> String {
        var items = 0
        var bytes: Int64 = 0
        var isPartial = false
        var notes: [String] = []
        for url in urls {
            let count = try await Providers.provider(for: url).peekCount(at: url, limit: peekLimit)
            items += count.items
            bytes += count.bytes
            isPartial = isPartial || count.isPartial
            if let note = count.note, !notes.contains(note) { notes.append(note) }
        }
        let scale = isPartial
            ? "More than \(peekLimit.formatted()) objects"
            : "\(items.formatted()) object\(items == 1 ? "" : "s") \u{00B7} \(FSFormat.size(bytes))"
        var text = scale + ".\n\n"
        if !notes.isEmpty { text += notes.joined(separator: " ") + "\n\n" }
        text += "Copying to the local Trash downloads everything first, so it can be "
              + "recovered from the Trash afterwards. Full deletion removes it from the "
              + "server immediately and can\u{2019}t be undone."
        return text
    }

    /// Carry out the choice. Progress is advanced per object; cancelling stops
    /// between objects, leaving everything not yet deleted in place.
    static func perform(_ urls: [URL], choice: Choice, progress: ProviderProgress) async throws {
        for url in urls {
            if progress.isCancelled { return }
            let provider = Providers.provider(for: url)
            if choice == .copyToTrash {
                try await copyToTrash(url, provider: provider, progress: progress)
                if progress.isCancelled { return }   // don't delete what wasn't saved
            }
            try await provider.deletePermanently(url, progress: progress)
        }
    }

    // MARK: - Copying down to the Trash

    /// Download `url` into the user's Trash, keeping a folder's structure. A folder
    /// lands in a dated container ("photos (deleted 2026-09-17 14:22)") because the
    /// Trash is flat enough already and two deletes of the same prefix shouldn't
    /// merge into one heap.
    private static func copyToTrash(_ url: URL, provider: FileSystemProvider,
                                    progress: ProviderProgress) async throws {
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        let item = try await provider.metadata(for: url)
        guard item.isDirectory else {
            let destination = uniqueURL(in: trash, named: url.lastPathComponent)
            try await provider.download(url, to: destination)
            progress.advance(bytes: Int64(item.byteSize ?? 0), detail: url.lastPathComponent)
            return
        }
        let stamp = Self.stampFormatter.string(from: Date())
        let root = uniqueURL(in: trash, named: "\(url.lastPathComponent) (deleted \(stamp))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await copyFolder(url, provider: provider, into: root, progress: progress)
    }

    /// Walk the remote folder with the provider's own listing and download as we go,
    /// rather than gathering every key up front: on a large prefix the up-front pass
    /// is the slow part, and this way the first files reach the Trash immediately.
    private static func copyFolder(_ folder: URL, provider: FileSystemProvider,
                                   into destination: URL, progress: ProviderProgress) async throws {
        let children = try await provider.children(of: folder, includeHidden: true)
        for child in children {
            if progress.isCancelled { return }
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(child.name)
            if child.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try await copyFolder(child.url, provider: provider, into: target, progress: progress)
            } else {
                try await provider.download(child.url, to: target)
                progress.advance(bytes: Int64(child.byteSize ?? 0), detail: child.name)
            }
        }
    }

    /// A free name in `directory` — the Trash may well hold something of this name
    /// already, and macOS doesn't merge for us here.
    private static func uniqueURL(in directory: URL, named name: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        repeat {
            let suffix = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(suffix)
            index += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()
}
