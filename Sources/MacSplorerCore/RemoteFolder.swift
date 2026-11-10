import Foundation

/// Folder-level transfers built from a provider's single-file operations, so any
/// backend that can list and download files can also hand over a whole folder.
public enum RemoteFolder {
    /// What a folder holds, at any depth, as paths relative to it (`"sub/file.txt"`).
    public struct Listing {
        public var files: [(url: URL, relative: String)] = []
        /// Folders with nothing in them, which a copy must create explicitly since
        /// no file will bring them into being. `""` is the folder itself.
        public var emptyFolders: [String] = []
    }

    /// Everything beneath `folder`, hidden items included.
    ///
    /// Throws `RemoteFolderError.unsafeName` rather than return a name that could
    /// write outside the destination (`..`, or one containing a slash).
    public static func contents(of folder: URL, provider: FileSystemProvider) async throws -> Listing {
        var listing = Listing()
        var pending: [(url: URL, relative: String)] = [(folder, "")]
        while let (directory, prefix) = pending.popLast() {
            try Task.checkCancellation()
            let children = try await provider.children(of: directory, includeHidden: true)
            if children.isEmpty { listing.emptyFolders.append(prefix) }
            for item in children {
                guard isSafeComponent(item.name) else { throw RemoteFolderError.unsafeName(item.name) }
                let relative = prefix.isEmpty ? item.name : prefix + "/" + item.name
                if item.isDirectory {
                    pending.append((item.url, relative))
                } else {
                    listing.files.append((item.url, relative))
                }
            }
        }
        listing.files.sort { $0.relative < $1.relative }
        listing.emptyFolders.sort()
        return listing
    }

    /// Download the folder at `folder` to the local folder `destination`, keeping
    /// its structure. Replaces anything already at `destination`, but only once
    /// every file has arrived: the download goes to a hidden sibling first, so a
    /// failure or Stop leaves what was there untouched and nothing half-made.
    ///
    /// `onFile` is told each file's relative path just before it is fetched.
    public static func download(_ folder: URL, to destination: URL,
                                provider: FileSystemProvider,
                                onFile: @Sendable (String) async -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let listing = try await contents(of: folder, provider: provider)
        let partial = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            for relative in listing.emptyFolders {
                try fm.createDirectory(at: partial.appendingPathComponent(relative),
                                       withIntermediateDirectories: true)
            }
            for (url, relative) in listing.files {
                try Task.checkCancellation()
                await onFile(relative)
                let local = partial.appendingPathComponent(relative)
                try fm.createDirectory(at: local.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try await provider.download(url, to: local)
            }
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// The total size of every file beneath `folder`, and how many files there are —
    /// Get Info's "Total Size" for a remote folder. Walks the whole tree, so it can
    /// take a while; cancel the task to stop it.
    public static func totalSize(of folder: URL,
                                 provider: FileSystemProvider) async throws -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        var pending = [folder]
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            for item in try await provider.children(of: directory, includeHidden: true) {
                if item.isDirectory {
                    pending.append(item.url)
                } else {
                    bytes += Int64(item.byteSize ?? 0)
                    files += 1
                }
            }
        }
        return (bytes, files)
    }

    /// The URL `relative` names beneath `folder`, its last component a file.
    public static func url(_ relative: String, beneath folder: URL) -> URL {
        var url = folder
        let parts = relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(part, isDirectory: index < parts.count - 1)
        }
        return url
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}

public enum RemoteFolderError: LocalizedError {
    /// A name in the remote folder that can't be written as a local file name.
    case unsafeName(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeName(let name):
            return "The folder contains an item named “\(name)”, which can’t be copied safely."
        }
    }
}
