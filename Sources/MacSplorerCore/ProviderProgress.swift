import Foundation

/// Shared progress + cancellation for provider work that can run long — deleting a
/// prefix that turns out to hold a hundred thousand objects, copying one to the
/// Trash file by file. The provider advances it; the UI polls `snapshot()` on a
/// timer and calls `cancel()`.
///
/// Deliberately a plain lock-guarded class rather than an actor: a provider loop
/// advances it thousands of times and the UI reads it 4×/second, so neither side
/// should have to await the other.
public final class ProviderProgress: @unchecked Sendable {
    /// What the UI draws. `total` is what a bounded peek found before the work
    /// started; `totalIsPartial` means the peek hit its limit and the real number
    /// is larger, so the UI shows "of more than 1,000" rather than a false total.
    public struct Snapshot: Sendable {
        public var items: Int
        public var bytes: Int64
        public var detail: String
        public var total: Int?
        public var totalIsPartial: Bool
    }

    private let lock = NSLock()
    private var items = 0
    private var bytes: Int64 = 0
    private var detail = ""
    private var total: Int?
    private var totalIsPartial = false
    private var cancelled = false
    private var cancelHandlers: [@Sendable () -> Void] = []

    public init() {}

    /// True once the user has pressed Stop. Provider loops check this between
    /// units of work and return early; stopping is never an error.
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let handlers = cancelHandlers
        lock.unlock()
        // Checking a flag only stops work between units; a provider paging through a
        // listing of millions of keys needs the task itself cancelled, or Stop does
        // nothing for minutes.
        for handler in handlers { handler() }
    }

    /// Run `handler` when the user stops the work — typically cancelling the Task
    /// that is doing it.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { cancelHandlers.append(handler) }
        lock.unlock()
        if alreadyCancelled { handler() }
    }

    /// Record the result of the pre-flight peek.
    public func setTotal(_ total: Int, isPartial: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.total = total
        self.totalIsPartial = isPartial
    }

    /// Count work just finished. `detail` is the name the UI shows; passing an
    /// empty string leaves the previous one in place.
    public func advance(items: Int = 1, bytes: Int64 = 0, detail: String = "") {
        lock.lock(); defer { lock.unlock() }
        self.items += items
        self.bytes += bytes
        if !detail.isEmpty { self.detail = detail }
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(items: items, bytes: bytes, detail: detail,
                        total: total, totalIsPartial: totalIsPartial)
    }
}

/// What a bounded peek found: how many items are at or under a location, and
/// whether the count is the whole truth.
///
/// The point is to tell the user what they're about to delete *without* walking the
/// whole tree first — on a remote store counting can take minutes. A provider looks
/// only as far as `limit` (for S3, one 1,000-key listing — a single round trip,
/// measured at well under a second) and says "exactly 23" or "at least 1,000".
public struct ProviderCount: Sendable {
    public var items: Int
    public var bytes: Int64
    /// The peek stopped at its limit; the real count is `items` or more.
    public var isPartial: Bool
    /// Anything else the user should know before deleting this — for a bucket, that
    /// the container itself goes too. Provider-specific, so the provider writes it.
    public var note: String?

    public init(items: Int, bytes: Int64 = 0, isPartial: Bool = false, note: String? = nil) {
        self.items = items
        self.bytes = bytes
        self.isPartial = isPartial
        self.note = note
    }
}
