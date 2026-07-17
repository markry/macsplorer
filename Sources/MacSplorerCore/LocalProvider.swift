import Foundation

/// The local-disk `FileSystemProvider`: MacSplorer's original behavior, now
/// behind the provider seam. It delegates to the existing `FSItem` listing and
/// `FileOperations` mutations, so extracting this interface changes nothing about
/// how local browsing works — it just gives S3 (and any future backend) a slot to
/// plug into the same call sites.
public struct LocalProvider: FileSystemProvider {
    public init() {}

    public var scheme: String { "file" }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            canWrite: true,
            canRename: true,
            atomicRename: true,
            hasTrash: true,
            emitsChangeEvents: true,
            needsDownloadToOpen: false,
            maxSinglePutBytes: nil)
    }

    // MARK: Enumeration & metadata

    public func children(of directory: URL, includeHidden: Bool) -> [FSItem] {
        FSItem.contents(of: directory, includeHidden: includeHidden)
    }

    public func metadata(for url: URL) -> FSItem {
        FSItem(url: url)
    }

    public func hasChildFolders(at directory: URL, includeHidden: Bool) -> Bool {
        FSItem.directoryHasSubfolders(at: directory, includeHidden: includeHidden)
    }

    // MARK: Mutations

    @discardableResult
    public func copy(_ source: URL, into directory: URL) throws -> URL {
        try FileOperations.copy(source, into: directory)
    }

    @discardableResult
    public func move(_ source: URL, into directory: URL) throws -> URL {
        try FileOperations.move(source, into: directory)
    }

    @discardableResult
    public func copy(_ source: URL, to destination: URL) throws -> URL {
        try FileOperations.copy(source, to: destination)
    }

    @discardableResult
    public func move(_ source: URL, to destination: URL) throws -> URL {
        try FileOperations.move(source, to: destination)
    }

    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        try FileOperations.rename(url, to: newName)
    }

    @discardableResult
    public func moveToTrash(_ url: URL) throws -> URL? {
        try FileOperations.moveToTrash(url)
    }

    @discardableResult
    public func newFolder(in directory: URL, named name: String) throws -> URL {
        try FileOperations.newFolder(in: directory, named: name)
    }

    @discardableResult
    public func newFile(in directory: URL, named name: String, contents: Data) throws -> URL {
        try FileOperations.newFile(in: directory, named: name, contents: contents)
    }
}
