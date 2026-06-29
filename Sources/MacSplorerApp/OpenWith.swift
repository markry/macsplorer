import AppKit
import UniformTypeIdentifiers

/// Builds an "Open With ▸" submenu listing the apps capable of opening a file,
/// the default app first. Each item carries its app URL as `representedObject`;
/// the menu's `target`/`action` receives the click and opens the selection.
enum OpenWith {
    /// A populated submenu for `fileURL`. The top items open the file once
    /// (`openAction`); a trailing "Set Default for All …" submenu changes the
    /// system default app for the file's kind (`setDefaultAction`). Items carry the
    /// chosen app's URL in `representedObject`; "Other…" carries `nil`.
    static func submenu(for fileURL: URL, target: AnyObject,
                        openAction: Selector, setDefaultAction: Selector) -> NSMenu {
        let menu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        var appURLs = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)

        // Default first, labelled; de-duplicated from the rest.
        if let defaultApp {
            appURLs.removeAll { $0 == defaultApp }
            addItem(to: menu, app: defaultApp, suffix: " (default)", target: target, action: openAction)
            if !appURLs.isEmpty { menu.addItem(.separator()) }
        }
        let others = appURLs.sorted(by: { appName($0) < appName($1) })
        for app in others {
            addItem(to: menu, app: app, suffix: "", target: target, action: openAction)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: openAction, keyEquivalent: "")
        other.target = target
        menu.addItem(other)

        // "Set Default for All …" — sets the system default app for this kind
        // (Finder's Get Info ▸ "Change All").
        let candidates = (defaultApp.map { [$0] } ?? []) + others
        guard !candidates.isEmpty else { return menu }
        let ext = fileURL.pathExtension
        let title = ext.isEmpty ? "Set Default for All Files of This Kind"
                                : "Set Default for All “.\(ext)” Files"
        let setDefault = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let setDefaultMenu = NSMenu()
        for app in candidates {
            addItem(to: setDefaultMenu, app: app, suffix: app == defaultApp ? " (current)" : "",
                    target: target, action: setDefaultAction)
        }
        setDefault.submenu = setDefaultMenu
        menu.addItem(.separator())
        menu.addItem(setDefault)
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
