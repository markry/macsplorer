import Foundation

/// The canonical mapping between MacSplorer URLs and S3 coordinates — one source
/// of truth so the provider, the address bar, and the breadcrumb all agree on how
/// an `s3://` location is represented.
///
/// The synthetic hierarchy (per the design spec's converged decisions):
/// ```
///   s3:///                          → root      (lists AWS profiles from ~/.aws)
///   s3://<profile>/                 → a profile (lists its buckets, ListBuckets)
///   s3://<profile>/<bucket>/        → a bucket  (lists top-level keys/prefixes)
///   s3://<profile>/<bucket>/<p>/…   → a prefix  (ListObjectsV2, Delimiter="/")
/// ```
/// The profile is the URL host; the bucket + key live in the path. Foundation
/// round-trips all of these cleanly (verified), including the empty-host root.
public enum S3Location: Equatable {
    /// `s3:///` — lists the AWS profiles found in `~/.aws`.
    case root
    /// `s3://<profile>/` — lists the buckets that profile can see.
    case profile(String)
    /// A bucket or a prefix within it. `key` is the S3 prefix to list under, with
    /// a trailing "/" (empty string == the bucket root).
    case prefix(profile: String, bucket: String, key: String)

    public static let scheme = "s3"

    /// Parse an `s3://` URL into a location, or nil if it isn't an S3 URL.
    public static func parse(_ url: URL) -> S3Location? {
        guard url.scheme == scheme else { return nil }
        // Empty/absent host == the root that lists profiles.
        guard let profile = url.host, !profile.isEmpty else { return .root }
        let comps = url.pathComponents.filter { $0 != "/" }
        guard let bucket = comps.first else { return .profile(profile) }
        let keyParts = comps.dropFirst()
        // Rebuild the prefix with a trailing "/" so ListObjectsV2(Delimiter:"/")
        // lists the *contents* of the folder, not siblings sharing its name.
        let key = keyParts.isEmpty ? "" : keyParts.joined(separator: "/") + "/"
        return .prefix(profile: profile, bucket: bucket, key: key)
    }

    /// `s3:///` — the S3 root (lists profiles).
    public static var rootURL: URL { URL(string: "\(scheme):///")! }

    /// `s3://<profile>/` — must be built explicitly (not via `appendingPathComponent`
    /// on the root, which has an empty host and would misplace the profile).
    public static func url(profile: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = profile
        c.path = "/"
        return c.url!
    }

    /// Build the internal URL from a user-facing *real* S3 URI (`s3://bucket/key`,
    /// the form AWS tools use) plus the active profile → `s3://profile/bucket/key`.
    /// Returns nil if `uri` isn't an `s3://bucket/…` URI.
    public static func url(fromUserURI uri: String, profile: String) -> URL? {
        guard let parsed = URL(string: uri), parsed.scheme == scheme,
              let bucket = parsed.host, !bucket.isEmpty else { return nil }
        var components = [bucket]
        components += parsed.pathComponents.filter { $0 != "/" }
        var c = URLComponents()
        c.scheme = scheme
        c.host = profile
        c.path = "/" + components.joined(separator: "/")
        if uri.hasSuffix("/") && !c.path.hasSuffix("/") { c.path += "/" }
        return c.url
    }

    /// The real S3 URI (`s3://bucket/key`) for a bucket/prefix location — profile
    /// dropped, since it isn't part of an S3 URI. Nil for the root/profile levels
    /// (no bucket yet).
    public static func userURI(for url: URL) -> String? {
        guard case .prefix(_, let bucket, let key) = parse(url) else { return nil }
        return "\(scheme)://\(bucket)/\(key)"
    }

    /// A child folder URL under a bucket/prefix URL (trailing slash → folder).
    public static func childFolderURL(under parent: URL, name: String) -> URL {
        parent.appendingPathComponent(name, isDirectory: true)
    }

    /// A child file (object) URL under a bucket/prefix URL.
    public static func childFileURL(under parent: URL, name: String) -> URL {
        parent.appendingPathComponent(name, isDirectory: false)
    }
}

/// Enumerates the named AWS profiles to surface as the first S3 level, across one
/// or more credential-file *locations* (folders). Pure filesystem parsing — no SDK,
/// no network, and it never reads secret values (only the `[section]` names).
///
/// Within a location, a profile named in both `config` (`[profile X]`/`[default]`)
/// and `credentials` (`[X]`) is one profile — the same merge AWS tools do, so that
/// case is not a conflict. Across *different* locations, the same profile name is a
/// conflict (the AWS tools point at one location via env vars, but we absorb
/// several). Policy: **first location wins** — the profile is shown and resolved
/// against the earliest configured location; later duplicates are ignored (never
/// yanking a working profile). `conflicts()` reports the duplicated names so the UI
/// can warn the user, and `locations(forProfile:)` names where each appears.
public enum AWSProfiles {
    /// The credential-file folders to read, in order. The app sets this from user
    /// preferences; defaults to the standard `~/.aws`. Capped by the UI at 10.
    public static var locations: [URL] = [defaultLocation]

    /// The standard `~/.aws` folder.
    public static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws")
    }

    /// All profile names to surface (union across locations), name-sorted. A name
    /// found in several locations is shown once and resolved against the FIRST
    /// location (see `resolverPaths`); later duplicates are ignored — see `conflicts()`.
    public static func names() -> [String] {
        profileLocations().keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Profile names that appear in more than one location — the first is used, the
    /// rest ignored; surfaced to the user to resolve.
    public static func conflicts() -> [String] {
        profileLocations()
            .filter { $0.value.count > 1 }
            .keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The location folders a profile appears in, in list order (the first is the
    /// one MacSplorer uses).
    public static func locations(forProfile profile: String) -> [URL] {
        profileLocations()[profile] ?? []
    }

    /// The explicit `config` / `credentials` file paths for a profile's location, to
    /// hand the SDK's profile resolver. Always explicit (never nil) so the SDK reads
    /// exactly the user's configured files and never falls back to its own env/system
    /// defaults — MacSplorer's configured folders are the single source of truth.
    public static func resolverPaths(forProfile profile: String) -> (config: String?, credentials: String?) {
        guard let folder = profileLocations()[profile]?.first else { return (nil, nil) }
        return (folder.appendingPathComponent("config").path,
                folder.appendingPathComponent("credentials").path)
    }

    // MARK: - Reading

    /// Map of profile name → the location folders it was found in.
    private static func profileLocations() -> [String: [URL]] {
        var map: [String: [URL]] = [:]
        for folder in locations {
            for name in names(in: folder) {
                var seen = map[name] ?? []
                seen.append(folder)
                map[name] = seen
            }
        }
        return map
    }

    /// Profile names in one location (union of its `config` + `credentials`).
    private static func names(in folder: URL) -> Set<String> {
        let (configURL, credentialsURL) = files(in: folder)
        var set = Set<String>()
        for header in sectionHeaders(at: configURL) {
            if header == "default" {
                set.insert("default")
            } else if header.hasPrefix("profile ") {
                let name = header.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { set.insert(name) }
            }
        }
        for header in sectionHeaders(at: credentialsURL) where !header.isEmpty {
            set.insert(header)
        }
        return set
    }

    /// The config + credentials file URLs for a location: always the literal
    /// `<folder>/config` + `<folder>/credentials`. MacSplorer deliberately does NOT
    /// honor `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` or any inherited system
    /// default — the user's configured folders are the single source of truth, so
    /// what the dialog shows is exactly what's read.
    private static func files(in folder: URL) -> (config: URL, credentials: URL) {
        (folder.appendingPathComponent("config"),
         folder.appendingPathComponent("credentials"))
    }

    /// The `[section]` header names in an INI file, in file order.
    private static func sectionHeaders(at url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var headers: [String] = []
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]") else { continue }
            headers.append(String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
        }
        return headers
    }
}
