import XCTest
import MacSplorerCore

final class FileOperationsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsplorer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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

    func testCopyCreatesFileAndKeepsOriginal() throws {
        let source = try makeFile("a.txt")
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let dest = try FileOperations.copy(source, into: sub)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(dest.lastPathComponent, "a.txt")
    }

    func testCopyCollisionGetsCopySuffix() throws {
        let source = try makeFile("a.txt")
        XCTAssertEqual(try FileOperations.copy(source, into: dir).lastPathComponent, "a copy.txt")
        XCTAssertEqual(try FileOperations.copy(source, into: dir).lastPathComponent, "a copy 2.txt")
    }

    func testMoveRemovesSource() throws {
        let source = try makeFile("m.txt")
        let sub = dir.appendingPathComponent("sub2")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let dest = try FileOperations.move(source, into: sub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testMoveIntoSameDirectoryIsNoop() throws {
        let source = try makeFile("same.txt")
        XCTAssertEqual(try FileOperations.move(source, into: dir), source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testRename() throws {
        let source = try makeFile("old.txt")
        let dest = try FileOperations.rename(source, to: "new.txt")
        XCTAssertEqual(dest.lastPathComponent, "new.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testRenameEmptyOrUnchangedIsNoop() throws {
        let source = try makeFile("keep.txt")
        XCTAssertEqual(try FileOperations.rename(source, to: "   "), source)
        XCTAssertEqual(try FileOperations.rename(source, to: "keep.txt"), source)
    }

    func testNewFolderAndCollision() throws {
        let first = try FileOperations.newFolder(in: dir, named: "Stuff")
        XCTAssertTrue(isDirectory(first))
        let second = try FileOperations.newFolder(in: dir, named: "Stuff")
        XCTAssertEqual(second.lastPathComponent, "Stuff copy")
    }

    func testMoveToTrashRemovesFromSource() throws {
        let source = try makeFile("trash-me.txt")
        _ = try FileOperations.moveToTrash(source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
}
