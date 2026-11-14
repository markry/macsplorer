import Foundation
import Testing
import MacSplorerCore

/// One volume with a read-only area inside a writable one, and a top level of fixed
/// containers: the provider answers per folder, and the app's questions follow.
@Suite struct LocationPermissionsTests {
    init() {
        Providers.register(scheme: MixedProvider.scheme) { _ in MixedProvider() }
    }

    private func url(_ path: String) -> URL { URL(string: "\(MixedProvider.scheme)://acct\(path)")! }

    @Test func aReadOnlyAreaRefusesNewItems() {
        #expect(!LocationPermissions.canAdd(into: url("/box/ro/")))
        #expect(!LocationPermissions.canAdd(into: url("/box/ro/deeper/")))
        #expect(LocationPermissions.canAdd(into: url("/box/rw/")))
    }

    @Test func itemsInAReadOnlyAreaCantBeRemovedOrRenamed() {
        #expect(!LocationPermissions.canRemove(url("/box/ro/report.pdf")))
        #expect(!LocationPermissions.canRename(url("/box/ro/report.pdf")))
        #expect(LocationPermissions.canRemove(url("/box/rw/report.pdf")))
        #expect(LocationPermissions.canRename(url("/box/rw/report.pdf")))
    }

    @Test func theReadOnlyFolderItselfFollowsItsParent() {
        // /box/ is writable, so the ro folder can be renamed or removed as a whole.
        #expect(LocationPermissions.canRemove(url("/box/ro/")))
    }

    @Test func fixedContainersAtTheTopStayPut() {
        #expect(!LocationPermissions.canAdd(into: url("/")))
        #expect(!LocationPermissions.canRemove(url("/box/")))
        #expect(!LocationPermissions.canRename(url("/box/")))
        #expect(LocationPermissions.canAdd(into: url("/box/")))
    }

    @Test func anAccountRootBelongsToItsSchemeRoot() {
        // The scheme root (which lists accounts) is read-only, so an account can't be
        // removed or renamed, however writable its own contents are.
        #expect(LocationPermissions.parent(of: URL(string: "mixedtest://acct/")!)
                == URL(string: "mixedtest:///")!)
        #expect(!LocationPermissions.canRemove(URL(string: "mixedtest://acct/")!))
        #expect(!LocationPermissions.canRename(URL(string: "mixedtest://acct/")!))
    }

    /// Even when an account's own root takes new items, the account itself is listed
    /// by the read-only scheme root, so it can't be removed, renamed or duplicated.
    @Test func aWritableAccountRootStillCantLeaveTheSchemeRoot() {
        let open = URL(string: "mixedtest://openacct/")!
        #expect(LocationPermissions.canAdd(into: open))
        #expect(!LocationPermissions.canRemove(open))
        #expect(!LocationPermissions.canRename(open))
        let parent = LocationPermissions.parent(of: open)
        #expect(parent.map(LocationPermissions.canAdd(into:)) == false)
    }

    @Test func rootsHaveNoParent() {
        #expect(LocationPermissions.parent(of: URL(string: "mixedtest:///")!) == nil)
        #expect(LocationPermissions.parent(of: URL(fileURLWithPath: "/")) == nil)
        #expect(!LocationPermissions.canRemove(URL(fileURLWithPath: "/")))
    }

    @Test func parentsOfNestedFoldersIgnoreTrailingSlashes() {
        #expect(LocationPermissions.parent(of: url("/box/ro/a/")) == url("/box/ro/"))
        #expect(LocationPermissions.parent(of: url("/box/ro/a")) == url("/box/ro/"))
    }

    @Test func writableButNotRenamableAllowsAddingButNotRenaming() {
        #expect(LocationPermissions.canAdd(into: url("/box/norename/")))
        #expect(LocationPermissions.canRemove(url("/box/norename/a.txt")))
        #expect(!LocationPermissions.canRename(url("/box/norename/a.txt")))
    }

    /// A locked file beside a free one, in a folder that allows everything.
    @Test func oneItemCanRefuseWhatItsFolderAllows() {
        let locked = url("/box/rw/locked.txt"), free = url("/box/rw/free.txt")
        #expect(!LocationPermissions.canRename(locked))
        #expect(!LocationPermissions.canRemove(locked))
        #expect(!LocationPermissions.canReplace(locked))
        #expect(LocationPermissions.canRename(free))
        #expect(LocationPermissions.canRemove(free))
        #expect(LocationPermissions.canReplace(free))
        // A selection is refused if any item refuses.
        #expect(![locked, free].allSatisfy(LocationPermissions.canRemove))
    }

    /// An item can't widen what its folder refuses: "allow everything" inside a
    /// read-only folder still allows nothing.
    @Test func anItemCantWidenItsFolder() {
        let item = url("/box/ro/generous.txt")
        #expect(!LocationPermissions.canRename(item))
        #expect(!LocationPermissions.canRemove(item))
        #expect(!LocationPermissions.canReplace(item))
    }

    /// Nil ("not known yet") falls back to the folder, so nothing is refused by mistake.
    @Test func unknownItemsFollowTheirFolder() {
        #expect(LocationPermissions.canRename(url("/box/rw/unlisted.txt")))
    }

    @Test func partialRefusals() {
        let shared = url("/box/rw/viewer-can-rename.txt")
        #expect(LocationPermissions.canRename(shared))
        #expect(!LocationPermissions.canRemove(shared))
        #expect(!LocationPermissions.canReplace(shared))
    }

    /// Merging a folder: a protected file inside the destination keeps its contents
    /// (the copy goes beside it), and a read-only subfolder stops the copy.
    @Test func mergePlacementPerFile() {
        #expect(LocationPermissions.placement(for: url("/box/rw/free.txt")) == .write)
        #expect(LocationPermissions.placement(for: url("/box/rw/new.txt")) == .write)
        #expect(LocationPermissions.placement(for: url("/box/rw/locked.txt")) == .besideExisting)
        #expect(LocationPermissions.placement(for: url("/box/ro/anything.txt")) == .refused)
        #expect(LocationPermissions.placement(for: url("/box/ro/deeper/x.txt")) == .refused)
    }

    @Test func renameInPlaceIsPerFolderToo() {
        #expect(LocationPermissions.renamesInPlace(url("/box/rw/a/")))
        #expect(!LocationPermissions.renamesInPlace(url("/box/copying/a/")))
    }

    @Test func providersWithoutPerFolderAnswersKeepTheirWholeVolumeOne() {
        let local = URL(fileURLWithPath: NSTemporaryDirectory())
        #expect(LocationPermissions.canAdd(into: local))
        #expect(LocationPermissions.canRemove(local.appendingPathComponent("x")))
    }
}

/// Root "/" holds fixed containers; inside a container, "ro/" is read-only and
/// "copying/" renames by copying.
private struct MixedProvider: FileSystemProvider {
    static let scheme = "mixedtest"
    private let local = LocalProvider()
    var scheme: String { Self.scheme }
    var capabilities: ProviderCapabilities { caps(write: true, atomic: true) }

    func capabilities(at url: URL) -> ProviderCapabilities {
        // The scheme root lists accounts and is fixed; an account's own root holds
        // fixed containers.
        if (url.host ?? "").isEmpty { return caps(write: false, atomic: true) }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.isEmpty { return caps(write: url.host == "openacct", atomic: true) }
        if parts.count >= 2 && parts[1] == "ro" { return caps(write: false, atomic: true) }
        if parts.count >= 2 && parts[1] == "copying" { return caps(write: true, atomic: false) }
        if parts.count >= 2 && parts[1] == "norename" {
            var c = caps(write: true, atomic: true)
            c.canRename = false
            return c
        }
        return capabilities
    }

    func permissions(of item: URL) -> ItemPermissions? {
        switch item.lastPathComponent {
        case "locked.txt": return ItemPermissions(canRename: false, canRemove: false, canChangeContents: false)
        case "generous.txt": return ItemPermissions()
        case "viewer-can-rename.txt": return ItemPermissions(canRemove: false, canChangeContents: false)
        default: return nil
        }
    }

    private func caps(write: Bool, atomic: Bool) -> ProviderCapabilities {
        ProviderCapabilities(canWrite: write, canRename: write, atomicRename: atomic, hasTrash: false,
                             emitsChangeEvents: false, needsDownloadToOpen: true, maxSinglePutBytes: nil)
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
