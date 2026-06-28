import AppKit
import Quartz
import MacSplorerCore

/// Presents a `FolderContents` as a grid of thumbnails (`NSCollectionView`):
/// content previews for images/PDFs/video, file-type icons otherwise, names
/// below. Selection, open, the context menu, inline rename, and Quick Look all
/// route back to the shared model — the same commands as the list view.
final class IconViewController: NSObject, FolderContentsPresenter {
    let scrollView = NSScrollView()
    private let collectionView = IconCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let contents: FolderContents

    private var edge: CGFloat = IconSize.large.thumbnailEdge
    private var renamingIndex = -1

    init(contents: FolderContents) {
        self.contents = contents
        super.init()

        layout.itemSize = IconSize.current().cellSize
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(IconItem.self,
                                forItemWithIdentifier: IconItem.identifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        collectionView.onOpenItem = { [weak self] index in self?.contents.openItem(at: index) }
        collectionView.singleClickOpens = { [weak self] in self?.contents.singleClickToOpen ?? false }
        collectionView.onContextMenu = { [weak self] index in
            guard let self else { return nil }
            if self.contents.item(at: index)?.isParentLink == true { return nil }
            return self.contents.contextMenu(clickedIndex: index, target: self.contents)
        }
        collectionView.onTrash = { [weak self] in self?.contents.trashSelectedItems() }
        collectionView.onRename = { [weak self] in self?.contents.renameSelectedItem() }
        collectionView.selectedURLs = { [weak self] in self?.contents.selectedFileURLs ?? [] }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The view to focus for Tab cycling, and the Tab passthrough.
    var keyView: NSView { collectionView }
    var onTab: ((Bool) -> Void)? {
        get { collectionView.onTab }
        set { collectionView.onTab = newValue }
    }

    /// Set the thumbnail size for this grid (per-window, so passed in rather than
    /// read from the global preference).
    func setSize(_ size: IconSize) {
        edge = size.thumbnailEdge
        layout.itemSize = size.cellSize
        collectionView.reloadData()
    }

    /// Called when the grid becomes the active presenter.
    func activate() {
        contents.presenter = self
        collectionView.reloadData()
        syncSelectionToModel()
    }

    /// Give the grid a hard selection (first item) if it has none — so arriving via
    /// Tab leaves the keyboard immediately usable.
    func ensureSelection() {
        guard collectionView.selectionIndexPaths.isEmpty,
              let first = contents.firstSelectableIndex else { return }
        collectionView.selectItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .top)
        contents.emitStatus()
    }

    // Keep the grid's highlight matching whatever the model considers selected
    // (e.g. after switching over from the list view).
    private func syncSelectionToModel() {
        let paths = Set(contents.selectedFileURLs.compactMap { url -> IndexPath? in
            contents.items.firstIndex { $0.url == url }.map { IndexPath(item: $0, section: 0) }
        })
        collectionView.selectionIndexPaths = paths
    }

    // MARK: FolderContentsPresenter

    var selectedIndexes: IndexSet {
        IndexSet(collectionView.selectionIndexPaths.map { $0.item })
    }

    func selectItems(at indexes: IndexSet) {
        let paths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        collectionView.selectItems(at: paths, scrollPosition: .nearestHorizontalEdge)
        contents.emitStatus()
    }

    func reloadContents() {
        collectionView.reloadData()
        contents.emitStatus()
    }

    func reloadItem(at index: Int) {
        let path = IndexPath(item: index, section: 0)
        guard collectionView.item(at: path) != nil else { return }
        collectionView.reloadItems(at: [path])
    }

    func scrollToTop() {
        collectionView.enclosingScrollView?.contentView.scroll(to: .zero)
    }

    func beginRename(at index: Int) {
        let path = IndexPath(item: index, section: 0)
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
        guard let item = collectionView.item(at: path) as? IconItem else { return }
        renamingIndex = index
        contents.isRenaming = true
        item.beginEditing(delegate: self)
    }
}

// MARK: - Data source / delegate

extension IconViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        contents.items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath) as! IconItem
        if let fsItem = contents.item(at: indexPath.item) {
            item.configure(with: fsItem, edge: edge)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        contents.emitStatus()
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didDeselectItemsAt indexPaths: Set<IndexPath>) {
        contents.emitStatus()
    }

    // Drag out.
    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let item = contents.item(at: indexPath.item), !item.isParentLink else { return nil }
        return item.url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        proposedDropOperation.pointee = .before
        return contents.dragOperation(for: draggingInfo)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let folder = contents.folder else { return false }
        let urls = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let move = contents.dragOperation(for: draggingInfo) == .move
        DispatchQueue.main.async { [weak self] in
            self?.contents.performTransfer(urls, into: folder, move: move, selectLanded: true)
        }
        return true
    }
}

// MARK: - Inline rename

extension IconViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renamingIndex = -1
        contents.isRenaming = false
        control.abortEditing()
        DispatchQueue.main.async { [weak self] in self?.contents.reload() }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard renamingIndex >= 0 else { return }
        let index = renamingIndex
        renamingIndex = -1
        contents.isRenaming = false
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        let canceled = movement == NSTextMovement.cancel.rawValue
        let newName = (obj.object as? NSTextField)?.stringValue ?? ""
        var renamed = false
        if !canceled { renamed = contents.commitRename(at: index, to: newName) }
        if !renamed { contents.reload() }
    }
}

// MARK: - Collection view (clicks, keys, context menu, Quick Look)

/// An `NSCollectionView` that adds double-click-to-open, single-click-open mode,
/// a right-click context menu, Return/Delete/Space keys, and Quick Look — the
/// grid equivalent of `HoverTableView`.
final class IconCollectionView: NSCollectionView {
    var onOpenItem: ((Int) -> Void)?
    var singleClickOpens: (() -> Bool)?
    var onContextMenu: ((Int) -> NSMenu?)?
    var onTrash: (() -> Void)?
    var onRename: (() -> Void)?
    var onTab: ((Bool) -> Void)?
    var selectedURLs: (() -> [URL])?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = indexPathForItem(at: point)?.item
        if event.clickCount == 2 {
            if let index { onOpenItem?(index) }
            return
        }
        super.mouseDown(with: event)
        if event.clickCount == 1, let index {
            let modifiers = event.modifierFlags
            if singleClickOpens?() == true, !modifiers.contains(.shift), !modifiers.contains(.command) {
                onOpenItem?(index)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = indexPathForItem(at: point)?.item ?? -1
        if index >= 0 {
            if !selectionIndexPaths.contains(IndexPath(item: index, section: 0)) {
                selectionIndexPaths = [IndexPath(item: index, section: 0)]
            }
        } else {
            deselectAll(nil)
        }
        return onContextMenu?(index)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, let onTab {          // Tab / Shift-Tab → next pane
            onTab(modifiers.contains(.shift))
        } else if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty {
            // Return / keypad Enter → rename (matches the list view).
            onRename?()
        } else if (event.keyCode == 51 || event.keyCode == 117),
                  modifiers.isEmpty || modifiers == .command {
            onTrash?()                                  // Delete / ⌘Delete → Trash
        } else if event.keyCode == 49, modifiers.isEmpty {
            toggleQuickLook()                           // Space
        } else {
            super.keyDown(with: event)
            if let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self {
                panel.reloadData()
            }
        }
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }
}

extension IconCollectionView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs?().count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedURLs?() ?? []
        guard index >= 0 && index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown { keyDown(with: event); return true }
        return false
    }
}

// MARK: - One grid cell

/// A single thumbnail tile: the icon/preview on top, the (up to two-line) name
/// below, with a rounded selection background.
final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")

    private let thumb = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let selectionBackground = NSView()
    private var url: URL?
    private var requestedEdge: CGFloat = 0

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 6
        selectionBackground.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        selectionBackground.isHidden = true
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false

        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.wraps = true
        name.font = .systemFont(ofSize: 11)
        name.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(selectionBackground)
        view.addSubview(thumb)
        view.addSubview(name)
        self.imageView = thumb
        self.textField = name

        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            thumb.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            thumb.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -8),
            thumb.heightAnchor.constraint(equalTo: view.widthAnchor, constant: -8),

            name.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 2),
            name.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            name.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),

            selectionBackground.topAnchor.constraint(equalTo: view.topAnchor),
            selectionBackground.bottomAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            selectionBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func configure(with item: FSItem, edge: CGFloat) {
        url = item.url
        requestedEdge = edge
        name.stringValue = item.name
        name.maximumNumberOfLines = 2
        name.isEditable = false
        name.isBordered = false
        name.drawsBackground = false

        if item.isParentLink {
            thumb.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: "Parent folder")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: edge * 0.5, weight: .light))
            return
        }

        // Show the regular file-type icon immediately; swap in a real content
        // thumbnail only if QuickLook produces one.
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        thumb.image = Thumbnailer.shared.cached(for: item.url, edge: edge) ?? icon
        let scale = view.window?.backingScaleFactor ?? 2
        Thumbnailer.shared.thumbnail(for: item.url, edge: edge, scale: scale) { [weak self] image in
            // Guard against cell reuse: only apply if still showing the same file.
            guard let self, self.url == item.url, self.requestedEdge == edge else { return }
            self.thumb.image = image
        }
    }

    override var isSelected: Bool {
        didSet { selectionBackground.isHidden = !isSelected }
    }

    func beginEditing(delegate: NSTextFieldDelegate) {
        name.isEditable = true
        name.isBordered = true
        name.drawsBackground = true
        name.maximumNumberOfLines = 1
        name.delegate = delegate
        view.window?.makeFirstResponder(name)
        if let editor = name.currentEditor() {
            let ns = name.stringValue as NSString
            let base = (ns.deletingPathExtension as NSString).length
            editor.selectedRange = (base > 0 && base < ns.length)
                ? NSRange(location: 0, length: base)
                : NSRange(location: 0, length: ns.length)
        }
    }
}
