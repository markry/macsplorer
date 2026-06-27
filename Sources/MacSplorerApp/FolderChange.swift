import Foundation

/// App-wide "these folders' contents changed" broadcast. Any file operation
/// posts the affected folders here, so every window's list and the tree refresh
/// — including the *source* folder of a drag-move, which the destination window
/// is the one to mutate.
enum FolderChange {
    static let didChange = Notification.Name("MacSplorerFolderDidChange")

    /// Post that `folders` changed. Delivered synchronously to observers.
    static func notify(_ folders: [URL]) {
        let normalized = folders.map { $0.standardizedFileURL }
        NotificationCenter.default.post(name: didChange, object: nil,
                                        userInfo: ["folders": normalized])
    }

    static func folders(from note: Notification) -> [URL] {
        note.userInfo?["folders"] as? [URL] ?? []
    }
}
