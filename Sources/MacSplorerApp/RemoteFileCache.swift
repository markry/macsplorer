import AppKit
import CryptoKit
import UniformTypeIdentifiers
import MacSplorerCore

/// Local copies of files held by a remote provider, so they can be opened, previewed
/// and dragged to the Finder like any other file.
///
/// Files land under this app's Caches folder, mirroring the remote URL's shape so a
/// downloaded file keeps a sensible name and path. A copy is reused only while the
/// file on the server still has the size and date it had when fetched: someone may
/// have uploaded a new version since. Concurrent requests for the same URL share
/// one download rather than racing.
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
    /// What each file looked like on the server when it was fetched.
    private var fingerprints: [URL: Fingerprint] = [:]
    /// When each copy was last confirmed current, for callers that can't wait.
    private var verifiedAt: [URL: Date] = [:]
    /// How long a confirmed copy is trusted without asking the server again.
    private static let trustInterval: TimeInterval = 30

    private struct Fingerprint: Equatable {
        let size: Int?
        let modified: Date?

        /// Nil when the provider reports neither, so there's nothing to compare.
        init?(_ item: FSItem) {
            guard item.byteSize != nil || item.modificationDate != nil else { return nil }
            size = item.byteSize
            modified = item.modificationDate
        }
    }

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = caches.appendingPathComponent("net.ryland.macsplorer/remote", isDirectory: true)
    }

    /// A local file holding `url`'s bytes, downloading if this session hasn't already.
    func localFile(for url: URL) async throws -> URL {
        let destination = localPath(for: url)
        if fetched.contains(url), FileManager.default.fileExists(atPath: destination.path) {
            if await isCurrent(url) {
                verifiedAt[url] = Date()
                return destination
            }
            fetched.remove(url)
            verifiedAt[url] = nil
        }
        if let existing = inFlight[url] { return try await existing.value }

        let provider = Providers.provider(for: url)
        let task = Task<URL, Error> {
            // Note what's on the server first: a version uploaded during the download
            // then reads as a change next time, rather than being mistaken for this one.
            let item = try? await provider.metadata(for: url)
            try await provider.download(url, to: destination)
            await MainActor.run { self.fingerprints[url] = item.flatMap(Fingerprint.init) }
            return destination
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let result = try await task.value
        fetched.insert(url)
        failed.remove(url)
        verifiedAt[url] = Date()
        return result
    }

    /// Whether the copy fetched earlier still matches the file on the server. When
    /// the provider can't say (no size or date, or it can't be reached), the copy is
    /// kept: an old copy beats none when offline.
    private func isCurrent(_ url: URL) async -> Bool {
        guard let known = fingerprints[url],
              let item = try? await Providers.provider(for: url).metadata(for: url),
              let now = Fingerprint(item) else { return true }
        return now == known
    }

    /// The local copy, if this session has one that was confirmed current within the
    /// last few seconds — for callers that can't wait (Quick Look asks synchronously).
    /// Otherwise nil, and the caller's prefetch checks with the server.
    func cachedFile(for url: URL) -> URL? {
        guard fetched.contains(url), let verified = verifiedAt[url],
              Date().timeIntervalSince(verified) < Self.trustInterval else { return nil }
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

    /// A promise for a remote file or folder. A folder is fetched whole, with
    /// everything beneath it, only if the drop is accepted.
    static func promiseProvider(for item: FSItem) -> RemoteFilePromise? {
        promiseProvider(url: item.url, name: item.name)
    }

    /// The same, for callers holding a URL rather than a listed item — copying to the
    /// clipboard, where the paste may land in another app.
    static func promiseProvider(url: URL, name: String) -> RemoteFilePromise? {
        guard !url.isFileURL else { return nil }
        let type = url.hasDirectoryPath
            ? UTType.folder
            : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
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
                if source.hasDirectoryPath {
                    try await RemoteFolder.download(source, to: url,
                                                    provider: Providers.provider(for: source))
                    completionHandler(nil)
                    return
                }
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
