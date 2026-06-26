import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowControllers: [MainWindowController] = []
    private var cascadePoint = NSPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The controller for the frontmost window — menu commands act on it.
    private var keyController: MainWindowController? {
        if let keyWindow = NSApp.keyWindow {
            return windowControllers.first { $0.window === keyWindow }
        }
        return windowControllers.first
    }

    // MARK: Windows

    @objc private func newWindow(_ sender: Any?) {
        let controller = MainWindowController()
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        // Cascade so a new window doesn't land exactly on the previous one.
        if let window = controller.window {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
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

        // File menu (New Window ⌘N, Open ⌘O; Return reserved for rename).
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let newWindowItem = NSMenuItem(title: "New Window",
                                       action: #selector(newWindow(_:)),
                                       keyEquivalent: "n")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
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

        // Window menu — once it's the app's designated windowsMenu, macOS
        // auto-populates it with the open-window list and the tabbing items
        // (Show Tab Bar, Merge All Windows, …) when multiple windows are open.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    @objc private func openSelection(_ sender: Any?) {
        keyController?.openSelection()
    }

    @objc private func toggleHiddenFiles(_ sender: Any?) {
        Preferences.shared.showHiddenFiles.toggle()
        windowControllers.forEach { $0.applyPreferences() }
    }

    @objc private func toggleSingleClick(_ sender: Any?) {
        Preferences.shared.singleClickToOpen.toggle()
        windowControllers.forEach { $0.applyPreferences() }
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
