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

    // MARK: Content

    /// Write the bytes of `url` to `destination` (always a local file URL),
    /// fetching over the network when the backend isn't the local disk.
    ///
    /// This is what makes a remote file openable, previewable and draggable to the
    /// Finder: the UI asks for a local copy and then treats it like any other file.
    /// Providers that can verify what they fetched (a content hash, say) should do so
    /// here, so a truncated download fails loudly instead of opening as a damaged
    /// file. Slow by nature — never call it on the main thread.
    func download(_ url: URL, to destination: URL) async throws

    /// Write a local file to `destination`, a location in this provider — the upload
    /// half of a copy between backends. Replacing an existing item must not leave it
    /// damaged or half-written when the upload fails.
    func upload(_ file: URL, to destination: URL) async throws

    /// Whether something is already at `url`, so a copy can ask before replacing it.
    func exists(_ url: URL) async -> Bool

    /// How much is at or under `url`, looking no further than `limit` items — what a
    /// confirmation dialog needs before a delete. Bounded on purpose: counting a
    /// remote prefix in full can take minutes, so a provider returns an exact number
    /// when the answer fits inside the limit and `isPartial` when it doesn't.
    func peekCount(at url: URL, limit: Int) async throws -> ProviderCount

    /// Create a folder, asynchronously — the remote counterpart of `newFolder`.
    ///
    /// A backend that has to go over the network can't answer from the sync mutation
    /// seam without blocking the main thread, and for some of them "folder" isn't one
    /// concept at every level (an S3 bucket is not a prefix). Providers that create
    /// locally inherit the default, which just calls `newFolder`.
    func createFolder(in directory: URL, named name: String) async throws -> URL

    /// Delete permanently, recursing into folders. Advances `progress` as it goes and
    /// stops cleanly when it is cancelled — a cancelled delete leaves whatever hasn't
    /// been deleted yet in place, and is not an error.
    func deletePermanently(_ url: URL, progress: ProviderProgress?) async throws

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

    /// Local disk: copying is the whole job. A remote provider overrides this;
    /// one that hasn't implemented downloading yet says so clearly.
    func download(_ url: URL, to destination: URL) async throws {
        guard url.isFileURL else { throw ProviderError.downloadUnsupported(url) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    /// Likewise for writing: a provider that hasn't implemented uploading says so.
    func upload(_ file: URL, to destination: URL) async throws {
        guard destination.isFileURL else { throw ProviderError.uploadUnsupported(destination) }
        try FileManager.default.copyItem(at: file, to: destination)
    }

    func exists(_ url: URL) async -> Bool {
        url.isFileURL && FileManager.default.fileExists(atPath: url.path)
    }

    /// Local disk: walk the tree, but stop at `limit` like any other provider, so a
    /// confirmation for a huge folder appears as fast as one for a small folder.
    func peekCount(at url: URL, limit: Int) async throws -> ProviderCount {
        guard url.isFileURL else { return ProviderCount(items: 1) }
        return localPeekCount(at: url, limit: limit)
    }

    /// Creating locally needs no network, so the async seam just calls the sync one.
    func createFolder(in directory: URL, named name: String) async throws -> URL {
        try newFolder(in: directory, named: name)
    }

    /// Local disk deletes in one call; a remote provider overrides this, and one that
    /// can't delete yet says so rather than pretending to succeed.
    func deletePermanently(_ url: URL, progress: ProviderProgress?) async throws {
        guard url.isFileURL else { throw ProviderError.deleteUnsupported(url) }
        try FileManager.default.removeItem(at: url)
        progress?.advance(detail: url.lastPathComponent)
    }
}

/// The local-disk walk behind `peekCount`, kept out of the async function because
/// `FileManager`'s enumerator can't be iterated from an async context.
private func localPeekCount(at url: URL, limit: Int) -> ProviderCount {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return ProviderCount(items: 0)
    }
    guard isDirectory.boolValue else {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ProviderCount(items: 1, bytes: Int64(size))
    }
    guard let walker = fm.enumerator(at: url,
                                     includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                     options: [.skipsPackageDescendants]) else {
        return ProviderCount(items: 0)
    }
    var items = 0
    var bytes: Int64 = 0
    for case let child as URL in walker {
        items += 1
        if items > limit { return ProviderCount(items: limit, bytes: bytes, isPartial: true) }
        let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
    }
    return ProviderCount(items: items, bytes: bytes)
}

/// Errors raised by the provider seam itself, rather than by one backend.
public enum ProviderError: LocalizedError {
    /// The backend serving this URL can't produce a local copy yet.
    case downloadUnsupported(URL)
    /// The backend serving this URL can't accept a file yet.
    case uploadUnsupported(URL)
    /// The backend serving this URL can't delete yet.
    case deleteUnsupported(URL)

    public var errorDescription: String? {
        switch self {
        case .downloadUnsupported(let url):
            return "Downloading isn’t supported for \(url.scheme ?? "this") locations yet."
        case .uploadUnsupported(let url):
            return "Uploading isn’t supported for \(url.scheme ?? "this") locations yet."
        case .deleteUnsupported(let url):
            return "Deleting isn’t supported for \(url.scheme ?? "this") locations yet."
        }
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

/// How a provider finds its credentials: a list of folders the user maintains.
///
/// The provider describes the setting; the app renders and edits it. That keeps the
/// core free of UI and lets a provider module contribute a settings screen without
/// linking against the app — it hands over text, a defaults key holding an array of
/// folder paths, and what to do once the list changes.
public struct ProviderLocations {
    /// Menu title for this provider's entry, e.g. "Amazon S3…".
    public let menuTitle: String
    /// Title of the window that edits the list.
    public let windowTitle: String
    /// A sentence or two explaining what belongs in these folders.
    public let explanation: String
    /// UserDefaults key holding `[String]` — the folder paths, in order.
    public let defaultsKey: String
    /// Where the "Add…" panel starts, when that folder is a sensible default.
    public let suggestedFolder: URL?
    /// An optional on/off setting shown as a checkbox (S3 hides its profiles this
    /// way). Nil when the provider has nothing to toggle.
    public let toggleTitle: String?
    public let isEnabled: (() -> Bool)?
    public let setEnabled: ((Bool) -> Void)?
    /// Re-read the locations and refresh anything showing them. Called after an edit.
    public let apply: () -> Void

    public init(menuTitle: String, windowTitle: String, explanation: String,
                defaultsKey: String, suggestedFolder: URL? = nil,
                toggleTitle: String? = nil,
                isEnabled: (() -> Bool)? = nil,
                setEnabled: ((Bool) -> Void)? = nil,
                apply: @escaping () -> Void) {
        self.menuTitle = menuTitle
        self.windowTitle = windowTitle
        self.explanation = explanation
        self.defaultsKey = defaultsKey
        self.suggestedFolder = suggestedFolder
        self.toggleTitle = toggleTitle
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.apply = apply
    }
}

/// A remote namespace surfaced as a folder under /Volumes. `url` is the location
/// the folder opens — normally its provider's scheme root (`scheme:///`).
public struct ProviderMount: Equatable {
    public let name: String
    public let url: URL
    public let typeDescription: String?

    public init(name: String, url: URL, typeDescription: String? = nil) {
        self.name = name
        self.url = url
        self.typeDescription = typeDescription
    }
}

/// Resolves the provider responsible for a location. Phase 0 has only the local
/// disk; the `s3://` case joins here on the `s3-provider` branch.
public enum Providers {
    private static let local = LocalProvider()
    private static let lock = NSLock()
    private static var factories: [String: (URL) -> FileSystemProvider] = [:]
    private static var mountSources: [() -> [ProviderMount]] = []
    private static var locationSettings: [ProviderLocations] = []

    /// Register a source of mounts: remote namespaces the UI shows as folders under
    /// /Volumes, beside mounted disks. Called at launch by a provider module; the
    /// source is re-evaluated on every `mounts()` call, so it can reflect settings
    /// that change while the app runs.
    public static func registerMounts(_ source: @escaping () -> [ProviderMount]) {
        lock.lock(); defer { lock.unlock() }
        mountSources.append(source)
    }

    /// Every mount currently contributed by the registered sources.
    public static func mounts() -> [ProviderMount] {
        lock.lock(); let sources = mountSources; lock.unlock()
        return sources.flatMap { $0() }
    }

    /// Register where this provider looks for credentials, so the app can offer a
    /// screen to edit it. Registration order is the order shown.
    public static func registerLocations(_ locations: ProviderLocations) {
        lock.lock(); defer { lock.unlock() }
        locationSettings.append(locations)
    }

    /// Every provider's credential-folder setting, for building the menu.
    public static func allLocations() -> [ProviderLocations] {
        lock.lock(); defer { lock.unlock() }
        return locationSettings
    }

    /// Register a provider factory for a URL scheme. The S3 module calls this at
    /// app startup (`register(scheme: "s3") { S3Provider(url: $0) }`), so the
    /// resolver can route `s3://` without MacSplorerCore importing S3 or the AWS
    /// SDK — keeping the core model dependency-free (and the open-core seam clean).
    public static func register(scheme: String, factory: @escaping (URL) -> FileSystemProvider) {
        lock.lock(); defer { lock.unlock() }
        factories[scheme] = factory
    }

    /// Whether a provider is registered for `scheme` — lets the UI accept a typed
    /// `scheme://…` address for any registered backend without knowing about it.
    public static func isRegistered(scheme: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return factories[scheme] != nil
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
