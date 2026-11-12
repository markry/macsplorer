import Foundation
import Testing
import MacSplorerCore
@testable import MacSplorerS3

/// What S3 says about itself decides how the app treats it. In particular, renaming
/// a folder with contents asks first only where rename isn't atomic: S3 copies
/// everything and deletes the originals, a local disk renames in place.
@Suite struct S3CapabilitiesTests {
    @Test func s3RenameIsNotAtomicSoAFolderRenameAsksFirst() {
        #expect(S3Provider(url: URL(string: "s3:///")!).capabilities.atomicRename == false)
    }

    /// The rename warning names the backend from here, so the app's text never
    /// says "S3" anywhere else.
    @Test func s3NamesItselfAndTheLocalDiskDoesnt() {
        #expect(S3Provider(url: URL(string: "s3:///")!).displayName == "S3")
        #expect(LocalProvider().displayName == nil)
    }

    @Test func localRenameIsAtomic() {
        #expect(LocalProvider().capabilities.atomicRename == true)
    }
}
