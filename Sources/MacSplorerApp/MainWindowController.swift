import AppKit
import MacSplorerCore

/// The main MacSplorer window: a browser-style tab strip on top and a content
/// area that shows one `BrowserPaneController` (tab) at a time. The strip hides
/// itself when only one tab is open.
final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let tabBar = TabBarView()
    private let containerView = NSView()
    private var tabBarHeight: NSLayoutConstraint!

    private var panes: [BrowserPaneController] = []
    private var titles: [String] = []
    private var activeIndex = 0

    /// Invoked when this window closes, so the app can release its controller.
    var onClose: (() -> Void)?

    private var activePane: BrowserPaneController? {
        panes.indices.contains(activeIndex) ? panes[activeIndex] : nil
    }

    convenience init(initialFolder: URL? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacSplorer"
        window.minSize = NSSize(width: 680, height: 380)
        // We manage our own browser-style tabs, so keep the system from ever
        // merging windows into native tabs.
        window.tabbingMode = .disallowed
        window.center()
        self.init(window: window)
        window.delegate = self
        buildLayout()
        addTab(folder: initialFolder, focusAddress: false)
    }

    // MARK: - Host-facing commands (forwarded to the active tab)

    func openSelection() { activePane?.openSelection() }
    func makeNewFolder() { activePane?.makeNewFolder() }
    @objc func openInTerminal() { activePane?.openInTerminal() }
    var canOpenInTerminal: Bool { activePane?.canOpenInTerminal ?? false }

    /// Re-read persisted preferences into every tab, so all stay in sync.
    func applyPreferences() { panes.forEach { $0.applyPreferences() } }

    // MARK: - Tabs

    /// Open a new tab (File ▸ New Tab / ⌘T / the strip's "+").
    func addTab(folder: URL? = nil, focusAddress: Bool = true) {
        let pane = BrowserPaneController(initialFolder: folder)
        pane.onTitleChange = { [weak self, weak pane] title in
            guard let self, let pane,
                  let index = self.panes.firstIndex(where: { $0 === pane }) else { return }
            self.titles[index] = title
            if index == self.activeIndex { self.window?.title = title }
            self.refreshTabStrip()
        }
        panes.append(pane)
        titles.append("MacSplorer")
        _ = pane.view // force load → initial navigation fires onTitleChange
        selectTab(at: panes.count - 1)
        if focusAddress { pane.focusAddressField() }
    }

    /// Close the frontmost tab (File ▸ Close Tab / ⌘W). Closing the last tab
    /// closes the window.
    func closeActiveTab() { closeTab(at: activeIndex) }

    private func selectTab(at index: Int) {
        guard panes.indices.contains(index) else { return }
        activeIndex = index
        let pane = panes[index]
        containerView.subviews.forEach { $0.removeFromSuperview() }
        let view = pane.view
        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: containerView.topAnchor),
            view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        window?.title = titles.indices.contains(index) ? titles[index] : "MacSplorer"
        refreshTabStrip()
    }

    private func closeTab(at index: Int) {
        guard panes.indices.contains(index) else { return }
        if panes.count == 1 { window?.performClose(nil); return }
        panes.remove(at: index).view.removeFromSuperview()
        titles.remove(at: index)
        if index < activeIndex { activeIndex -= 1 }
        activeIndex = min(activeIndex, panes.count - 1)
        selectTab(at: activeIndex)
    }

    private func refreshTabStrip() {
        tabBar.setTabs(titles: titles, active: activeIndex)
        let show = panes.count > 1
        tabBar.isHidden = !show
        tabBarHeight.constant = show ? TabBarView.height : 0
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// Drives the tab strip's "+" button on the native window title bar (kept for
    /// the `⌘T` responder path): open a new tab in this window.
    override func newWindowForTab(_ sender: Any?) {
        addTab()
    }

    /// Route the field-editor request to whichever tab owns the address field
    /// being edited, so each tab's FAB gets its custom completion-commit editor.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        for pane in panes {
            if let editor = pane.fieldEditor(forClient: client) { return editor }
        }
        return nil
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabBar)
        content.addSubview(containerView)

        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBarHeight,
            containerView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            containerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewTab = { [weak self] in self?.addTab() }
    }
}
