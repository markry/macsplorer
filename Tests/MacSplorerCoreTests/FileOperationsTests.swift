import Foundation
import Testing
import MacSplorerCore

/// FileOperations behavior. Uses swift-testing (not XCTest) so the suite runs
/// under a stand-alone swift.org toolchain — no full Xcode required, matching
/// how MacSplorer is built and shipped (Command Line Tools only).
///
/// A fresh instance is created per `@Test`, so `init` / `deinit` give us the
/// old setUp / tearDown behavior: a unique temp dir per test, cleaned up after.
final class FileOperationsTests {
    let dir: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsplorer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func makeFile(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? dir).appendingPathComponent(name)
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    @Test func copyCreatesFileAndKeepsOriginal() throws {
        let source = try makeFile("a.txt")
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let dest = try FileOperations.copy(source, into: sub)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(dest.lastPathComponent == "a.txt")
    }

    @Test func copyCollisionGetsCopySuffix() throws {
        let source = try makeFile("a.txt")
        #expect(try FileOperations.copy(source, into: dir).lastPathComponent == "a copy.txt")
        #expect(try FileOperations.copy(source, into: dir).lastPathComponent == "a copy 2.txt")
    }

    @Test func moveRemovesSource() throws {
        let source = try makeFile("m.txt")
        let sub = dir.appendingPathComponent("sub2")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let dest = try FileOperations.move(source, into: sub)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func moveIntoSameDirectoryIsNoop() throws {
        let source = try makeFile("same.txt")
        #expect(try FileOperations.move(source, into: dir) == source)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func rename() throws {
        let source = try makeFile("old.txt")
        let dest = try FileOperations.rename(source, to: "new.txt")
        #expect(dest.lastPathComponent == "new.txt")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func renameEmptyOrUnchangedIsNoop() throws {
        let source = try makeFile("keep.txt")
        #expect(try FileOperations.rename(source, to: "   ") == source)
        #expect(try FileOperations.rename(source, to: "keep.txt") == source)
    }

    @Test func renameToExistingNameThrowsFileExists() throws {
        // Mirrors the reported bug: renaming a just-created folder to an existing
        // folder's name must THROW (fileWriteFileExists) so the UI can report it,
        // rather than failing silently. Also asserts the source is left intact.
        _ = try FileOperations.newFolder(in: dir, named: "Existing")
        let other = try FileOperations.newFolder(in: dir, named: "Temp")
        do {
            _ = try FileOperations.rename(other, to: "Existing")
            Issue.record("expected rename to an existing name to throw")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteFileExists)
        }
        #expect(isDirectory(other))
    }

    @Test func renameWithPathSeparatorThrowsInvalidName() throws {
        let source = try makeFile("safe.txt")
        do {
            _ = try FileOperations.rename(source, to: "a/b")
            Issue.record("expected rename with a path separator to throw")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteInvalidFileName)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func newFolderAndCollision() throws {
        let first = try FileOperations.newFolder(in: dir, named: "Stuff")
        #expect(isDirectory(first))
        let second = try FileOperations.newFolder(in: dir, named: "Stuff")
        #expect(second.lastPathComponent == "Stuff copy")
    }

    @Test func moveToTrashRemovesFromSource() throws {
        let source = try makeFile("trash-me.txt")
        _ = try FileOperations.moveToTrash(source)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
}
