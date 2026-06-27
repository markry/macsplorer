import Foundation

/// Filesystem mutations behind MacSplorer's file operations. Pure of UI so it
/// can be unit-tested directly. All operations avoid clobbering: a destination
/// name that already exists gets a " copy" / " copy N" suffix rather than
/// overwriting (no destructive overwrite until we add a real replace prompt).
public enum FileOperations {

    /// Copy `source` into `directory`, returning the created URL.
    @discardableResult
    public static func copy(_ source: URL, into directory: URL) throws -> URL {
        let destination = uniqueDestination(forName: source.lastPathComponent, in: directory)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Move `source` into `directory`, returning the new URL. Moving an item
    /// into the folder it already lives in is a no-op (returns it unchanged).
    @discardableResult
    public static func move(_ source: URL, into directory: URL) throws -> URL {
        if source.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
            return source
        }
        let destination = uniqueDestination(forName: source.lastPathComponent, in: directory)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// Copy `source` to an exact destination URL (caller ensures it's free).
    @discardableResult
    public static func copy(_ source: URL, to destination: URL) throws -> URL {
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Move `source` to an exact destination URL (caller ensures it's free).
    @discardableResult
    public static func move(_ source: URL, to destination: URL) throws -> URL {
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// Rename `url` to `newName` within the same parent. Returns the new URL.
    @discardableResult
    public static func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return url }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Move `url` to the Trash. Returns the in-Trash URL when the system reports it.
    @discardableResult
    public static func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Create a new folder in `directory`, returning its URL.
    @discardableResult
    public static func newFolder(in directory: URL, named name: String = "untitled folder") throws -> URL {
        let destination = uniqueDestination(forName: name, in: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    /// A non-colliding URL for `name` in `directory`: appends " copy", " copy 2",
    /// … until the path is free, preserving the extension.
    public static func uniqueDestination(forName name: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        while true {
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            let candidateName = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            let url = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            counter += 1
        }
    }
}
