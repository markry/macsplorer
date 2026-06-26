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
    targets: [
        // Pure model layer — filesystem items, loading, sorting, formatting.
        // No UI, so it stays testable and is the clean seam for any future
        // (e.g. open-core) feature split.
        .target(name: "MacSplorerCore"),

        // AppKit UI layer.
        .executableTarget(
            name: "MacSplorerApp",
            dependencies: ["MacSplorerCore"]
        ),

        // Tests for the UI-free core.
        .testTarget(
            name: "MacSplorerCoreTests",
            dependencies: ["MacSplorerCore"]
        ),
    ]
)
