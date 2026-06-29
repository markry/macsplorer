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
        // Compact numeric date + time (no spelled-out month, no localized "at")
        // so the date columns stay narrow: e.g. 06/28/2026 10:30 AM.
        formatter.dateFormat = "MM/dd/yyyy h:mm a"
        return formatter
    }()

    /// Human size string, or "" for directories (nil byteSize).
    public static func size(_ bytes: Int?) -> String {
        guard let bytes else { return "" }
        return byteFormatter.string(fromByteCount: Int64(bytes))
    }

    public static func size(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    public static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }
}
