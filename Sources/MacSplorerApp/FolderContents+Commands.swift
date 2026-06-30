import AppKit
import MacSplorerCore
import UniformTypeIdentifiers

// MARK: - File-operation commands (shared by the list and the grid)

extension FolderContents {
    func copySelectedItems() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        Clipboard.shared.set(urls, operation: .copy)
    }

    func cutSelectedItems() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        Clipboard.shared.set(urls, operation: .cut)
    }

    func pasteIntoFolder() {
        guard let folder else { return }
        let (urls, move) = Clipboard.shared.pasteSource()
        guard !urls.isEmpty else { return }
        performTransfer(urls, into: folder, move: move, selectLanded: true)
        if move { Clipboard.shared.clearAfterMove() }
    }

    func trashSelectedItems() {
        let urls = selectedURLs()
        guard !urls.isEmpty, let folder else { return }
        for url in urls {
            do { _ = try FileOperations.moveToTrash(url) } catch { NSSound.beep() }
        }
        finishMutation(affected: [folder])
    }

    func duplicateSelectedItems() {
        let urls = selectedURLs()
        guard !urls.isEmpty, let folder else { return }
        var names: [String] = []
        for url in urls {
            do { names.append(try FileOperations.copy(url, into: folder).lastPathComponent) }
            catch { NSSound.beep() }
        }
        finishMutation(affected: [folder], selecting: names)
    }

    func renameSelectedItem() {
        let rows = (presenter?.selectedIndexes ?? []).filter { $0 < items.count }.sorted()
        guard let row = rows.first else { return }
        // Return on ".." goes up rather than renaming (Windows-style).
        if items[row].isParentLink { openItem(items[row]); return }
        beginRenameDeferred(named: items[row].name)
    }

    func revealSelection() {
        let urls = selectedURLs()
        if urls.isEmpty {
            if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func copySelectionPaths() {
        let urls = selectedURLs()
        let paths = urls.isEmpty ? (folder.map { [$0.path] } ?? []) : urls.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func openSelectionInTerminal() {
        guard let target = singleSelectedFolderURLForTerminal() ?? folder else { return }
        Shell.openInTerminal(target)
    }

    private func singleSelectedFolderURLForTerminal() -> URL? {
        let rows = (presenter?.selectedIndexes ?? []).filter { $0 < items.count }
        guard rows.count == 1, let row = rows.first else { return nil }
        let item = items[row]
        return (item.isDirectory && !item.isPackage) ? item.url : nil
    }
}

// MARK: - Inline-rename orchestration + create-then-name flow

extension FolderContents {
    /// The reliable way to start an inline rename (menu, keyboard, post-creation):
    /// run **only in the default run-loop mode** so a still-tracking context menu
    /// can't start the edit mid-teardown, and re-find the row by name in case a
    /// reload reordered things. The active presenter performs the actual edit.
    func beginRenameDeferred(named name: String) {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self,
                  let row = self.items.firstIndex(where: { $0.name == name }) else { return }
            self.presenter?.beginRename(at: row)
        }
    }

    /// Commit an inline rename the presenter just finished. Returns whether the
    /// file was actually renamed (false → the presenter should restore the label).
    func commitRename(at index: Int, to newName: String) -> Bool {
        guard items.indices.contains(index) else { return false }
        let item = items[index]
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return false }
        do {
            let dest = try FileOperations.rename(item.url, to: newName)
            finishMutation(affected: [item.url.deletingLastPathComponent()],
                           selecting: [dest.lastPathComponent])
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// Create a new folder in `directory` (the current folder if nil), then select
    /// it and start renaming.
    func makeNewFolder(in directory: URL? = nil) {
        guard let target = directory ?? folder else { return }
        showTargetThenCreate(in: target) {
            try FileOperations.newFolder(in: target).lastPathComponent
        }
    }

    /// Create an empty `untitled.<ext>` document and drop into inline rename.
    func makeNewDocument(_ type: NewDocumentType, in directory: URL? = nil) {
        guard let target = directory ?? folder else { return }
        showTargetThenCreate(in: target) {
            try FileOperations.newFile(
                in: target, named: "\(NewDocument.defaultBaseName).\(type.ext)").lastPathComponent
        }
    }

    /// Write the clipboard URL as a cross-platform `.url` Internet Shortcut.
    func makeInternetShortcut(in directory: URL? = nil) {
        guard let target = directory ?? folder,
              let urlString = NewDocument.clipboardURL() else { NSSound.beep(); return }
        showTargetThenCreate(in: target) {
            let data = NewDocument.internetShortcutData(for: urlString)
            return try FileOperations.newFile(
                in: target, named: "\(NewDocument.defaultBaseName).url", contents: data).lastPathComponent
        }
    }

    private func showTargetThenCreate(in target: URL, _ create: () throws -> String) {
        if !samePath(target, folder) { onOpenFolder?(target) }
        do {
            let name = try create()
            finishMutation(affected: [target], selecting: [name], renameFirst: true)
        } catch {
            NSSound.beep()
        }
    }

    /// Broadcast the affected folders (refreshing this + other windows + the tree),
    /// then select/begin-rename newly-created items in this folder.
    func finishMutation(affected: Set<URL>, selecting names: [String] = [], renameFirst: Bool = false) {
        FolderChange.notify(Array(affected))
        guard !names.isEmpty else { return }
        let wanted = Set(names)
        let rows = items.enumerated()
            .filter { wanted.contains($0.element.url.lastPathComponent) }
            .map(\.offset)
        guard !rows.isEmpty else { return }
        presenter?.selectItems(at: IndexSet(rows))
        if renameFirst, let name = names.first { beginRenameDeferred(named: name) }
    }

    // Folder commands by URL — for the tree's context menu to call.

    func cutFolder(_ url: URL) { Clipboard.shared.set([url], operation: .cut) }
    func copyFolder(_ url: URL) { Clipboard.shared.set([url], operation: .copy) }

    func duplicateFolder(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        do {
            let name = try FileOperations.copy(url, into: parent).lastPathComponent
            finishMutation(affected: [parent], selecting: samePath(parent, folder) ? [name] : [])
        } catch { NSSound.beep() }
    }

    func trashFolder(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        do {
            _ = try FileOperations.moveToTrash(url)
            finishMutation(affected: [parent])
        } catch { NSSound.beep() }
    }

    func renameFolder(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if !samePath(parent, folder) { onOpenFolder?(parent) }
        beginRenameDeferred(named: url.lastPathComponent)
    }
}

// MARK: - Transfer (drag/drop + paste) with collision handling

extension FolderContents {
    private enum CollisionChoice { case keepBoth, replace, stop }

    /// Move by default; copy when ⌥ is held (or when move isn't offered).
    func dragOperation(for info: NSDraggingInfo) -> NSDragOperation {
        let allowed = info.draggingSourceOperationMask
        if NSEvent.modifierFlags.contains(.option) { return allowed.contains(.copy) ? .copy : [] }
        if allowed.contains(.move) { return .move }
        return allowed.contains(.copy) ? .copy : []
    }

    func isSelfOrDescendant(_ url: URL, of directory: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let dir = directory.standardizedFileURL.path
        return dir == target || dir.hasPrefix(target + "/")
    }

    func samePath(_ a: URL?, _ b: URL?) -> Bool {
        a?.standardizedFileURL.path == b?.standardizedFileURL.path
    }

    /// Copy or move `urls` into `destination`, resolving name collisions per the
    /// user's preference (silent keep-both, or a Finder-style prompt), then refresh.
    func performTransfer(_ urls: [URL], into destination: URL, move: Bool, selectLanded: Bool) {
        var landed: [String] = []
        var affected: Set<URL> = [destination]
        var applyToAll: CollisionChoice?
        var failure: (name: String, error: Error)?
        let ask = Preferences.shared.promptOnCollision

        for url in urls {
            if isSelfOrDescendant(url, of: destination) { continue }
            let target = destination.appendingPathComponent(url.lastPathComponent)
            let sameParent = samePath(url.deletingLastPathComponent(), destination)
            let collides = !sameParent && FileManager.default.fileExists(atPath: target.path)

            var choice: CollisionChoice = .keepBoth
            if collides {
                if !ask {
                    choice = .keepBoth
                } else if let all = applyToAll {
                    choice = all
                } else {
                    let result = askCollision(name: url.lastPathComponent, in: destination,
                                              multiple: urls.count > 1)
                    if result.applyToAll { applyToAll = result.choice }
                    choice = result.choice
                }
            }
            if choice == .stop { break }

            do {
                switch choice {
                case .keepBoth:
                    let dest = move ? try FileOperations.move(url, into: destination)
                                    : try FileOperations.copy(url, into: destination)
                    landed.append(dest.lastPathComponent)
                case .replace:
                    _ = try? FileOperations.moveToTrash(target)
                    let dest = move ? try FileOperations.move(url, to: target)
                                    : try FileOperations.copy(url, to: target)
                    landed.append(dest.lastPathComponent)
                case .stop:
                    break
                }
                if move { affected.insert(url.deletingLastPathComponent()) }
            } catch {
                NSSound.beep()
                if failure == nil { failure = (url.lastPathComponent, error) }
            }
        }
        finishMutation(affected: affected, selecting: selectLanded ? landed : [])
        if let failure { reportTransferFailure(failure.name, error: failure.error, moving: move) }
    }

    /// Surface a copy/move failure (out of space, permissions, …) instead of just
    /// the beep — the error's own message is usually clear ("not enough space…").
    private func reportTransferFailure(_ name: String, error: Error, moving: Bool) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t \(moving ? "move" : "copy") “\(name)”."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func askCollision(name: String, in destination: URL,
                              multiple: Bool) -> (choice: CollisionChoice, applyToAll: Bool) {
        let alert = NSAlert()
        alert.messageText = "An item named “\(name)” already exists in “\(destination.lastPathComponent)”."
        alert.informativeText = "Keep both items, replace the existing one, or cancel?"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        var checkbox: NSButton?
        if multiple {
            let box = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
            box.sizeToFit()
            alert.accessoryView = box
            checkbox = box
        }
        let response = alert.runModal()
        let applyToAll = checkbox?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.keepBoth, applyToAll)
        case .alertSecondButtonReturn: return (.replace, applyToAll)
        default: return (.stop, applyToAll)
        }
    }
}

// MARK: - File promises (drags from Outlook, Mail, Photos, Messages, …)

extension FolderContents {
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// The drag types that signal promised files, for `registerForDraggedTypes`.
    static var promiseDragTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// File-promise receivers on the drag pasteboard. Apps like Outlook/Mail/Photos
    /// drag out *promised* files — there's no file yet; the source writes it only
    /// once a destination accepts the drop (which is why a plain file-URL read,
    /// like ours was, comes back empty and the drop silently fails).
    func promiseReceivers(from info: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
    }

    /// Accept promised files: have each source write its file into `destination`
    /// (off the main thread), then refresh + select what landed.
    func receivePromisedFiles(_ receivers: [NSFilePromiseReceiver], into destination: URL) {
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:],
                                          operationQueue: Self.promiseQueue) { [weak self] url, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if error != nil { NSSound.beep(); return }
                    self.finishMutation(
                        affected: [destination],
                        selecting: self.samePath(destination, self.folder) ? [url.lastPathComponent] : [])
                }
            }
        }
    }
}

// MARK: - Right-button drag (Explorer-style Copy/Move-on-drop menu)

/// Captured drop intent for a Copy/Move menu item.
final class RightDropInfo: NSObject {
    let urls: [URL]
    let destination: URL
    let move: Bool
    init(urls: [URL], destination: URL, move: Bool) {
        self.urls = urls; self.destination = destination; self.move = move
    }
}

extension FolderContents {
    /// Present the Copy Here / Move Here / Cancel menu for a right-drag drop. The
    /// default (bold, under the cursor) is the *opposite* of what a left-drag would
    /// do here — copy on the same volume, move across volumes — mirroring Explorer.
    func showRightDropMenu(urls: [URL], into destination: URL, at point: NSPoint, in view: NSView) {
        guard !urls.isEmpty else { return }
        let crossVolume = !sameVolume(urls[0], as: destination)

        let menu = NSMenu()
        menu.autoenablesItems = false   // keep "Cancel" (no action) from greying out
        let copyItem = NSMenuItem(title: "Copy Here",
                                  action: #selector(performRightDrop(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = RightDropInfo(urls: urls, destination: destination, move: false)
        let moveItem = NSMenuItem(title: "Move Here",
                                  action: #selector(performRightDrop(_:)), keyEquivalent: "")
        moveItem.target = self
        moveItem.representedObject = RightDropInfo(urls: urls, destination: destination, move: true)

        let defaultItem = crossVolume ? moveItem : copyItem
        defaultItem.attributedTitle = NSAttributedString(
            string: defaultItem.title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])

        menu.addItem(copyItem)
        menu.addItem(moveItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cancel", action: nil, keyEquivalent: ""))
        menu.popUp(positioning: defaultItem, at: point, in: view)
    }

    @objc func performRightDrop(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? RightDropInfo else { return }
        performTransfer(info.urls, into: info.destination, move: info.move, selectLanded: true)
    }

    /// Whether `a` and `b` live on the same mounted volume.
    private func sameVolume(_ a: URL, as b: URL) -> Bool {
        let av = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let bv = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let av, let bv else { return true }   // unknown → treat as same (copy default)
        return av.isEqual(bv)
    }
}

// MARK: - Context menu (identical in the list, the grid, and the tree folders)

extension FolderContents {
    /// Build the right-click menu for the item at `clickedIndex` (-1 for empty
    /// space → acts on the current folder). `target` receives the action selectors
    /// (the presenter, which forwards to the ctx* handlers here).
    func contextMenu(clickedIndex index: Int, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if index < 0 || index >= items.count {
            if let folder {
                menu.addItem(NewDocument.submenuItem(for: folder, target: target,
                                                     action: #selector(ctxNew(_:))))
            }
            add(menu, "Paste", #selector(ctxPaste(_:)), target, enabled: Clipboard.shared.canPaste)
            menu.addItem(.separator())
            add(menu, "Open in Terminal", #selector(ctxTerminal(_:)), target)
            add(menu, "Reveal in Finder", #selector(ctxReveal(_:)), target)
            add(menu, "Copy Path", #selector(ctxCopyPath(_:)), target)
            return menu
        }
        let item = items[index]
        let isFolder = item.isDirectory && !item.isPackage
        add(menu, "Open", #selector(ctxOpen(_:)), target)
        if isFolder {
            add(menu, "Open in New Window", #selector(ctxOpenInNewWindow(_:)), target)
            add(menu, "Open in Terminal", #selector(ctxTerminal(_:)), target)
            menu.addItem(NewDocument.submenuItem(for: item.url, target: target,
                                                 action: #selector(ctxNew(_:))))
        } else {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = OpenWith.submenu(for: item.url, target: target,
                                                openAction: #selector(ctxOpenWithApp(_:)),
                                                setDefaultAction: #selector(ctxSetDefaultApp(_:)))
            menu.addItem(openWith)
        }
        menu.addItem(.separator())
        add(menu, "Cut", #selector(ctxCut(_:)), target)
        add(menu, "Copy", #selector(ctxCopy(_:)), target)
        add(menu, "Duplicate", #selector(ctxDuplicate(_:)), target)
        menu.addItem(.separator())
        add(menu, "Rename", #selector(ctxRename(_:)), target)
        add(menu, "Move to Trash", #selector(ctxTrash(_:)), target)
        menu.addItem(.separator())
        add(menu, "Reveal in Finder", #selector(ctxReveal(_:)), target)
        add(menu, "Copy Path", #selector(ctxCopyPath(_:)), target)
        if isFolder {
            menu.addItem(.separator())
            if Favorites.shared.contains(item.url) {
                add(menu, "Remove from Favorites", #selector(ctxRemoveFavorite(_:)), target)
            } else {
                add(menu, "Add to Favorites", #selector(ctxAddFavorite(_:)), target)
            }
            if FolderContextMenu.isEjectableVolume(item.url) {
                menu.addItem(.separator())
                add(menu, "Eject", #selector(ctxEject(_:)), target)
            }
        }
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     _ target: AnyObject, enabled: Bool = true) {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = target
        menuItem.isEnabled = enabled
        menu.addItem(menuItem)
    }

    @objc func ctxNew(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? NewMenuChoice else { return }
        switch choice.kind {
        case .folder: makeNewFolder(in: choice.directory)
        case .document(let type): makeNewDocument(type, in: choice.directory)
        case .internetShortcut: makeInternetShortcut(in: choice.directory)
        }
    }

    @objc func ctxOpen(_ sender: Any?) { openSelected() }
    @objc func ctxCut(_ sender: Any?) { cutSelectedItems() }
    @objc func ctxCopy(_ sender: Any?) { copySelectedItems() }
    @objc func ctxPaste(_ sender: Any?) { pasteIntoFolder() }
    @objc func ctxDuplicate(_ sender: Any?) { duplicateSelectedItems() }
    @objc func ctxRename(_ sender: Any?) { renameSelectedItem() }
    @objc func ctxTrash(_ sender: Any?) { trashSelectedItems() }
    @objc func ctxReveal(_ sender: Any?) { revealSelection() }
    @objc func ctxCopyPath(_ sender: Any?) { copySelectionPaths() }
    @objc func ctxTerminal(_ sender: Any?) { openSelectionInTerminal() }

    @objc func ctxAddFavorite(_ sender: Any?) {
        if let url = selectedFolderForFavorite() { Favorites.shared.add(url) }
    }
    @objc func ctxRemoveFavorite(_ sender: Any?) {
        if let url = selectedFolderForFavorite() { Favorites.shared.remove(url) }
    }
    @objc func ctxEject(_ sender: Any?) {
        if let url = selectedFolderForFavorite() { FolderContextMenu.eject(url) }
    }
    @objc func ctxOpenInNewWindow(_ sender: Any?) {
        if let url = selectedFolderForFavorite() {
            (NSApp.delegate as? AppDelegate)?.openWindow(showing: url)
        }
    }
    @objc func ctxOpenWithApp(_ sender: NSMenuItem) {
        let urls = selectedURLs()
        if let appURL = sender.representedObject as? URL {
            OpenWith.open(urls, with: appURL)
        } else {
            OpenWith.openWithOtherApp(urls)
        }
    }

    /// Make `sender`'s app the system default for the selected file's kind
    /// (Finder's "Change All"), then refresh so icons update.
    @objc func ctxSetDefaultApp(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL,
              let fileURL = selectedURLs().first else { return }
        let type = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: fileURL.pathExtension)
        guard let type else { NSSound.beep(); return }
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { [weak self] error in
            DispatchQueue.main.async {
                if error != nil { NSSound.beep(); return }
                if let folder = self?.folder { FolderChange.notify([folder]) }
            }
        }
    }

    private func selectedFolderForFavorite() -> URL? {
        let rows = (presenter?.selectedIndexes ?? []).filter { $0 < items.count }
        guard rows.count == 1, let row = rows.first else { return nil }
        let item = items[row]
        return (item.isDirectory && !item.isPackage) ? item.url : nil
    }
}
