import Testing
@testable import MacSplorerS3

/// Copy Public Link turns an object key into a URL path by hand, so the encoding
/// rules — the reason the feature exists — are pinned here.
struct S3PublicLinkTests {

    @Test func spacesAndPlusAreEncodedButSlashesKept() {
        #expect(S3PublicLink.encodeKey("videos/Summer 2026/day 1+2.mp4")
                == "videos/Summer%202026/day%201%2B2.mp4")
    }

    @Test func reservedAndNonASCIICharactersAreEncoded() {
        #expect(S3PublicLink.encodeKey("a#b?c%d&e=f") == "a%23b%3Fc%25d%26e%3Df")
        #expect(S3PublicLink.encodeKey("café/naïve.txt") == "caf%C3%A9/na%C3%AFve.txt")
        #expect(S3PublicLink.encodeKey("safe-name_v1.2~x") == "safe-name_v1.2~x")
    }

    @Test func linkJoinsBaseAndEncodedKey() {
        let url = S3PublicLink.link(base: "https://ryland.net/", key: "media/My Video.mp4")
        #expect(url?.absoluteString == "https://ryland.net/media/My%20Video.mp4")
    }

    @Test func defaultBaseUsesPathStyleForDottedBuckets() {
        // A dotted name breaks TLS in the virtual-hosted form (*.s3 cert).
        #expect(S3PublicLink.defaultBase(bucket: "www.example.com", region: "us-east-1")
                == "https://s3.us-east-1.amazonaws.com/www.example.com/")
        #expect(S3PublicLink.defaultBase(bucket: "my-bucket", region: "eu-west-2")
                == "https://my-bucket.s3.eu-west-2.amazonaws.com/")
    }

    @Test func normalizedBaseTidiesAndValidates() {
        #expect(S3PublicLink.normalizedBase("https://ryland.net") == "https://ryland.net/")
        #expect(S3PublicLink.normalizedBase("  https://ryland.net/media//  ") == "https://ryland.net/media/")
        #expect(S3PublicLink.normalizedBase("ryland.net") == "https://ryland.net/")
        #expect(S3PublicLink.normalizedBase("http://cdn.example.com/x/") == "http://cdn.example.com/x/")
        #expect(S3PublicLink.normalizedBase("") == nil)
        #expect(S3PublicLink.normalizedBase("ftp://example.com/") == nil)
        #expect(S3PublicLink.normalizedBase("https://example.com/?a=1") == nil)
        #expect(S3PublicLink.normalizedBase("https://exa mple.com/") == nil)
    }
}
