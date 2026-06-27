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

    @objc private func newWindow(_ sender: Any?) { openWindow() }

    /// New Tab (⌘T): add a tab to the frontmost window, or open a window if
    /// there isn't one.
    @objc private func newTab(_ sender: Any?) {
        if let controller = keyController {
            controller.addTab()
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            openWindow()
        }
    }

    /// Close Tab (⌘W): close the frontmost window's active tab (or the window,
    /// if it's the last tab).
    @objc private func closeTab(_ sender: Any?) {
        keyController?.closeActiveTab()
    }

    /// Open a new window, optionally navigated to `folder` (used by the
    /// "Open in New Window" context-menu command).
    func openWindow(showing folder: URL? = nil) {
        let controller = MainWindowController(initialFolder: folder)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        guard let window = controller.window else { return }
        // Cascade so a new window doesn't land exactly on the previous one.
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
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
        let newTabItem = NSMenuItem(title: "New Tab",
                                    action: #selector(newTab(_:)),
                                    keyEquivalent: "t")
        newTabItem.target = self
        fileMenu.addItem(newTabItem)
        let closeTabItem = NSMenuItem(title: "Close Tab",
                                      action: #selector(closeTab(_:)),
                                      keyEquivalent: "w")
        closeTabItem.target = self
        fileMenu.addItem(closeTabItem)
        let newFolderItem = NSMenuItem(title: "New Folder",
                                       action: #selector(newFolder(_:)),
                                       keyEquivalent: "n")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        newFolderItem.target = self
        fileMenu.addItem(newFolderItem)
        let open = NSMenuItem(title: "Open",
                              action: #selector(openSelection(_:)),
                              keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        let terminal = NSMenuItem(title: "Open in Terminal",
                                  action: #selector(openTerminal(_:)),
                                  keyEquivalent: "t")
        terminal.keyEquivalentModifierMask = [.command, .option]
        terminal.target = self
        fileMenu.addItem(terminal)

        // Edit menu. Cut/Copy/Paste use the standard selectors with no target, so
        // they route through the responder chain — acting on the address-bar text
        // when it's focused, or on the focused file list otherwise. Rename and
        // Move to Trash are MacSplorer commands the list implements.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Duplicate",
                         action: #selector(HoverTableView.duplicate(_:)), keyEquivalent: "d")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Rename",
                         action: #selector(HoverTableView.renameItem(_:)), keyEquivalent: "")
        let trashItem = NSMenuItem(title: "Move to Trash",
                                   action: #selector(HoverTableView.moveToTrash(_:)),
                                   keyEquivalent: "\u{8}")
        trashItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(trashItem)

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

        let collision = NSMenuItem(title: "Prompt on Name Collision",
                                   action: #selector(togglePromptOnCollision(_:)),
                                   keyEquivalent: "")
        collision.target = self
        viewMenu.addItem(collision)

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

    @objc private func newFolder(_ sender: Any?) {
        keyController?.makeNewFolder()
    }

    @objc private func openTerminal(_ sender: Any?) {
        keyController?.openInTerminal()
    }

    @objc private func toggleHiddenFiles(_ sender: Any?) {
        Preferences.shared.showHiddenFiles.toggle()
        windowControllers.forEach { $0.applyPreferences() }
    }

    @objc private func toggleSingleClick(_ sender: Any?) {
        Preferences.shared.singleClickToOpen.toggle()
        windowControllers.forEach { $0.applyPreferences() }
    }

    @objc private func togglePromptOnCollision(_ sender: Any?) {
        Preferences.shared.promptOnCollision.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = Preferences.shared.showHiddenFiles ? .on : .off
        case #selector(toggleSingleClick(_:)):
            menuItem.state = Preferences.shared.singleClickToOpen ? .on : .off
        case #selector(togglePromptOnCollision(_:)):
            menuItem.state = Preferences.shared.promptOnCollision ? .on : .off
        case #selector(openTerminal(_:)):
            return keyController?.canOpenInTerminal ?? false
        default:
            break
        }
        return true
    }
}
