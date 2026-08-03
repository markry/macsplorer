import Foundation
import AWSS3
import AWSSDKIdentity
import MacSplorerCore

/// Read-only Amazon S3 browsing behind MacSplorer's `FileSystemProvider` seam
/// (Phase 1 of the S3 design spec). It enumerates the synthetic hierarchy
/// root → profiles → buckets → prefixes; opening/downloading and every mutation
/// are later phases and currently throw `S3Error.readOnly`.
///
/// The provider is created per navigation by `Providers.register(scheme:"s3")`,
/// so it is deliberately stateless — the S3 clients and per-bucket region lookups
/// that must persist across navigations live in the shared `S3ClientPool` actor.
/// See `S3Location` for the URL↔S3 mapping and the design spec §6–§8.
public final class S3Provider: FileSystemProvider {
    /// The factory hands us the location URL; we re-parse per call (the protocol
    /// methods each carry their own URL), so nothing is stored.
    public init(url: URL) {}

    public var scheme: String { S3Location.scheme }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            canWrite: false,          // Phase 1 is read-only browse
            canRename: false,
            atomicRename: false,      // S3 rename is emulated (copy+delete) — later phase
            hasTrash: false,          // S3 has no Trash; deletes are permanent
            emitsChangeEvents: false, // no change events → the UI offers manual Refresh
            needsDownloadToOpen: true,// opening needs a local temp copy (Phase 2)
            maxSinglePutBytes: nil)
    }

    // MARK: - Enumeration & metadata

    public func children(of directory: URL, includeHidden: Bool) async throws -> [FSItem] {
        guard let location = S3Location.parse(directory) else { return [] }
        switch location {
        case .root:
            // First level: the AWS profiles configured on this machine. Purely
            // local — no network, no credentials touched.
            return AWSProfiles.names().map { profile in
                FSItem(providerURL: S3Location.url(profile: profile),
                       name: profile, isDirectory: true, byteSize: nil,
                       modificationDate: nil, typeDescription: "AWS Profile")
            }
        case .profile(let profile):
            return try await listBuckets(profile: profile, parent: directory)
        case .prefix(let profile, let bucket, let key):
            return try await listObjects(profile: profile, bucket: bucket, key: key, parent: directory)
        }
    }

    public func metadata(for url: URL) async throws -> FSItem {
        guard let location = S3Location.parse(url) else { throw S3Error.notS3(url) }
        switch location {
        case .root:
            return FSItem(providerURL: url, name: "S3", isDirectory: true,
                          byteSize: nil, modificationDate: nil)
        case .profile(let profile):
            return FSItem(providerURL: url, name: profile, isDirectory: true,
                          byteSize: nil, modificationDate: nil, typeDescription: "AWS Profile")
        case .prefix(_, let bucket, let key):
            // A bucket or prefix node; both are directories in the UI.
            let name = key.isEmpty ? bucket
                                   : String(key.split(separator: "/").last ?? Substring(bucket))
            return FSItem(providerURL: url, name: name, isDirectory: true,
                          byteSize: nil, modificationDate: nil)
        }
    }

    public func hasChildFolders(at directory: URL, includeHidden: Bool) async -> Bool {
        // Drives the tree disclosure triangle; best-effort, failures → false.
        guard let location = S3Location.parse(directory) else { return false }
        switch location {
        case .root:    return !AWSProfiles.names().isEmpty
        case .profile: return true    // assume a profile has buckets; cheap to assume
        case .prefix(let profile, let bucket, let key):
            guard let client = try? await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
            else { return false }
            let input = ListObjectsV2Input(bucket: bucket, delimiter: "/", maxKeys: 1, prefix: key)
            guard let output = try? await client.listObjectsV2(input: input) else { return false }
            return !(output.commonPrefixes ?? []).isEmpty
        }
    }

    // MARK: - Listing helpers

    private func listBuckets(profile: String, parent: URL) async throws -> [FSItem] {
        do {
            let client = try await S3ClientPool.shared.bootstrapClient(profile: profile)
            var items: [FSItem] = []
            var token: String?
            repeat {
                let output = try await client.listBuckets(input: ListBucketsInput(continuationToken: token))
                for bucket in output.buckets ?? [] {
                    guard let name = bucket.name else { continue }
                    items.append(FSItem(
                        providerURL: S3Location.childFolderURL(under: parent, name: name),
                        name: name, isDirectory: true, byteSize: nil,
                        // Buckets have a real creation date — show it (unlike plain
                        // prefixes, which have no folder mtime and stay blank).
                        modificationDate: bucket.creationDate, typeDescription: "S3 Bucket"))
                }
                token = output.continuationToken
            } while token != nil
            return items
        } catch {
            throw Self.clarify(error, listing: "buckets for profile “\(profile)”", profile: profile)
        }
    }

    private func listObjects(profile: String, bucket: String, key: String,
                             parent: URL) async throws -> [FSItem] {
        do {
            return try await listObjectsUnwrapped(profile: profile, bucket: bucket, key: key, parent: parent)
        } catch {
            throw Self.clarify(error, listing: "“\(bucket)”", profile: profile)
        }
    }

    private func listObjectsUnwrapped(profile: String, bucket: String, key: String,
                                      parent: URL) async throws -> [FSItem] {
        let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
        var folders: [FSItem] = []
        var files: [FSItem] = []
        var token: String?
        repeat {
            let input = ListObjectsV2Input(bucket: bucket, continuationToken: token,
                                           delimiter: "/", prefix: key)
            let output = try await client.listObjectsV2(input: input)
            // CommonPrefixes are the sub-"folders".
            for common in output.commonPrefixes ?? [] {
                guard let prefix = common.prefix else { continue }
                let name = Self.lastSegment(ofPrefix: prefix, under: key)
                guard !name.isEmpty else { continue }
                folders.append(FSItem(
                    providerURL: S3Location.childFolderURL(under: parent, name: name),
                    name: name, isDirectory: true, byteSize: nil, modificationDate: nil))
            }
            // Contents are the objects directly under this prefix.
            for object in output.contents ?? [] {
                guard let objectKey = object.key, objectKey != key else { continue } // skip the folder marker
                let name = String(objectKey.dropFirst(key.count))
                // With Delimiter="/", names here never contain "/"; guard anyway.
                guard !name.isEmpty, !name.contains("/") else { continue }
                files.append(FSItem(
                    providerURL: S3Location.childFileURL(under: parent, name: name),
                    name: name, isDirectory: false, byteSize: object.size,
                    modificationDate: object.lastModified))
            }
            token = output.nextContinuationToken
        } while token != nil
        // FolderContents re-sorts (folders before files); order here is immaterial.
        return folders + files
    }

    /// The last path segment of a CommonPrefix relative to the parent key.
    /// e.g. prefix `photos/2020/`, key `photos/` → `2020`.
    private static func lastSegment(ofPrefix prefix: String, under key: String) -> String {
        var s = prefix
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasPrefix(key) { s.removeFirst(key.count) }
        return s
    }

    /// Translate a raw S3/credential failure into a clear, actionable error; pass
    /// anything else (network, etc.) through unchanged. The AWS SDK surfaces these
    /// as untyped errors, so we match on text/status rather than a Swift type.
    /// AccessDenied is a 403 (creds worked, IAM said no); a credential-resolution
    /// failure means the profile has no usable credentials at all.
    static func clarify(_ error: Error, listing what: String, profile: String) -> Error {
        if error is S3Error { return error }
        let text = "\(error)"
        if text.contains("AccessDenied") || text.contains("not authorized")
            || text.contains("HTTP status code: 403") {
            return S3Error.cannotList(what: what)
        }
        let lower = text.lowercased()
        if lower.contains("credentialidentityresolver") || lower.contains("credential") {
            return S3Error.noCredentials(profile: profile)
        }
        return error
    }

    // MARK: - Region mapping

    /// The region string for a bucket's `LocationConstraint`. A nil/empty constraint
    /// means `us-east-1`; the legacy `EU` constraint means `eu-west-1`; every other
    /// case is already the region string.
    static func regionString(from constraint: S3ClientTypes.BucketLocationConstraint?) -> String {
        guard let constraint else { return "us-east-1" }
        let raw = constraint.rawValue
        if raw.isEmpty { return "us-east-1" }
        if raw == "EU" { return "eu-west-1" }
        return raw
    }

    /// Build an `S3Client` for `profile` in `region`, resolving credentials via the
    /// SDK's named-profile provider chain (env/SSO/assume-role honored). MacSplorer
    /// stores no secrets itself.
    static func makeClient(profile: String, region: String) async throws -> S3Client {
        // Resolve against the profile's own location's files (nil → the SDK's
        // defaults for the standard ~/.aws), so a profile from a non-standard folder
        // authenticates correctly.
        let paths = AWSProfiles.resolverPaths(forProfile: profile)
        let resolver = ProfileAWSCredentialIdentityResolver(
            profileName: profile,
            configFilePath: paths.config,
            credentialsFilePath: paths.credentials)
        let config = try await S3Client.S3ClientConfiguration(
            awsCredentialIdentityResolver: resolver,
            region: region)
        return S3Client(config: config)
    }

    // MARK: - Mutations (read-only in Phase 1)

    @discardableResult public func copy(_ source: URL, into directory: URL) throws -> URL { throw S3Error.readOnly }
    @discardableResult public func move(_ source: URL, into directory: URL) throws -> URL { throw S3Error.readOnly }
    @discardableResult public func copy(_ source: URL, to destination: URL) throws -> URL { throw S3Error.readOnly }
    @discardableResult public func move(_ source: URL, to destination: URL) throws -> URL { throw S3Error.readOnly }
    @discardableResult public func rename(_ url: URL, to newName: String) throws -> URL { throw S3Error.readOnly }
    @discardableResult public func moveToTrash(_ url: URL) throws -> URL? { throw S3Error.readOnly }
    @discardableResult public func newFolder(in directory: URL, named name: String) throws -> URL { throw S3Error.readOnly }
    @discardableResult public func newFile(in directory: URL, named name: String, contents: Data) throws -> URL { throw S3Error.readOnly }
}

/// Errors surfaced by the S3 provider.
public enum S3Error: LocalizedError {
    /// A write was attempted while S3 support is still read-only (Phase 1).
    case readOnly
    /// A URL that isn't an `s3://` location reached the provider.
    case notS3(URL)
    /// The profile's credentials don't permit listing at this level.
    case cannotList(what: String)
    /// The profile has no usable credentials (empty profile, missing keys, expired
    /// SSO, or a broken role chain).
    case noCredentials(profile: String)

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return "This S3 location is read-only in this version of MacSplorer."
        case .notS3(let url):
            return "Not an S3 location: \(url.absoluteString)"
        case .cannotList(let what):
            return "Can’t list \(what): this profile’s credentials don’t allow it. "
                 + "A read-only browse needs s3:ListBucket, s3:ListAllMyBuckets, and "
                 + "s3:GetBucketLocation — or open a known bucket directly via the "
                 + "address bar (s3://profile/bucket/)."
        case .noCredentials(let profile):
            return "Profile “\(profile)” has no usable credentials. Add access keys to "
                 + "its credentials file, or configure SSO / a role — if it uses SSO you "
                 + "may just need to log in again (e.g. aws sso login --profile \(profile))."
        }
    }
}

/// Shared, process-wide cache of S3 clients and per-bucket regions. The provider
/// is recreated on every navigation, so this must outlive it. An actor because the
/// caches are touched concurrently from multiple async browse tasks.
///
/// "One `S3Client` per (profile, region)" per the spec: account-level calls
/// (ListBuckets) use a bootstrap client in `us-east-1`; object calls use a client
/// bound to the bucket's discovered region.
actor S3ClientPool {
    static let shared = S3ClientPool()

    private var clients: [String: S3Client] = [:]   // key: "profile|region"
    private var bucketRegions: [String: String] = [:] // key: "profile|bucket"

    /// A client in the bootstrap region (`us-east-1`) for account-level calls like
    /// ListBuckets, which are not region-specific.
    func bootstrapClient(profile: String) async throws -> S3Client {
        try await client(profile: profile, region: "us-east-1")
    }

    /// A cached client for (profile, region).
    func client(profile: String, region: String) async throws -> S3Client {
        let key = "\(profile)|\(region)"
        if let existing = clients[key] { return existing }
        let created = try await S3Provider.makeClient(profile: profile, region: region)
        clients[key] = created
        return created
    }

    /// A client bound to a bucket's own region (required for ListObjectsV2, which
    /// 301-redirects if you target the wrong region). Discovers + caches the region.
    func clientForBucket(profile: String, bucket: String) async throws -> S3Client {
        let region = try await regionForBucket(profile: profile, bucket: bucket)
        return try await client(profile: profile, region: region)
    }

    private func regionForBucket(profile: String, bucket: String) async throws -> String {
        let key = "\(profile)|\(bucket)"
        if let cached = bucketRegions[key] { return cached }
        let region: String
        do {
            let boot = try await bootstrapClient(profile: profile)
            let output = try await boot.getBucketLocation(input: GetBucketLocationInput(bucket: bucket))
            region = S3Provider.regionString(from: output.locationConstraint)
        } catch {
            // If GetBucketLocation is denied, fall back to the bootstrap region;
            // ListObjectsV2 will still work for us-east-1 buckets.
            region = "us-east-1"
        }
        bucketRegions[key] = region
        return region
    }
}
