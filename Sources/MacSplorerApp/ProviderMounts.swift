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

    /// The mount whose namespace contains `url`.
    static func mount(containing url: URL) -> ProviderMount? {
        Providers.mounts().first { contains($0.url, url) }
    }

    /// `/Volumes/<name>` (as typed in the address bar) → that mount.
    static func mount(forVolumesPath path: String) -> ProviderMount? {
        let trimmed = (path.count > 1 && path.hasSuffix("/")) ? String(path.dropLast()) : path
        let prefix = S3Mount.volumesURL.path + "/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let name = trimmed.dropFirst(prefix.count)
        return Providers.mounts().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Same scheme, host and (decoded) path — ignoring percent-encoding differences
    /// and trailing slashes.
    static func sameLocation(_ a: URL, _ b: URL) -> Bool {
        a.scheme == b.scheme && (a.host ?? "") == (b.host ?? "") && components(a) == components(b)
    }

    /// Whether `inner` is `outer` or lies beneath it. A host-less `outer` (a scheme
    /// root) contains every location of its scheme.
    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        guard outer.scheme == inner.scheme else { return false }
        let outerHost = outer.host ?? ""
        if outerHost.isEmpty { return true }
        guard outerHost == (inner.host ?? "") else { return false }
        let o = components(outer), i = components(inner)
        return i.count >= o.count && Array(i.prefix(o.count)) == o
    }

    private static func components(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }
}
