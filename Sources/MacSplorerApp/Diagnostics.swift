import Foundation
import OSLog

/// Lightweight structured logging for timing-sensitive UI sequences — the kind of
/// bug where the code is obviously correct in isolation and only the ordering of
/// events explains what the user saw. Reading the log beats guessing at a fix.
///
/// Read it back with:
///   log show --predicate 'subsystem == "net.ryland.macsplorer"' --last 5m --info
enum Diag {
    /// Creating an item and starting its inline rename: several async steps, two
    /// possible reloads, and a first-responder change, all racing to be last.
    static let rename = Logger(subsystem: "net.ryland.macsplorer", category: "rename")

    /// Cut / copy / paste: which view had focus, what went on the clipboard, and
    /// what came back off it. Names are deliberately left out — counts and states
    /// are enough to see the flow, and the system log is not the place for a user's
    /// filenames.
    static let commands = Logger(subsystem: "net.ryland.macsplorer", category: "commands")
}

extension Diag {
    /// The class of whatever currently has keyboard focus — the fastest way to see
    /// why a keyboard command went nowhere, since each view implements its own set.
    static func responder(_ contents: FolderContents) -> String {
        guard let responder = contents.presenter?.presentingWindow?.firstResponder else { return "none" }
        return String(describing: type(of: responder))
    }
}
