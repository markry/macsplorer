import Foundation
import Testing
@testable import MacSplorerCore

/// Listing a folder when one entry can't be read (a dead network share in /Volumes):
/// the readable entries must still come back, rather than the folder looking empty.
final class FSItemListingTests {
    let dir: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsplorer-tests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private let keys: [URLResourceKey] = [.isDirectoryKey]

    /// Stands in for the prefetching listing failing on one bad entry.
    private func failing(_: URL, _: [URLResourceKey], _: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        throw CocoaError(.fileReadNoSuchFile)
    }

    @Test func aFailedListingFallsBackToTheReadableEntries() {
        let names = FSItem.entries(of: dir, keys: keys, includeHidden: false, prefetching: failing)
            .map(\.lastPathComponent).sorted()
        #expect(names == ["a", "b", "file.txt"])
    }

    @Test func theFallbackHonorsHiddenFiles() {
        let names = FSItem.entries(of: dir, keys: keys, includeHidden: true, prefetching: failing)
            .map(\.lastPathComponent).sorted()
        #expect(names == [".hidden", "a", "b", "file.txt"])
    }

    @Test func aMissingFolderListsAsEmpty() {
        let missing = dir.appendingPathComponent("nope")
        #expect(FSItem.entries(of: missing, keys: keys, includeHidden: false).isEmpty)
    }

    @Test func subfolderCheckStillFindsFolders() {
        #expect(FSItem.directoryHasSubfolders(at: dir, includeHidden: false))
    }
}
