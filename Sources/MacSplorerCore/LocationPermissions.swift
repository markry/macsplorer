import Foundation

/// An item's own refusals (`FileSystemProvider.permissions(of:)`). Each one only
/// narrows what the item's folder allows; true leaves the folder's answer standing.
public struct ItemPermissions: Sendable, Equatable {
    public var canRename: Bool
    public var canRemove: Bool
    /// Whether the item's contents may be replaced (Replace in a collision).
    public var canChangeContents: Bool

    public init(canRename: Bool = true, canRemove: Bool = true, canChangeContents: Bool = true) {
        self.canRename = canRename
        self.canRemove = canRemove
        self.canChangeContents = canChangeContents
    }
}

/// What may be done at a location, asked of the provider that serves it
/// (`FileSystemProvider.capabilities(at:)`). Adding is a question about the
/// destination folder; renaming, deleting and moving an item away are questions
/// about the folder the item is in.
public enum LocationPermissions {
    /// Whether items can be put into `folder`: paste, drop, New Folder, New File.
    public static func canAdd(into folder: URL) -> Bool {
        capabilities(at: folder).canWrite
    }

    /// Whether `item` can be deleted, or moved away (cut, a moving drag). A root has
    /// no folder to leave, so it can't.
    public static func canRemove(_ item: URL) -> Bool {
        guard let parent = parent(of: item) else { return false }
        return capabilities(at: parent).canWrite && itemPermissions(item)?.canRemove != false
    }

    /// Whether `item` can be renamed.
    public static func canRename(_ item: URL) -> Bool {
        guard let parent = parent(of: item) else { return false }
        let caps = capabilities(at: parent)
        return caps.canWrite && caps.canRename && itemPermissions(item)?.canRename != false
    }

    /// Whether the existing `item` may be replaced by a copy arriving with the same
    /// name (Replace in a collision). Its folder must take items, and the item itself
    /// must not refuse.
    public static func canReplace(_ item: URL) -> Bool {
        guard let parent = parent(of: item) else { return false }
        return capabilities(at: parent).canWrite && itemPermissions(item)?.canChangeContents != false
    }

    /// Whether renaming `item` happens in one step, in place, rather than as a copy
    /// of everything followed by a delete.
    public static func renamesInPlace(_ item: URL) -> Bool {
        guard let parent = parent(of: item) else { return false }
        return capabilities(at: parent).atomicRename
    }

    /// The folder `item` is in. Removing a path component can't cross an account
    /// boundary — `scheme://account/` would become `scheme://account/../` — so an
    /// account's root belongs to its scheme's root (`scheme:///`), the level that
    /// lists the accounts. A scheme root, and the local "/", have no parent.
    public static func parent(of item: URL) -> URL? {
        guard LocationIdentity.components(item).isEmpty else { return item.deletingLastPathComponent() }
        if item.isFileURL || item.scheme == nil { return nil }
        guard !LocationIdentity.Authority(item).isEmpty, let scheme = item.scheme else { return nil }
        return URL(string: "\(scheme):///")
    }

    /// How one file of a folder being copied or merged may land at `target`.
    public enum Placement: Equatable {
        /// Write it there, replacing anything already there.
        case write
        /// If something is already there, it refuses to be replaced: put the copy
        /// beside it under a new name, as Keep Both does.
        case besideExisting
        /// The folder it would land in takes no new items.
        case refused
    }

    /// The placement for a file arriving at `target` during a folder copy or merge.
    /// Ask for every file before writing any, so a refusal can stop the whole copy
    /// with nothing changed.
    public static func placement(for target: URL) -> Placement {
        guard let folder = parent(of: target), canAdd(into: folder) else { return .refused }
        return canReplace(target) ? .write : .besideExisting
    }

    private static func itemPermissions(_ item: URL) -> ItemPermissions? {
        Providers.provider(for: item).permissions(of: item)
    }

    private static func capabilities(at url: URL) -> ProviderCapabilities {
        Providers.provider(for: url).capabilities(at: url)
    }

}
