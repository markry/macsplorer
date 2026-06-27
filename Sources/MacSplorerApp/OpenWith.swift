import AppKit
import UniformTypeIdentifiers

/// Builds an "Open With ▸" submenu listing the apps capable of opening a file,
/// the default app first. Each item carries its app URL as `representedObject`;
/// the menu's `target`/`action` receives the click and opens the selection.
enum OpenWith {
    /// A populated submenu for `fileURL`. Items (except "Other…") carry the
    /// chosen app's URL in `representedObject`; "Other…" carries `nil`.
    static func submenu(for fileURL: URL, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        var appURLs = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)

        // Default first, labelled; de-duplicated from the rest.
        if let defaultApp {
            appURLs.removeAll { $0 == defaultApp }
            addItem(to: menu, app: defaultApp, suffix: " (default)", target: target, action: action)
            if !appURLs.isEmpty { menu.addItem(.separator()) }
        }
        for app in appURLs.sorted(by: { appName($0) < appName($1) }) {
            addItem(to: menu, app: app, suffix: "", target: target, action: action)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: action, keyEquivalent: "")
        other.target = target
        menu.addItem(other)
        return menu
    }

    private static func addItem(to menu: NSMenu, app: URL, suffix: String,
                                target: AnyObject, action: Selector) {
        let item = NSMenuItem(title: appName(app) + suffix, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = app
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        menu.addItem(item)
    }

    private static func appName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Open `urls` with the application at `appURL`.
    static func open(_ urls: [URL], with appURL: URL) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }

    /// Prompt for an application (rooted at /Applications) and open `urls` with it.
    static func openWithOtherApp(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        open(urls, with: appURL)
    }
}
