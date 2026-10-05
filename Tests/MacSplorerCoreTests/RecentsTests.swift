import Foundation
import Testing
@testable import MacSplorerCore

/// Recents and the "Date Last Opened" column both rest on one attribute macOS keeps
/// on each file: `com.apple.lastuseddate#PS`, a timespec written whenever the file is
/// opened through Launch Services.
@Suite struct RecentsTests {
    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsplorer-recents-\(UUID().uuidString).txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func readsTheLastUsedDateAttribute() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // 2026-09-21 23:56:18.858 UTC, written the way Launch Services writes it.
        var spec = timespec(tv_sec: 1_790_034_978, tv_nsec: 858_000_000)
        let status = url.withUnsafeFileSystemRepresentation { path in
            withUnsafeBytes(of: &spec) { setxattr(path!, "com.apple.lastuseddate#PS", $0.baseAddress, $0.count, 0, 0) }
        }
        #expect(status == 0)

        let date = try #require(FSItem.lastUsedDate(of: url))
        #expect(abs(date.timeIntervalSince1970 - 1_790_034_978.858) < 0.001)
        #expect(FSItem(url: url).lastOpenedDate == date)
    }

    @Test func aFileNeverOpenedHasNoLastOpenedDate() throws {
        // Previously the column showed access time, which moves whenever anything
        // reads the file. A file nobody opened must show nothing.
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try Data(contentsOf: url)   // a read, not an open
        #expect(FSItem.lastUsedDate(of: url) == nil)
        #expect(FSItem(url: url).lastOpenedDate == nil)
    }

    @Test func queryAsksForRecentDocumentsOnly() {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let query = RecentsProvider.queryString(since: since)
        #expect(query.contains("kMDItemLastUsedDate >= $time.iso(2026-09-21"))
        #expect(query.contains("!= \"public.folder\""))
        #expect(query.contains("!= \"com.apple.application\""))
    }

    /// Runs the real Spotlight query. It asserts the shape of what comes back rather
    /// than a count, so it holds on a machine with little recent activity too.
    @Test func listingIsRealFilesNewestFirst() async throws {
        let items = try await RecentsProvider(url: RecentsProvider.url)
            .children(of: RecentsProvider.url, includeHidden: false)
        #expect(items.count <= RecentsProvider.limit)
        for item in items {
            #expect(item.url.isFileURL)                       // the real file, not a virtual URL
            #expect(!item.isDirectory || item.isPackage)      // documents only
            #expect(!item.name.hasPrefix("."))
        }
        let dates = items.compactMap(\.lastOpenedDate)
        #expect(dates == dates.sorted(by: >))
    }

    @Test func refusesToHoldAnything() throws {
        let provider = RecentsProvider(url: RecentsProvider.url)
        #expect(!provider.capabilities.canWrite)
        #expect(throws: RecentsError.self) {
            try provider.newFolder(in: RecentsProvider.url, named: "x")
        }
    }
}
