import Foundation
import UniformTypeIdentifiers
import AWSS3
import AWSCloudFront
import AWSSDKIdentity
import MacSplorerCore

/// Fix Content Type: give an S3 object the type its file extension implies, so a
/// browser plays or shows it instead of downloading it.
///
/// S3 can't edit metadata in place; the object is copied onto itself with the new
/// type. Everything else is carried across deliberately, because a plain
/// metadata-REPLACE copy silently drops it: custom metadata, cache/disposition/
/// encoding/language headers, storage class, encryption (incl. its KMS key), tags,
/// and a public-read ACL where the bucket still uses ACLs (losing that would make a
/// public file private and break its links). Objects over 5 GB go part by part.
public enum S3ContentType {

    public struct Outcome: Sendable {
        public enum Kind: Sendable { case fixed, alreadyRight, unknownType }
        public let name: String
        public let kind: Kind
        public let from: String?
        public let to: String?
    }

    /// The type a file's extension implies, or nil when the extension is unknown.
    public static func expectedType(forName name: String) -> String? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    /// Fix one object (an `s3://profile/bucket/key` file URL).
    public static func fix(_ url: URL, progress: ProviderProgress?) async throws -> Outcome {
        guard case .prefix(let profile, let bucket, let key) = S3Location.parse(url),
              !key.isEmpty, !key.hasSuffix("/") else { throw S3Error.notS3(url) }
        let name = url.lastPathComponent
        let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
        do {
            let head = try await client.headObject(input: HeadObjectInput(bucket: bucket, key: key))
            guard let wanted = expectedType(forName: name) else {
                progress?.advance(items: 1, detail: name)
                return Outcome(name: name, kind: .unknownType, from: head.contentType, to: nil)
            }
            if head.contentType?.lowercased() == wanted.lowercased() {
                progress?.advance(items: 1, detail: name)
                return Outcome(name: name, kind: .alreadyRight, from: head.contentType, to: wanted)
            }
            let acl = await keepPublicRead(client: client, bucket: bucket, key: key)
            let size = Int64(head.contentLength ?? 0)
            let storageClass = head.storageClass.flatMap { S3ClientTypes.StorageClass(rawValue: $0.rawValue) }
            let copySource = "\(bucket)/\(S3PublicLink.encodeKey(key))"
            if size <= S3Provider.maxSingleCopyBytes {
                _ = try await client.copyObject(input: CopyObjectInput(
                    acl: acl,
                    bucket: bucket,
                    cacheControl: head.cacheControl,
                    contentDisposition: head.contentDisposition,
                    contentEncoding: head.contentEncoding,
                    contentLanguage: head.contentLanguage,
                    contentType: wanted,
                    copySource: copySource,
                    key: key,
                    metadata: head.metadata,
                    metadataDirective: .replace,
                    serverSideEncryption: head.serverSideEncryption,
                    ssekmsKeyId: head.ssekmsKeyId,
                    storageClass: storageClass,
                    taggingDirective: .copy))
                progress?.advance(items: 1, bytes: size, detail: name)
            } else {
                try await S3Provider(url: url).multipartCopy(
                    client: client, srcClient: client, head: head, size: size,
                    copySource: copySource, srcBucket: bucket, srcKey: key,
                    dstBucket: bucket, dstKey: key, storageClass: storageClass,
                    name: name, progress: progress, contentType: wanted, acl: acl)
            }
            return Outcome(name: name, kind: .fixed, from: head.contentType, to: wanted)
        } catch {
            if error is CancellationError || error is S3Error { throw error }
            if S3Provider.isAccessDenied(error) { throw S3Error.writeDenied(name: name, profile: profile) }
            throw S3Provider.clarify(error, listing: "\u{201C}\(name)\u{201D}", profile: profile)
        }
    }

    /// `.publicRead` if the object is currently readable by everyone through its
    /// ACL, so the copy keeps it public. Nil otherwise — including buckets with ACLs
    /// disabled (public through the bucket policy, which a copy can't change).
    private static func keepPublicRead(client: S3Client, bucket: String, key: String) async
        -> S3ClientTypes.ObjectCannedACL? {
        guard let acl = try? await client.getObjectAcl(input: GetObjectAclInput(bucket: bucket, key: key))
        else { return nil }
        let everyone = "http://acs.amazonaws.com/groups/global/AllUsers"
        let isPublic = (acl.grants ?? []).contains {
            $0.grantee?.uri == everyone && ($0.permission == .read || $0.permission == .fullControl)
        }
        return isPublic ? .publicRead : nil
    }

    // MARK: - CloudFront

    public struct CDNResult: Sendable {
        /// Distribution IDs whose cache was cleared for the fixed files.
        public var invalidated: [String] = []
        /// Why nothing could be cleared (no permission, say), if so.
        public var problem: String?
        public init() {}
    }

    /// Clear the fixed objects from the cache of every CloudFront distribution that
    /// serves this bucket — otherwise the CDN keeps handing out the old type until
    /// its copy expires. Best effort: a profile without CloudFront permission gets
    /// a plain explanation, and the S3 fix stands either way.
    public static func clearCDN(profile: String, bucket: String, keys: [String]) async -> CDNResult {
        var result = CDNResult()
        guard !keys.isEmpty else { return result }
        do {
            guard let paths = AWSProfiles.resolverPaths(forProfile: profile) else { return result }
            let resolver = ProfileAWSCredentialIdentityResolver(
                profileName: profile, configFilePath: paths.config, credentialsFilePath: paths.credentials)
            let config = try await CloudFrontClient.CloudFrontClientConfiguration(
                awsCredentialIdentityResolver: resolver, region: "us-east-1")
            let cf = CloudFrontClient(config: config)

            // S3 origins appear under several host names (REST, regional, website).
            func servesBucket(_ domain: String) -> Bool {
                let d = domain.lowercased(), b = bucket.lowercased()
                return d == "\(b).s3.amazonaws.com"
                    || (d.hasPrefix("\(b).s3.") && d.hasSuffix(".amazonaws.com"))
                    || (d.hasPrefix("\(b).s3-website") && d.hasSuffix(".amazonaws.com"))
            }

            var marker: String?
            repeat {
                let page = try await cf.listDistributions(input: ListDistributionsInput(marker: marker))
                for dist in page.distributionList?.items ?? [] {
                    guard let id = dist.id else { continue }
                    let allOrigins: [CloudFrontClientTypes.Origin] = dist.origins?.items ?? []
                    let origins = allOrigins.filter { servesBucket($0.domainName ?? "") }
                    guard !origins.isEmpty else { continue }
                    var invalidations: Set<String> = []
                    for origin in origins {
                        // An origin path ("/site") is prepended by CloudFront, so a key
                        // "site/a.mp4" is served at "/a.mp4"; keys outside it aren't served.
                        let originPath = (origin.originPath ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        for key in keys {
                            if originPath.isEmpty {
                                invalidations.insert("/" + S3PublicLink.encodeKey(key))
                            } else if key.hasPrefix(originPath + "/") {
                                invalidations.insert("/" + S3PublicLink.encodeKey(String(key.dropFirst(originPath.count + 1))))
                            }
                        }
                    }
                    guard !invalidations.isEmpty else { continue }
                    _ = try await cf.createInvalidation(input: CreateInvalidationInput(
                        distributionId: id,
                        invalidationBatch: CloudFrontClientTypes.InvalidationBatch(
                            callerReference: UUID().uuidString,
                            paths: CloudFrontClientTypes.Paths(items: Array(invalidations),
                                                               quantity: invalidations.count))))
                    result.invalidated.append(id)
                }
                marker = (page.distributionList?.isTruncated == true) ? page.distributionList?.nextMarker : nil
            } while marker != nil
        } catch {
            result.problem = S3Provider.isAccessDenied(error)
                ? "this AWS profile isn\u{2019}t allowed to manage CloudFront"
                : "CloudFront couldn\u{2019}t be updated (\(error.localizedDescription))"
        }
        return result
    }
}
