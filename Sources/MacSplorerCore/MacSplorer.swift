import Foundation

/// Namespace + package metadata. The model layer (filesystem item types,
/// directory loading, sorting, size/date formatting) will grow under this
/// target; the UI target depends on it but never the other way around.
public enum MacSplorer {
    public static let version = "0.1.1"
}
