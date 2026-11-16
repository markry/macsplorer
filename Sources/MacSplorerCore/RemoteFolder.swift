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
        // Two names this disk would take for one item ("A" and "a" on a case-
        // insensitive volume) would silently leave only one: refuse up front.
        let caseSensitive = (try? destination.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? false
        let rules = NameRules(caseSensitive: caseSensitive == true, compositionSensitive: false)
        let base = URL(fileURLWithPath: "/", isDirectory: true)
        if let (a, b) = firstNameClash(listing.files.map { url($0.relative, beneath: base) },
                                       folders: listing.emptyFolders.map { folderURL($0, beneath: base) },
                                       rules: rules) {
            throw RemoteFolderError.nameClash(String(a.path.dropFirst()), String(b.path.dropFirst()))
        }
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

    /// Keep Both names for `name`, in order: "name copy", "name copy 2", … — the same
    /// form a local copy uses, with the extension kept after the suffix.
    public static func keepBothNames(for name: String, isFolder: Bool) -> [String] {
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return (1...999).map { counter in
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            return ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
        }
    }

    /// Where each file of a folder copy lands, decided for the whole set before any
    /// is written. A file whose existing destination refuses to be replaced goes
    /// beside it under a Keep Both name that is free at the destination — as a file
    /// or a folder — and that no part of the incoming tree will use: not another
    /// incoming file, not an incoming folder (`folders`, the empty ones) and not a
    /// folder any incoming file sits in. Otherwise a later write would overwrite the
    /// redirected file, or need its name as a folder.
    ///
    /// Names are compared as a forgiving destination would (`identityKey`): case,
    /// Unicode composition and percent-encoding don't distinguish them. On a strict
    /// destination that only makes the chosen name more cautious ("a copy 2"); it
    /// never makes two writes land on one item.
    public static func planDestinations(_ targets: [URL], reserving folders: [URL] = [],
                                        exists: (URL) async -> Bool) async -> [URL] {
        var taken = Set<String>()
        for target in targets {
            taken.insert(identityKey(target))
            var ancestor = target.deletingLastPathComponent()
            while !LocationIdentity.components(ancestor).isEmpty, taken.insert(identityKey(ancestor)).inserted {
                ancestor = ancestor.deletingLastPathComponent()
            }
        }
        for folder in folders {
            var ancestor = folder
            while !LocationIdentity.components(ancestor).isEmpty, taken.insert(identityKey(ancestor)).inserted {
                ancestor = ancestor.deletingLastPathComponent()
            }
        }

        var planned: [URL] = []
        for target in targets {
            guard LocationPermissions.placement(for: target) == .besideExisting,
                  await exists(target) else {
                planned.append(target)
                continue
            }
            let folder = target.deletingLastPathComponent()
            var choice: URL?
            for name in keepBothNames(for: target.lastPathComponent, isFolder: false) {
                let candidate = folder.appendingPathComponent(name, isDirectory: false)
                guard !taken.contains(identityKey(candidate)) else { continue }
                // Free at the destination both as a file and as a folder.
                if !(await exists(candidate)),
                   !(await exists(folder.appendingPathComponent(name, isDirectory: true))) {
                    choice = candidate
                    break
                }
            }
            let landed = choice ?? folder.appendingPathComponent(
                UUID().uuidString + ((target.pathExtension.isEmpty) ? "" : ".\(target.pathExtension)"))
            taken.insert(identityKey(landed))
            planned.append(landed)
        }
        return planned
    }

    /// A location's identity for collision purposes: scheme, account and decoded path,
    /// each component in canonical Unicode composition and lowercased, so `a copy`,
    /// `A copy` and `%61%20copy` are one name, and a precomposed "é" matches a
    /// decomposed one. Trailing slashes don't matter.
    public static func identityKey(_ url: URL, rules: NameRules = .forgiving) -> String {
        let parts = LocationIdentity.components(url).map { part -> String in
            var name = part
            if !rules.caseSensitive { name = name.lowercased() }
            // Swift's String equality already treats the two forms of "é" as equal, so
            // when composition matters the key is the name's bytes.
            return rules.compositionSensitive
                ? name.utf8.map { String($0, radix: 16) }.joined(separator: ".")
                : name.precomposedStringWithCanonicalMapping
        }
        return (url.scheme ?? "").lowercased() + "://" + LocationIdentity.Authority(url).display
            + "/" + parts.joined(separator: "/")
    }

    /// Two incoming items that the destination, comparing names by `rules`, would
    /// take for one: two files ("A" and "a" arriving from a case-sensitive source),
    /// or a file and a folder ("A" and "a/…"). Nil when every item lands apart.
    /// `folders` are the incoming empty folders; the folders the files sit in are
    /// worked out from `targets`.
    public static func firstNameClash(_ targets: [URL], folders: [URL] = [],
                                      rules: NameRules) -> (URL, URL)? {
        var seen: [String: (url: URL, isFolder: Bool)] = [:]
        func claim(_ url: URL, isFolder: Bool) -> (URL, URL)? {
            let key = identityKey(url, rules: rules)
            if let earlier = seen[key] {
                // The same folder reached twice is fine; anything else is one item twice.
                return (earlier.isFolder && isFolder) ? nil : (earlier.url, url)
            }
            seen[key] = (url, isFolder)
            return nil
        }
        for target in targets {
            if let clash = claim(target, isFolder: false) { return clash }
        }
        for target in targets + folders {
            var ancestor = target.hasDirectoryPath ? target : target.deletingLastPathComponent()
            while !LocationIdentity.components(ancestor).isEmpty {
                if let clash = claim(ancestor, isFolder: true) { return clash }
                ancestor = ancestor.deletingLastPathComponent()
            }
        }
        return nil
    }

    /// The folder URL `relative` names beneath `folder`: every component a folder,
    /// so it keeps the trailing slash a provider may need to tell a folder from a file.
    public static func folderURL(_ relative: String, beneath folder: URL) -> URL {
        relative.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1), isDirectory: true) }
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
    /// Two incoming items the destination would take for one.
    case nameClash(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsafeName(let name):
            return "The folder contains an item named “\(name)”, which can’t be copied safely."
        case .nameClash(let a, let b):
            return "“\(a)” and “\(b)” would be the same item at the destination, which doesn’t "
                + "tell those names apart, so one would replace the other. Nothing was copied. "
                + "Rename one of them first."
        }
    }
}

/// How a backend compares item names. Percent-encoding never distinguishes names.
public struct NameRules: Sendable, Equatable {
    /// "A" and "a" are different items.
    public var caseSensitive: Bool
    /// An accented letter written as one character and as letter-plus-accent are
    /// different items.
    public var compositionSensitive: Bool

    public init(caseSensitive: Bool, compositionSensitive: Bool) {
        self.caseSensitive = caseSensitive
        self.compositionSensitive = compositionSensitive
    }

    /// Neither distinguishes: the safe assumption for a backend that doesn't say.
    public static let forgiving = NameRules(caseSensitive: false, compositionSensitive: false)
    /// Names compared exactly, as S3 compares keys.
    public static let exact = NameRules(caseSensitive: true, compositionSensitive: true)
}
