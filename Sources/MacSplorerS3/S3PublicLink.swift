import Foundation

/// Plain, unsigned links to S3 objects — for buckets served publicly, usually
/// through a CDN such as CloudFront. Unlike `S3Presign`, nothing is signed and
/// nothing expires; the link works only if the object is public at that address.
///
/// The public address of a bucket (`https://example.com/`) is the user's to say:
/// a CloudFront distribution in front of a bucket can't be inferred reliably from
/// the bucket alone (several aliases, origin paths, other accounts), so the app
/// asks once per bucket, remembers it, and checks the link each time it's used.
public enum S3PublicLink {

    /// RFC 3986 "unreserved" characters — the only ones safe unencoded in a path
    /// segment everywhere. Everything else in a key is percent-encoded, notably
    /// space, `+` (which S3 and some CDNs read as a space), `#`, `?`, `%`, and
    /// non-ASCII letters (encoded as their UTF-8 bytes).
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encode an object key for use as a URL path, keeping its `/`s.
    public static func encodeKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }
            .joined(separator: "/")
    }

    /// The bucket's own S3 address, offered as the starting point when no public
    /// address has been set. Buckets with dots in their names (`www.example.com`)
    /// use the path-style form: in the virtual-hosted form their name becomes
    /// several DNS labels, which S3's `*.s3…` certificate doesn't cover, so
    /// browsers reject the connection.
    public static func defaultBase(bucket: String, region: String) -> String {
        if bucket.contains(".") {
            return "https://s3.\(region).amazonaws.com/\(bucket)/"
        }
        return "https://\(bucket).s3.\(region).amazonaws.com/"
    }

    /// Validate and tidy a user-entered public address: trimmed, `http`/`https`
    /// with a host, no query or fragment, ending in exactly one `/`. Nil if it
    /// isn't usable.
    public static func normalizedBase(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = comps.host, !host.isEmpty,
              comps.query == nil, comps.fragment == nil else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s + "/"
    }

    /// The public link for `key` under a (normalized) base address.
    public static func link(base: String, key: String) -> URL? {
        URL(string: base + encodeKey(key))
    }

    /// The bucket's region, as the rest of the S3 provider resolves it (cached).
    public static func region(profile: String, bucket: String) async -> String {
        (try? await S3ClientPool.shared.regionForBucket(profile: profile, bucket: bucket)) ?? "us-east-1"
    }
}
