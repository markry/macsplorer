import AppKit
import MacSplorerCore
import MacSplorerS3

/// Asking for the name of something new on a remote provider.
///
/// Locally, New Folder creates "untitled folder" and drops into an inline rename.
/// That doesn't transfer: a remote provider may not support rename at all (S3
/// doesn't), and at the top level of S3 a "folder" is a bucket — globally named,
/// region-bound, and not something to create by accident and rename later. So the
/// name is settled before anything is created.
@MainActor
enum NewRemoteFolder {
    struct Choice {
        var name: String
        /// Set only when creating a bucket, which has to live somewhere.
        var region: String?
    }

    /// Ask for a name — and, for a bucket, a region. The region list comes from the
    /// account when it can (see AWSRegions); the combo stays editable either way.
    static func ask(in directory: URL) async -> Choice? {
        let isBucket = isProfileRoot(directory)
        var regions = AWSRegions.fallback
        var regionsAreLive = false
        if isBucket, let profile = profile(of: directory) {
            regions = await AWSRegions.available(profile: profile)
            regionsAreLive = AWSRegions.isLive(regions)
        }
        let alert = NSAlert()
        alert.messageText = isBucket ? "New Bucket" : "New Folder"
        alert.informativeText = isBucket
            ? "Bucket names are shared across all of AWS, so they have to be globally "
            + "unique: lowercase letters, numbers, dots and hyphens only."
            : "Name the new folder in “\(directory.lastPathComponent)”."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = isBucket ? "bucket-name" : "folder name"
        var regionBox: NSComboBox?

        if isBucket {
            let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 78))
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            let box = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            box.addItems(withObjectValues: regions)
            box.stringValue = regions.contains("us-east-1") ? "us-east-1" : (regions.first ?? "us-east-1")
            box.isEditable = true
            let label = NSTextField(labelWithString: regionsAreLive
                ? "Region — enabled for this account"
                : "Region")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(field)
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(box)
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            box.widthAnchor.constraint(equalToConstant: 260).isActive = true
            alert.accessoryView = stack
            regionBox = box
        } else {
            alert.accessoryView = field
        }
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let region = regionBox?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Choice(name: name, region: (region?.isEmpty == false) ? region : "us-east-1")
    }

    /// True when `directory` is the level whose children are buckets.
    static func isProfileRoot(_ directory: URL) -> Bool {
        if case .profile = S3Location.parse(directory) { return true }
        return false
    }

    /// The profile a bucket would be created in.
    static func profile(of directory: URL) -> String? {
        if case .profile(let profile) = S3Location.parse(directory) { return profile }
        return nil
    }
}
