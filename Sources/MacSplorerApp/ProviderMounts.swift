import Foundation
import MacSplorerCore

/// Surfaces provider-contributed mounts (`Providers.registerMounts`) as folders
/// under /Volumes, beside mounted disks and connected S3 profiles — and answers the
/// URL questions the address bar, breadcrumb and tree need about them.
enum ProviderMounts {
    /// Folder items for every current mount, for the /Volumes listing.
    static func items() -> [FSItem] {
        Providers.mounts().map(item(for:))
    }

    static func item(for mount: ProviderMount) -> FSItem {
        FSItem(providerURL: mount.url, name: mount.name, isDirectory: true, byteSize: nil,
               modificationDate: nil, typeDescription: mount.typeDescription)
    }

    /// The mount whose root is exactly `url`.
    static func mount(rootedAt url: URL) -> ProviderMount? {
        Providers.mounts().first { sameLocation($0.url, url) }
    }

    /// The mount whose namespace contains `url` — the most specific one when several
    /// do (an account's own mount over its scheme's root).
    static func mount(containing url: URL) -> ProviderMount? {
        LocationIdentity.bestMount(for: url, among: Providers.mounts()) { $0.url }
    }

    /// `/Volumes/<name>` (as typed in the address bar) → that mount.
    static func mount(forVolumesPath path: String) -> ProviderMount? {
        let trimmed = (path.count > 1 && path.hasSuffix("/")) ? String(path.dropLast()) : path
        let prefix = S3Mount.volumesURL.path + "/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let name = trimmed.dropFirst(prefix.count)
        return Providers.mounts().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Same scheme, account (user, host and port) and (decoded) path — ignoring
    /// percent-encoding differences and trailing slashes.
    static func sameLocation(_ a: URL, _ b: URL) -> Bool {
        LocationIdentity.same(a, b)
    }

    /// Whether `inner` is `outer` or lies beneath it, in the same account. A scheme
    /// root (no user, host or port) contains every location of its scheme.
    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        LocationIdentity.mount(outer, contains: inner)
    }
}
