import Foundation
import MacSplorerCore
import MacSplorerS3

/// The UI-integration layer that surfaces S3 inside the `/Volumes` namespace.
/// "Connecting" (a persisted toggle) makes each AWS profile appear as a folder
/// under /Volumes; disconnecting removes them. The provider itself is stateless —
/// this only decides *where in the tree* the S3 namespace shows up.
enum S3Mount {
    static let volumesURL = URL(fileURLWithPath: "/Volumes")

    /// Posted after the configured credential locations change, so the file watcher
    /// can re-arm on the new folder set.
    static let locationsChanged = Notification.Name("MacSplorerS3LocationsChanged")

    /// Whether S3 profiles are currently surfaced under /Volumes (persisted).
    static var isConnected: Bool {
        get { Preferences.shared.s3Connected }
        set { Preferences.shared.s3Connected = newValue }
    }

    /// True for the /Volumes root, where S3 profiles are injected.
    static func isVolumesRoot(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path == volumesURL.path
    }

    /// The AWS profile names to surface (empty when disconnected).
    static func profileNames() -> [String] {
        isConnected ? AWSProfiles.names() : []
    }

    /// Push the user's configured credential-file folders into AWSProfiles. Call at
    /// startup and whenever the locations change.
    static func applyCredentialLocations() {
        AWSProfiles.locations = Preferences.shared.s3CredentialLocations.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        NotificationCenter.default.post(name: locationsChanged, object: nil)
    }

    /// The location folders as URLs (for the file watcher).
    static func locationFolders() -> [URL] {
        Preferences.shared.s3CredentialLocations.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
    }

    /// A synthetic FSItem for one profile, positioned under /Volumes.
    static func profileItem(_ name: String) -> FSItem {
        FSItem(providerURL: S3Location.url(profile: name),
               name: name, isDirectory: true, byteSize: nil,
               modificationDate: nil, typeDescription: "AWS Profile")
    }

    /// Fresh profile items (for the async list pane, where instance identity
    /// doesn't matter — the view is rebuilt each load).
    static func profileItems() -> [FSItem] {
        profileNames().map(profileItem)
    }
}
