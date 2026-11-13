import Foundation
import Testing
import MacSplorerCore
@testable import MacSplorerS3

/// What S3 says about itself decides how the app treats it. In particular, renaming
/// a folder with contents asks first only where rename isn't atomic: S3 copies
/// everything and deletes the originals, a local disk renames in place.
@Suite struct S3CapabilitiesTests {
    init() {
        Providers.register(scheme: "s3") { S3Provider(url: $0) }
    }

    @Test func s3RenameIsNotAtomicSoAFolderRenameAsksFirst() {
        #expect(S3Provider(url: URL(string: "s3:///")!).capabilities.atomicRename == false)
    }

    /// The rename warning names the backend from here, so the app's text never
    /// says "S3" anywhere else.
    @Test func s3NamesItselfAndTheLocalDiskDoesnt() {
        #expect(S3Provider(url: URL(string: "s3:///")!).displayName == "S3")
        #expect(LocalProvider().displayName == nil)
    }

    /// Codex caught beta.6 refusing S3 renames: S3 still said canRename: false.
    @Test func s3ObjectsAndFoldersCanBeRenamedButBucketsAndProfilesCant() {
        let report = URL(string: "s3://work/bucket/reports/q3.pdf")!
        let folder = URL(string: "s3://work/bucket/reports/")!
        #expect(LocationPermissions.canRename(report))
        #expect(LocationPermissions.canRename(folder))
        #expect(LocationPermissions.canRemove(report))
        #expect(LocationPermissions.canAdd(into: URL(string: "s3://work/bucket/")!))

        let bucket = URL(string: "s3://work/bucket/")!
        #expect(!LocationPermissions.canRename(bucket))
        #expect(LocationPermissions.canRemove(bucket))          // emptied, then deleted
        #expect(LocationPermissions.canAdd(into: URL(string: "s3://work/")!))  // New Bucket

        let profile = URL(string: "s3://work/")!
        #expect(!LocationPermissions.canRename(profile))
        #expect(!LocationPermissions.canRemove(profile))
    }

    @Test func localRenameIsAtomic() {
        #expect(LocalProvider().capabilities.atomicRename == true)
    }
}
