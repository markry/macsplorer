// swift-tools-version: 5.9
//
// MacSplorer — a two-pane (tree + details) file manager for macOS,
// in the spirit of Windows Explorer. MIT-licensed.
//
// Built with Swift Package Manager + AppKit (programmatic UI, no Storyboards),
// so it builds with just the Command Line Tools (no full Xcode required) and
// still opens directly in Xcode if you have it.
import Foundation
import PackageDescription

// Optional private provider modules. If this checkout contains a
// `Sources/MacSplorerPlugins` directory, it's compiled in and linked into the
// app; when it's absent the package builds exactly as it would without it. That
// lets ONE manifest serve both a checkout carrying extra, unpublished providers
// and one without — no divergence to maintain, nothing to patch when publishing.
// The app side pairs this with `#if canImport(MacSplorerPlugins)`.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasPlugins = FileManager.default.fileExists(
    atPath: packageDir.appendingPathComponent("Sources/MacSplorerPlugins").path)

// AppKit UI layer — links the optional plugins module only when it's present.
var appDependencies: [Target.Dependency] = ["MacSplorerCore", "MacSplorerS3"]
if hasPlugins { appDependencies.append("MacSplorerPlugins") }

var targets: [Target] = [
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

    .executableTarget(name: "MacSplorerApp", dependencies: appDependencies),

    // Tests for the UI-free core.
    .testTarget(
        name: "MacSplorerCoreTests",
        dependencies: ["MacSplorerCore"]
    ),
]

if hasPlugins {
    targets.append(
        .target(name: "MacSplorerPlugins", dependencies: ["MacSplorerCore", "MacSplorerS3"])
    )
}

let package = Package(
    name: "MacSplorer",
    platforms: [.macOS(.v13)],
    dependencies: [
        // AWS SDK for Swift — the S3 client (SigV4, retries, multipart, the
        // credential/SSO provider chain). Heavy graph (Smithy + AWS CRT); isolated
        // in the MacSplorerS3 target below so it doesn't touch the core model.
        .package(url: "https://github.com/awslabs/aws-sdk-swift", from: "1.0.0"),
    ],
    targets: targets
)
