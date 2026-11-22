import AppKit
import Quartz

final class RootViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 680))
    }
}

/// Which items a command works on (from a context menu, or the focused pane).
final class ActionContext: NSObject {
    let urls: [URL]
    /// Where "Einfügen" / "Neu" put things.
    let folder: URL
    /// Shortcuts like "Dokumente" or drives must never be cut, renamed or trashed.
    let isProtected: Bool
    let fromTree: Bool

    init(urls: [URL], folder: URL, isProtected: Bool = false, fromTree: Bool = false) {
        self.urls = urls
        self.folder = folder
        self.isProtected = isProtected
        self.fromTree = fromTree
    }
}

final class TagRequest: NSObject {
    let urls: [URL]
    let tag: String
    init(urls: [URL], tag: String) { self.urls = urls; self.tag = tag }
}

final class OpenWithRequest: NSObject {
    let urls: [URL]
    let app: URL
    init(urls: [URL], app: URL) { self.urls = urls; self.app = app }
}

/// One explorer window: address bar, command bar, sidebar tree, details view and status bar.
/// The sidebar and the main view navigate independently of each other.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, SidebarDelegate, FileListDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let finderTags: [(String, NSColor)] = [
        ("Rot", .systemRed), ("Orange", .systemOrange), ("Gelb", .systemYellow), ("Grün", .systemGreen),
        ("Blau", .systemBlue), ("Lila", .systemPurple), ("Grau", .systemGray),
    ]

    private let rootVC = RootViewController()
    private let splitVC = NSSplitViewController()
    let sidebarVC = SidebarViewController()
    let fileListVC = FileListViewController()
    private var sidebarItem: NSSplitViewItem!
    let previewVC = PreviewPaneViewController()
    private var previewSplitItem: NSSplitViewItem!
    private var quickLookItems: [PreviewItem] = []
    private let quickLookBuilder = PreviewBuilder()
    private var quickLookActive = false
    private let addressBar = AddressBarView()
    private var commandBar: CommandBarView!
    private let statusBar = StatusBarView()

    private(set) var currentURL: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var keyMonitor: Any?
    var onClose: (() -> Void)?

    /// `select`: items to highlight right away (e.g. the file from "Speicherort öffnen").
    init(url: URL, select: [URL] = []) {
        currentURL = url.standardizedFileURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        commandBar = CommandBarView(newMenu: { [unowned self] in self.makeNewMenu(self.context(nil)) },
                                    sortMenu: { [unowned self] in self.makeSortMenu() },
                                    viewMenu: { [unowned self] in self.makeViewMenu() },
                                    moreMenu: { [unowned self] in self.makeMoreMenu() })
        buildLayout()
        window.contentViewController = rootVC
        window.setContentSize(NSSize(width: 1100, height: 680))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.initialFirstResponder = fileListVC.activeView
        window.tabbingIdentifier = "MacExplorerMain"
        window.tabbingMode = .automatic

        sidebarVC.delegate = self
        fileListVC.delegate = self
        addressBar.breadcrumb.onNavigate = { [weak self] url in
            self?.navigate(to: url)
            self?.focusFileList()
        }
        addressBar.breadcrumb.onCancel = { [weak self] in self?.focusFileList() }
        addressBar.onSearch = { [weak self] query in self?.search(query) }
        installKeyMonitor()
        commandBar.setPreviewVisible(!previewSplitItem.isCollapsed)

        let nc = NotificationCenter.default
        for name in [Notification.Name.clipboardChanged, .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            nc.addObserver(self, selector: #selector(updateCommandBar), name: name, object: nil)
        }
        navigate(to: currentURL, record: false, select: select)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildLayout() {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 560
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: fileListVC)
        contentItem.minimumThickness = 300
        previewSplitItem = NSSplitViewItem(viewController: previewVC)
        previewSplitItem.canCollapse = true
        previewSplitItem.minimumThickness = 220
        previewSplitItem.maximumThickness = 900
        previewSplitItem.holdingPriority = NSLayoutConstraint.Priority(255)
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)
        splitVC.addSplitViewItem(previewSplitItem)
        splitVC.splitView.dividerStyle = .thin
        splitVC.splitView.autosaveName = "MainSplit"
        rootVC.addChild(splitVC)
        previewSplitItem.isCollapsed = !UserDefaults.standard.bool(forKey: "showPreviewPane")

        let root = rootVC.view
        func separator() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            return box
        }
        let sep1 = separator(), sep2 = separator(), sep3 = separator()
        let split = splitVC.view
        for v in [addressBar, sep1, commandBar!, sep2, split, sep3, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            addressBar.topAnchor.constraint(equalTo: root.topAnchor),
            addressBar.heightAnchor.constraint(equalToConstant: 42),
            commandBar.heightAnchor.constraint(equalToConstant: 38),
            sep1.topAnchor.constraint(equalTo: addressBar.bottomAnchor),
            commandBar.topAnchor.constraint(equalTo: sep1.bottomAnchor),
            sep2.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            split.topAnchor.constraint(equalTo: sep2.bottomAnchor),
            sep3.topAnchor.constraint(equalTo: split.bottomAnchor),
            statusBar.topAnchor.constraint(equalTo: sep3.bottomAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onClose?()
    }

    /// Typing in text fields gets its own undo history; everything else undoes file operations.
    private let textUndoManager = UndoManager()

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSText ? textUndoManager : FileOps.shared.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateCommandBar()   // the clipboard may have changed in another app
    }

    private func focusFileList() {
        window?.makeFirstResponder(fileListVC.activeView)
    }

    /// Windows habits that are not menu shortcuts: ⌫ / Entf, Alt+Up/Left/Right and F5.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.attachedSheet == nil else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if Settings.shared.windowsShortcuts, mods.contains(.control), !mods.contains(.command), !mods.contains(.option),
               let action = self.windowsShortcut(event, shift: mods.contains(.shift)) {
                NSApp.sendAction(action, to: nil, from: self)
                return nil
            }
            if window.firstResponder is NSText { return event }   // typing in a text field
            let inTree = window.firstResponder === self.sidebarVC.outline
            switch (event.keyCode, mods) {
            case (126, .option): self.goUp(nil)                     // ⌥↑
            case (123, .option) where !inTree: self.goBack(nil)     // ⌥←
            case (124, .option) where !inTree: self.goForward(nil)  // ⌥→
            case (96, []): self.refresh(nil)                        // F5
            case (51, []) where Settings.shared.backspaceGoesBack: self.goBack(nil)   // ⌫ = back (Windows)
            case (51, []), (117, []): self.moveToTrash(nil)         // ⌫ and forward delete
            case (36, .option): self.showProperties(nil)           // ⌥↩ (Windows: Alt+Enter)
            case (99, []): self.focusSearch(nil)                    // F3
            case (49, []): self.toggleQuickLook(nil)                // space
            case (35, .option): self.togglePreviewPane(nil)         // ⌥P (Windows: Alt+P)
            default: return event
            }
            return nil
        }
    }

    /// Optional Windows shortcuts with ctrl (Strg).
    private func windowsShortcut(_ event: NSEvent, shift: Bool) -> Selector? {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        if shift { return key == "n" ? #selector(newFolder(_:)) : (key == "z" ? Selector(("redo:")) : nil) }
        switch key {
        case "c": return #selector(NSText.copy(_:))
        case "x": return #selector(NSText.cut(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return Selector(("undo:"))
        case "y": return Selector(("redo:"))
        case "f", "e": return #selector(focusSearch(_:))
        case "l": return #selector(focusAddressBar(_:))
        case "t": return #selector(newWindowForTab(_:))
        case "w": return #selector(NSWindow.performClose(_:))
        case "n": return #selector(AppDelegate.newWindow(_:))
        case "d": return #selector(moveToTrash(_:))
        case "r": return #selector(refresh(_:))
        default: return nil
        }
    }

    // MARK: - Navigation (main view only)

    private var parentURL: URL? {
        currentURL.path == "/" ? nil : currentURL.deletingLastPathComponent()
    }

    func navigate(to url: URL, record: Bool = true, select: [URL] = [], rename: Bool = false) {
        let url = url.standardizedFileURL
        if record && url != currentURL {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }
        currentURL = url
        addressBar.clearSearch()
        fileListVC.load(url, select: select, rename: rename)
        Settings.shared.lastFolderPath = url.path
        updateChrome()
    }

    private func updateChrome() {
        window?.title = FileManager.default.displayName(atPath: currentURL.path)
        // No proxy icon (representedURL): in tabs it sat where the close "x" appears and pushed it away on hover.
        window?.tab.toolTip = currentURL.path
        addressBar.update(url: currentURL, canGoBack: !backStack.isEmpty,
                          canGoForward: !forwardStack.isEmpty, canGoUp: parentURL != nil)
    }

    private func updateStatus() {
        let selected = fileListVC.selectedItems
        let files = selected.filter { !$0.isFolder }
        let size: Int64? = files.isEmpty ? nil : files.compactMap(\.size).reduce(0, +)
        statusBar.update(total: fileListVC.items.count, selected: selected.count, selectedSize: size,
                         searching: fileListVC.searchQuery == nil ? nil : fileListVC.isSearchRunning)
        updateCommandBar()
        updatePreview()
    }

    // MARK: - Preview pane and Quick Look

    private func updatePreview() {
        let urls = context(nil).urls
        if !previewSplitItem.isCollapsed { previewVC.show(urls) }
        if quickLookActive, let panel = QLPreviewPanel.shared(), panel.isVisible {
            quickLookItems = makeQuickLookItems()
            panel.reloadData()
        }
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        let show = previewSplitItem.isCollapsed
        UserDefaults.standard.set(show, forKey: "showPreviewPane")
        previewSplitItem.animator().isCollapsed = !show
        if show { previewVC.show(context(nil).urls) } else { previewVC.clear() }
        commandBar.setPreviewVisible(show)
    }

    private func makeQuickLookItems() -> [PreviewItem] {
        let ctx = context(nil)
        let urls = ctx.urls.isEmpty ? [currentURL] : ctx.urls
        return quickLookBuilder.items(for: urls) { item in
            guard let panel = QLPreviewPanel.shared(), panel.isVisible, panel.currentPreviewItem === item else { return }
            panel.refreshCurrentPreviewItem()
        }
    }

    /// Space bar: open / close Quick Look (like Finder). Folders show item count, size and dates.
    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookActive = true
        quickLookItems = makeQuickLookItems()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookActive = false
        quickLookBuilder.cancel()
        quickLookItems = []
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        index < quickLookItems.count ? quickLookItems[index] : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        switch event.keyCode {
        case 49:   // space closes, like in Finder
            panel.orderOut(nil)
            return true
        case 125, 126:   // up / down: move the selection in the list, the preview follows
            if quickLookItems.count <= 1 || fileListVC.selectedItems.count <= 1 {
                fileListVC.activeView.keyDown(with: event)
                return true
            }
            return false
        default:
            return false
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard fileListVC.viewMode == .details, let item = item as? PreviewItem, let window,
              let row = fileListVC.items.firstIndex(where: { $0.url == item.source }) else { return .zero }
        let table = fileListVC.tableView
        let rect = table.rect(ofRow: row)
        guard table.visibleRect.intersects(rect) else { return .zero }
        let iconRect = NSRect(x: rect.minX + 4, y: rect.minY + 3, width: 16, height: 16)
        return window.convertToScreen(table.convert(iconRect, to: nil))
    }

    @objc private func updateCommandBar() {
        let ctx = context(nil)
        commandBar.update(hasSelection: !ctx.urls.isEmpty, canModify: !ctx.urls.isEmpty && !ctx.isProtected,
                          canPaste: FileClipboard.shared.hasFiles, canUndo: FileOps.shared.undoManager.canUndo)
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = backStack.popLast() else { NSSound.beep(); return }
        forwardStack.append(currentURL)
        navigate(to: previous, record: false, select: [currentURL])
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forwardStack.popLast() else { NSSound.beep(); return }
        backStack.append(currentURL)
        navigate(to: next, record: false, select: [currentURL])
    }

    @objc func goUp(_ sender: Any?) {
        guard let parent = parentURL else { NSSound.beep(); return }
        navigate(to: parent, select: [currentURL])
    }

    @objc func goToPlace(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        navigate(to: url)
    }

    @objc func refresh(_ sender: Any?) {
        fileListVC.reload()
        sidebarVC.refreshLoaded()
    }

    @objc func focusAddressBar(_ sender: Any?) {
        addressBar.breadcrumb.beginEditing()
    }

    // MARK: - Search, view mode, tabs

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(addressBar.searchField)
    }

    private func search(_ query: String) {
        if query.isEmpty {
            fileListVC.endSearch()
            window?.title = FileManager.default.displayName(atPath: currentURL.path)
        } else {
            fileListVC.startSearch(query, in: currentURL)
            window?.title = "Suche: \(query)"
        }
    }

    @objc func setViewMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ViewMode(rawValue: raw) else { return }
        fileListVC.setViewMode(mode)
        Settings.shared.defaultViewMode = raw
    }

    /// ⌘T and the "+" in the tab bar: a new tab showing the same folder.
    override func newWindowForTab(_ sender: Any?) {
        openTab(at: currentURL)
    }

    @objc func openInNewTab(_ sender: Any?) {
        guard let url = context(sender).urls.first else { return }
        openTab(at: url)
    }

    private func openTab(at url: URL) {
        guard let app = NSApp.delegate as? AppDelegate, let window, let newWindow = app.makeController(at: url).window else { return }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }

    /// If the folder shown on the right was renamed or removed, follow it / step out of it.
    private func fixCurrentFolder(old: URL, new: URL?) {
        let oldPath = old.standardizedFileURL.path
        guard currentURL.path == oldPath || currentURL.path.hasPrefix(oldPath + "/") else { return }
        if let new {
            let rest = String(currentURL.path.dropFirst(oldPath.count))
            navigate(to: URL(fileURLWithPath: new.path + rest), record: false)
        } else {
            navigate(to: old.deletingLastPathComponent(), record: false)
        }
    }

    // MARK: - What do commands work on?

    private var treeHasFocus: Bool { window?.firstResponder === sidebarVC.outline }

    private func treeContext(_ node: TreeNode) -> ActionContext? {
        guard let url = node.url else { return nil }
        return ActionContext(urls: [url], folder: node.isFolder ? url : url.deletingLastPathComponent(),
                             isProtected: node.kind != .entry, fromTree: true)
    }

    private func context(_ sender: Any?) -> ActionContext {
        if let item = sender as? NSMenuItem, let ctx = item.representedObject as? ActionContext { return ctx }
        if treeHasFocus, let node = sidebarVC.selectedNode, let ctx = treeContext(node) { return ctx }
        return ActionContext(urls: fileListVC.selectedItems.map(\.url), folder: currentURL)
    }

    // MARK: - Opening

    @objc func openSelection(_ sender: Any?) {
        let ctx = context(sender)
        if ctx.fromTree {
            guard let url = ctx.urls.first else { return }
            if DirectoryReader.isDirectory(url) && FileOps.shared.isPlainFolder(url) { navigate(to: url) } else { NSWorkspace.shared.open(url) }
        } else {
            fileListVC.openSelection()
        }
    }

    @objc func openInNewWindow(_ sender: Any?) {
        guard let url = context(sender).urls.first else { return }
        (NSApp.delegate as? AppDelegate)?.openWindow(at: url)
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? OpenWithRequest else { return }
        NSWorkspace.shared.open(request.urls, withApplicationAt: request.app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// From a search result: open the folder that contains it and select it.
    /// From a search result: open the folder in a NEW window with the file selected.
    /// This window keeps its search results.
    @objc func openContainingFolder(_ sender: Any?) {
        guard let url = context(sender).urls.first else { return }
        (NSApp.delegate as? AppDelegate)?.openWindow(at: url.deletingLastPathComponent(), select: [url])
    }

    @objc func revealInFinder(_ sender: Any?) {
        let ctx = context(sender)
        NSWorkspace.shared.activateFileViewerSelecting(ctx.urls.isEmpty ? [ctx.folder] : ctx.urls)
    }

    // MARK: - Clipboard

    @objc func cut(_ sender: Any?) {
        let ctx = context(sender)
        guard !ctx.urls.isEmpty, !ctx.isProtected else { NSSound.beep(); return }
        FileClipboard.shared.write(ctx.urls, cut: true)
    }

    @objc func copy(_ sender: Any?) {
        let ctx = context(sender)
        guard !ctx.urls.isEmpty else { NSSound.beep(); return }
        FileClipboard.shared.write(ctx.urls, cut: false)
    }

    @objc func paste(_ sender: Any?) {
        let ctx = context(sender)
        let clipboard = FileClipboard.shared
        let urls = clipboard.readURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let wasCut = clipboard.isCutActive
        let folder = ctx.folder
        FileOps.shared.transfer(urls, into: folder, kind: wasCut ? .move : .copy) { [weak self] results in
            if wasCut { clipboard.finishCut() }
            guard let self, folder.standardizedFileURL == self.currentURL else { return }
            self.fileListVC.load(self.currentURL, select: results)
        }
    }

    // MARK: - New, rename, trash

    @objc func newFolder(_ sender: Any?) {
        let folder = context(sender).folder
        guard let url = FileOps.shared.createFolder(in: folder) else { return }
        showNewItem(url, in: folder)
    }

    @objc func newTextFile(_ sender: Any?) {
        let folder = context(sender).folder
        guard let url = FileOps.shared.createTextFile(in: folder) else { return }
        showNewItem(url, in: folder)
    }

    /// Like Windows: show the new item and let the user type its name right away.
    private func showNewItem(_ url: URL, in folder: URL) {
        focusFileList()
        if folder.standardizedFileURL == currentURL {
            fileListVC.load(currentURL, select: [url], rename: true)
        } else {
            navigate(to: folder, select: [url], rename: true)
        }
    }

    @objc func renameItem(_ sender: Any?) {
        let ctx = context(sender)
        guard let url = ctx.urls.first, !ctx.isProtected else { NSSound.beep(); return }
        if ctx.fromTree {
            renameWithDialog(url)
        } else {
            focusFileList()
            fileListVC.beginRename(url)
        }
    }

    private func renameWithDialog(_ url: URL) {
        guard let name = FileOps.askNewName(for: url) else { return }
        if let new = FileOps.shared.rename(url, to: name) { fixCurrentFolder(old: url, new: new) }
    }

    func fileList(_ list: FileListViewController, rename url: URL, to name: String) {
        guard let new = FileOps.shared.rename(url, to: name) else { return }
        fixCurrentFolder(old: url, new: new)
        fileListVC.load(currentURL, select: [new])
    }

    @objc func moveToTrash(_ sender: Any?) {
        let ctx = context(sender)
        guard !ctx.urls.isEmpty, !ctx.isProtected else { NSSound.beep(); return }
        if Settings.shared.confirmTrash {
            let alert = NSAlert()
            alert.messageText = "In den Papierkorb legen?"
            alert.informativeText = ctx.urls.count == 1
                ? "„\(FileManager.default.displayName(atPath: ctx.urls[0].path))“ wird in den Papierkorb gelegt. Mit ⌘Z holst du es zurück."
                : "Diese \(ctx.urls.count) Elemente werden in den Papierkorb gelegt. Mit ⌘Z holst du sie zurück."
            alert.addButton(withTitle: "In den Papierkorb")
            alert.addButton(withTitle: "Abbrechen").keyEquivalent = "\u{1b}"
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Nicht mehr nachfragen"
            let answer = alert.runModal()
            if alert.suppressionButton?.state == .on && answer == .alertFirstButtonReturn { Settings.shared.confirmTrash = false }
            guard answer == .alertFirstButtonReturn else { return }
        }
        FileOps.shared.trashItems(ctx.urls)
        ctx.urls.forEach { fixCurrentFolder(old: $0, new: nil) }
    }

    @objc func toggleConfirmTrash(_ sender: Any?) {
        Settings.shared.confirmTrash.toggle()
    }

    // MARK: - ZIP, share, tags, properties

    @objc func compressItems(_ sender: Any?) {
        let ctx = context(sender)
        guard !ctx.urls.isEmpty else { NSSound.beep(); return }
        FileOps.shared.compress(ctx.urls) { [weak self] zip in
            guard let self, zip.deletingLastPathComponent().standardizedFileURL == self.currentURL else { return }
            self.fileListVC.load(self.currentURL, select: [zip])
        }
    }

    private func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    @objc func extractItem(_ sender: Any?) {
        guard let zip = context(sender).urls.first(where: isZip) else { NSSound.beep(); return }
        FileOps.shared.extract(zip) { [weak self] result in
            guard let self, result.deletingLastPathComponent().standardizedFileURL == self.currentURL else { return }
            self.fileListVC.load(self.currentURL, select: [result])
        }
    }

    @objc func shareItems(_ sender: Any?) {
        let ctx = context(sender)
        let urls = ctx.urls.isEmpty ? [ctx.folder] : ctx.urls
        let picker = NSSharingServicePicker(items: urls)
        if let view = sender as? NSView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let row = fileListVC.tableView.selectedRowIndexes.first {
            picker.show(relativeTo: fileListVC.tableView.rect(ofRow: row), of: fileListVC.tableView, preferredEdge: .maxY)
        } else if let view = window?.contentView {
            picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }

    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? TagRequest else { return }
        let ops = FileOps.shared
        let allHave = request.urls.allSatisfy { ops.tags(of: $0).contains(request.tag) }
        var map: [URL: [String]] = [:]
        for url in request.urls {
            var tags = ops.tags(of: url)
            if allHave { tags.removeAll { $0 == request.tag } } else if !tags.contains(request.tag) { tags.append(request.tag) }
            map[url] = tags
        }
        ops.setTags(map)
        fileListVC.reload()
    }

    @objc func showProperties(_ sender: Any?) {
        let ctx = context(sender)
        PropertiesWindowController.show(for: ctx.urls.isEmpty ? [ctx.folder] : ctx.urls)
    }

    // MARK: - Sidebar

    @objc func toggleSidebarPane(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
    }

    @objc func revealInTree(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebarVC.reveal(currentURL)
    }

    @objc func pinToFavorites(_ sender: NSMenuItem) {
        guard let url = context(sender).urls.first else { return }
        var list = Settings.shared.favorites
        if let index = list.firstIndex(of: url) { list.remove(at: index) } else { list.append(url) }
        Settings.shared.favorites = list
    }

    // MARK: - Settings

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Settings.shared.showHiddenFiles.toggle()
    }

    @objc func toggleFilesInTree(_ sender: Any?) {
        Settings.shared.hideFilesInTree.toggle()
    }

    // MARK: - Small helpers

    @objc func selectAllFiles(_ sender: Any?) {
        focusFileList()
        fileListVC.tableView.selectAll(nil)
    }

    @objc func copyPath(_ sender: Any?) {
        let ctx = context(sender)
        let paths = (ctx.urls.isEmpty ? [ctx.folder] : ctx.urls).map(\.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func openInTerminal(_ sender: Any?) {
        let ctx = context(sender)
        let folders = ctx.urls.filter { DirectoryReader.isDirectory($0) && FileOps.shared.isPlainFolder($0) }
        let target = folders.count == 1 && ctx.urls.count == 1 ? folders[0] : ctx.folder
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([target], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Sorting

    @objc func sortByColumn(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        fileListVC.setSort(key: key)
    }

    @objc func sortAscending(_ sender: Any?) { fileListVC.setSort(ascending: true) }
    @objc func sortDescending(_ sender: Any?) { fileListVC.setSort(ascending: false) }

    // MARK: - Menus

    private func menuItem(_ title: String, _ action: Selector?, _ ctx: ActionContext? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = ctx
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func submenuItem(_ title: String, symbol: String? = nil, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.submenu = menu
        return item
    }

    private func makeNewMenu(_ ctx: ActionContext) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Ordner", #selector(newFolder(_:)), ctx, symbol: "folder.badge.plus"))
        menu.addItem(menuItem("Textdokument", #selector(newTextFile(_:)), ctx, symbol: "doc.badge.plus"))
        return menu
    }

    private func makeSortMenu() -> NSMenu {
        let menu = NSMenu()
        for column in FileListViewController.columns {
            let item = NSMenuItem(title: column.title, action: #selector(sortByColumn(_:)), keyEquivalent: "")
            item.representedObject = column.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Aufsteigend", action: #selector(sortAscending(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Absteigend", action: #selector(sortDescending(_:)), keyEquivalent: ""))
        return menu
    }

    private func makeViewMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in ViewMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setViewMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Seitenleiste", action: #selector(toggleSidebarPane(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Vorschaubereich", action: #selector(togglePreviewPane(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Schnellansicht (Leertaste)", action: #selector(toggleQuickLook(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Versteckte Dateien anzeigen", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Dateien im Baum ausblenden", action: #selector(toggleFilesInTree(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Einstellungen …", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ""))
        return menu
    }

    private func makeTagMenu(_ urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        for (name, color) in Self.finderTags {
            let item = NSMenuItem(title: name, action: #selector(toggleTag(_:)), keyEquivalent: "")
            item.representedObject = TagRequest(urls: urls, tag: name)
            let config = NSImage.SymbolConfiguration(paletteColors: [color])
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: name)?.withSymbolConfiguration(config)
            item.state = !urls.isEmpty && urls.allSatisfy { FileOps.shared.tags(of: $0).contains(name) } ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeMoreMenu() -> NSMenu {
        let ctx = context(nil)
        let menu = NSMenu()
        menu.addItem(menuItem("Alles auswählen", #selector(selectAllFiles(_:)), symbol: "checklist"))
        menu.addItem(menuItem("Pfad kopieren", #selector(copyPath(_:)), symbol: "link"))
        menu.addItem(menuItem("Im Terminal öffnen", #selector(openInTerminal(_:)), symbol: "terminal"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Als ZIP komprimieren", #selector(compressItems(_:)), symbol: "doc.zipper"))
        menu.addItem(menuItem("Entpacken", #selector(extractItem(_:)), symbol: "arrow.up.bin"))
        menu.addItem(submenuItem("Tags", symbol: "tag", makeTagMenu(ctx.urls)))
        menu.addItem(menuItem("Eigenschaften", #selector(showProperties(_:)), symbol: "info.circle"))
        menu.addItem(.separator())
        let undo = menuItem(FileOps.shared.undoManager.undoMenuItemTitle, Selector(("undo:")), symbol: "arrow.uturn.backward")
        menu.addItem(undo)
        return menu
    }

    /// Right-click menu for the list (on items or on the empty background).
    func fileList(_ list: FileListViewController, buildMenu menu: NSMenu, clicked: FileItem?) {
        guard clicked != nil else {
            let ctx = ActionContext(urls: [], folder: currentURL)
            menu.addItem(submenuItem("Ansicht", symbol: "rectangle.split.3x1", makeViewMenu()))
            menu.addItem(submenuItem("Sortieren nach", symbol: "arrow.up.arrow.down", makeSortMenu()))
            menu.addItem(menuItem("Aktualisieren", #selector(refresh(_:)), symbol: "arrow.clockwise"))
            menu.addItem(.separator())
            menu.addItem(menuItem("Einfügen", #selector(paste(_:)), ctx, symbol: "doc.on.clipboard"))
            menu.addItem(menuItem(FileOps.shared.undoManager.undoMenuItemTitle, Selector(("undo:")), symbol: "arrow.uturn.backward"))
            menu.addItem(.separator())
            menu.addItem(submenuItem("Neu", symbol: "plus.circle", makeNewMenu(ctx)))
            menu.addItem(.separator())
            menu.addItem(menuItem("Im Terminal öffnen", #selector(openInTerminal(_:)), ctx, symbol: "terminal"))
            menu.addItem(menuItem("Pfad kopieren", #selector(copyPath(_:)), ctx, symbol: "link"))
            menu.addItem(menuItem("Eigenschaften", #selector(showProperties(_:)), ctx, symbol: "info.circle"))
            return
        }
        let selected = list.selectedItems
        let urls = selected.map(\.url)
        let ctx = ActionContext(urls: urls, folder: currentURL)
        let singleFolder = selected.count == 1 && selected[0].isFolder ? selected[0] : nil

        menu.addItem(menuItem("Öffnen", #selector(openSelection(_:)), ctx, symbol: "arrow.up.forward.app"))
        if fileListVC.searchQuery != nil, urls.count == 1 {
            menu.addItem(menuItem("Speicherort öffnen", #selector(openContainingFolder(_:)), ctx, symbol: "folder"))
        }
        if let folder = singleFolder {
            menu.addItem(menuItem("In neuem Tab öffnen", #selector(openInNewTab(_:)), ActionContext(urls: [folder.url], folder: folder.url), symbol: "plus.square.on.square"))
            menu.addItem(menuItem("In neuem Fenster öffnen", #selector(openInNewWindow(_:)), ActionContext(urls: [folder.url], folder: folder.url), symbol: "macwindow.badge.plus"))
        } else if selected.allSatisfy({ !$0.isFolder }), let first = urls.first {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: first).prefix(12)
            if !apps.isEmpty {
                let sub = NSMenu()
                for app in apps {
                    let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: #selector(openWithApp(_:)), keyEquivalent: "")
                    item.representedObject = OpenWithRequest(urls: urls, app: app)
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                    sub.addItem(item)
                }
                menu.addItem(submenuItem("Öffnen mit", symbol: "square.grid.2x2", sub))
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Ausschneiden", #selector(cut(_:)), ctx, symbol: "scissors"))
        menu.addItem(menuItem("Kopieren", #selector(copy(_:)), ctx, symbol: "doc.on.doc"))
        if let folder = singleFolder {
            menu.addItem(menuItem("Einfügen in „\(folder.name)“", #selector(paste(_:)), ActionContext(urls: [], folder: folder.url), symbol: "doc.on.clipboard"))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Umbenennen", #selector(renameItem(_:)), ctx, symbol: "character.cursor.ibeam"))
        menu.addItem(menuItem("In den Papierkorb legen", #selector(moveToTrash(_:)), ctx, symbol: "trash"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Als ZIP komprimieren", #selector(compressItems(_:)), ctx, symbol: "doc.zipper"))
        if urls.count == 1, isZip(urls[0]) {
            menu.addItem(menuItem("Entpacken", #selector(extractItem(_:)), ctx, symbol: "arrow.up.bin"))
        }
        menu.addItem(.separator())
        menu.addItem(NSSharingServicePicker(items: urls).standardShareMenuItem)
        menu.addItem(submenuItem("Tags", symbol: "tag", makeTagMenu(urls)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Pfad kopieren", #selector(copyPath(_:)), ctx, symbol: "link"))
        if let folder = singleFolder {
            let folderCtx = ActionContext(urls: [folder.url], folder: folder.url)
            menu.addItem(menuItem("Im Terminal öffnen", #selector(openInTerminal(_:)), folderCtx, symbol: "terminal"))
            let pinned = Settings.shared.favorites.contains(folder.url)
            menu.addItem(menuItem(pinned ? "Von Favoriten lösen" : "An Favoriten anheften", #selector(pinToFavorites(_:)), folderCtx, symbol: "star"))
        }
        menu.addItem(menuItem("Im Finder zeigen", #selector(revealInFinder(_:)), ctx, symbol: "macwindow"))
        menu.addItem(menuItem("Eigenschaften", #selector(showProperties(_:)), ctx, symbol: "info.circle"))
    }

    /// Right-click menu for the tree.
    func sidebar(_ sidebar: SidebarViewController, buildMenu menu: NSMenu, node: TreeNode) {
        guard let ctx = treeContext(node) else { return }
        menu.addItem(menuItem("Öffnen", #selector(openSelection(_:)), ctx, symbol: "arrow.up.forward.app"))
        if node.isFolder {
            menu.addItem(menuItem("In neuem Tab öffnen", #selector(openInNewTab(_:)), ctx, symbol: "plus.square.on.square"))
            menu.addItem(menuItem("In neuem Fenster öffnen", #selector(openInNewWindow(_:)), ctx, symbol: "macwindow.badge.plus"))
        }
        menu.addItem(.separator())
        if node.kind == .entry {
            menu.addItem(menuItem("Ausschneiden", #selector(cut(_:)), ctx, symbol: "scissors"))
        }
        menu.addItem(menuItem("Kopieren", #selector(copy(_:)), ctx, symbol: "doc.on.doc"))
        if node.isFolder {
            menu.addItem(menuItem("Einfügen", #selector(paste(_:)), ctx, symbol: "doc.on.clipboard"))
            menu.addItem(submenuItem("Neu", symbol: "plus.circle", makeNewMenu(ctx)))
        }
        if node.kind == .entry {
            menu.addItem(.separator())
            menu.addItem(menuItem("Umbenennen", #selector(renameItem(_:)), ctx, symbol: "character.cursor.ibeam"))
            menu.addItem(menuItem("In den Papierkorb legen", #selector(moveToTrash(_:)), ctx, symbol: "trash"))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Pfad kopieren", #selector(copyPath(_:)), ctx, symbol: "link"))
        if node.isFolder {
            menu.addItem(menuItem("Im Terminal öffnen", #selector(openInTerminal(_:)), ctx, symbol: "terminal"))
        }
        menu.addItem(menuItem("Im Finder zeigen", #selector(revealInFinder(_:)), ctx, symbol: "macwindow"))
        menu.addItem(menuItem("Eigenschaften", #selector(showProperties(_:)), ctx, symbol: "info.circle"))
    }

    // MARK: - Menu state

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let renaming = fileListVC.isRenaming
        switch item.action {
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goUp(_:)): return parentURL != nil
        case #selector(openSelection(_:)): return !context(item).urls.isEmpty
        case #selector(cut(_:)), #selector(moveToTrash(_:)), #selector(renameItem(_:)):
            let ctx = context(item)
            return !renaming && !ctx.urls.isEmpty && !ctx.isProtected
        case #selector(copy(_:)), #selector(compressItems(_:)):
            return !renaming && !context(item).urls.isEmpty
        case #selector(paste(_:)):
            return !renaming && FileClipboard.shared.hasFiles
        case #selector(extractItem(_:)):
            return context(item).urls.contains(where: isZip)
        case #selector(toggleConfirmTrash(_:)):
            item.state = Settings.shared.confirmTrash ? .on : .off
        case #selector(toggleHiddenFiles(_:)):
            item.state = Settings.shared.showHiddenFiles ? .on : .off
        case #selector(toggleFilesInTree(_:)):
            item.state = Settings.shared.hideFilesInTree ? .on : .off
        case #selector(toggleSidebarPane(_:)):
            if item.keyEquivalent.isEmpty {
                item.state = sidebarItem.isCollapsed ? .off : .on
            } else {
                item.title = sidebarItem.isCollapsed ? "Seitenleiste einblenden" : "Seitenleiste ausblenden"
            }
        case #selector(togglePreviewPane(_:)):
            if item.keyEquivalent.isEmpty {
                item.state = previewSplitItem.isCollapsed ? .off : .on
            } else {
                item.title = previewSplitItem.isCollapsed ? "Vorschaubereich einblenden" : "Vorschaubereich ausblenden"
            }
        case #selector(setViewMode(_:)):
            item.state = (item.representedObject as? String) == fileListVC.viewMode.rawValue ? .on : .off
        case #selector(sortByColumn(_:)):
            item.state = (item.representedObject as? String) == fileListVC.sortKey ? .on : .off
        case #selector(sortAscending(_:)):
            item.state = fileListVC.sortAscending ? .on : .off
        case #selector(sortDescending(_:)):
            item.state = fileListVC.sortAscending ? .off : .on
        default: break
        }
        return true
    }

    // MARK: - Delegates

    func sidebar(_ sidebar: SidebarViewController, openFolder url: URL) {
        navigate(to: url)
    }

    func sidebarSelectionChanged(_ sidebar: SidebarViewController) {
        updateCommandBar()
        updatePreview()
    }

    func fileList(_ list: FileListViewController, openFolder url: URL) {
        navigate(to: url)
    }

    func fileListDidChange(_ list: FileListViewController) {
        updateStatus()
    }
}
