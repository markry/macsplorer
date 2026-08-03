import Foundation
import MacSplorerCore
import MacSplorerS3

// Headless Phase-1 smoke test: exercises the S3 provider's enumeration path
// (root → profiles → buckets → a bucket's top level) against a real profile,
// printing what the UI would show. The profile comes from the environment so no
// account/profile name is ever hardcoded.
//   S3_TEST_PROFILE=my-s3-profile swift run S3Smoke

func line(_ item: FSItem) -> String {
    let kind = item.isDirectory ? "[DIR]" : "     "
    let size = item.byteSize.map { " · \($0) bytes" } ?? ""
    let date = item.modificationDate.map { " · \($0)" } ?? ""
    let type = item.typeDescription.map { " · \($0)" } ?? ""
    return "  \(kind) \(item.name)\(size)\(date)\(type)"
}

// Optional: point enumeration/resolution at a throwaway location for testing.
if let loc = ProcessInfo.processInfo.environment["S3_TEST_LOCATION"] {
    AWSProfiles.locations = [URL(fileURLWithPath: (loc as NSString).expandingTildeInPath)]
}

let provider = S3Provider(url: S3Location.rootURL)

// 1. Root → profiles (local; no network).
let profiles = (try? await provider.children(of: S3Location.rootURL, includeHidden: false)) ?? []
print("PROFILES (\(profiles.count)):")
profiles.forEach { print(line($0)) }

guard let profileName = ProcessInfo.processInfo.environment["S3_TEST_PROFILE"] else {
    print("\nSet S3_TEST_PROFILE=<profile> to list buckets and objects.")
    exit(0)
}

// Direct-bucket mode: exercises ListObjectsV2 + region discovery WITHOUT needing
// s3:ListAllMyBuckets — the path a read-only, bucket-scoped credential uses.
//   S3_TEST_PROFILE=<p> S3_TEST_BUCKET=<bucket> swift run S3Smoke
if let bucket = ProcessInfo.processInfo.environment["S3_TEST_BUCKET"] {
    let bucketURL = S3Location.url(profile: profileName).appendingPathComponent(bucket, isDirectory: true)
    do {
        let top = try await provider.children(of: bucketURL, includeHidden: false)
        print("\nTOP OF '\(bucket)' (\(top.count) items, showing ≤25):")
        top.prefix(25).forEach { print(line($0)) }
        if let folder = top.first(where: { $0.isDirectory }) {
            let inside = try await provider.children(of: folder.url, includeHidden: false)
            print("\nINSIDE '\(folder.name)' (\(inside.count) items, showing ≤15):")
            inside.prefix(15).forEach { print(line($0)) }
        }
        print("\nOK — direct bucket enumeration succeeded (no ListBuckets needed).")
    } catch { print("\nERROR: \(error.localizedDescription)"); exit(1) }
    exit(0)
}

do {
    // 2. Profile → buckets (ListBuckets).
    let profileURL = S3Location.url(profile: profileName)
    let buckets = try await provider.children(of: profileURL, includeHidden: false)
    print("\nBUCKETS for '\(profileName)' (\(buckets.count)):")
    buckets.forEach { print(line($0)) }

    // 3. First bucket → top-level prefixes + objects (ListObjectsV2, region discovery).
    guard let firstBucket = buckets.first else { print("\n(no buckets)"); exit(0) }
    let top = try await provider.children(of: firstBucket.url, includeHidden: false)
    print("\nTOP OF '\(firstBucket.name)' (\(top.count) items, showing ≤25):")
    top.prefix(25).forEach { print(line($0)) }

    // 4. If there's a sub-"folder", descend one level to prove prefix listing.
    if let folder = top.first(where: { $0.isDirectory }) {
        let inside = try await provider.children(of: folder.url, includeHidden: false)
        print("\nINSIDE '\(folder.name)' (\(inside.count) items, showing ≤15):")
        inside.prefix(15).forEach { print(line($0)) }
    }
    print("\nOK — S3 enumeration succeeded.")
} catch {
    print("\nERROR: \(error.localizedDescription)")
    exit(1)
}
