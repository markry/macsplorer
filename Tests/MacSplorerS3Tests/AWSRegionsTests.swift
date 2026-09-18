import Testing
@testable import MacSplorerS3

/// The real DescribeRegions response nests `<item>` elements: every region carries a
/// `geographySet` containing items of its own. Two earlier parsers got this wrong —
/// one crashed on inverted string ranges, the other silently returned nothing — so
/// the shape is pinned here.
private let nestedResponse = """
<?xml version="1.0" encoding="UTF-8"?>
<DescribeRegionsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>cac52878-0000-0000-0000-4dc840ec8156</requestId>
    <regionInfo>
        <item>
            <regionName>ap-south-2</regionName>
            <regionEndpoint>ec2.ap-south-2.amazonaws.com</regionEndpoint>
            <optInStatus>opted-in</optInStatus>
            <geographySet>
                <item>
                    <name>India</name>
                </item>
            </geographySet>
        </item>
        <item>
            <regionName>us-east-1</regionName>
            <regionEndpoint>ec2.us-east-1.amazonaws.com</regionEndpoint>
            <optInStatus>opt-in-not-required</optInStatus>
        </item>
        <item>
            <regionName>ap-east-1</regionName>
            <regionEndpoint>ec2.ap-east-1.amazonaws.com</regionEndpoint>
            <optInStatus>not-opted-in</optInStatus>
        </item>
    </regionInfo>
</DescribeRegionsResponse>
"""

@Test func parsesRegionsDespiteNestedItems() {
    let regions = AWSRegions.parseRegions(nestedResponse)
    #expect(regions == ["ap-south-2", "us-east-1"])   // ap-east-1 isn't enabled
}

@Test func emptyAndJunkParseToNothing() {
    #expect(AWSRegions.parseRegions("").isEmpty)
    #expect(AWSRegions.parseRegions("<regionName>unterminated").isEmpty)
}

@Test func rejectsBucketNamesS3Would() throws {
    for bad in ["ab", "Has_Caps", "dots..dots", "-leading", "trailing-", "xn--puny"] {
        #expect(throws: S3Error.self) { try S3Provider.validateBucketName(bad) }
    }
    for good in ["my-bucket", "a.b.c", "logs2026"] {
        #expect(throws: Never.self) { try S3Provider.validateBucketName(good) }
    }
}
