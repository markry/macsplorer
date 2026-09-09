import Foundation
import AWSS3
import AWSSDKIdentity
import MacSplorerCore

/// Generates presigned S3 download URLs (SigV4) for a single object — a link
/// anyone can use to fetch that object until it expires, no AWS credentials needed
/// by the recipient.
///
/// Presigning is a purely local, offline signature over the object request using
/// the profile's own credentials: no network call is made and no IAM permission
/// beyond the `s3:GetObject` the credential already needs is required. Because the
/// URL executes AS the signing profile, it hands the holder read access they
/// wouldn't otherwise have — that's inherent to presigned URLs, by design. See the
/// S3 design spec §"Signed URLs".
public enum S3Presign {
    /// Content-Disposition baked into the signed URL. `.inline` lets a browser
    /// render/stream the object in place (e.g. play an mp4); `.attachment` forces a
    /// download ("Save As") using the object's filename.
    public enum Disposition {
        case inline
        case attachment
    }

    /// What kind of credentials back a profile — this bounds how long a link can live.
    public enum CredentialKind {
        /// Long-term IAM user access keys: can sign for the full 7-day maximum.
        case longTerm
        /// Temporary credentials (SSO / assumed role / STS): a signed URL cannot
        /// outlive them. `expiry` is when the session ends, if the SDK reports it.
        case temporary(expiry: Date?)
    }

    /// SigV4's hard ceiling on presigned-URL lifetime: 7 days.
    public static let maxExpiration: TimeInterval = 7 * 24 * 60 * 60

    /// Resolve `profile`'s credentials (locally) and classify them, so the UI can
    /// cap the offered duration and warn when a link can't outlive the session.
    public static func credentialKind(profile: String) async throws -> CredentialKind {
        let paths = AWSProfiles.resolverPaths(forProfile: profile)
        let resolver = ProfileAWSCredentialIdentityResolver(
            profileName: profile,
            configFilePath: paths.config,
            credentialsFilePath: paths.credentials)
        let identity: (sessionToken: String?, expiration: Date?)
        do {
            let resolved = try await resolver.getIdentity()
            identity = (resolved.sessionToken, resolved.expiration)
        } catch {
            throw S3Error.noCredentials(profile: profile)
        }
        // A session token (or an expiration) means temporary credentials — the URL
        // dies with the session; static IAM user keys have neither.
        if identity.sessionToken != nil || identity.expiration != nil {
            return .temporary(expiry: identity.expiration)
        }
        return .longTerm
    }

    /// The effective lifetime for a link: the requested `seconds`, clamped to the
    /// 7-day SigV4 max and — for temporary credentials — to the time left on the
    /// session (a signed URL can't outlive the credentials that signed it). May be
    /// 0 if the session has already expired.
    public static func effectiveExpiration(requested seconds: TimeInterval,
                                           kind: CredentialKind,
                                           now: Date) -> TimeInterval {
        var limit = maxExpiration
        if case .temporary(let expiry) = kind, let expiry {
            limit = min(limit, max(0, expiry.timeIntervalSince(now)))
        }
        return min(seconds, limit)
    }

    /// Generate a presigned GET URL for the S3 object at `url` (an
    /// `s3://profile/bucket/key` object location — not a folder). `filename` is the
    /// download's suggested name when `disposition == .attachment`. A non-nil
    /// `contentType` overrides the object's stored Content-Type in the response
    /// (e.g. to force `video/mp4` so a mis-tagged object streams); nil leaves the
    /// stored type untouched.
    public static func downloadURL(for url: URL, expiration: TimeInterval,
                                   disposition: Disposition, filename: String,
                                   contentType: String? = nil) async throws -> URL {
        guard case .prefix(let profile, let bucket, let key) = S3Location.parse(url),
              !key.isEmpty, !key.hasSuffix("/") else {
            throw S3Error.notS3(url)
        }
        // Sign against a client bound to the bucket's own region, or the URL's host
        // won't match and the link will fail with a redirect.
        let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
        let overrideType = contentType?.trimmingCharacters(in: .whitespaces)
        let input = GetObjectInput(
            bucket: bucket,
            key: key,
            responseContentDisposition: dispositionHeader(disposition, filename: filename),
            responseContentType: (overrideType?.isEmpty == false) ? overrideType : nil)
        do {
            return try await client.presignedURLForGetObject(input: input, expiration: expiration)
        } catch {
            throw S3Provider.clarify(error, listing: "“\(filename)”", profile: profile)
        }
    }

    /// The `response-content-disposition` header value baked into the URL.
    private static func dispositionHeader(_ disposition: Disposition, filename: String) -> String {
        switch disposition {
        case .inline:
            return "inline"
        case .attachment:
            // RFC 6266 quoted-string: drop the two characters that would break it.
            let safe = filename.replacingOccurrences(of: "\"", with: "")
                               .replacingOccurrences(of: "\\", with: "")
            return "attachment; filename=\"\(safe)\""
        }
    }
}
