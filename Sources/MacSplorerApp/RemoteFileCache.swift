import AppKit
import CryptoKit
import UniformTypeIdentifiers
import MacSplorerCore

/// Local copies of files held by a remote provider, so they can be opened, previewed
/// and dragged to the Finder like any other file.
///
/// Files land under this app's Caches folder, mirroring the remote URL's shape so a
/// downloaded file keeps a sensible name and path. A copy is reused for the rest of
/// the session; a new launch fetches again, which keeps a "latest" view honest
/// without needing a change feed. Concurrent requests for the same URL share one
/// download rather than racing.
@MainActor
final class RemoteFileCache {
    static let shared = RemoteFileCache()

    private let root: URL
    /// URLs fetched during this session, so repeat opens don't re-download.
    private var fetched: Set<URL> = []
    /// URLs whose download failed, so a background prefetch doesn't retry forever.
    /// An explicit open clears the entry and tries again.
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<URL, Error>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = caches.appendingPathComponent("net.ryland.macsplorer/remote", isDirectory: true)
    }

    /// A local file holding `url`'s bytes, downloading if this session hasn't already.
    func localFile(for url: URL) async throws -> URL {
        let destination = localPath(for: url)
        if fetched.contains(url), FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<URL, Error> {
            try await Providers.provider(for: url).download(url, to: destination)
            return destination
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let result = try await task.value
        fetched.insert(url)
        failed.remove(url)
        return result
    }

    /// The local copy if one is already on disk from this session — for callers that
    /// can't wait (Quick Look asks synchronously).
    func cachedFile(for url: URL) -> URL? {
        guard fetched.contains(url) else { return nil }
        let path = localPath(for: url)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Start a download and run `completion` on the main thread once it lands, so a
    /// caller that had nothing to show can ask again.
    ///
    /// `completion` runs only on success, and a URL that failed isn't retried: Quick
    /// Look reloads its panel from this callback, which asks for the same file again —
    /// a failing download would otherwise spin, fetching and failing for as long as the
    /// panel stays open.
    func prefetch(_ url: URL, completion: @escaping () -> Void) {
        guard cachedFile(for: url) == nil, inFlight[url] == nil, !failed.contains(url) else { return }
        Task { @MainActor in
            do {
                _ = try await localFile(for: url)
                completion()
            } catch {
                failed.insert(url)
            }
        }
    }

    /// Where a remote URL's bytes live locally:
    /// `<caches>/remote/<scheme>/<host>/<url digest>/<filename>`.
    ///
    /// The digest folder does the addressing, so the filename can be kept as-is for
    /// the Finder and Quick Look without the remote path having to be mirrored. That
    /// avoids two hazards of echoing remote names into local paths: a `..` component
    /// escaping the cache, and one location's file colliding with another's folder
    /// (`a/b` the file versus `a/b/c`).
    private func localPath(for url: URL) -> URL {
        var path = root.appendingPathComponent(url.scheme ?? "remote", isDirectory: true)
        path.appendPathComponent(Self.safeComponent(url.host ?? "-"), isDirectory: true)
        path.appendPathComponent(Self.digest(of: url.absoluteString), isDirectory: true)
        path.appendPathComponent(Self.safeComponent(url.lastPathComponent), isDirectory: false)
        return path
    }

    /// One path component that can't escape the folder it's placed in.
    private static func safeComponent(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "item" }
        return String(cleaned.prefix(200))
    }

    private static func digest(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// A file promise that also carries the provider URL it came from.
///
/// Dragging out to another app needs a promise: there is no file until the drop is
/// accepted. But a drop *back into MacSplorer* shouldn't round-trip through a
/// promise — the destination can fetch the bytes itself, with collision handling and
/// progress. So the same drag advertises a private type holding the item's provider
/// URL, which only MacSplorer reads.
final class RemoteFilePromise: NSFilePromiseProvider {
    static let providerURLType = NSPasteboard.PasteboardType("net.ryland.macsplorer.provider-url")

    var providerURL: URL?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [Self.providerURLType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == Self.providerURLType else { return super.pasteboardPropertyList(forType: type) }
        return providerURL?.absoluteString
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        guard type == Self.providerURLType else {
            return super.writingOptions(forType: type, pasteboard: pasteboard)
        }
        return []
    }

    /// The provider URLs on a pasteboard, for a drop landing back inside MacSplorer.
    static func providerURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.string(forType: providerURLType).flatMap(URL.init(string:))
        }
    }
}

/// Supplies remote files to the Finder (and anything else accepting file promises)
/// when one is dragged out of MacSplorer. The drag carries a promise rather than a
/// URL, so the bytes are fetched only if the user actually drops it somewhere.
final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    static let shared = RemoteFilePromiseDelegate()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// A promise for a remote file, or nil for anything that can't be handed over
    /// this way (folders, which would need a recursive download).
    static func promiseProvider(for item: FSItem) -> RemoteFilePromise? {
        guard !item.isDirectory else { return nil }
        return promiseProvider(url: item.url, name: item.name)
    }

    /// The same, for callers holding a URL rather than a listed item — copying to the
    /// clipboard, where the paste may land in another app.
    static func promiseProvider(url: URL, name: String) -> RemoteFilePromise? {
        guard !url.isFileURL else { return nil }
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        let provider = RemoteFilePromise(fileType: type.identifier, delegate: shared)
        provider.providerURL = url
        provider.userInfo = [Key.url: url, Key.name: name]
        return provider
    }

    private enum Key {
        static let url = "url"
        static let name = "name"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        let info = filePromiseProvider.userInfo as? [String: Any]
        return (info?[Key.name] as? String) ?? "Untitled"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let info = filePromiseProvider.userInfo as? [String: Any]
        guard let source = info?[Key.url] as? URL else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        Task { @MainActor in
            do {
                // Reuse the session copy when there is one, so dragging a file you
                // just opened doesn't fetch it twice.
                let local = try await RemoteFileCache.shared.localFile(for: source)
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: local, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}
