import Foundation
import MacSplorerCore

/// Keeps Recents live: a standing Spotlight query that reports whenever its results
/// change — a file opened in Finder, the Dock, any app — and tells the panes showing
/// Recents to re-list. Without it the list would only change when revisited.
///
/// It asks the index exactly the question the provider asks, so "changed" means the
/// same thing to both. Started the first time Recents is shown, and left running:
/// an idle live query costs nothing noticeable, and restarting it on every visit
/// would re-gather the whole result set each time.
final class RecentsMonitor: NSObject {
    static let shared = RecentsMonitor()

    private var query: NSMetadataQuery?
    private var pendingNotify: DispatchWorkItem?

    func start() {
        guard query == nil else { return }
        let since = Calendar.current.date(byAdding: .day, value: -RecentsProvider.windowDays, to: Date()) ?? Date()
        let live = NSMetadataQuery()
        live.predicate = NSPredicate(fromMetadataQueryString: RecentsProvider.queryString(since: since))
        live.searchScopes = [NSMetadataQueryUserHomeScope]
        // Coalesce: opening one document can change several attributes in a burst.
        live.notificationBatchingInterval = 1
        NotificationCenter.default.addObserver(self, selector: #selector(resultsChanged),
                                               name: .NSMetadataQueryDidUpdate, object: live)
        query = live
        live.start()
    }

    @objc private func resultsChanged(_ note: Notification) {
        // One refresh per burst, not one per changed item.
        pendingNotify?.cancel()
        let work = DispatchWorkItem { FolderChange.notify([RecentsProvider.url]) }
        pendingNotify = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
