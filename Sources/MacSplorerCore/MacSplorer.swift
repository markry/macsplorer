import Foundation

/// Namespace + package metadata. The model layer (filesystem item types,
/// directory loading, sorting, size/date formatting) will grow under this
/// target; the UI target depends on it but never the other way around.
public enum MacSplorer {
    public static let version = "0.13.0-beta.3"

    /// Which build this is, when a plugins module makes it more than the public app
    /// (e.g. "Acme"). Set once at launch from `Plugins.registerAll()`; nil for the
    /// public build.
    nonisolated(unsafe) public static var edition: String?

    /// The version as people should see it: "0.13.0 (Acme)".
    public static var displayVersion: String {
        edition.map { "\(version) (\($0))" } ?? version
    }
}
