import Foundation

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
        return capabilities(at: parent).canWrite
    }

    /// Whether `item` can be renamed.
    public static func canRename(_ item: URL) -> Bool {
        guard let parent = parent(of: item) else { return false }
        let caps = capabilities(at: parent)
        return caps.canWrite && caps.canRename
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

    private static func capabilities(at url: URL) -> ProviderCapabilities {
        Providers.provider(for: url).capabilities(at: url)
    }

}
