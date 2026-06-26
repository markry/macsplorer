import Foundation

/// Presentation formatting for the details columns. Foundation-only so it stays
/// in the UI-free Core layer and is easy to unit-test.
public enum FSFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Human size string, or "" for directories (nil byteSize).
    public static func size(_ bytes: Int?) -> String {
        guard let bytes else { return "" }
        return byteFormatter.string(fromByteCount: Int64(bytes))
    }

    public static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }
}
