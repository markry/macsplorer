import Foundation
import Testing
import MacSplorerCore

/// Colored chips in Get Info: color parsing and text contrast.
@Suite struct InfoRowTests {
    @Test func parsesSixDigitHex() throws {
        let c = try #require(InfoChip(text: "t", color: "#c8102e").rgba)
        #expect(abs(c.red - 200.0 / 255) < 0.001)
        #expect(abs(c.green - 16.0 / 255) < 0.001)
        #expect(abs(c.blue - 46.0 / 255) < 0.001)
        #expect(c.alpha == 1)
    }

    @Test func parsesShortAndAlphaForms() throws {
        let short = try #require(InfoChip(text: "t", color: "fff").rgba)
        #expect(short.red == 1 && short.green == 1 && short.blue == 1)
        let alpha = try #require(InfoChip(text: "t", color: "#00000080").rgba)
        #expect(abs(alpha.alpha - 128.0 / 255) < 0.001)
    }

    @Test func badColorsFallBackToDefault() {
        for color in [nil, "", "#12", "#gggggg", "red", "#1234567"] {
            #expect(InfoChip(text: "t", color: color).rgba == nil)
            #expect(InfoChip(text: "t", color: color).prefersDarkText == nil)
        }
    }

    @Test func textContrastFollowsTheColor() {
        #expect(InfoChip(text: "t", color: "#ffeb3b").prefersDarkText == true)    // yellow
        #expect(InfoChip(text: "t", color: "#c8102e").prefersDarkText == false)   // dark red
        #expect(InfoChip(text: "t", color: "#1a237e").prefersDarkText == false)   // navy
    }

    /// A provider that only implements today's plain-text rows still shows them.
    @Test func plainRowsStillCome() async throws {
        let rows = try await PlainRows().detailedInfoRows(for: URL(string: "x://h/a")!)
        #expect(rows == [InfoRow(label: "Version", value: "3")])
    }
}

private struct PlainRows: FileSystemProvider {
    private let local = LocalProvider()
    var scheme: String { "x" }
    var capabilities: ProviderCapabilities { local.capabilities }
    func infoRows(for url: URL) async throws -> [(label: String, value: String)] { [("Version", "3")] }
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
