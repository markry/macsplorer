import AppKit
import MacSplorerCore
import MacSplorerS3
import UniformTypeIdentifiers

// MARK: - File-operation commands (shared by the list and the grid)

extension FolderContents {
    func copySelectedItems() {
        let urls = selectedURLs()
        Diag.commands.info("copy: urls=\(urls.count) responder=\(Diag.responder(self), privacy: .public)")
        guard !urls.isEmpty else { return }
        Clipboard.shared.set(urls, operation: .copy)
    }

    func cutSelectedItems() {
        let urls = selectedURLs()
        Diag.commands.info("cut: urls=\(urls.count) responder=\(Diag.responder(self), privacy: .public)")
        guard !urls.isEmpty else { return }
        Clipboard.shared.set(urls, operation: .cut)
    }

    /// Paste into a folder that isn't the one on screen — the right-click "Paste
    /// into …" on a folder row, and the same entry in the tree and Favorites. The
    /// pane follows the files in, as a drop onto a folder does, so the result is
    /// visible rather than landing somewhere the user can't see.
    func pasteInto(_ directory: URL) {
        guard accepts(itemsInto: directory) else { NSSound.beep(); return }
        let (urls, move) = Clipboard.shared.pasteSource()
        Diag.commands.info("paste into folder: urls=\(urls.count) move=\(move)")
        guard !urls.isEmpty else { return }
        performTransfer(urls, into: directory, move: move, selectLanded: true)
        if move { Clipboard.shared.clearAfterMove() }
    }

    func pasteIntoFolder() {
        guard let folder, folderAcceptsItems else { NSSound.beep(); return }
        let (urls, move) = Clipboard.shared.pasteSource()
        Diag.commands.info("paste: urls=\(urls.count) move=\(move) responder=\(Diag.responder(self), privacy: .public)")
        guard !urls.isEmpty else { return }
        performTransfer(urls, into: folder, move: move, selectLanded: true)
        if move { Clipboard.shared.clearAfterMove() }
    }

    func trashSelectedItems() {
        let urls = selectedURLs()
        guard !urls.isEmpty, let folder else { return }
        // A remote store has no Trash to move things into, so the same keystroke has
        // to ask what the user meant — see RemoteDelete.
        if urls.contains(where: { !$0.isFileURL }) {
            deleteRemoteItems(urls, reloading: folder)
            return
        }
        for url in urls {
            do { _ = try Providers.provider(for: url).moveToTrash(url) } catch { NSSound.beep() }
        }
        finishMutation(affected: [folder])
    }

    /// Confirm, then delete from a remote provider with progress and a working Stop.
    func deleteRemoteItems(_ urls: [URL], reloading folder: URL) {
        // Ask nothing of a backend that can't delete: offering the choice and then
        // failing on either button is worse than saying so up front.
        guard Providers.provider(for: urls[0]).capabilities.canWrite else {
            reportDeleteFailure(ProviderError.deleteUnsupported(urls[0]))
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let choice = await RemoteDelete.confirm(urls) else { return }
            let progress = ProviderProgress()
            self.onBackgroundWork?(choice == .copyToTrash ? "Copying to Trash" : "Deleting", progress, false)
            let work = Task { @MainActor in
                try await RemoteDelete.perform(urls, choice: choice, progress: progress)
            }
            // Stop has to reach the task, not just set a flag: a provider paging
            // through a huge listing checks the flag only between pages.
            progress.onCancel { work.cancel() }
            let result = await work.result
            self.onBackgroundWorkEnded?()
            self.finishMutation(affected: [folder])
            if case .failure(let error) = result, !(error is CancellationError) {
                self.reportDeleteFailure(error)
            }
        }
    }

    /// Say what went wrong, and that a partial delete really did delete part of it —
    /// the one thing the user can't discover by looking at the dialog.
    private func reportDeleteFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t finish deleting."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func duplicateSelectedItems() {
        let urls = selectedURLs()
        guard !urls.isEmpty, let folder else { return }
        var names: [String] = []
        var affected: Set<URL> = [folder]
        // In Recents there's no folder to put a copy into, so it goes beside the
        // original, as Finder does. Everywhere else the original's folder IS this
        // one, and behaviour is unchanged.
        let besideOriginal = !folderAcceptsItems
        for url in urls {
            let target = besideOriginal ? url.deletingLastPathComponent() : folder
            do {
                let copy = try Providers.provider(for: target).copy(url, into: target)
                if samePath(target, folder) { names.append(copy.lastPathComponent) }
                affected.insert(target)
            } catch { NSSound.beep() }
        }
        finishMutation(affected: affected, selecting: names)
    }

    func renameSelectedItem() {
        let rows = selectedIndexes().sorted()
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
        let rows = selectedIndexes()
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
    func beginRenameDeferred(named name: String, attempt: Int = 0) {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self else { return }
            // A "New…" chosen from a right-click while another app was frontmost
            // brings our window forward but NOT key — so the inline field editor
            // can't take keyboard focus and the "untitled" name isn't editable.
            // Make the app active + window key first, then retry on later runloop
            // ticks (activation is async) until key status settles, capped so a
            // window that never becomes key can't loop forever.
            if let window = self.presenter?.presentingWindow,
               !window.isKeyWindow, attempt < 5 {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                self.beginRenameDeferred(named: name, attempt: attempt + 1)
                return
            }
            guard let row = self.items.firstIndex(where: { $0.name == name }) else {
                Diag.rename.error("beginRenameDeferred: the new item is not in the listing")
                return
            }
            Diag.rename.info("beginRenameDeferred: row=\(row) attempt=\(attempt)")
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
        // A remote rename needs the network: let the edit close now, then reload
        // with the result — the new name on success, the old one (and why) if not.
        // On S3 a file, or a folder with contents, is a copy of everything plus a
        // delete, so a folder asks first (with a count) and both show progress/Stop.
        if !item.url.isFileURL {
            let parent = item.url.deletingLastPathComponent()
            let provider = Providers.provider(for: item.url)
            let isFolder = item.isDirectory && !item.isPackage
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isFolder, let count = try? await provider.peekCount(at: item.url, limit: 1000),
                   count.items > 1 || count.isPartial,
                   !self.confirmRemoteRename(item.url, from: item.name, to: trimmed, count: count) {
                    self.finishMutation(affected: [parent], selecting: [item.name])
                    return
                }
                let progress = ProviderProgress()
                self.onBackgroundWork?("Renaming", progress, true)
                let work = Task { try await provider.renameWithProgress(item.url, to: trimmed, progress: progress) }
                progress.onCancel { work.cancel() }
                let result = await work.result
                self.onBackgroundWorkEnded?()
                switch result {
                case .success(let dest):
                    self.finishMutation(affected: [parent], selecting: [dest.lastPathComponent])
                case .failure(let error):
                    Diag.rename.error("remote rename failed: \(Diag.describe(error), privacy: .public)")
                    self.finishMutation(affected: [parent], selecting: [item.name])
                    if !(error is CancellationError) {
                        self.reportRenameFailure(name: trimmed, error: error)
                    }
                }
            }
            return true
        }
        do {
            let dest = try Providers.provider(for: item.url).rename(item.url, to: newName)
            finishMutation(affected: [item.url.deletingLastPathComponent()],
                           selecting: [dest.lastPathComponent])
            return true
        } catch {
            reportRenameFailure(name: trimmed, error: error)
            return false
        }
    }

    /// Confirm renaming a remote folder that has contents: say how much will be
    /// copied, that the originals are deleted only once every copy has landed, and
    /// that web links to the files change (naming the address when the bucket has
    /// a public one set).
    private func confirmRemoteRename(_ url: URL, from oldName: String, to newName: String,
                                     count: ProviderCount) -> Bool {
        let amount = count.isPartial
            ? "More than \(count.items.formatted()) objects"
            : "\(count.items.formatted()) object\(count.items == 1 ? "" : "s") · \(FSFormat.size(count.bytes))"
        var links = "Any links to these files will stop working."
        if case .prefix(_, let bucket, let key) = S3Location.parse(url),
           let base = Preferences.shared.s3PublicAddresses[bucket] {
            let oldPath = S3PublicLink.encodeKey(key.hasSuffix("/") ? key : key + "/")
            links = "Web links will change: \(base)\(oldPath)… will no longer work."
        }
        let alert = NSAlert()
        alert.messageText = "Rename “\(oldName)” to “\(newName)”?"
        alert.informativeText = "\(amount).\n\n"
            + "S3 has no rename, so every file is copied to the new name on S3 and the originals are "
            + "deleted only after all the copies have succeeded. If you stop it or something fails, "
            + "the originals are kept and the partial copy is removed.\n\n\(links)"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Surface a rename failure with a clear reason instead of just a beep. The
    /// common case — the typed name already exists (e.g. renaming a just-created
    /// "untitled folder" to an existing folder's name) — otherwise looks like the
    /// rename silently did nothing: no message, the label just snaps back.
    private func reportRenameFailure(name: String, error: Error) {
        let alert = NSAlert()
        switch (error as? CocoaError)?.code {
        case .fileWriteFileExists:
            alert.messageText = "The name “\(name)” is already taken."
            alert.informativeText =
                "An item named “\(name)” already exists in this folder. Please choose a different name."
        case .fileWriteInvalidFileName:
            alert.messageText = "“\(name)” isn’t a valid name."
            alert.informativeText = "A name can’t contain “/” or “:”. Please choose a different name."
        default:
            alert.messageText = "Couldn’t rename to “\(name)”."
            alert.informativeText = error.localizedDescription
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Create a new folder in `directory` (the current folder if nil), then select
    /// it and start renaming.
    func makeNewFolder(in directory: URL? = nil) {
        guard let target = directory ?? folder else { return }
        guard accepts(itemsInto: target) else { NSSound.beep(); return }
        // Remote creation needs the name up front — see NewRemoteFolder.
        guard target.isFileURL else { makeRemoteFolder(in: target); return }
        showTargetThenCreate(in: target) {
            try Providers.provider(for: target).newFolder(in: target).lastPathComponent
        }
    }

    /// Create a folder — or, at the top level of a provider that has containers of
    /// its own, a bucket — on a remote provider.
    private func makeRemoteFolder(in target: URL) {
        // Inside a bucket a folder behaves like a local one: it appears as
        // "untitled folder" with its name ready to type over (renaming an empty S3
        // folder is just a new marker plus a delete). Only a new BUCKET still asks
        // up front — its name can never change afterwards, and it needs a region.
        var atProfileLevel = false
        if case .profile = S3Location.parse(target) { atProfileLevel = true }
        if !atProfileLevel {
            makeRemoteFolderInPlace(in: target)
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let choice = await NewRemoteFolder.ask(in: target) else { return }
            do {
                let created: URL
                if let profile = NewRemoteFolder.profile(of: target), let region = choice.region {
                    created = try await S3Provider(url: target)
                        .createBucket(profile: profile, name: choice.name, region: region)
                } else {
                    created = try await Providers.provider(for: target)
                        .createFolder(in: target, named: choice.name)
                }
                self.finishMutation(affected: [target], selecting: [created.lastPathComponent])
            } catch {
                Diag.transfer.error("create remote folder failed: \(Diag.describe(error), privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Couldn’t create “\(choice.name)”."
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    /// Create "untitled folder" (or "untitled folder 2", …) in a remote location,
    /// then start an inline rename on it, as for a local New Folder.
    private func makeRemoteFolderInPlace(in target: URL) {
        let provider = Providers.provider(for: target)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var name = "untitled folder"
                var n = 2
                while await provider.exists(target.appendingPathComponent(name, isDirectory: true)) {
                    name = "untitled folder \(n)"
                    n += 1
                }
                let created = try await provider.createFolder(in: target, named: name)
                if !self.samePath(target, self.folder) { self.onOpenFolder?(target) }
                self.finishMutation(affected: [target], selecting: [created.lastPathComponent],
                                    renameFirst: true)
            } catch {
                Diag.transfer.error("create remote folder failed: \(Diag.describe(error), privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Couldn’t create a new folder."
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    /// Create an empty `untitled.<ext>` document and drop into inline rename.
    func makeNewDocument(_ type: NewDocumentType, in directory: URL? = nil) {
        guard let target = directory ?? folder else { return }
        guard accepts(itemsInto: target) else { NSSound.beep(); return }
        showTargetThenCreate(in: target) {
            try Providers.provider(for: target).newFile(
                in: target, named: "\(NewDocument.defaultBaseName).\(type.ext)").lastPathComponent
        }
    }

    /// Write the clipboard URL as a cross-platform `.url` Internet Shortcut.
    func makeInternetShortcut(in directory: URL? = nil) {
        guard let target = directory ?? folder, accepts(itemsInto: target),
              let urlString = NewDocument.clipboardURL() else { NSSound.beep(); return }
        showTargetThenCreate(in: target) {
            let data = NewDocument.internetShortcutData(for: urlString)
            return try Providers.provider(for: target).newFile(
                in: target, named: "\(NewDocument.defaultBaseName).url", contents: data).lastPathComponent
        }
    }

    private func showTargetThenCreate(in target: URL, _ create: () throws -> String) {
        let navigating = !samePath(target, folder)
        Diag.rename.info("create: navigating=\(navigating)")
        if navigating { onOpenFolder?(target) }
        do {
            let name = try create()
            Diag.rename.info("created an item")
            finishMutation(affected: [target], selecting: [name], renameFirst: true)
        } catch {
            NSSound.beep()
        }
    }

    /// Broadcast the affected folders (refreshing this + other windows + the tree),
    /// then select/begin-rename newly-created items in this folder.
    func finishMutation(affected: Set<URL>, selecting names: [String] = [], renameFirst: Bool = false) {
        guard !names.isEmpty else {
            FolderChange.notify(Array(affected))   // nothing to select — a normal reload is fine
            return
        }
        // We reload (awaited) + select + rename ourselves below, so skip the duplicate
        // reload this pane's own broadcast would trigger — a second reload rebuilding
        // the table mid-edit is what dropped the rename intermittently. Other windows
        // and the tree still update from the notify.
        skipsNextSelfChangeReload = true
        FolderChange.notify(Array(affected))
        // The provider reload is async, so the newly-created items aren't in `items`
        // synchronously. Await the reload, THEN select + begin-rename — deterministic,
        // unlike racing a timer against the reload.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reloadAndWait()
            let wanted = Set(names)
            let rows = self.items.enumerated()
                .filter { wanted.contains($0.element.url.lastPathComponent) }
                .map(\.offset)
            Diag.rename.info("finishMutation: reloaded, rows=\(rows.count) renameFirst=\(renameFirst)")
            guard !rows.isEmpty else { return }
            self.presenter?.selectItems(at: IndexSet(rows))
            // `revealItems` takes focus a turn later, which would end an edit started
            // here; `beginRename` does its own focusing and scrolling anyway.
            if renameFirst, let name = names.first {
                self.beginRenameDeferred(named: name)
            } else {
                self.presenter?.revealItems(at: IndexSet(rows))
            }
        }
    }

    // Folder commands by URL — for the tree's context menu to call.

    func cutFolder(_ url: URL) { Clipboard.shared.set([url], operation: .cut) }
    func copyFolder(_ url: URL) { Clipboard.shared.set([url], operation: .copy) }

    func duplicateFolder(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        do {
            let name = try Providers.provider(for: parent).copy(url, into: parent).lastPathComponent
            finishMutation(affected: [parent], selecting: samePath(parent, folder) ? [name] : [])
        } catch { NSSound.beep() }
    }

    func trashFolder(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if !url.isFileURL { deleteRemoteItems([url], reloading: parent); return }
        do {
            _ = try Providers.provider(for: url).moveToTrash(url)
            finishMutation(affected: [parent])
        } catch { NSSound.beep() }
    }

    func renameFolder(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        guard !samePath(parent, folder) else {
            beginRenameDeferred(named: url.lastPathComponent)
            return
        }
        // Showing the parent is asynchronous; the row can only be edited once its
        // listing has arrived.
        renameAfterLoad(url.lastPathComponent)
        onOpenFolder?(parent)
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

    /// Whether a drop of our own remote items moves them, as Finder decides for
    /// disks: within the same place (one S3 bucket under one profile) a plain drag
    /// moves; anywhere else it copies; Option always copies.
    func remoteDropMoves(_ sources: [URL], into destination: URL) -> Bool {
        if NSEvent.modifierFlags.contains(.option) { return false }
        guard case .prefix(let profile, let bucket, _) = S3Location.parse(destination) else { return false }
        return sources.allSatisfy {
            if case .prefix(let p, let b, _) = S3Location.parse($0) { return p == profile && b == bucket }
            return false
        }
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
        // A provider can't read another backend's files, so transfers that cross a
        // backend boundary are bridged here. Into a remote location: every source is
        // uploaded, fetched first if it is itself remote.
        guard destination.isFileURL || destination.scheme == nil else {
            uploadTransfer(urls, into: destination, move: move, selectLanded: selectLanded)
            return
        }
        // Out of a remote location into a local folder: a download.
        let remoteSources = urls.filter { !($0.isFileURL || $0.scheme == nil) }
        if !remoteSources.isEmpty {
            downloadTransfer(remoteSources, into: destination, selectLanded: selectLanded)
        }
        let urls = urls.filter { $0.isFileURL || $0.scheme == nil }
        guard !urls.isEmpty else { return }

        var landed: [String] = []
        var affected: Set<URL> = [destination]
        var applyToAll: CollisionChoice?
        var failure: (name: String, error: Error)?
        let ask = Preferences.shared.promptOnCollision
        let provider = Providers.provider(for: destination)

        for url in urls {
            if isSelfOrDescendant(url, of: destination) { continue }
            // A stale clipboard (a second paste after a cut+paste already moved these)
            // points at files that no longer exist. Skip them: offering "Replace" for a
            // source that is gone can only destroy the copy already at the destination.
            guard FileManager.default.fileExists(atPath: url.path) else {
                if failure == nil { failure = (url.lastPathComponent, TransferRefusal.sourceMissing) }
                continue
            }
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
                    let dest = move ? try provider.move(url, into: destination)
                                    : try provider.copy(url, into: destination)
                    landed.append(dest.lastPathComponent)
                case .replace:
                    // Safe ordering lives in the provider seam — see `replace`.
                    let dest = try provider.replace(url, at: target, moving: move)
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
        if !selectLanded { followInto(destination, selecting: landed) }
        if let failure { reportTransferFailure(failure.name, error: failure.error, moving: move) }
    }

    /// Open the folder files were just copied into, and select them there.
    ///
    /// Dropping onto a folder row puts the files somewhere the user isn't looking, with
    /// no sign anything happened — worse on a remote provider, where the "folder" is
    /// just a shared prefix and there's nothing to reassure them it arrived.
    private func followInto(_ destination: URL, selecting landed: [String]) {
        guard !landed.isEmpty, !samePath(destination, folder) else { return }
        selectAfterLoad(landed)
        onOpenFolder?(destination)
    }

    /// Copy files out of a remote provider into a local folder by downloading them —
    /// the cross-provider half of a copy or a drag.
    ///
    /// Always a copy: removing the original would mean deleting it on the server,
    /// which nothing here is allowed to do yet, so a "move" degrades to a copy and
    /// leaves the remote file alone.
    private func downloadTransfer(_ urls: [URL], into destination: URL, selectLanded: Bool) {
        let ask = Preferences.shared.promptOnCollision
        Task { @MainActor [weak self] in
            guard let self else { return }
            var landed: [String] = []
            var applyToAll: CollisionChoice?
            var failure: (name: String, error: Error)?

            for url in urls {
                let name = url.lastPathComponent
                var target = destination.appendingPathComponent(name)
                var skip = false

                if FileManager.default.fileExists(atPath: target.path) {
                    var choice: CollisionChoice = .keepBoth
                    if ask {
                        if let all = applyToAll {
                            choice = all
                        } else {
                            let result = self.askCollision(name: name, in: destination,
                                                           multiple: urls.count > 1)
                            if result.applyToAll { applyToAll = result.choice }
                            choice = result.choice
                        }
                    }
                    switch choice {
                    case .keepBoth: target = FileOperations.uniqueDestination(forName: name, in: destination)
                    // Replace, but not yet: the provider swaps the file in only once the
                    // download has arrived and verified, so a failure leaves what's here
                    // untouched rather than destroying it up front.
                    case .replace:  break
                    case .stop:     skip = true
                    }
                }
                if skip { break }

                self.onStatus?("Downloading “\(name)”…")
                do {
                    if url.hasDirectoryPath { throw TransferRefusal.remoteFolder(name) }
                    try await Providers.provider(for: url).download(url, to: target)
                    landed.append(target.lastPathComponent)
                } catch {
                    NSSound.beep()
                    if failure == nil { failure = (name, error) }
                }
            }

            self.emitStatus()
            self.finishMutation(affected: [destination], selecting: selectLanded ? landed : [])
            if !selectLanded { self.followInto(destination, selecting: landed) }
            if let failure {
                self.reportTransferFailure(failure.name, error: failure.error, moving: false)
            }
        }
    }

    /// Copy or move items into a remote location (an S3 prefix, say).
    ///
    /// When the destination's backend can copy the source itself — S3 to S3 under
    /// one profile — it does, server-side: no bytes pass through this Mac, and a
    /// move then deletes the original once the copy has landed. Otherwise each
    /// source is downloaded to a scratch folder (if remote) and uploaded, so any
    /// backend that can download can copy into any backend that can upload; such a
    /// cross-backend "move" leaves the original alone.
    ///
    /// Progress and Stop go through the pane's status bar, as remote deletes do.
    private func uploadTransfer(_ urls: [URL], into destination: URL, move: Bool,
                                selectLanded: Bool) {
        let ask = Preferences.shared.promptOnCollision
        let target = Providers.provider(for: destination)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var landed: [String] = []
            var affected: Set<URL> = [destination]
            var applyToAll: CollisionChoice?
            var failure: (name: String, error: Error)?
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("macsplorer-transfer-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            let progress = ProviderProgress()
            progress.setTotal(urls.count, isPartial: false)
            self.onBackgroundWork?(move ? "Moving" : "Copying", progress, true)
            // Stop cancels whichever operation is running, not just a flag: a single
            // CopyObject or upload is one long request with no loop to check one.
            var work: Task<Void, Error>?
            progress.onCancel { Task { @MainActor in work?.cancel() } }

            for source in urls {
                if progress.isCancelled { break }
                let name = source.lastPathComponent
                // Dropping something onto its own folder (or itself) does nothing.
                if self.samePath(source.deletingLastPathComponent(), destination)
                    || self.isSelfOrDescendant(source, of: destination) { continue }
                do {
                    let direct = await target.canCopyDirectly(
                        source, to: destination.appendingPathComponent(name))
                    Diag.transfer.info("transfer: direct=\(direct, privacy: .public) move=\(move, privacy: .public)")
                    // Something local to send: the source itself, or a download of it.
                    var local = source
                    if !direct && !(source.isFileURL || source.scheme == nil) {
                        if source.hasDirectoryPath { throw TransferRefusal.remoteFolder(name) }
                        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                        local = scratch.appendingPathComponent(name)
                        progress.advance(items: 0, detail: "downloading “\(name)”")
                        let download = Task { try await Providers.provider(for: source).download(source, to: local) }
                        work = download
                        try await download.value
                    }

                    var isFolder = false
                    if !direct {
                        var isDirectory: ObjCBool = false
                        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory)
                        isFolder = isDirectory.boolValue
                    }
                    var placed = destination.appendingPathComponent(name, isDirectory: isFolder)

                    if await target.exists(placed) {
                        var choice: CollisionChoice = .keepBoth
                        if ask {
                            if let all = applyToAll {
                                choice = all
                            } else {
                                let result = self.askCollision(name: name, in: destination,
                                                               multiple: urls.count > 1)
                                if result.applyToAll { applyToAll = result.choice }
                                choice = result.choice
                            }
                        }
                        if choice == .stop { break }
                        if choice == .keepBoth {
                            placed = await self.uniqueRemoteDestination(forName: name, in: destination,
                                                                       isFolder: isFolder, provider: target)
                        }
                        // Replace needs nothing extra: the provider overwrites in place,
                        // and must leave the original intact if that fails.
                    }

                    if direct {
                        progress.advance(items: 0, detail: "“\(name)”")
                        let copy = Task { try await target.copyDirectly(source, to: placed, progress: progress) }
                        work = copy
                        try await copy.value
                        // A move deletes the original only once the copy is really there.
                        if move {
                            guard await target.exists(placed) else { throw TransferRefusal.sourceMissing }
                            try await Providers.provider(for: source).deletePermanently(source, progress: nil)
                            affected.insert(source.deletingLastPathComponent())
                        }
                    } else {
                        progress.advance(items: 0, detail: "uploading “\(name)”")
                        let upload = Task {
                            if isFolder {
                                try await self.uploadFolder(local, to: placed, provider: target)
                            } else {
                                try await target.upload(local, to: placed)
                            }
                        }
                        work = upload
                        try await upload.value
                        progress.advance(items: 1, detail: "“\(name)”")
                    }
                    landed.append(placed.lastPathComponent)
                } catch is CancellationError {
                    Diag.transfer.info("transfer: stopped")
                    break
                } catch {
                    Diag.transfer.error("transfer failed: \(Diag.describe(error), privacy: .public)")
                    if progress.isCancelled { break }
                    NSSound.beep()
                    if failure == nil { failure = (name, error) }
                }
            }
            Diag.transfer.info("transfer: done, landed=\(landed.count, privacy: .public) of \(urls.count, privacy: .public)")

            self.onBackgroundWorkEnded?()
            self.emitStatus()
            self.finishMutation(affected: affected, selecting: selectLanded ? landed : [])
            if !selectLanded { self.followInto(destination, selecting: landed) }
            if let failure {
                self.reportTransferFailure(failure.name, error: failure.error, moving: move)
            }
        }
    }

    /// Upload a local folder's files beneath `destination`, keeping its structure.
    /// Empty folders aren't sent: an object store has no folders, only keys that share
    /// a prefix, so a folder with nothing in it has nothing to store.
    private func uploadFolder(_ folder: URL, to destination: URL, provider: FileSystemProvider) async throws {
        for (file, relative) in Self.files(beneath: folder) {
            var placed = destination
            let parts = relative.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                placed.appendPathComponent(part, isDirectory: index < parts.count - 1)
            }
            onStatus?("Uploading “\(relative)”…")
            try await provider.upload(file, to: placed)
        }
    }

    /// Every regular file beneath `folder`, with its path relative to it. Symbolic links
    /// are skipped so an upload can't follow one out of the folder. Collected up front,
    /// because a directory enumerator can't be iterated across `await`s.
    private static func files(beneath folder: URL) -> [(file: URL, relative: String)] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: folder,
                                                              includingPropertiesForKeys: Array(keys)) else {
            return []
        }
        let root = folder.standardizedFileURL.path
        var found: [(file: URL, relative: String)] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isDirectory != true, values.isSymbolicLink != true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            found.append((file, String(path.dropFirst(root.count + 1))))
        }
        return found
    }

    /// A free name for "Keep Both" at a remote destination, in the same form a local
    /// copy uses: "name copy", then "name copy 2", and so on.
    private func uniqueRemoteDestination(forName name: String, in directory: URL, isFolder: Bool,
                                         provider: FileSystemProvider) async -> URL {
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for counter in 1...999 {
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            let candidate = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            let url = directory.appendingPathComponent(candidate, isDirectory: isFolder)
            if !(await provider.exists(url)) { return url }
        }
        let fallback = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        return directory.appendingPathComponent(fallback, isDirectory: isFolder)
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

/// A transfer the app declines itself, before asking any provider.
private enum TransferRefusal: LocalizedError {
    case remoteFolder(String)
    case sourceMissing

    var errorDescription: String? {
        switch self {
        case .remoteFolder(let name):
            return "“\(name)” is a folder. Copying folders out of a remote location isn’t supported yet."
        case .sourceMissing:
            return "The item no longer exists where it was copied from — it was probably "
                 + "already moved. Nothing at the destination was changed."
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
    /// Everything a drop needs once its destination folder is known: plain files,
    /// our own remote items, a right-button drag's copy/move menu, and promised
    /// files from Outlook/Mail/Photos. Shared so the folder tree behaves exactly
    /// like the details list rather than growing a second, subtly different copy.
    @discardableResult
    func acceptDrop(_ info: NSDraggingInfo, into destination: URL, in view: NSView) -> Bool {
        guard accepts(itemsInto: destination) else { return false }
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            if RightDragSource.shared.isActive {
                let point = view.convert(info.draggingLocation, from: nil)
                DispatchQueue.main.async { [weak self] in
                    self?.showRightDropMenu(urls: urls, into: destination, at: point, in: view)
                }
                return true
            }
            let move = dragOperation(for: info) == .move
            let selectLanded = samePath(destination, folder)
            DispatchQueue.main.async { [weak self] in
                self?.performTransfer(urls, into: destination, move: move, selectLanded: selectLanded)
            }
            return true
        }
        let providerURLs = RemoteFilePromise.providerURLs(on: info.draggingPasteboard)
        if !providerURLs.isEmpty {
            let selectLanded = samePath(destination, folder)
            let move = remoteDropMoves(providerURLs, into: destination)
            Diag.transfer.info("drop: \(providerURLs.count, privacy: .public) remote item(s), move=\(move, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.performTransfer(providerURLs, into: destination, move: move,
                                      selectLanded: selectLanded)
            }
            return true
        }
        let receivers = promiseReceivers(from: info)
        guard !receivers.isEmpty else { return false }
        receivePromisedFiles(receivers, into: destination)
        return true
    }

    /// What a drop on `destination` would do — for a view's validate step.
    func dropOperation(for info: NSDraggingInfo, into destination: URL) -> NSDragOperation {
        // No highlight at all over Recents: there's nowhere for the files to go.
        guard accepts(itemsInto: destination) else { return [] }
        let operation = dragOperation(for: info)
        if operation != [] { return operation }
        return promiseReceivers(from: info).isEmpty ? [] : .copy
    }

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
            if RecentsProvider.isRecents(folder) {
                // Terminal, Reveal, Copy Path, sizes, Get Info — all act on a folder on
                // disk, and Recents isn't one. Paste stays, greyed, so the menu still
                // answers "can I paste here?" rather than vanishing.
                add(menu, "Paste", #selector(ctxPaste(_:)), target, enabled: false)
                return menu
            }
            if let folder, folderAcceptsItems {
                menu.addItem(NewDocument.submenuItem(for: folder, target: target,
                                                     action: #selector(ctxNew(_:))))
            }
            add(menu, "Paste", #selector(ctxPaste(_:)), target, enabled: canPaste)
            menu.addItem(.separator())
            add(menu, "Open in Terminal", #selector(ctxTerminal(_:)), target)
            add(menu, "Reveal in Finder", #selector(ctxReveal(_:)), target)
            add(menu, "Copy Path", #selector(ctxCopyPath(_:)), target)
            if let folder, S3PublicLinkCommand.isBucket(folder) {
                add(menu, "Set Public Address…", #selector(ctxSetPublicAddressFolder(_:)), target)
            }
            menu.addItem(.separator())
            add(menu, "Calculate Folder Sizes…", #selector(ctxCalculateFolderSizesFolder(_:)), target)
            add(menu, "Get Info", #selector(ctxGetInfoFolder(_:)), target)
            return menu
        }
        let item = items[index]
        let isFolder = item.isDirectory && !item.isPackage
        add(menu, "Open", #selector(ctxOpen(_:)), target)
        if isFolder {
            add(menu, "Open in New Window", #selector(ctxOpenInNewWindow(_:)), target)
            add(menu, "Open in Terminal", #selector(ctxTerminal(_:)), target)
            if accepts(itemsInto: item.url) {
                menu.addItem(NewDocument.submenuItem(for: item.url, target: target,
                                                     action: #selector(ctxNew(_:))))
            }
        } else {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = OpenWith.submenu(for: item.url, target: target,
                                                openAction: #selector(ctxOpenWithApp(_:)),
                                                setDefaultAction: #selector(ctxSetDefaultApp(_:)))
            menu.addItem(openWith)
        }
        // Recents mixes files from everywhere, so the way back to a file's own folder
        // is a command of its own, as in Finder.
        if RecentsProvider.isRecents(folder) {
            menu.addItem(.separator())
            add(menu, "Show in Enclosing Folder", #selector(ctxShowInEnclosingFolder(_:)), target)
        }
        // Links to S3 objects (not folders/prefixes): a plain public link at the
        // bucket's public address, and a presigned temporary one (which works on
        // private objects too, and expires).
        if item.url.scheme == S3Location.scheme && !isFolder {
            menu.addItem(.separator())
            add(menu, "Copy Public Link", #selector(ctxCopyPublicLink(_:)), target)
            add(menu, "Copy Temporary Link…", #selector(ctxDownloadLink(_:)), target)
        }
        // The public address is a property of the bucket, so it's set on the bucket.
        if isFolder && S3PublicLinkCommand.isBucket(item.url) {
            menu.addItem(.separator())
            add(menu, "Set Public Address…", #selector(ctxSetPublicAddress(_:)), target)
        }
        menu.addItem(.separator())
        add(menu, "Cut", #selector(ctxCut(_:)), target)
        add(menu, "Copy", #selector(ctxCopy(_:)), target)
        // Paste belongs in every one of these menus, not only the empty-space one:
        // whether a right-click lands on a row or between rows is luck, and a
        // command that appears and disappears reads as broken. Absent vs. greyed is
        // the difference between "this app can't" and "not right now".
        if isFolder {
            add(menu, "Paste into “\(item.name)”", #selector(ctxPasteInto(_:)), target,
                enabled: accepts(itemsInto: item.url) && Clipboard.shared.canPaste)
        } else {
            add(menu, "Paste", #selector(ctxPaste(_:)), target, enabled: canPaste)
        }
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
        menu.addItem(.separator())
        if isFolder {
            add(menu, "Calculate Folder Sizes…", #selector(ctxCalculateFolderSizes(_:)), target)
        }
        add(menu, "Get Info", #selector(ctxGetInfo(_:)), target)
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
    @objc func ctxShowInEnclosingFolder(_ sender: Any?) {
        guard let url = selectedURLs().first else { return }
        showInEnclosingFolder(url)
    }

    /// Go to the folder a file actually lives in, with the file selected.
    func showInEnclosingFolder(_ url: URL) {
        selectAfterLoad([url.lastPathComponent])
        onOpenFolder?(url.deletingLastPathComponent())
    }

    @objc func ctxPasteInto(_ sender: Any?) {
        guard let url = selectedURLs().first else { return }
        pasteInto(url)
    }
    @objc func ctxDuplicate(_ sender: Any?) { duplicateSelectedItems() }
    @objc func ctxRename(_ sender: Any?) { renameSelectedItem() }
    @objc func ctxTrash(_ sender: Any?) { trashSelectedItems() }
    @objc func ctxReveal(_ sender: Any?) { revealSelection() }
    @objc func ctxGetInfo(_ sender: Any?) {
        for url in selectedURLs() { (NSApp.delegate as? AppDelegate)?.presentGetInfo(for: url) }
    }
    @objc func ctxGetInfoFolder(_ sender: Any?) {
        if let folder { (NSApp.delegate as? AppDelegate)?.presentGetInfo(for: folder) }
    }
    @objc func ctxCalculateFolderSizes(_ sender: Any?) {
        if let url = selectedFolderForFavorite() {
            (NSApp.delegate as? AppDelegate)?.calculateFolderSizes(for: url)
        }
    }
    @objc func ctxCalculateFolderSizesFolder(_ sender: Any?) {
        if let folder { (NSApp.delegate as? AppDelegate)?.calculateFolderSizes(for: folder) }
    }
    @objc func ctxCopyPath(_ sender: Any?) { copySelectionPaths() }
    @objc func ctxTerminal(_ sender: Any?) { openSelectionInTerminal() }
    // Menu actions run on the main thread; `assumeIsolated` says so to the compiler.
    @objc func ctxCopyPublicLink(_ sender: Any?) {
        // Option-click re-asks for the bucket's public address first.
        let urls = selectedURLs()
        let force = NSEvent.modifierFlags.contains(.option)
        MainActor.assumeIsolated { S3PublicLinkCommand.copy(urls, forcePrompt: force) }
    }
    @objc func ctxSetPublicAddress(_ sender: Any?) {
        guard let url = selectedURLs().first(where: S3PublicLinkCommand.isBucket) else { return }
        MainActor.assumeIsolated { S3PublicLinkCommand.setAddress(forBucketURL: url) }
    }
    @objc func ctxSetPublicAddressFolder(_ sender: Any?) {
        guard let folder, S3PublicLinkCommand.isBucket(folder) else { return }
        MainActor.assumeIsolated { S3PublicLinkCommand.setAddress(forBucketURL: folder) }
    }
    @objc func ctxDownloadLink(_ sender: Any?) {
        guard let url = selectedURLs().first(where: { $0.scheme == S3Location.scheme }) else { return }
        (NSApp.delegate as? AppDelegate)?.presentS3DownloadLink(for: url)
    }

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
        let rows = selectedIndexes()
        guard rows.count == 1, let row = rows.first else { return nil }
        let item = items[row]
        return (item.isDirectory && !item.isPackage) ? item.url : nil
    }
}
