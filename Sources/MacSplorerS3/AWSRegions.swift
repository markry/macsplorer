import Foundation
import CryptoKit
import AWSSDKIdentity

/// The regions a profile can actually create a bucket in.
///
/// A hard-coded list goes stale and can't know which opt-in regions an account has
/// enabled, so we ask: `ec2:DescribeRegions` returns exactly the regions enabled for
/// the caller's account — the always-on ones plus any opt-in region that account has
/// turned on, and nothing it hasn't. That needs one narrow extra permission, so a
/// profile without it simply falls back to the built-in list; nothing breaks and
/// nobody is asked to fix their IAM policy to create a bucket.
///
/// The call is signed by hand rather than by importing the EC2 SDK: this is one
/// query-protocol GET, and the generated EC2 client is 11 MB of source for it.
public enum AWSRegions {
    /// Regions offered when DescribeRegions isn't permitted or doesn't answer. The
    /// always-on commercial regions as of 2026; opt-in regions are deliberately
    /// absent, since an account that hasn't enabled one can't use it anyway.
    public static let fallback = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "ca-central-1", "sa-east-1",
        "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-north-1",
        "ap-south-1", "ap-northeast-1", "ap-northeast-2", "ap-northeast-3",
        "ap-southeast-1", "ap-southeast-2",
    ]

    /// Where the signed request goes. Any region can answer for all of them; this is
    /// one of the two largest, and using it avoids asking the user a question whose
    /// only purpose is to ask another question.
    private static let queryRegion = "us-east-1"

    /// Enabled regions for `profile`, sorted, falling back to the built-in list on
    /// any failure — no credentials, no permission, no network.
    public static func available(profile: String) async -> [String] {
        if let cached = await Cache.shared.regions(for: profile) { return cached }
        guard let fetched = try? await describeRegions(profile: profile), !fetched.isEmpty else {
            return fallback
        }
        let sorted = fetched.sorted()
        await Cache.shared.store(sorted, for: profile)
        return sorted
    }

    /// True when the list came from the account rather than the fallback — the dialog
    /// says so, because "every region you have enabled" and "the ones we know about"
    /// deserve different trust.
    public static func isLive(_ regions: [String]) -> Bool { regions != fallback }

    // MARK: - The call

    private static func describeRegions(profile: String) async throws -> [String] {
        guard let paths = AWSProfiles.resolverPaths(forProfile: profile) else {
            throw S3Error.noCredentials(profile: profile)
        }
        let resolver = ProfileAWSCredentialIdentityResolver(
            profileName: profile,
            configFilePath: paths.config,
            credentialsFilePath: paths.credentials)
        let identity = try await resolver.getIdentity()

        let host = "ec2.\(queryRegion).amazonaws.com"
        let query = "Action=DescribeRegions&Version=2016-11-15"
        var request = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
        request.httpMethod = "GET"
        for (field, value) in signedHeaders(host: host, query: query, identity: identity) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw S3Error.cannotList(what: "regions")   // caller falls back
        }
        return parseRegions(String(decoding: data, as: UTF8.self))
    }

    /// `<regionName>` values, keeping only regions the account can use. DescribeRegions
    /// already filters to enabled ones by default; the opt-in check is belt and braces
    /// in case that default ever changes.
    /// `<regionName>` / `<optInStatus>` pairs out of the DescribeRegions response.
    ///
    /// Keyed off the region name rather than the `<item>` elements that hold it,
    /// because those nest: each region carries a `geographySet` of its own `<item>`
    /// entries, so anything that pairs the first `<item>` with the first `</item>`
    /// reads the wrong boundary. Splitting on `<regionName>` makes each chunk exactly
    /// one region's fields, up to where the next region starts.
    static func parseRegions(_ xml: String) -> [String] {
        var regions: [String] = []
        for chunk in xml.components(separatedBy: "<regionName>").dropFirst() {
            guard let nameEnd = chunk.range(of: "</regionName>") else { continue }
            let name = String(chunk[..<nameEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            // A region the account hasn't enabled can't hold a bucket, so leave it out.
            if value(of: "optInStatus", in: chunk[nameEnd.upperBound...]) == "not-opted-in" { continue }
            regions.append(name)
        }
        return regions
    }

    private static func value(of tag: String, in text: Substring) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SigV4

    /// Sign an empty-payload GET the way SigV4 requires (AWS Signature Version 4,
    /// "Tasks 1–3"). Query-protocol services like EC2 accept nothing else.
    private static func signedHeaders(host: String, query: String,
                                      identity: AWSCredentialIdentity) -> [String: String] {
        let now = Date()
        let amzDate = iso8601.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let service = "ec2"
        let scope = "\(dateStamp)/\(queryRegion)/\(service)/aws4_request"
        let emptyHash = hex(SHA256.hash(data: Data()))

        var headers = ["host": host, "x-amz-date": amzDate]
        if let token = identity.sessionToken { headers["x-amz-security-token"] = token }
        let signedNames = headers.keys.sorted()
        let canonicalHeaders = signedNames.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaderList = signedNames.joined(separator: ";")

        let canonicalRequest = [
            "GET", "/", query, canonicalHeaders, signedHeaderList, emptyHash,
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(identity.secret)".utf8))
        for element in [dateStamp, queryRegion, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
                for: Data(element.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8), using: key))

        var result = headers
        result["Authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(identity.accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaderList), Signature=\(signature)"
        result.removeValue(forKey: "host")   // URLSession sets Host itself
        return result
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static let iso8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Per-profile cache: the dialog can be opened repeatedly, and the answer changes
    /// about as often as someone enables a region.
    private actor Cache {
        static let shared = Cache()
        private var byProfile: [String: [String]] = [:]
        func regions(for profile: String) -> [String]? { byProfile[profile] }
        func store(_ regions: [String], for profile: String) { byProfile[profile] = regions }
    }
}
