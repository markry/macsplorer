import Foundation

/// The seam that lets MacSplorer browse and mutate storage backends other than
/// the local disk (starting with Amazon S3). The UI and command layers talk to
/// the model in terms of `FSItem` + a `URL`; a provider is what actually reads
/// and writes for a given location, chosen by the URL's scheme.
///
/// Phase 0 (this refactor) introduces the protocol and the `LocalProvider` that
/// reproduces today's local-disk behavior exactly — the methods are synchronous,
/// matching the current code so nothing about local browsing changes. The async
/// conversion (which S3 requires, and which brings explicit loading states) lands
/// on the `s3-provider` branch, where a second provider actually needs it.
public protocol FileSystemProvider {
    /// URL scheme this provider serves (`"file"`, later `"s3"`).
    var scheme: String { get }

    /// What this backend can and can't do, so the UI can adapt honestly rather
    /// than pretending every location behaves like a local disk.
    var capabilities: ProviderCapabilities { get }

    // MARK: Enumeration & metadata
    //
    // Async because a remote backend (S3) does network I/O and can fail. Local
    // completes without suspending, so local loading stays imperceptible.

    /// Children (files + folders) of `directory`, unsorted — the listing chokepoint.
    func children(of directory: URL, includeHidden: Bool) async throws -> [FSItem]

    /// A single item's metadata — the metadata chokepoint.
    func metadata(for url: URL) async throws -> FSItem

    /// Whether `directory` contains at least one non-package subfolder (drives the
    /// tree's disclosure triangle). Best-effort: failures resolve to `false`.
    func hasChildFolders(at directory: URL, includeHidden: Bool) async -> Bool

    // MARK: Mutations (the FileOperations chokepoint)

    @discardableResult func copy(_ source: URL, into directory: URL) throws -> URL
    @discardableResult func move(_ source: URL, into directory: URL) throws -> URL
    /// Copy/move to an EXACT destination URL (caller ensures it's free) — the
    /// collision "Replace" path uses these, vs. the `into:` variants above which
    /// auto-uniquify the name.
    @discardableResult func copy(_ source: URL, to destination: URL) throws -> URL
    @discardableResult func move(_ source: URL, to destination: URL) throws -> URL
    @discardableResult func rename(_ url: URL, to newName: String) throws -> URL
    @discardableResult func moveToTrash(_ url: URL) throws -> URL?
    @discardableResult func newFolder(in directory: URL, named name: String) throws -> URL
    @discardableResult func newFile(in directory: URL, named name: String, contents: Data) throws -> URL
}

public extension FileSystemProvider {
    /// Create a folder with the default "untitled folder" name. (Protocol
    /// requirements can't carry default arguments, so this preserves the old
    /// `FileOperations.newFolder(in:)` call shape.)
    @discardableResult
    func newFolder(in directory: URL) throws -> URL {
        try newFolder(in: directory, named: "untitled folder")
    }

    /// Create an empty file.
    @discardableResult
    func newFile(in directory: URL, named name: String) throws -> URL {
        try newFile(in: directory, named: name, contents: Data())
    }
}

/// A backend's honest self-description, so the UI can show a manual Refresh where
/// there are no change events, a "Downloading…" state where opening needs a local
/// copy, and so on — instead of faking local-disk semantics. `LocalProvider`
/// reports the all-local-capable values; S3 will differ.
public struct ProviderCapabilities {
    /// Supports creating / modifying / deleting items at all.
    public var canWrite: Bool
    /// Supports renaming an item.
    public var canRename: Bool
    /// Rename/move is atomic (local: true; S3: emulated via copy+delete).
    public var atomicRename: Bool
    /// Deletes go to a recoverable Trash (local: true; S3: no Trash).
    public var hasTrash: Bool
    /// Emits change notifications so a directory watcher works (local: true;
    /// S3: false → the UI offers a manual Refresh).
    public var emitsChangeEvents: Bool
    /// Opening/Quick Look needs the bytes fetched to a local temp file first
    /// (local: false; S3: true).
    public var needsDownloadToOpen: Bool
    /// Largest single-shot write; above this a backend must chunk (local: nil;
    /// S3: the multipart threshold).
    public var maxSinglePutBytes: Int?

    public init(canWrite: Bool, canRename: Bool, atomicRename: Bool, hasTrash: Bool,
                emitsChangeEvents: Bool, needsDownloadToOpen: Bool, maxSinglePutBytes: Int?) {
        self.canWrite = canWrite
        self.canRename = canRename
        self.atomicRename = atomicRename
        self.hasTrash = hasTrash
        self.emitsChangeEvents = emitsChangeEvents
        self.needsDownloadToOpen = needsDownloadToOpen
        self.maxSinglePutBytes = maxSinglePutBytes
    }
}

/// Resolves the provider responsible for a location. Phase 0 has only the local
/// disk; the `s3://` case joins here on the `s3-provider` branch.
public enum Providers {
    private static let local = LocalProvider()
    private static let lock = NSLock()
    private static var factories: [String: (URL) -> FileSystemProvider] = [:]

    /// Register a provider factory for a URL scheme. The S3 module calls this at
    /// app startup (`register(scheme: "s3") { S3Provider(url: $0) }`), so the
    /// resolver can route `s3://` without MacSplorerCore importing S3 or the AWS
    /// SDK — keeping the core model dependency-free (and the open-core seam clean).
    public static func register(scheme: String, factory: @escaping (URL) -> FileSystemProvider) {
        lock.lock(); defer { lock.unlock() }
        factories[scheme] = factory
    }

    /// The provider responsible for `url`: a registered factory for its scheme
    /// (e.g. `s3`), else the local disk. Local file URLs have scheme `file` (or
    /// none) and fall through here.
    public static func provider(for url: URL) -> FileSystemProvider {
        if let scheme = url.scheme {
            lock.lock(); let factory = factories[scheme]; lock.unlock()
            if let factory { return factory(url) }
        }
        return local
    }
}
