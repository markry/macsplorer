import Foundation

/// When two locations are the same place, and when one lies inside another.
///
/// A remote location is named by its scheme, its whole authority (user, host and
/// port) and its path. Comparing the host alone, or the path alone, confuses
/// accounts: `s3://work/bucket/` and `s3://personal/bucket/` share a path, and
/// `scheme://alice@server/` and `scheme://bob@server/` share a host. Local files
/// compare by their standardized path, as they always have.
public enum LocationIdentity {
    /// The parts of a URL's authority that tell accounts apart, compared exactly:
    /// for S3 the "host" is a profile name, and `Work` and `work` can be different
    /// profiles.
    public struct Authority: Hashable {
        public let user: String?
        public let host: String
        public let port: Int?

        public init(_ url: URL) {
            user = url.user.flatMap { $0.isEmpty ? nil : $0 }
            host = url.host ?? ""
            port = url.port
        }

        /// No user, host or port: a scheme root such as `scheme:///`.
        public var isEmpty: Bool { user == nil && host.isEmpty && port == nil }

        /// How the address bar and breadcrumb name it: `user@host:port`.
        public var display: String {
            var text = user.map { "\($0)@" } ?? ""
            text += host
            if let port { text += ":\(port)" }
            return text
        }
    }

    /// Whether `a` and `b` are the same location, ignoring percent-encoding
    /// differences and trailing slashes.
    public static func same(_ a: URL, _ b: URL) -> Bool {
        if isLocal(a) || isLocal(b) {
            return isLocal(a) && isLocal(b) && a.standardizedFileURL.path == b.standardizedFileURL.path
        }
        return sameScheme(a, b) && Authority(a) == Authority(b) && components(a) == components(b)
    }

    /// Whether `inner` is `outer` or lies beneath it.
    public static func isSelfOrDescendant(_ inner: URL, of outer: URL) -> Bool {
        if isLocal(inner) || isLocal(outer) {
            guard isLocal(inner) && isLocal(outer) else { return false }
            let i = inner.standardizedFileURL.path, o = outer.standardizedFileURL.path
            return i == o || i.hasPrefix(o.hasSuffix("/") ? o : o + "/")
        }
        guard sameScheme(inner, outer), Authority(inner) == Authority(outer) else { return false }
        let o = components(outer), i = components(inner)
        return i.count >= o.count && Array(i.prefix(o.count)) == o
    }

    /// Whether a mount rooted at `mount` holds `url`. A mount with no authority (a
    /// scheme root) holds every location of its scheme; one with an authority holds
    /// only that account's locations, beneath its path.
    public static func mount(_ mount: URL, contains url: URL) -> Bool {
        guard sameScheme(mount, url) else { return false }
        if Authority(mount).isEmpty && components(mount).isEmpty { return true }
        return isSelfOrDescendant(url, of: mount)
    }

    /// Of the mounts that hold `url`, the most specific: one naming the account
    /// beats a scheme root, and a deeper path beats a shallower one.
    public static func bestMount<M>(for url: URL, among mounts: [M], root: (M) -> URL) -> M? {
        mounts.filter { mount(root($0), contains: url) }.max { a, b in
            specificity(root(a)) < specificity(root(b))
        }
    }

    /// A location typed as `scheme://user@host:port/path` (path decoded, as the
    /// address bar shows it) as a URL. The user may itself contain "@" (an email
    /// address): the host starts after the last one. Nil when it doesn't parse.
    public static func parseAddress(_ entered: String) -> URL? {
        guard let separator = entered.range(of: "://") else { return nil }
        let scheme = entered[..<separator.lowerBound].lowercased()
        guard !scheme.isEmpty else { return nil }
        let rest = entered[separator.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = Substring(rest[..<slash])
        var components = URLComponents()
        components.scheme = scheme
        if let at = authority.lastIndex(of: "@") {
            components.user = String(authority[..<at])
            authority = authority[authority.index(after: at)...]
        }
        // A port follows the last ":", outside any [IPv6] brackets.
        if let colon = authority.lastIndex(of: ":"),
           !authority[colon...].contains("]"),
           let port = Int(authority[authority.index(after: colon)...]) {
            components.port = port
            authority = authority[..<colon]
        }
        components.host = String(authority)
        let path = String(rest[slash...])
        components.path = path.isEmpty ? "/" : (path.removingPercentEncoding ?? path)
        return components.url
    }

    /// The path's components, decoded, without the root "/".
    public static func components(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    private static func isLocal(_ url: URL) -> Bool { url.isFileURL || url.scheme == nil }

    private static func sameScheme(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
    }

    private static func specificity(_ url: URL) -> Int {
        (Authority(url).isEmpty ? 0 : 1_000) + components(url).count
    }
}
