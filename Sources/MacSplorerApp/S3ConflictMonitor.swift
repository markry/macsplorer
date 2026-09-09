import AppKit
import MacSplorerS3

/// Warns the user (once) when a profile name newly appears in more than one
/// configured credential location. Policy is "first location wins" — the earliest
/// location's copy keeps working; later duplicates are ignored — so this never
/// removes a working profile; it just explains what's being ignored. Symmetric
/// across both entry points (the locations dialog and the live file watcher).
enum S3ConflictMonitor {
    /// Conflicts already surfaced, so we don't re-nag for known ones.
    private static var known: Set<String> = []

    /// Record the current conflicts without alerting (call once at startup).
    static func seed() { known = Set(AWSProfiles.conflicts()) }

    /// Re-check conflicts; alert for any that are newly conflicting. `changed` are
    /// the files that just changed (from the watcher), called out in the message.
    static func check(changed: [URL] = []) {
        let current = Set(AWSProfiles.conflicts())
        let newly = current.subtracting(known)
        known = current
        guard !newly.isEmpty else { return }
        warn(profiles: newly.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
             changed: changed)
    }

    private static func warn(profiles: [String], changed: [URL]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = profiles.count == 1
            ? "Profile “\(profiles[0])” is defined in more than one location"
            : "\(profiles.count) profiles are defined in more than one location"
        alert.informativeText =
            "MacSplorer keeps the first configured location's copy and ignores the "
            + "duplicate(s) — your existing profile is unaffected. Resolve the "
            + "duplication (rename or remove one), then it will update on its own."

        // Copyable detail: which location is used, which are ignored, and — for a
        // live edit — the file(s) that just changed.
        var lines: [String] = []
        for profile in profiles {
            let locs = AWSProfiles.locations(forProfile: profile)
            guard let used = locs.first else { continue }
            lines.append("“\(profile)”")
            lines.append("    using:   \(used.path)")
            for ignored in locs.dropFirst() { lines.append("    ignoring: \(ignored.path)") }
        }
        let changedFiles = changed.filter {
            $0.lastPathComponent == "config" || $0.lastPathComponent == "credentials"
        }
        if !changedFiles.isEmpty {
            lines.append("")
            lines.append("Just edited:")
            for file in changedFiles { lines.append("    \(file.path)") }
        }
        alert.accessoryView = copyableText(lines.joined(separator: "\n"))

        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// A read-only but selectable/copyable multi-line text field for the paths.
    private static func copyableText(_ string: String) -> NSView {
        let text = NSTextView()
        text.string = string
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 2, height: 2)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 120))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.frame = NSRect(x: 0, y: 0, width: 460, height: 120)
        text.minSize = NSSize(width: 0, height: 120)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        return scroll
    }
}
