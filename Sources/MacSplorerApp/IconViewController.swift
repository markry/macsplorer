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
        collectionView.registerForDraggedTypes([.fileURL] + FolderContents.promiseDragTypes)
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

    var presentingWindow: NSWindow? { collectionView.window }

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
            item.configure(with: fsItem, edge: edge, downloading: contents.isDownloading(fsItem))
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
        let operation = contents.dragOperation(for: draggingInfo)
        if operation != [] { return operation }
        return contents.promiseReceivers(from: draggingInfo).isEmpty ? [] : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let folder = contents.folder else { return false }
        let urls = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            if RightDragSource.shared.isActive {
                let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
                DispatchQueue.main.async { [weak self] in
                    self?.contents.showRightDropMenu(urls: urls, into: folder, at: point, in: collectionView)
                }
                return true
            }
            let move = contents.dragOperation(for: draggingInfo) == .move
            DispatchQueue.main.async { [weak self] in
                self?.contents.performTransfer(urls, into: folder, move: move, selectLanded: true)
            }
            return true
        }
        let receivers = contents.promiseReceivers(from: draggingInfo)
        guard !receivers.isEmpty else { return false }
        contents.receivePromisedFiles(receivers, into: folder)
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

    // MARK: Hover (single-click-to-open feedback — parallels HoverTableView)

    private var hoveredIndex = -1
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Only in single-click mode, and never while an inline rename is active
        // (its field editor is an NSText) — matches the list view.
        guard singleClickOpens?() == true, !(window?.firstResponder is NSText) else { return }
        let point = convert(event.locationInWindow, from: nil)
        setHovered(index: indexPathForItem(at: point)?.item ?? -1)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(index: -1)
    }

    /// Move the hover highlight from the old tile to the new one (either may be
    /// absent). Only realized (visible) items need updating.
    private func setHovered(index: Int) {
        guard index != hoveredIndex else { return }
        let previous = hoveredIndex
        hoveredIndex = index
        for i in [previous, index] where i >= 0 {
            (item(at: IndexPath(item: i, section: 0)) as? IconItem)?.setHovered(i == index)
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

    /// Right-button drag copies (Explorer-style); a plain right-click shows the
    /// context menu.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point), !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        if let dragEvent = waitForRightDrag(start: event),
           let urls = selectedURLs?(), !urls.isEmpty {
            beginRightDrag(of: urls, with: dragEvent)
            return
        }
        if let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Forward-Delete reports .function (a nav/function key); ignore it and
        // numeric-pad so bare Forward-Delete trashes like ⌫ (see HoverTableView).
        let editModifiers = modifiers.subtracting([.function, .numericPad])
        if event.keyCode == 48, let onTab {          // Tab / Shift-Tab → next pane
            onTab(modifiers.contains(.shift))
        } else if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty {
            // Return / keypad Enter → rename (matches the list view).
            onRename?()
        } else if (event.keyCode == 51 || event.keyCode == 117),
                  editModifiers.isEmpty || editModifiers == .command {
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
    private let hoverBackground = NSView()
    private let spinner = NSProgressIndicator()
    private var url: URL?
    private var requestedEdge: CGFloat = 0
    private var itemName = ""
    private var hovered = false

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 6
        selectionBackground.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        selectionBackground.isHidden = true
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false

        // Subtle hover highlight for single-click mode (parallels the list view's
        // hover underline), sitting under the selection tint.
        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 6
        hoverBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        hoverBackground.isHidden = true
        hoverBackground.translatesAutoresizingMaskIntoConstraints = false

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false

        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.wraps = true
        name.font = .systemFont(ofSize: 11)
        name.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hoverBackground)
        view.addSubview(selectionBackground)
        view.addSubview(thumb)
        view.addSubview(spinner)
        view.addSubview(name)
        self.imageView = thumb
        self.textField = name

        NSLayoutConstraint.activate([
            hoverBackground.topAnchor.constraint(equalTo: selectionBackground.topAnchor),
            hoverBackground.bottomAnchor.constraint(equalTo: selectionBackground.bottomAnchor),
            hoverBackground.leadingAnchor.constraint(equalTo: selectionBackground.leadingAnchor),
            hoverBackground.trailingAnchor.constraint(equalTo: selectionBackground.trailingAnchor),

            thumb.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            thumb.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            thumb.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -8),
            thumb.heightAnchor.constraint(equalTo: view.widthAnchor, constant: -8),

            spinner.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),

            name.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 2),
            name.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            name.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),

            selectionBackground.topAnchor.constraint(equalTo: view.topAnchor),
            selectionBackground.bottomAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            selectionBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func configure(with item: FSItem, edge: CGFloat, downloading: Bool = false) {
        url = item.url
        requestedEdge = edge
        itemName = item.name
        name.maximumNumberOfLines = 2
        name.isEditable = false
        name.isBordered = false
        name.drawsBackground = false
        applyNameStyling()   // plain, or underlined if this tile is still hovered

        // Spin over the icon while an online-only file is being materialized.
        if downloading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        if item.isParentLink {
            thumb.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: "Parent folder")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: edge * 0.5, weight: .light))
            return
        }

        // Show the regular file-type icon immediately; swap in a real content
        // thumbnail only if QuickLook produces one. Online-only cloud files get a
        // download badge so it's clear they aren't on disk yet — but not while the
        // spinner is up (it already conveys "downloading").
        let placeholder = item.isCloudPlaceholder && !downloading
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        let initial = Thumbnailer.shared.cached(for: item.url, edge: edge) ?? icon
        thumb.image = placeholder ? CloudBadge.badged(initial) : initial
        let scale = view.window?.backingScaleFactor ?? 2
        Thumbnailer.shared.thumbnail(for: item.url, edge: edge, scale: scale) { [weak self] image in
            // Guard against cell reuse: only apply if still showing the same file.
            guard let self, self.url == item.url, self.requestedEdge == edge else { return }
            self.thumb.image = placeholder ? CloudBadge.badged(image) : image
        }
    }

    override var isSelected: Bool {
        didSet {
            selectionBackground.isHidden = !isSelected
            updateHoverBackground()   // selection tint supersedes the hover tint
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
        updateHoverBackground()
    }

    /// Hover feedback for single-click-to-open mode, mirroring the list view: a
    /// subtle background tint plus an underlined name. Driven by the collection
    /// view's mouse tracking.
    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        updateHoverBackground()
        applyNameStyling()
    }

    private func updateHoverBackground() {
        hoverBackground.isHidden = !hovered || isSelected
    }

    /// Draw the name plain, or underlined while hovered — keeping the centered,
    /// two-line, middle-truncated layout the tile uses.
    private func applyNameStyling() {
        guard !hovered else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            name.attributedStringValue = NSAttributedString(
                string: itemName,
                attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue,
                             .paragraphStyle: paragraph,
                             .font: name.font as Any])
            return
        }
        name.stringValue = itemName
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
