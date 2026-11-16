import Foundation
import Testing
@testable import MacSplorerCore

/// Codex's release-gate blocker: two incoming names the destination takes for one
/// item. The copy must refuse before writing, so a move can't delete the source of
/// the file that would have been lost.
@Suite struct NameClashTests {
    private func url(_ path: String) -> URL { URL(string: "x://acct/dest\(path)")! }

    @Test func caseVariantsClashOnAForgivingDestination() throws {
        let clash = try #require(RemoteFolder.firstNameClash([url("/A"), url("/a")], rules: .forgiving))
        #expect(clash.0 == url("/A") && clash.1 == url("/a"))
    }

    @Test func caseVariantsAreFineWhereNamesAreExact() {
        // S3: "A" and "a" are different keys.
        #expect(RemoteFolder.firstNameClash([url("/A"), url("/a")], rules: .exact) == nil)
    }

    @Test func compositionVariantsClashUnlessCompositionCounts() {
        let composed = URL(string: "x://acct/dest/caf%C3%A9")!     // é as one character
        let decomposed = URL(string: "x://acct/dest/cafe%CC%81")!  // e + combining accent
        #expect(RemoteFolder.firstNameClash([composed, decomposed], rules: .forgiving) != nil)
        // A case-sensitive but normalizing destination (like case-sensitive APFS).
        #expect(RemoteFolder.firstNameClash([composed, decomposed],
                                            rules: NameRules(caseSensitive: true, compositionSensitive: false)) != nil)
        #expect(RemoteFolder.firstNameClash([composed, decomposed], rules: .exact) == nil)
    }

    @Test func aFileClashesWithAFolderOfTheSameName() {
        // File "A" and folder "a/" (holding a file, or empty).
        #expect(RemoteFolder.firstNameClash([url("/A"), url("/a/child")], rules: .forgiving) != nil)
        #expect(RemoteFolder.firstNameClash([url("/A")], folders: [url("/a/")], rules: .forgiving) != nil)
    }

    @Test func manyFilesInOneFolderDontClash() {
        #expect(RemoteFolder.firstNameClash([url("/sub/one"), url("/sub/two"), url("/Sub/three")],
                                            rules: .forgiving) == nil)
    }

    @Test func distinctNamesNeverClash() {
        #expect(RemoteFolder.firstNameClash([url("/a"), url("/b"), url("/a copy")], rules: .forgiving) == nil)
    }

    /// The deferred P2: a nested empty folder's parents are reserved too, so a Keep
    /// Both name can't take the place of the folder that leads to it.
    @Test func nestedEmptyFoldersReserveTheirParents() async {
        let locked = URL(string: "lockedtest://acct/box/rw/locked")!
        let empty = URL(string: "lockedtest://acct/box/rw/locked%20copy/inner/")!
        Providers.register(scheme: "lockedtest") { _ in LockedOnly() }
        let planned = await RemoteFolder.planDestinations([locked], reserving: [empty]) {
            $0.absoluteString == locked.absoluteString
        }
        #expect(planned == [URL(string: "lockedtest://acct/box/rw/locked%20copy%202")!])
    }

    /// A download to this Mac refuses two names its disk would take for one.
    @Test func downloadRefusesNamesTheLocalDiskWouldMerge() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsplorer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let caseSensitive = (try? dir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? false
        let target = dir.appendingPathComponent("copy", isDirectory: true)
        if caseSensitive == true {
            try await RemoteFolder.download(URL(string: "mem:///src/")!, to: target, provider: TwoCases())
        } else {
            await #expect(throws: RemoteFolderError.self) {
                try await RemoteFolder.download(URL(string: "mem:///src/")!, to: target, provider: TwoCases())
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }
}

/// Lists "A" and "a" in one folder, as a case-sensitive backend can.
private struct TwoCases: FileSystemProvider {
    private let local = LocalProvider()
    var scheme: String { "mem" }
    var capabilities: ProviderCapabilities { local.capabilities }
    func children(of directory: URL, includeHidden: Bool) async throws -> [FSItem] {
        ["A", "a"].map {
            FSItem(providerURL: directory.appendingPathComponent($0), name: $0, isDirectory: false,
                   byteSize: 1, modificationDate: nil)
        }
    }
    func metadata(for url: URL) async throws -> FSItem { try await local.metadata(for: url) }
    func hasChildFolders(at directory: URL, includeHidden: Bool) async -> Bool { false }
    func download(_ url: URL, to destination: URL) async throws {
        try url.lastPathComponent.write(to: destination, atomically: true, encoding: .utf8)
    }
    func copy(_ source: URL, into directory: URL) throws -> URL { source }
    func move(_ source: URL, into directory: URL) throws -> URL { source }
    func copy(_ source: URL, to destination: URL) throws -> URL { destination }
    func move(_ source: URL, to destination: URL) throws -> URL { destination }
    func rename(_ url: URL, to newName: String) throws -> URL { url }
    func moveToTrash(_ url: URL) throws -> URL? { nil }
    func newFolder(in directory: URL, named name: String) throws -> URL { directory }
    func newFile(in directory: URL, named name: String, contents: Data) throws -> URL { directory }
}

/// Everything writable; only "locked" refuses replacement.
private struct LockedOnly: FileSystemProvider {
    private let local = LocalProvider()
    var scheme: String { "lockedtest" }
    var capabilities: ProviderCapabilities { local.capabilities }
    func permissions(of item: URL) -> ItemPermissions? {
        item.lastPathComponent == "locked" ? ItemPermissions(canChangeContents: false) : nil
    }
    func children(of directory: URL, includeHidden: Bool) async throws -> [FSItem] { [] }
    func metadata(for url: URL) async throws -> FSItem { try await local.metadata(for: url) }
    func hasChildFolders(at directory: URL, includeHidden: Bool) async -> Bool { false }
    func download(_ url: URL, to destination: URL) async throws {}
    func copy(_ source: URL, into directory: URL) throws -> URL { source }
    func move(_ source: URL, into directory: URL) throws -> URL { source }
    func copy(_ source: URL, to destination: URL) throws -> URL { destination }
    func move(_ source: URL, to destination: URL) throws -> URL { destination }
    func rename(_ url: URL, to newName: String) throws -> URL { url }
    func moveToTrash(_ url: URL) throws -> URL? { nil }
    func newFolder(in directory: URL, named name: String) throws -> URL { directory }
    func newFile(in directory: URL, named name: String, contents: Data) throws -> URL { directory }
}
