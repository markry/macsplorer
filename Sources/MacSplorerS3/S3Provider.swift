import Foundation
import AWSS3
import MacSplorerCore

// Scaffold for the Amazon S3 storage provider. This file exists first to prove
// the AWS SDK for Swift builds and links under Command Line Tools (its AWS CRT
// dependency compiles C) before the real provider logic lands. Referencing
// `S3Client` forces the AWSS3 product to actually compile.
enum S3Build {
    /// Trivial touch of the SDK so it's linked — replaced by the real S3Provider.
    static func smokeReference() -> String {
        String(describing: S3Client.self)
    }
}
