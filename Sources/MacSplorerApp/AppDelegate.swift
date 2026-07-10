import AppKit
import MacSplorerCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var windowControllers: [MainWindowController] = []
    private var cascadePoint = NSPoint.zero
    private let applyLayoutsMenu = NSMenu(title: "Apply Window Layout")
    private let deleteLayoutsMenu = NSMenu(title: "Delete Window Layout")
    private let columnsMenu = NSMenu(title: "Columns")
    private var internetShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't let macOS auto-insert its own icon-bearing "Enter Full Screen"
        // item into the View menu — its image column misaligns the other items.
        // We add a clean, icon-less one ourselves below.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        NSApp.mainMenu = makeMainMenu()
        installInternetShortcutHotkey()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        // Restore the last arrangement (reopen each window at its saved frame),
        // or a single default window if there's no saved session.
        let frames = WindowLayoutStore.shared.lastSessionFrames
        if frames.isEmpty {
            newWindow(nil)
        } else {
            frames.forEach { openWindow(frame: $0) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Set once quitting begins. The full arrangement is snapshotted here, before
    /// windows tear down; without this flag each window's `onClose` would re-run
    /// `saveSession()` during teardown, overwriting the snapshot with an ever-
    /// shrinking set and leaving only the last window to restore.
    private var isTerminating = false

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
        isTerminating = true
    }

    private var isRaisingAll = false

    /// When the "raise all together" preference is on, bringing any one of our
    /// windows forward pulls the rest forward too. We defer to the next run-loop
    /// tick — reordering synchronously *inside* the key-change / order-front
    /// processing reenters and corrupts the stacking (new windows land behind,
    /// the reorder doesn't take). `arrangeInFront` is the standard "bring all of
    /// this app's windows forward"; it leaves the key window on top.
    @objc private func windowBecameKey(_ note: Notification) {
        guard Preferences.shared.raiseAllWindowsTogether, !isRaisingAll,
              let keyWindow = note.object as? NSWindow,
              windowControllers.contains(where: { $0.window === keyWindow }) else { return }
        isRaisingAll = true
        DispatchQueue.main.async { [weak self] in
            NSApp.arrangeInFront(nil)
            self?.isRaisingAll = false
        }
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

    /// Open a new window, optionally navigated to `folder`. With an explicit
    /// `frame` (restore / apply-layout) the window takes that frame; otherwise it
    /// inherits the launching window's size (cascaded), or cascades from default.
    func openWindow(showing folder: URL? = nil, frame: NSRect? = nil) {
        let controller = MainWindowController(initialFolder: folder)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
            self.saveSession()
        }
        controller.onFrameChanged = { [weak self] in self?.saveSession() }
        windowControllers.append(controller)
        guard let window = controller.window else { return }
        if let frame {
            window.setFrame(frame, display: false)
        } else if let source = NSApp.keyWindow,
                  windowControllers.contains(where: { $0.window === source }), source !== window {
            // Match the launching window's size, offset so it doesn't land on it.
            var f = source.frame
            f.origin.x += 24
            f.origin.y -= 24
            window.setFrame(f, display: false)
        } else {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        saveSession()
    }

    /// Snapshot the current window arrangement for restore-on-restart. Never
    /// saves an empty set, so quitting via closing the last window keeps the
    /// prior arrangement.
    private func saveSession() {
        guard !isTerminating else { return }
        let frames = windowControllers.compactMap { $0.window?.frame }
        guard !frames.isEmpty else { return }
        WindowLayoutStore.shared.lastSessionFrames = frames
    }

    // MARK: Window layouts

    @objc private func saveWindowLayout(_ sender: Any?) {
        guard !windowControllers.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Save Window Layout"
        alert.informativeText = "Name this arrangement of \(windowControllers.count) window(s). Reusing a name replaces it."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.placeholderString = "Layout name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let frames = windowControllers.compactMap { $0.window?.frame }
        WindowLayoutStore.shared.save(name: name, frames: frames)
    }

    @objc private func applyLayoutItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let layout = WindowLayoutStore.shared.layout(named: name) else { return }
        applyLayout(layout)
    }

    @objc private func deleteLayoutItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        WindowLayoutStore.shared.delete(name: name)
    }

    /// Reproduce the saved arrangement: move existing windows to the saved
    /// frames, open windows for any extra frames, and close any windows beyond
    /// the layout's count.
    private func applyLayout(_ layout: WindowLayout) {
        let frames = layout.frames
        // Position the windows we already have.
        for index in 0..<min(frames.count, windowControllers.count) {
            windowControllers[index].window?.setFrame(frames[index], display: true, animate: false)
        }
        // Open windows for any extra frames.
        if frames.count > windowControllers.count {
            let base = windowControllers.count
            for index in base..<frames.count { openWindow(frame: frames[index]) }
        }
        // Close any windows beyond the layout.
        else if windowControllers.count > frames.count {
            let extras = Array(windowControllers[frames.count...])
            extras.forEach { $0.window?.close() }
        }
        windowControllers.forEach { $0.window?.makeKeyAndOrderFront(nil) }
    }

    /// Toggle a details-pane column on/off (from the View ▸ Columns submenu or the
    /// header right-click menu), applying the change to every open pane.
    func toggleDetailsColumn(_ id: String) {
        guard id != "name" else { return }
        var columns = Preferences.shared.detailsColumns
        if columns.contains(id) {
            columns.removeAll { $0 == id }
        } else {
            columns = DetailsColumnSpec.insertInOrder(id, into: columns)
        }
        Preferences.shared.detailsColumns = columns
        windowControllers.forEach { $0.applyColumns() }
    }

    @objc private func toggleColumnItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        toggleDetailsColumn(id)
    }

    // MARK: View mode (list / icon grid)

    /// Switch the key window to the details list (view mode is per-window).
    func chooseListView() {
        keyController?.setViewMode("list", iconSize: nil)
    }

    /// Switch the key window to the icon grid at `size` (view mode is per-window).
    func chooseIconView(size: IconSize) {
        keyController?.setViewMode("icon", iconSize: size.rawValue)
    }

    @objc private func showAsList(_ sender: Any?) { chooseListView() }
    @objc private func showAsSmallIcons(_ sender: Any?) { chooseIconView(size: .small) }
    @objc private func showAsLargeIcons(_ sender: Any?) { chooseIconView(size: .large) }

    /// Rebuild the Apply / Delete / Columns submenus when they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === columnsMenu {
            menu.removeAllItems()
            let visible = Set(Preferences.shared.detailsColumns)
            for spec in DetailsColumnSpec.toggleable {
                let item = NSMenuItem(title: spec.title,
                                      action: #selector(toggleColumnItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = spec.id
                item.state = visible.contains(spec.id) ? .on : .off
                menu.addItem(item)
            }
            return
        }
        let isApply = (menu === applyLayoutsMenu)
        guard isApply || menu === deleteLayoutsMenu else { return }
        menu.removeAllItems()
        let layouts = WindowLayoutStore.shared.layouts()
        guard !layouts.isEmpty else {
            let empty = NSMenuItem(title: "No Saved Layouts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for layout in layouts {
            let item = NSMenuItem(
                title: layout.name,
                action: isApply ? #selector(applyLayoutItem(_:)) : #selector(deleteLayoutItem(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = layout.name
            menu.addItem(item)
        }
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
        // New ▸ — mirrors the right-click New submenu; each item acts on the
        // current folder of the frontmost window. Static so ⌘⇧N keeps working.
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        let newMenu = NSMenu(title: "New")

        let folderItem = NSMenuItem(title: "Folder", action: #selector(newFolder(_:)), keyEquivalent: "n")
        folderItem.keyEquivalentModifierMask = [.command, .shift]
        folderItem.target = self
        let folderIcon = NSImage(named: NSImage.folderName)
        folderIcon?.size = NSSize(width: 16, height: 16)
        folderItem.image = folderIcon
        newMenu.addItem(folderItem)

        newMenu.addItem(.separator())
        for type in NewDocument.types {
            let item = NSMenuItem(title: type.title, action: #selector(newDocumentFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type
            item.image = NewDocument.icon(forExtension: type.ext)
            newMenu.addItem(item)
        }

        newMenu.addItem(.separator())
        // Internet Shortcut from the clipboard URL (also Fn+Shift+S / Fn+Shift+U,
        // via a key monitor since Fn isn't a standard menu modifier).
        let shortcutItem = NSMenuItem(title: "Internet Shortcut",
                                      action: #selector(newInternetShortcut(_:)), keyEquivalent: "")
        shortcutItem.target = self
        shortcutItem.image = NewDocument.icon(forExtension: "url")
        newMenu.addItem(shortcutItem)

        newItem.submenu = newMenu
        fileMenu.addItem(newItem)
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

        fileMenu.addItem(.separator())
        // Order matches the context menus: Calculate Folder Sizes… then Get Info.
        let calcSizes = NSMenuItem(title: "Calculate Folder Sizes…",
                                   action: #selector(calculateFolderSizes(_:)),
                                   keyEquivalent: "")
        calcSizes.target = self
        fileMenu.addItem(calcSizes)
        let getInfo = NSMenuItem(title: "Get Info",
                                 action: #selector(getInfoForSelection(_:)),
                                 keyEquivalent: "i")
        getInfo.target = self
        fileMenu.addItem(getInfo)

        // Edit menu. Cut/Copy/Paste use the standard selectors with no target, so
        // they route through the responder chain — acting on the address-bar text
        // when it's focused, or on the focused file list otherwise. Rename and
        // Move to Trash are MacSplorer commands the list implements.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        // Undo/Redo + Select All route through the responder chain (the focused
        // text field's field editor). Without these items the ⌘Z / ⌘A key
        // equivalents never reach the FAB.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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

        let upItem = NSMenuItem(title: "Show Up Item (..)",
                                action: #selector(toggleParentItem(_:)),
                                keyEquivalent: "")
        upItem.target = self
        viewMenu.addItem(upItem)

        let startupDisk = NSMenuItem(title: "Show Startup Disk",
                                     action: #selector(toggleStartupDiskRoot(_:)),
                                     keyEquivalent: "")
        startupDisk.target = self
        viewMenu.addItem(startupDisk)

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

        let skipCloud = NSMenuItem(title: "Skip Cloud Storage When Scanning",
                                   action: #selector(toggleSkipCloud(_:)),
                                   keyEquivalent: "")
        skipCloud.target = self
        viewMenu.addItem(skipCloud)

        let raiseAll = NSMenuItem(title: "Raise All Windows Together",
                                  action: #selector(toggleRaiseAll(_:)),
                                  keyEquivalent: "")
        raiseAll.target = self
        viewMenu.addItem(raiseAll)

        // Columns ▸ — a checkmark per optional details-pane column. Rebuilds its
        // contents each time it opens (via menuNeedsUpdate).
        let columnsItem = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
        columnsMenu.delegate = self
        columnsItem.submenu = columnsMenu
        viewMenu.addItem(columnsItem)

        // Right-pane view (mirrors the status-bar control): list / small / large.
        viewMenu.addItem(.separator())
        let asList = NSMenuItem(title: "as List", action: #selector(showAsList(_:)), keyEquivalent: "1")
        asList.target = self
        viewMenu.addItem(asList)
        let asSmall = NSMenuItem(title: "as Small Icons", action: #selector(showAsSmallIcons(_:)), keyEquivalent: "2")
        asSmall.target = self
        viewMenu.addItem(asSmall)
        let asLarge = NSMenuItem(title: "as Large Icons", action: #selector(showAsLargeIcons(_:)), keyEquivalent: "3")
        asLarge.target = self
        viewMenu.addItem(asLarge)

        viewMenu.addItem(.separator())
        let showFavorites = NSMenuItem(title: "Show Favorites",
                                       action: #selector(toggleFavorites(_:)),
                                       keyEquivalent: "")
        showFavorites.target = self
        viewMenu.addItem(showFavorites)

        let showMenuBar = NSMenuItem(title: "Show Menu Bar",
                                     action: #selector(toggleMenuBar(_:)),
                                     keyEquivalent: "")
        showMenuBar.target = self
        viewMenu.addItem(showMenuBar)

        viewMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: "Enter Full Screen",
                                    action: #selector(NSWindow.toggleFullScreen(_:)),
                                    keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command] // routes to the key window
        viewMenu.addItem(fullScreen)

        // Saved window layouts: capture the current window arrangement by name,
        // and switch to a saved one. These live in View (not Window) because the
        // Window menu is macOS-owned; the Apply/Delete submenus rebuild their
        // contents each time they open (via menuNeedsUpdate).
        viewMenu.addItem(.separator())
        let save = NSMenuItem(title: "Save Window Layout…",
                              action: #selector(saveWindowLayout(_:)), keyEquivalent: "")
        save.target = self
        viewMenu.addItem(save)

        let applyItem = NSMenuItem(title: "Apply Window Layout", action: nil, keyEquivalent: "")
        applyLayoutsMenu.delegate = self
        applyItem.submenu = applyLayoutsMenu
        viewMenu.addItem(applyItem)

        let deleteItem = NSMenuItem(title: "Delete Window Layout", action: nil, keyEquivalent: "")
        deleteLayoutsMenu.delegate = self
        deleteItem.submenu = deleteLayoutsMenu
        viewMenu.addItem(deleteItem)

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

        windowMenu.addItem(.separator())
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    @objc private func openSelection(_ sender: Any?) {
        keyController?.openSelection()
    }

    @objc private func newFolder(_ sender: Any?) {
        keyController?.makeNewFolder()
    }

    @objc private func newInternetShortcut(_ sender: Any?) {
        keyController?.makeInternetShortcut()
    }

    @objc private func newDocumentFromMenu(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? NewDocumentType else { return }
        keyController?.makeNewDocument(type)
    }

    /// Fire "New Internet Shortcut" on Fn+Shift+S or Fn+Shift+U while MacSplorer is
    /// focused (and not editing text). Done with a key monitor because Fn (Globe)
    /// isn't a usable menu-item modifier. A *global* Fn+Shift+S macro will still
    /// grab the key first; Fn+Shift+U is the reliable fallback.
    private func installInternetShortcutHotkey() {
        internetShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let window = NSApp.keyWindow, window.firstResponder is NSText { return event } // typing
            let flags = event.modifierFlags
            let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
            let isS = event.keyCode == 1, isU = event.keyCode == 32   // S / U
            guard flags.contains(.function), flags.contains(.shift),
                  flags.isDisjoint(with: blocked), isS || isU else { return event }
            self.keyController?.makeInternetShortcut()
            return nil   // consume
        }
    }

    @objc private func openTerminal(_ sender: Any?) {
        keyController?.openInTerminal()
    }

    @objc private func getInfoForSelection(_ sender: Any?) {
        keyController?.getInfoForSelection()
    }

    @objc private func calculateFolderSizes(_ sender: Any?) {
        keyController?.calculateFolderSizes()
    }

    /// Show a Get Info panel for `url` (retained until the user closes it). A
    /// second request for the same item just refocuses the open panel.
    private var infoWindows: [GetInfoWindowController] = []
    func presentGetInfo(for url: URL) {
        if let existing = infoWindows.first(where: { $0.window?.title == "\(url.lastPathComponent) Info" }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = GetInfoWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in
            self?.infoWindows.removeAll { $0 === controller }
        }
        infoWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Start a folder-size scan on a specific folder (a context-menu "Calculate
    /// Folder Sizes…" on the clicked folder, vs. the File-menu entry's current one),
    /// running in and reported by the front window.
    func calculateFolderSizes(for url: URL) {
        keyController?.calculateFolderSizes(root: url)
    }

    /// Show a scan's results in a new window (retained until the user closes it).
    private var resultsWindows: [ScanResultsWindowController] = []
    func presentScanResults(_ root: SizeNode, onOpenFolder: @escaping (URL) -> Void) {
        let controller = ScanResultsWindowController(root: root)
        controller.onOpenFolder = onOpenFolder
        controller.onClose = { [weak self, weak controller] in
            self?.resultsWindows.removeAll { $0 === controller }
        }
        resultsWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleHiddenFiles(_ sender: Any?) {
        Preferences.shared.showHiddenFiles.toggle()
        windowControllers.forEach { $0.applyPreferences() }
    }

    @objc private func toggleSingleClick(_ sender: Any?) {
        Preferences.shared.singleClickToOpen.toggle()
        windowControllers.forEach { $0.applyPreferences() }
    }

    @objc private func toggleParentItem(_ sender: Any?) {
        Preferences.shared.showParentItem.toggle()
        windowControllers.forEach { $0.applyPreferences() }
    }

    @objc private func toggleStartupDiskRoot(_ sender: Any?) {
        Preferences.shared.showStartupDiskRoot.toggle()
        windowControllers.forEach { $0.applyPreferences() }
    }

    @objc private func togglePromptOnCollision(_ sender: Any?) {
        Preferences.shared.promptOnCollision.toggle()
    }

    @objc private func toggleSkipCloud(_ sender: Any?) {
        Preferences.shared.skipCloudInSizeScan.toggle()
    }

    @objc private func toggleRaiseAll(_ sender: Any?) {
        Preferences.shared.raiseAllWindowsTogether.toggle()
    }

    @objc private func toggleFavorites(_ sender: Any?) {
        Preferences.shared.showFavorites.toggle()
        windowControllers.forEach { $0.applyPreferences() }
    }

    @objc private func toggleMenuBar(_ sender: Any?) {
        Preferences.shared.showMenuBar.toggle()
        windowControllers.forEach { $0.applyMenuBarVisibility() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = Preferences.shared.showHiddenFiles ? .on : .off
        case #selector(toggleSingleClick(_:)):
            menuItem.state = Preferences.shared.singleClickToOpen ? .on : .off
        case #selector(toggleParentItem(_:)):
            menuItem.state = Preferences.shared.showParentItem ? .on : .off
        case #selector(toggleStartupDiskRoot(_:)):
            menuItem.state = Preferences.shared.showStartupDiskRoot ? .on : .off
        case #selector(togglePromptOnCollision(_:)):
            menuItem.state = Preferences.shared.promptOnCollision ? .on : .off
        case #selector(toggleSkipCloud(_:)):
            menuItem.state = Preferences.shared.skipCloudInSizeScan ? .on : .off
        case #selector(toggleRaiseAll(_:)):
            menuItem.state = Preferences.shared.raiseAllWindowsTogether ? .on : .off
        case #selector(toggleFavorites(_:)):
            menuItem.state = Preferences.shared.showFavorites ? .on : .off
        case #selector(toggleMenuBar(_:)):
            menuItem.state = Preferences.shared.showMenuBar ? .on : .off
        case #selector(showAsList(_:)):
            menuItem.state = keyController?.activeViewMode?.mode == "list" ? .on : .off
        case #selector(showAsSmallIcons(_:)):
            let active = keyController?.activeViewMode
            menuItem.state = (active?.mode == "icon" && active?.iconSize == "small") ? .on : .off
        case #selector(showAsLargeIcons(_:)):
            let active = keyController?.activeViewMode
            menuItem.state = (active?.mode == "icon" && active?.iconSize == "large") ? .on : .off
        case #selector(openTerminal(_:)):
            return keyController?.canOpenInTerminal ?? false
        case #selector(newInternetShortcut(_:)):
            return NewDocument.clipboardURL() != nil
        case #selector(closeTab(_:)):
            // Only with real tabs — never close the window via "Close Tab".
            return (keyController?.tabCount ?? 0) > 1
        default:
            break
        }
        return true
    }
}
