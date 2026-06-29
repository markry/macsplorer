import Foundation

/// One folder in a size-scan result: its own loose-file bytes plus the recursive
/// total of everything beneath it. A reference type so the tree can be built
/// concurrently (each node mutated only by its own scan task) then summed.
public final class SizeNode {
    public let url: URL
    public let name: String
    /// Size-on-disk of files directly in this folder (not subfolders).
    public internal(set) var ownSize: Int64 = 0
    /// Files directly in this folder.
    public internal(set) var fileCount: Int = 0
    /// `ownSize` + every descendant's size — filled in after the walk.
    public internal(set) var totalSize: Int64 = 0
    public internal(set) var children: [SizeNode] = []

    init(url: URL) {
        self.url = url
        let last = url.lastPathComponent
        self.name = last.isEmpty ? url.path : last
    }
}

/// A snapshot of an in-flight scan, polled by the UI for the status bar.
public struct ScanProgress {
    public let files: Int
    public let bytes: Int64
    public let currentPath: String
}

/// Walks a folder tree off the main thread, in parallel at low priority, totalling
/// each folder's size-on-disk. Reports progress, supports cancellation. One scan
/// per instance.
public final class FolderSizeScanner {
    public init() {}

    private let lock = NSLock()
    private var _files = 0
    private var _bytes: Int64 = 0
    private var _currentPath = ""
    private var _cancelled = false
    /// When set, the walk won't descend into cloud (File Provider) mounts — set
    /// only when the scan root is itself outside such a location.
    private var skipCloud = false

    /// Cloud / File-Provider locations whose contents are virtual placeholders
    /// (Google Drive, OneDrive, Dropbox, iCloud Drive, …).
    public static func isCloudLocation(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/Library/CloudStorage") || path.contains("/Library/Mobile Documents")
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    public func progress() -> ScanProgress {
        lock.lock(); defer { lock.unlock() }
        return ScanProgress(files: _files, bytes: _bytes, currentPath: _currentPath)
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    /// Walk `root` in the background. `completion` runs on the main thread with the
    /// root node (totals filled, children sorted largest-first), or nil if cancelled.
    /// With `skipCloudLocations`, cloud mounts encountered during the walk are
    /// skipped — unless the root itself is inside one (then you asked for it).
    public func scan(root: URL, skipCloudLocations: Bool, completion: @escaping (SizeNode?) -> Void) {
        skipCloud = skipCloudLocations && !Self.isCloudLocation(root)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        queue.qualityOfService = .utility

        let rootNode = SizeNode(url: root)
        let group = DispatchGroup()
        scanDirectory(rootNode, queue: queue, group: group)

        group.notify(queue: DispatchQueue.global(qos: .utility)) { [weak self] in
            guard let self else { return }
            if self.isCancelled {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.computeTotals(rootNode)
            DispatchQueue.main.async { completion(rootNode) }
        }
    }

    private func scanDirectory(_ node: SizeNode, queue: OperationQueue, group: DispatchGroup) {
        group.enter()
        // `queue` is captured strongly by the operations (the only thing keeping it
        // alive after scan() returns); the queue drops finished ops, so it frees
        // once the walk completes.
        let operation = BlockOperation { [weak self] in
            defer { group.leave() }
            guard let self, !self.isCancelled else { return }

            self.lock.lock(); self._currentPath = node.url.path; self.lock.unlock()

            // List the resolved directory (so symlinked roots like ~/OneDrive read),
            // but keep child URLs based on the friendly path for later navigation.
            let listingURL = node.url.resolvingSymlinksInPath()
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: listingURL, includingPropertiesForKeys: Self.keys, options: [])) ?? []

            var ownSize: Int64 = 0
            var fileCount = 0
            for entry in entries {
                if self.isCancelled { break }
                let values = try? entry.resourceValues(forKeys: Set(Self.keys))
                // Don't follow symlinks/aliases — avoids cycles and double counting.
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    let childURL = node.url.appendingPathComponent(entry.lastPathComponent)
                    // Don't wander into cloud mounts (virtual placeholders / slow
                    // enumeration / duplicate views) unless the user rooted here.
                    if self.skipCloud && Self.isCloudLocation(childURL) { continue }
                    // Real directories *and* packages (.app, …) are walked, so a
                    // bundle's real size is counted (its inode size alone is tiny).
                    let child = SizeNode(url: childURL)
                    node.children.append(child)
                    self.scanDirectory(child, queue: queue, group: group)
                } else {
                    ownSize += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                    fileCount += 1
                }
            }

            node.ownSize = ownSize
            node.fileCount = fileCount
            self.lock.lock()
            self._files += fileCount
            self._bytes += ownSize
            self.lock.unlock()
        }
        operation.qualityOfService = .utility
        queue.addOperation(operation)
    }

    /// Post-order sum (cheap, single-threaded) + sort each level largest-first.
    @discardableResult
    private func computeTotals(_ node: SizeNode) -> Int64 {
        var total = node.ownSize
        for child in node.children { total += computeTotals(child) }
        node.totalSize = total
        node.children.sort { $0.totalSize > $1.totalSize }
        return total
    }
}
