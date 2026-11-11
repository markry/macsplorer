import Foundation
import Testing
import MacSplorerCore

/// Telling accounts apart: user, host and port all name the location.
@Suite struct LocationIdentityTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func differentUsersAreDifferentPlaces() {
        #expect(!LocationIdentity.same(url("x://alice@server/a/"), url("x://bob@server/a/")))
        #expect(LocationIdentity.same(url("x://alice@server/a/"), url("x://alice@server/a")))
    }

    @Test func differentPortsAreDifferentPlaces() {
        #expect(!LocationIdentity.same(url("x://server:8080/a/"), url("x://server:9090/a/")))
        #expect(!LocationIdentity.same(url("x://server:8080/a/"), url("x://server/a/")))
    }

    @Test func s3ProfilesAreDifferentPlaces() {
        // The bug: a copy between two profiles' same-named buckets looked like a
        // drop onto its own folder and was skipped.
        let work = url("s3://work/bucket/"), personal = url("s3://personal/bucket/")
        #expect(!LocationIdentity.same(work, personal))
        #expect(!LocationIdentity.isSelfOrDescendant(url("s3://work/bucket/a.txt"), of: personal))
        #expect(LocationIdentity.isSelfOrDescendant(url("s3://work/bucket/a/b.txt"), of: work))
        // Profile names are case-sensitive.
        #expect(!LocationIdentity.same(url("s3://Work/bucket/"), work))
    }

    @Test func percentEncodingAndTrailingSlashesDontMatter() {
        var components = URLComponents()
        components.scheme = "x"; components.host = "h"; components.path = "/a b"
        #expect(LocationIdentity.same(url("x://h/a%20b/"), components.url!))
    }

    @Test func localPathsCompareAsBefore() {
        let a = URL(fileURLWithPath: "/tmp/x/"), b = URL(fileURLWithPath: "/tmp/x")
        #expect(LocationIdentity.same(a, b))
        #expect(LocationIdentity.isSelfOrDescendant(URL(fileURLWithPath: "/tmp/x/y"), of: a))
        #expect(!LocationIdentity.isSelfOrDescendant(URL(fileURLWithPath: "/tmp/xy"), of: a))
        #expect(!LocationIdentity.same(a, url("x:///tmp/x")))
    }

    @Test func mountsHoldOnlyTheirOwnAccount() {
        let alice = url("x://alice@server/"), bob = url("x://bob@server/")
        #expect(LocationIdentity.mount(alice, contains: url("x://alice@server/docs/")))
        #expect(!LocationIdentity.mount(alice, contains: url("x://bob@server/docs/")))
        #expect(!LocationIdentity.mount(bob, contains: url("x://alice@server/")))
        // A scheme root holds everything of its scheme.
        #expect(LocationIdentity.mount(url("x:///"), contains: url("x://bob@server/docs/")))
    }

    @Test func theMostSpecificMountWins() {
        let mounts = [url("x:///"), url("x://alice@server/"), url("x://alice@server/projects/"),
                      url("x://bob@server/")]
        func best(_ s: String) -> URL? { LocationIdentity.bestMount(for: url(s), among: mounts) { $0 } }
        #expect(best("x://bob@server/a/") == url("x://bob@server/"))
        #expect(best("x://alice@server/projects/p1/") == url("x://alice@server/projects/"))
        #expect(best("x://alice@server/other/") == url("x://alice@server/"))
        #expect(best("x://carol@server/") == url("x:///"))
    }

    @Test func addressesWithUserHostAndPortParse() throws {
        let parsed = try #require(LocationIdentity.parseAddress("x://user@host:8443/a b/c/"))
        #expect(parsed.scheme == "x")
        #expect(parsed.user == "user")
        #expect(parsed.host == "host")
        #expect(parsed.port == 8443)
        #expect(LocationIdentity.components(parsed) == ["a b", "c"])
    }

    @Test func anEmailAddressAsUserParses() throws {
        let parsed = try #require(LocationIdentity.parseAddress("x://me@example.com@server/a/"))
        #expect(parsed.user == "me@example.com")
        #expect(parsed.host == "server")
    }

    @Test func plainHostsStillParse() throws {
        let parsed = try #require(LocationIdentity.parseAddress("x://server/a%20b/"))
        #expect(parsed.user == nil)
        #expect(parsed.port == nil)
        #expect(parsed.host == "server")
        #expect(LocationIdentity.components(parsed) == ["a%20b"].map { $0.removingPercentEncoding! })
    }

    @Test func displayedAddressesRoundTrip() throws {
        let original = url("x://me%40example.com@server:8443/My%20Folder/")
        let shown = original.absoluteString.removingPercentEncoding!
        let back = try #require(LocationIdentity.parseAddress(shown))
        #expect(LocationIdentity.same(back, original))
    }
}
