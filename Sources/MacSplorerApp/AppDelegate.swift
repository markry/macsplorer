import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller

        NSApp.mainMenu = makeMainMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Menu

    private func makeMainMenu() -> NSMenu {
        let appName = "MacSplorer"
        let mainMenu = NSMenu()

        // Application menu (About + Quit).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // File menu (Open — ⌘O, Finder convention; Return is reserved for rename).
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let open = NSMenuItem(title: "Open",
                              action: #selector(openSelection(_:)),
                              keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)

        // View menu (toggles; checkmarks reflect persisted preferences).
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        let hidden = NSMenuItem(title: "Show Hidden Files",
                                action: #selector(toggleHiddenFiles(_:)),
                                keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        hidden.target = self
        viewMenu.addItem(hidden)

        let singleClick = NSMenuItem(title: "Single-Click to Open",
                                     action: #selector(toggleSingleClick(_:)),
                                     keyEquivalent: "")
        singleClick.target = self
        viewMenu.addItem(singleClick)

        return mainMenu
    }

    @objc private func openSelection(_ sender: NSMenuItem) {
        mainWindowController?.openSelection()
    }

    @objc private func toggleHiddenFiles(_ sender: NSMenuItem) {
        mainWindowController?.toggleShowHiddenFiles()
    }

    @objc private func toggleSingleClick(_ sender: NSMenuItem) {
        mainWindowController?.toggleSingleClickToOpen()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = Preferences.shared.showHiddenFiles ? .on : .off
        case #selector(toggleSingleClick(_:)):
            menuItem.state = Preferences.shared.singleClickToOpen ? .on : .off
        default:
            break
        }
        return true
    }
}
