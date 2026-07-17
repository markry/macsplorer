// swift-tools-version: 5.9
//
// MacSplorer — a two-pane (tree + details) file manager for macOS,
// in the spirit of Windows Explorer. MIT-licensed.
//
// Built with Swift Package Manager + AppKit (programmatic UI, no Storyboards),
// so it builds with just the Command Line Tools (no full Xcode required) and
// still opens directly in Xcode if you have it.
import PackageDescription

let package = Package(
    name: "MacSplorer",
    platforms: [.macOS(.v13)],
    dependencies: [
        // AWS SDK for Swift — the S3 client (SigV4, retries, multipart, the
        // credential/SSO provider chain). Heavy graph (Smithy + AWS CRT); isolated
        // in the MacSplorerS3 target below so it doesn't touch the core model.
        .package(url: "https://github.com/awslabs/aws-sdk-swift", from: "1.0.0"),
    ],
    targets: [
        // Pure model layer — filesystem items, loading, sorting, formatting.
        // No UI, so it stays testable and is the clean seam for any future
        // (e.g. open-core) feature split.
        .target(name: "MacSplorerCore"),

        // S3 storage provider — kept in its own target so the AWS SDK dependency
        // stays out of MacSplorerCore and can be a separable / open-core module.
        .target(
            name: "MacSplorerS3",
            dependencies: [
                "MacSplorerCore",
                .product(name: "AWSS3", package: "aws-sdk-swift"),
            ]
        ),

        // AppKit UI layer.
        .executableTarget(
            name: "MacSplorerApp",
            dependencies: ["MacSplorerCore", "MacSplorerS3"]
        ),

        // Tests for the UI-free core.
        .testTarget(
            name: "MacSplorerCoreTests",
            dependencies: ["MacSplorerCore"]
        ),
    ]
)
