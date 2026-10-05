import Foundation
import CoreServices

/// A virtual folder of recently opened documents, like Finder's Recents.
///
/// Finder's Recents is a Spotlight search, and so is this: files whose
/// `kMDItemLastUsedDate` falls inside the window, which Launch Services updates
/// whenever something is opened through Finder, the Dock, an app's Open panel or
/// MacSplorer. Nothing is scanned or tracked here — the index already holds it,
/// and the query answers in a few hundred milliseconds even across cloud folders.
///
/// The items it returns are the real files, at their real `file://` URLs. That is
/// what lets everything else keep working unchanged: opening, Quick Look, dragging
/// out, copying, renaming and trashing all act on the file where it lives. What
/// Recents can't do is *hold* anything — there is no folder on disk behind it — so
/// every operation that would put an item into it is refused.
public final class RecentsProvider: FileSystemProvider {
    public static let scheme = "recents"
    public static let url = URL(string: "recents:///")!

    /// How far back Recents looks. Finder's own window isn't documented; a month is
    /// long enough to find last week's work and short enough to stay relevant.
    public static let windowDays = 30
    /// A ceiling so a very busy month can't produce an unmanageable list.
    public static let limit = 1000

    public init(url: URL) {}

    public var scheme: String { Self.scheme }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            canWrite: false,          // nothing can be put into it — see the type comment
            canRename: false,         // the folder itself; its items rename as local files
            atomicRename: false,
            hasTrash: false,
            emitsChangeEvents: false, // the app watches Spotlight for changes instead
            needsDownloadToOpen: false,
            maxSinglePutBytes: nil)
    }

    public static func isRecents(_ url: URL?) -> Bool { url?.scheme == scheme }

    // MARK: - Listing

    public func children(of directory: URL, includeHidden: Bool) async throws -> [FSItem] {
        guard Self.isRecents(directory) else { return [] }
        let since = Calendar.current.date(byAdding: .day, value: -Self.windowDays, to: Date()) ?? Date()
        let query = Self.queryString(since: since)
        let items = await Task.detached(priority: .userInitiated) {
            Self.items(at: Self.search(query), includeHidden: includeHidden)
        }.value
        // Keep the most recent when trimming to the limit; the pane sorts for display.
        let newestFirst = items.sorted { ($0.lastOpenedDate ?? .distantPast) > ($1.lastOpenedDate ?? .distantPast) }
        return Array(newestFirst.prefix(Self.limit))
    }

    /// Read each result's metadata, in parallel. Most recent files live in cloud
    /// folders, where every metadata read goes through the File Provider; one at a
    /// time, that was most of a 1.4-second listing for ~650 files, against 0.3 s for
    /// the query itself. The reads are independent, so they spread across cores.
    static func items(at paths: [String], includeHidden: Bool) -> [FSItem] {
        var slots = [FSItem?](repeating: nil, count: paths.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let path = paths[index]
            // Spotlight can briefly remember a file that has since moved or gone.
            guard FileManager.default.fileExists(atPath: path) else { return }
            let url = URL(fileURLWithPath: path)
            if !includeHidden && url.lastPathComponent.hasPrefix(".") { return }
            let item = FSItem(url: url)
            // Documents only, as in Finder. A package (.rtfd, .pages) is a document.
            if item.isDirectory && !item.isPackage { return }
            lock.lock(); slots[index] = item; lock.unlock()
        }
        return slots.compactMap { $0 }
    }

    /// The Spotlight query behind Recents. Separate so it can be tested, and so the
    /// app's live-update watcher asks the index exactly the same question.
    public static func queryString(since: Date) -> String {
        let iso = ISO8601DateFormatter().string(from: since)
        return "kMDItemLastUsedDate >= $time.iso(\(iso))"
            + " && kMDItemContentTypeTree != \"public.folder\""
            + " && kMDItemContentTypeTree != \"com.apple.application\""
    }

    /// Run a Spotlight query over the user's home folder, synchronously. Home covers
    /// ~/Library/CloudStorage, so OneDrive and Google Drive files are included.
    static func search(_ query: String) -> [String] {
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(mdQuery, [kMDQueryScopeHome] as CFArray, 0)
        guard MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var paths: [String] = []
        for index in 0..<MDQueryGetResultCount(mdQuery) {
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { paths.append(path) }
        }
        return paths
    }

    public func metadata(for url: URL) async throws -> FSItem {
        FSItem(providerURL: Self.url, name: "Recents", isDirectory: true,
               byteSize: nil, modificationDate: nil, typeDescription: "Recents")
    }

    public func hasChildFolders(at directory: URL, includeHidden: Bool) async -> Bool { false }

    // MARK: - Nothing goes in

    @discardableResult public func copy(_ source: URL, into directory: URL) throws -> URL { throw RecentsError.cannotHold }
    @discardableResult public func move(_ source: URL, into directory: URL) throws -> URL { throw RecentsError.cannotHold }
    @discardableResult public func copy(_ source: URL, to destination: URL) throws -> URL { throw RecentsError.cannotHold }
    @discardableResult public func move(_ source: URL, to destination: URL) throws -> URL { throw RecentsError.cannotHold }
    @discardableResult public func rename(_ url: URL, to newName: String) throws -> URL { throw RecentsError.cannotHold }
    @discardableResult public func moveToTrash(_ url: URL) throws -> URL? { throw RecentsError.cannotHold }
    @discardableResult public func newFolder(in directory: URL, named name: String) throws -> URL { throw RecentsError.cannotHold }
    @discardableResult public func newFile(in directory: URL, named name: String, contents: Data) throws -> URL { throw RecentsError.cannotHold }
}

public enum RecentsError: LocalizedError {
    case cannotHold

    public var errorDescription: String? {
        "Recents shows files where they already are, so nothing can be put into it. "
            + "Use Show in Enclosing Folder to work in a file’s own folder."
    }
}
