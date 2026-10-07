import Foundation
import UniformTypeIdentifiers
import AWSS3
import AWSSDKIdentity
import SmithyStreams
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
            canWrite: true,           // upload and delete; rename/copy-in-place are not
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
            return try await listObjects(profile: profile, bucket: bucket, key: Self.folderKey(key),
                                         parent: directory)
        }
    }

    /// The listing prefix for a folder: its key with a trailing "/", so
    /// ListObjectsV2(Delimiter: "/") lists the folder's contents rather than siblings
    /// that merely share its name. Applied where folder semantics are wanted, not
    /// when parsing, so an object's own key is never altered.
    static func folderKey(_ key: String) -> String {
        key.isEmpty || key.hasSuffix("/") ? key : key + "/"
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
            let input = ListObjectsV2Input(bucket: bucket, delimiter: "/", maxKeys: 1,
                                           prefix: Self.folderKey(key))
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
            // A bucket can hold millions of keys at one level, so a listing is itself
            // long-running work: without this check, Stop can't interrupt a copy or a
            // delete that is still paging.
            try Task.checkCancellation()
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
        if isAccessDenied(error) {
            return S3Error.cannotList(what: what)
        }
        let lower = text.lowercased()
        if lower.contains("credentialidentityresolver") || lower.contains("credential") {
            return S3Error.noCredentials(profile: profile)
        }
        return error
    }

    /// IAM said no. The AWS SDK surfaces these as untyped errors, so we match on
    /// text/status rather than a Swift type.
    static func isAccessDenied(_ error: Error) -> Bool {
        let text = "\(error)"
        return text.contains("AccessDenied") || text.contains("not authorized")
            || text.contains("HTTP status code: 403")
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
    static func makeClient(profile: String, region: String,
                           paths: (config: String, credentials: String)) async throws -> S3Client {
        // Always the profile's own configured files — never the SDK's defaults, which
        // could sign in with a same-named profile from outside MacSplorer's settings.
        let resolver = ProfileAWSCredentialIdentityResolver(
            profileName: profile,
            configFilePath: paths.config,
            credentialsFilePath: paths.credentials)
        let config = try await S3Client.S3ClientConfiguration(
            awsCredentialIdentityResolver: resolver,
            region: region)
        // Keep a key's trailing "/" (folder markers) — the SDK drops it otherwise.
        config.addInterceptorProvider(TrailingSlashKeyInterceptorProvider())
        return S3Client(config: config)
    }

    // MARK: - Content

    /// Fetch an object's bytes to `destination`, so it can be opened, previewed, or
    /// dragged out to the Finder.
    ///
    /// Streamed in chunks to a temporary file: an object can be far larger than
    /// memory, and nothing should touch `destination` until the whole download has
    /// arrived — a failure part-way through must not damage a file already there.
    public func download(_ url: URL, to destination: URL) async throws {
        guard case .prefix(let profile, let bucket, let key) = S3Location.parse(url),
              !key.isEmpty, !key.hasSuffix("/") else { throw S3Error.notS3(url) }
        let name = url.lastPathComponent

        let output: GetObjectOutput
        do {
            let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
            output = try await client.getObject(input: GetObjectInput(bucket: bucket, key: key))
        } catch {
            throw Self.clarify(error, listing: "“\(name)”", profile: profile)
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsplorer-s3-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temporary) else {
            throw S3Error.downloadFailed(name: name)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        var written = 0
        do {
            switch output.body {
            case .data(let data):
                if let data {
                    try handle.write(contentsOf: data)
                    written = data.count
                }
            case .stream(let stream):
                while let chunk = try await stream.readAsync(upToCount: 1 << 20), !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                    written += chunk.count
                }
            default:
                break
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // S3 offers no content hash worth checking — an ETag is an MD5 only for
        // single-part uploads — so the honest integrity check is the byte count.
        if let expected = output.contentLength, expected != written {
            throw S3Error.downloadTruncated(name: name, expected: expected, received: written)
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// S3's limit for a single PUT; anything larger needs a multipart upload.
    private static let maxSinglePutBytes = 5 * 1024 * 1024 * 1024

    /// Upload a local file as the object at `destination`, streamed from disk rather
    /// than read into memory.
    ///
    /// S3 replaces an existing object atomically — readers see the old object or the
    /// new one, never a partial write — so replacing needs no staging here, and a
    /// failed upload leaves whatever was there untouched.
    public func upload(_ file: URL, to destination: URL) async throws {
        guard case .prefix(let profile, let bucket, let key) = S3Location.parse(destination),
              !key.isEmpty, !key.hasSuffix("/") else { throw S3Error.notS3(destination) }
        let name = destination.lastPathComponent
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, size > Self.maxSinglePutBytes { throw S3Error.uploadTooLarge(name: name) }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let contentType = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType

        do {
            let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
            _ = try await client.putObject(input: PutObjectInput(
                body: .stream(FileStream(fileHandle: handle)),
                bucket: bucket,
                contentLength: size,
                contentType: contentType,
                key: key))
        } catch {
            if error is S3Error { throw error }
            if Self.isAccessDenied(error) {
                throw S3Error.writeDenied(name: name, profile: profile)
            }
            throw Self.clarify(error, listing: "“\(name)”", profile: profile)
        }
    }

    public func exists(_ url: URL) async -> Bool {
        guard case .prefix(let profile, let bucket, let key) = S3Location.parse(url), !key.isEmpty,
              let client = try? await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
        else { return false }
        if key.hasSuffix("/") {
            // S3 has no folders, only keys sharing a prefix: a "folder" exists when
            // anything is stored beneath it.
            let output = try? await client.listObjectsV2(
                input: ListObjectsV2Input(bucket: bucket, maxKeys: 1, prefix: key))
            return !(output?.contents ?? []).isEmpty
        }
        return (try? await client.headObject(input: HeadObjectInput(bucket: bucket, key: key))) != nil
    }

    /// Create a bucket (at profile level) or a folder marker (inside one).
    ///
    /// S3 has no folders, only keys that share a prefix, so a new empty folder is a
    /// zero-byte object whose key ends in "/" — the same convention the AWS console
    /// uses, and the only way a folder with nothing in it can be seen at all.
    ///
    /// A bucket is a different animal: globally-named, region-bound, and created with
    /// a different call. `region` picks where it lives; S3 requires no location
    /// constraint for us-east-1 and one everywhere else.
    public func createBucket(profile: String, name: String, region: String) async throws -> URL {
        try Self.validateBucketName(name)
        let client = try await S3ClientPool.shared.client(profile: profile, region: region)
        do {
            let constraint: S3ClientTypes.CreateBucketConfiguration? = region == "us-east-1"
                ? nil
                : S3ClientTypes.CreateBucketConfiguration(
                    locationConstraint: S3ClientTypes.BucketLocationConstraint(rawValue: region))
            _ = try await client.createBucket(input: CreateBucketInput(
                bucket: name, createBucketConfiguration: constraint))
        } catch {
            if Self.isAccessDenied(error) {
                throw S3Error.writeDenied(name: name, profile: profile)
            }
            let text = "\(error)"
            if text.contains("BucketAlreadyExists") {
                throw S3Error.bucketNameTaken(name: name)
            }
            if text.contains("BucketAlreadyOwnedByYou") {
                throw S3Error.bucketExists(name: name)
            }
            throw Self.clarify(error, listing: "\u{201C}\(name)\u{201D}", profile: profile)
        }
        return S3Location.childFolderURL(under: S3Location.url(profile: profile), name: name)
    }

    public func createFolder(in directory: URL, named name: String) async throws -> URL {
        switch S3Location.parse(directory) {
        case .profile(let profile):
            // Region is chosen in the New Bucket dialog; this path is the fallback for
            // anything that creates without asking.
            return try await createBucket(profile: profile, name: name, region: "us-east-1")
        case .prefix(let profile, let bucket, let key):
            guard !name.contains("/") else { throw S3Error.invalidFolderName(name: name) }
            let markerKey = Self.folderKey(key) + name + "/"
            let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
            do {
                _ = try await client.putObject(input: PutObjectInput(
                    body: .data(Data()), bucket: bucket, key: markerKey))
            } catch {
                if Self.isAccessDenied(error) {
                    throw S3Error.writeDenied(name: name, profile: profile)
                }
                throw Self.clarify(error, listing: "\u{201C}\(name)\u{201D}", profile: profile)
            }
            return S3Location.childFolderURL(under: directory, name: name)
        case .root, .none:
            throw S3Error.notS3(directory)
        }
    }

    /// The subset of S3's bucket-naming rules worth checking before a round trip, so
    /// a bad name is refused with a readable reason rather than an XML error.
    public static func validateBucketName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        let reason: String?
        if name.count < 3 || name.count > 63 {
            reason = "a bucket name must be 3 to 63 characters long"
        } else if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            reason = "a bucket name can only use lowercase letters, numbers, dots and hyphens"
        } else if !(name.first?.isLetter == true || name.first?.isNumber == true)
                    || !(name.last?.isLetter == true || name.last?.isNumber == true) {
            reason = "a bucket name must start and end with a letter or number"
        } else if name.contains("..") {
            reason = "a bucket name can\u{2019}t contain two dots in a row"
        } else if name.hasPrefix("xn--") || name.hasSuffix("-s3alias") {
            reason = "that prefix or suffix is reserved by AWS"
        } else {
            reason = nil
        }
        if let reason { throw S3Error.invalidBucketName(name: name, reason: reason) }
    }

    /// The profile/bucket/key of something that can actually be deleted, or a
    /// refusal saying why not. A profile is the one level that isn't stored data —
    /// it's a credential setting on this Mac — and it's reached by the same Move to
    /// Trash gesture, so it needs a straight answer rather than a failure once the
    /// user has already chosen how to delete.
    static func deletable(_ url: URL) throws -> (profile: String, bucket: String, key: String) {
        switch S3Location.parse(url) {
        case .prefix(let profile, let bucket, let key):
            // An empty key means the bucket itself: deleting it means emptying it
            // first, which is the one delete that removes a container too.
            return (profile, bucket, key)
        case .profile(let profile):
            throw S3Error.cannotDelete(
                name: profile,
                reason: "a profile is a credential setting on this Mac, not something stored in S3. "
                      + "Remove it with Connect to External Files instead.")
        case .root, .none:
            throw S3Error.notS3(url)
        }
    }

    /// One listing request — 1,000 keys, a single round trip — is enough to tell the
    /// user either the exact number of objects they're about to delete or that there
    /// are more than a page of them. Counting a large prefix in full can take many
    /// minutes, and nobody should wait for that before a confirmation appears.
    public func peekCount(at url: URL, limit: Int) async throws -> ProviderCount {
        let (profile, bucket, key) = try Self.deletable(url)
        let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
        guard key.isEmpty || key.hasSuffix("/") else {
            let head = try? await client.headObject(input: HeadObjectInput(bucket: bucket, key: key))
            return ProviderCount(items: 1, bytes: Int64(head?.contentLength ?? 0))
        }
        do {
            // No delimiter: everything beneath the prefix, at every depth, is what a
            // delete would remove.
            let output = try await client.listObjectsV2(
                input: ListObjectsV2Input(bucket: bucket, maxKeys: min(limit, 1000), prefix: key))
            let objects = output.contents ?? []
            let bytes = objects.reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
            return ProviderCount(items: objects.count, bytes: bytes,
                                 isPartial: output.isTruncated ?? false,
                                 note: key.isEmpty
                                     ? "The bucket \u{201C}\(bucket)\u{201D} itself will be removed too, "
                                       + "once it is empty."
                                     : nil)
        } catch {
            throw Self.clarify(error, listing: "“\(url.lastPathComponent)”", profile: profile)
        }
    }

    /// Delete an object, or everything beneath a prefix.
    ///
    /// Listing and deleting alternate a page at a time, both capped at 1,000 keys, so
    /// the page just listed is the page deleted next — the peek that fed the
    /// confirmation dialog is the first unit of real work, not a survey pass. Stop
    /// takes effect between pages: what is already deleted stays deleted, and the
    /// rest is untouched.
    ///
    /// On a versioned bucket this deletes the current version, which is what the
    /// console's Delete does; earlier versions remain until a lifecycle rule or an
    /// explicit version delete removes them.
    public func deletePermanently(_ url: URL, progress: ProviderProgress?) async throws {
        let (profile, bucket, key) = try Self.deletable(url)
        let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
        let name = url.lastPathComponent
        do {
            guard key.isEmpty || key.hasSuffix("/") else {
                _ = try await client.deleteObject(input: DeleteObjectInput(bucket: bucket, key: key))
                progress?.advance(detail: name)
                return
            }
            var token: String?
            repeat {
                if progress?.isCancelled == true { return }
                try Task.checkCancellation()
                let output = try await client.listObjectsV2(
                    input: ListObjectsV2Input(bucket: bucket, continuationToken: token,
                                              maxKeys: 1000, prefix: key))
                let objects = output.contents ?? []
                if objects.isEmpty { return }
                if progress?.isCancelled == true { return }
                let identifiers = objects.compactMap { object in
                    object.key.map { S3ClientTypes.ObjectIdentifier(key: $0) }
                }
                let result = try await client.deleteObjects(input: DeleteObjectsInput(
                    bucket: bucket,
                    delete: S3ClientTypes.Delete(objects: identifiers, quiet: true)))
                if let failure = result.errors?.first {
                    throw S3Error.deleteDenied(name: failure.key ?? name, profile: profile)
                }
                let bytes = objects.reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
                progress?.advance(items: objects.count, bytes: bytes,
                                  detail: objects.last?.key.map {
                                      ($0 as NSString).lastPathComponent
                                  } ?? name)
                token = output.nextContinuationToken
            } while token != nil
            // Emptying a bucket is the precondition for removing it, so the bucket
            // goes last and only if nothing was left behind by a Stop.
            if key.isEmpty, progress?.isCancelled != true {
                _ = try await client.deleteBucket(input: DeleteBucketInput(bucket: bucket))
                progress?.advance(items: 0, detail: bucket)
            }
        } catch let error as S3Error {
            throw error
        } catch {
            if Self.isAccessDenied(error) {
                throw S3Error.deleteDenied(name: name, profile: profile)
            }
            throw Self.clarify(error, listing: "“\(name)”", profile: profile)
        }
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
    /// A local file couldn't be opened to receive the download.
    case downloadFailed(name: String)
    /// Fewer bytes arrived than S3 said the object holds.
    case downloadTruncated(name: String, expected: Int, received: Int)
    /// A file larger than a single S3 upload can carry.
    case uploadTooLarge(name: String)
    /// The profile's credentials don't allow writing here.
    case writeDenied(name: String, profile: String)
    /// The profile's credentials don't allow deleting this.
    case deleteDenied(name: String, profile: String)
    /// This isn't a thing MacSplorer deletes (a profile).
    case cannotDelete(name: String, reason: String)
    /// The typed bucket name breaks S3's naming rules.
    case invalidBucketName(name: String, reason: String)
    /// Bucket names are global; someone else has this one.
    case bucketNameTaken(name: String)
    /// This profile already owns a bucket by that name.
    case bucketExists(name: String)
    /// A folder name S3 can't carry.
    case invalidFolderName(name: String)
    /// Rename of something S3 can't rename cheaply yet: a file, or a folder with
    /// contents (each would be a copy of everything plus a delete).
    case renameUnsupported(name: String)

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
            // Deliberately general: a profile can sign in several ways, and advice
            // aimed at the wrong one is worse than none.
            return "Profile “\(profile)” has no usable credentials. Add appropriate "
                 + "credentials to the AWS config and/or credentials files and retry."
        case .downloadFailed(let name):
            return "Couldn’t create a local file to download “\(name)” into."
        case .downloadTruncated(let name, let expected, let received):
            return "The download of “\(name)” was incomplete "
                 + "(\(received) of \(expected) bytes) and was discarded."
        case .uploadTooLarge(let name):
            return "“\(name)” is larger than 5 GB, more than a single S3 upload can carry."
        case .writeDenied(let name, let profile):
            return "Profile “\(profile)” isn’t allowed to write “\(name)” here."
        case .invalidBucketName(let name, let reason):
            return "\u{201C}\(name)\u{201D} isn\u{2019}t a valid bucket name: \(reason)."
        case .bucketNameTaken(let name):
            return "The bucket name \u{201C}\(name)\u{201D} is already taken. Bucket names are "
                 + "shared across all of AWS, so they have to be globally unique."
        case .bucketExists(let name):
            return "You already have a bucket named \u{201C}\(name)\u{201D}."
        case .invalidFolderName(let name):
            return "\u{201C}\(name)\u{201D} can\u{2019}t be used as a folder name here."
        case .renameUnsupported(let name):
            return "\u{201C}\(name)\u{201D} can\u{2019}t be renamed on S3 yet. Only empty folders "
                + "can be renamed in this version; S3 has no rename, so a file or a folder "
                + "with contents would have to be copied in full and the original deleted."
        case .cannotDelete(let name, let reason):
            return "Can\u{2019}t delete \u{201C}\(name)\u{201D}: \(reason)"
        case .deleteDenied(let name, let profile):
            return "Profile “\(profile)” isn’t allowed to delete “\(name)”. "
                 + "Anything already deleted stays deleted."
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

    private var clients: [String: S3Client] = [:]   // key: "profile|region|credentials file"
    private var bucketRegions: [String: String] = [:] // key: "profile|bucket|credentials file"

    /// A client in the bootstrap region (`us-east-1`) for account-level calls like
    /// ListBuckets, which are not region-specific.
    func bootstrapClient(profile: String) async throws -> S3Client {
        try await client(profile: profile, region: "us-east-1")
    }

    /// A cached client for (profile, region), built from wherever that profile's
    /// credentials are configured *now*.
    ///
    /// The credentials file is part of the cache key, and the profile is re-checked
    /// against the configured folders on every call — including cache hits. Keyed on
    /// profile and region alone, a client built from folder A kept being handed out
    /// after the user switched to folder B, or removed the folder altogether.
    func client(profile: String, region: String) async throws -> S3Client {
        guard let paths = AWSProfiles.resolverPaths(forProfile: profile) else {
            throw S3Error.noCredentials(profile: profile)
        }
        let key = "\(profile)|\(region)|\(paths.credentials)"
        if let existing = clients[key] { return existing }
        let created = try await S3Provider.makeClient(profile: profile, region: region, paths: paths)
        clients[key] = created
        return created
    }

    /// A client bound to a bucket's own region (required for ListObjectsV2, which
    /// 301-redirects if you target the wrong region). Discovers + caches the region.
    func clientForBucket(profile: String, bucket: String) async throws -> S3Client {
        let region = try await regionForBucket(profile: profile, bucket: bucket)
        return try await client(profile: profile, region: region)
    }

    func regionForBucket(profile: String, bucket: String) async throws -> String {
        // Same identity as the clients: a region looked up with one credential source
        // isn't reused for another.
        guard let paths = AWSProfiles.resolverPaths(forProfile: profile) else {
            throw S3Error.noCredentials(profile: profile)
        }
        let key = "\(profile)|\(bucket)|\(paths.credentials)"
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
