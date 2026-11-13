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

    /// Whether `item` can be deleted, or moved away (cut, a moving drag).
    public static func canRemove(_ item: URL) -> Bool {
        capabilities(at: parent(of: item)).canWrite
    }

    /// Whether `item` can be renamed.
    public static func canRename(_ item: URL) -> Bool {
        let caps = capabilities(at: parent(of: item))
        return caps.canWrite && caps.canRename
    }

    /// Whether renaming `item` happens in one step, in place, rather than as a copy
    /// of everything followed by a delete.
    public static func renamesInPlace(_ item: URL) -> Bool {
        capabilities(at: parent(of: item)).atomicRename
    }

    private static func capabilities(at url: URL) -> ProviderCapabilities {
        Providers.provider(for: url).capabilities(at: url)
    }

    private static func parent(of item: URL) -> URL {
        item.deletingLastPathComponent()
    }
}
