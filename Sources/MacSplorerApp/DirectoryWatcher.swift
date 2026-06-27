import Foundation

/// Watches a single directory for content changes (items added / removed /
/// renamed within it) using a kqueue-backed `DispatchSource` — the macOS analog
/// of Windows' `ReadDirectoryChangesW`. Fires `onChange` on the main queue,
/// coalescing rapid bursts (e.g. an unzip) into one callback.
final class DirectoryWatcher {
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var coalescing = false

    /// Start watching `url` (replacing any previous watch).
    func watch(_ url: URL) {
        stop()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .link, .revoke],
            queue: .main)
        newSource.setEventHandler { [weak self] in self?.scheduleChange() }
        // Capture THIS descriptor: cancel handlers run asynchronously, so a later
        // watch() must not let an older source close the newer fd.
        newSource.setCancelHandler { close(descriptor) }
        source = newSource
        newSource.resume()
    }

    func stop() {
        source?.cancel() // the cancel handler closes the descriptor
        source = nil
    }

    deinit { stop() }

    private func scheduleChange() {
        guard !coalescing else { return }
        coalescing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.coalescing = false
            self?.onChange?()
        }
    }
}
