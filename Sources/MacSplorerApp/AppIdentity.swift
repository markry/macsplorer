import Foundation

/// Who this running app is. A relabeled build (a different bundle identifier and
/// name, stamped in by `build.sh`) runs beside the public MacSplorer, so anything
/// the two must not share — caches, window titles, menus, logs — follows the
/// running app rather than assuming there is only one.
enum AppIdentity {
    /// "MacSplorer", or the edition's own name ("MacSplorer Acme").
    static let name: String = {
        let info = Bundle.main.infoDictionary
        let display = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        return (display?.isEmpty == false) ? display! : "MacSplorer"
    }()

    /// The bundle identifier, falling back to the public one (a bare `swift run`).
    static let bundleID: String = Bundle.main.bundleIdentifier ?? "net.ryland.macsplorer"
}
