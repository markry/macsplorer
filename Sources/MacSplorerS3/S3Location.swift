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
    /// A bucket, a prefix within it, or an object. `key` ends with "/" when the URL
    /// names a folder and not when it names an object (empty string == the bucket
    /// root). Code that lists should normalize with `S3Provider.folderKey`.
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
        // A folder URL (trailing slash) keeps its trailing "/"; an object URL does not.
        // Appending the slash unconditionally turned `report.pdf` into `report.pdf/`,
        // which every object operation rightly rejects. Listing code adds the slash
        // where folder semantics need it (`S3Provider.folderKey`).
        let joined = keyParts.joined(separator: "/")
        let key = keyParts.isEmpty ? "" : (url.hasDirectoryPath ? joined + "/" : joined)
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
/// no network, and it never reads secret values: only `[section]` names and the
/// names of the settings under them.
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
    /// hand the SDK's profile resolver — or nil when no configured folder defines the
    /// profile.
    ///
    /// Nil must mean "refuse", never "let the SDK decide". Handing the resolver no
    /// paths switches on its own fallbacks (`~/.aws`, the `AWS_*` environment
    /// variables), so a profile removed from MacSplorer's settings — or a stale
    /// favorite naming one — could still sign in with a same-named profile from some
    /// other account. The configured folders are the only source of credentials.
    public static func resolverPaths(forProfile profile: String) -> (config: String, credentials: String)? {
        guard let folder = profileLocations()[profile]?.first else { return nil }
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

    /// Settings that give a profile a way to sign in. A `config` section with none of
    /// these — just a region or an output format, as `aws configure` routinely writes
    /// for `[default]` — has nothing to authenticate with, so listing it would only
    /// produce a volume that can never open.
    private static let signInKeys: Set<String> = [
        "aws_access_key_id",        // inline keys
        "credential_process",       // an external credential helper
        "sso_session", "sso_start_url", "sso_account_id",   // IAM Identity Center
        "role_arn",                 // an assumed role (with a source profile or credential source)
        "web_identity_token_file",  // web identity federation
        "login_session",            // `aws login`
    ]

    /// Profile names in one location (union of its `config` + `credentials`).
    ///
    /// A `credentials` section is listed as it is — holding credentials is what that
    /// file is for. A `config`-only profile is listed only when it has some way to
    /// sign in (`signInKeys`); a profile whose keys live in `credentials` is already
    /// covered by the first rule. Configured-but-expired sessions still count: they
    /// have a sign-in method, and saying so is more useful than hiding them.
    private static func names(in folder: URL) -> Set<String> {
        let (configURL, credentialsURL) = files(in: folder)
        var set = Set<String>()
        for section in sections(at: configURL) {
            let name: String
            if section.name == "default" {
                name = "default"
            } else if section.name.hasPrefix("profile ") {
                name = section.name.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }
            if !name.isEmpty, !section.keys.isDisjoint(with: signInKeys) { set.insert(name) }
        }
        for section in sections(at: credentialsURL) where !section.name.isEmpty {
            set.insert(section.name)
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

    /// The `[section]` names in an INI file, in file order, each with the *names* of
    /// the settings under it (lowercased).
    ///
    /// Setting values are never read: everything right of `=` is discarded unseen, so
    /// secret keys in a credentials file never enter memory here.
    private static func sections(at url: URL) -> [(name: String, keys: Set<String>)] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [(name: String, keys: Set<String>)] = []
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                result.append((name, []))
            } else if let equals = line.firstIndex(of: "="), !result.isEmpty {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                if !key.isEmpty { result[result.count - 1].keys.insert(key) }
            }
        }
        return result
    }
}
