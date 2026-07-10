import AppKit
import MacSplorerCore

/// One action in the shared folder context menu (right-clicking a folder in the
/// tree or the Favorites pane). Carried as a menu item's `representedObject`.
final class FolderMenuAction: NSObject {
    enum Kind {
        case open, openInNewWindow, openInTerminal
        case cut, copy, duplicate, rename, trash
        case reveal, copyPath, addFavorite, removeFavorite
        case eject, getInfo, calculateSizes
    }
    let kind: Kind
    let url: URL
    init(_ kind: Kind, _ url: URL) { self.kind = kind; self.url = url }
}

/// The standard folder context menu — one definition shared by the folder tree
/// and the Favorites pane (and kept in step with the details pane's). Build it
/// with `make`; dispatch a clicked item with `perform` / `performNew`.
enum FolderContextMenu {
    /// Build the menu for `url`. Plain items route to `action` (carrying a
    /// `FolderMenuAction`); the New ▸ submenu routes to `newAction` (carrying a
    /// `NewMenuChoice`, via `NewDocument`).
    static func make(for url: URL, target: AnyObject,
                     action: Selector, newAction: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ kind: FolderMenuAction.Kind) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = FolderMenuAction(kind, url)
            menu.addItem(item)
        }
        add("Open", .open)
        add("Open in New Window", .openInNewWindow)
        add("Open in Terminal", .openInTerminal)
        menu.addItem(NewDocument.submenuItem(for: url, target: target, action: newAction))
        menu.addItem(.separator())
        add("Cut", .cut)
        add("Copy", .copy)
        add("Duplicate", .duplicate)
        menu.addItem(.separator())
        add("Rename", .rename)
        add("Move to Trash", .trash)
        menu.addItem(.separator())
        add("Reveal in Finder", .reveal)
        add("Copy Path", .copyPath)
        menu.addItem(.separator())
        if Favorites.shared.contains(url) {
            add("Remove from Favorites", .removeFavorite)
        } else {
            add("Add to Favorites", .addFavorite)
        }
        if isEjectableVolume(url) {
            menu.addItem(.separator())
            add("Eject", .eject)
        }
        menu.addItem(.separator())
        add("Calculate Folder Sizes…", .calculateSizes)
        add("Get Info", .getInfo)
        return menu
    }

    /// Whether `url` is the mount point of an ejectable volume (a mounted disk,
    /// image, RAM disk, network share — but not the boot disk or a normal folder).
    static func isEjectableVolume(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsRootFileSystemKey]),
              values.volumeIsRootFileSystem != true,
              let volumeRoot = values.volume else { return false }
        return volumeRoot.standardizedFileURL == url.standardizedFileURL
    }

    /// Eject the volume at `url`, reporting a failure (e.g. "in use") in a dialog.
    static func eject(_ url: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t eject “\(url.lastPathComponent)”."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Run a clicked action. `open` shows the folder; `command` performs a file
    /// operation (the host routes it to the model). Everything else is intrinsic.
    static func perform(_ action: FolderMenuAction,
                        open: (URL) -> Void, command: (FolderCommand, URL) -> Void) {
        let url = action.url
        switch action.kind {
        case .open: open(url)
        case .openInNewWindow: (NSApp.delegate as? AppDelegate)?.openWindow(showing: url)
        case .openInTerminal: Shell.openInTerminal(url)
        case .cut: command(.cut, url)
        case .copy: command(.copy, url)
        case .duplicate: command(.duplicate, url)
        case .rename: command(.rename, url)
        case .trash: command(.trash, url)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        case .addFavorite: Favorites.shared.add(url)
        case .removeFavorite: Favorites.shared.remove(url)
        case .eject: eject(url)
        case .getInfo: (NSApp.delegate as? AppDelegate)?.presentGetInfo(for: url)
        case .calculateSizes: (NSApp.delegate as? AppDelegate)?.calculateFolderSizes(for: url)
        }
    }

    /// Run a New ▸ submenu choice.
    static func performNew(_ choice: NewMenuChoice, command: (FolderCommand, URL) -> Void) {
        switch choice.kind {
        case .folder: command(.newFolder, choice.directory)
        case .document(let type): command(.newDocument(type), choice.directory)
        case .internetShortcut: command(.internetShortcut, choice.directory)
        }
    }
}
