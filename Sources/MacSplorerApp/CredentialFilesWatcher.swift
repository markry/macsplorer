import Foundation

/// Watches the configured AWS credential *locations* for content changes so the S3
/// profile list stays live: add a profile to a config/credentials file MacSplorer
/// already reads, and it notices. It watches each location folder (to catch a
/// config/credentials file being created/removed/renamed) AND the config/credentials
/// files themselves (to catch in-place edits — the common "append a profile" case).
///
/// It deliberately does NOT follow files that move: only the folders the user
/// configured are watched. A burst of events is coalesced into one `onChange`.
final class CredentialFilesWatcher {
    /// Fired (on the main queue, coalesced) when any watched file/folder changes,
    /// carrying the URLs that changed in the coalesced window.
    var onChange: (([URL]) -> Void)?

    private var folders: [URL] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var coalescing = false
    private var pendingChanges: Set<URL> = []

    /// Watch these location folders (replacing any previous set).
    func watch(folders: [URL]) {
        self.folders = folders
        rearm()
    }

    func stop() {
        sources.forEach { $0.cancel() }   // cancel handlers close the descriptors
        sources = []
    }

    deinit { stop() }

    /// (Re)establish watches for every folder + its config/credentials files that
    /// currently exist. Called on setup and after each change, since an edit may
    /// have created or atomically-replaced a file (invalidating its descriptor).
    private func rearm() {
        stop()
        var targets: [URL] = []
        for folder in folders {
            targets.append(folder)
            targets.append(folder.appendingPathComponent("config"))
            targets.append(folder.appendingPathComponent("credentials"))
        }
        for url in targets {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }   // not present yet — the folder watch will catch its creation
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .link, .revoke],
                queue: .main)
            source.setEventHandler { [weak self] in
                self?.pendingChanges.insert(url)
                self?.scheduleChange()
            }
            // Capture THIS descriptor so a later rearm can't let an old source close
            // a newer fd.
            source.setCancelHandler { close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }

    private func scheduleChange() {
        guard !coalescing else { return }
        coalescing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.coalescing = false
            let changed = self.pendingChanges
            self.pendingChanges = []
            self.rearm()          // files may have been created / replaced
            self.onChange?(Array(changed))
        }
    }
}
