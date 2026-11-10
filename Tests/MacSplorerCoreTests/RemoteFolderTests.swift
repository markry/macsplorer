import Foundation
import Testing
import MacSplorerCore

/// Folder transfers, exercised through the local provider: the logic only uses
/// `children(of:)` and `download(_:to:)`, which the local disk implements too.
final class RemoteFolderTests {
    let dir: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsplorer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `source/a.txt`, `source/.hidden`, `source/sub/b.txt`, `source/sub/deeper/c.txt`,
    /// and an empty `source/empty/`.
    private func makeSource() throws -> URL {
        let fm = FileManager.default
        let source = dir.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent("sub/deeper"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("empty"),
                               withIntermediateDirectories: true)
        for path in ["a.txt", ".hidden", "sub/b.txt", "sub/deeper/c.txt"] {
            try path.write(to: source.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return source
    }

    @Test func listsEveryFileAtAnyDepthIncludingHidden() async throws {
        let listing = try await RemoteFolder.contents(of: try makeSource(), provider: LocalProvider())
        #expect(listing.files.map(\.relative) == [".hidden", "a.txt", "sub/b.txt", "sub/deeper/c.txt"])
        #expect(listing.emptyFolders == ["empty"])
    }

    @Test func anEmptyFolderListsItself() async throws {
        let empty = dir.appendingPathComponent("nothing", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let listing = try await RemoteFolder.contents(of: empty, provider: LocalProvider())
        #expect(listing.files.isEmpty)
        #expect(listing.emptyFolders == [""])
    }

    @Test func downloadRecreatesTheStructure() async throws {
        let target = dir.appendingPathComponent("copy", isDirectory: true)
        try await RemoteFolder.download(try makeSource(), to: target, provider: LocalProvider())
        for path in [".hidden", "a.txt", "sub/b.txt", "sub/deeper/c.txt"] {
            let text = try String(contentsOf: target.appendingPathComponent(path), encoding: .utf8)
            #expect(text == path)
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("empty").path,
                                               isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["copy", "source"])
    }

    @Test func downloadReplacesWhatWasThere() async throws {
        let target = dir.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        try await RemoteFolder.download(try makeSource(), to: target, provider: LocalProvider())
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("stale.txt").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.txt").path))
    }

    @Test func failedDownloadLeavesNothingBehind() async throws {
        let target = dir.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "keep".write(to: target.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: Error.self) {
            try await RemoteFolder.download(try self.makeSource(), to: target, provider: FailingProvider())
        }
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("existing.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["copy", "source"])
    }

    @Test func totalSizeCountsEveryFile() async throws {
        let total = try await RemoteFolder.totalSize(of: try makeSource(), provider: LocalProvider())
        // Each file holds its own relative path as text.
        let expected = [".hidden", "a.txt", "sub/b.txt", "sub/deeper/c.txt"].reduce(0) { $0 + $1.utf8.count }
        #expect(total.files == 4)
        #expect(total.bytes == Int64(expected))
    }

    @Test func relativePathsMapBackToURLs() {
        let folder = URL(string: "s3://profile/bucket/top/")!
        #expect(RemoteFolder.url("sub/file.txt", beneath: folder).absoluteString
                == "s3://profile/bucket/top/sub/file.txt")
    }
}

/// Lists like the local disk but fails every download.
private struct FailingProvider: FileSystemProvider {
    private let local = LocalProvider()
    var scheme: String { "file" }
    var capabilities: ProviderCapabilities { local.capabilities }
    func children(of directory: URL, includeHidden: Bool) async throws -> [FSItem] {
        try await local.children(of: directory, includeHidden: includeHidden)
    }
    func metadata(for url: URL) async throws -> FSItem { try await local.metadata(for: url) }
    func hasChildFolders(at directory: URL, includeHidden: Bool) async -> Bool { false }
    func download(_ url: URL, to destination: URL) async throws {
        throw CocoaError(.fileReadUnknown)
    }
    func copy(_ source: URL, into directory: URL) throws -> URL { try local.copy(source, into: directory) }
    func move(_ source: URL, into directory: URL) throws -> URL { try local.move(source, into: directory) }
    func copy(_ source: URL, to destination: URL) throws -> URL { try local.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws -> URL { try local.move(source, to: destination) }
    func rename(_ url: URL, to newName: String) throws -> URL { try local.rename(url, to: newName) }
    func moveToTrash(_ url: URL) throws -> URL? { try local.moveToTrash(url) }
    func newFolder(in directory: URL, named name: String) throws -> URL {
        try local.newFolder(in: directory, named: name)
    }
    func newFile(in directory: URL, named name: String, contents: Data) throws -> URL {
        try local.newFile(in: directory, named: name, contents: contents)
    }
}
