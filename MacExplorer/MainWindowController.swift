import AppKit

final class RootViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 680))
    }
}

/// One explorer window: address bar, command bar, sidebar tree, details view and status bar.
/// The sidebar and the main view navigate independently of each other.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, SidebarDelegate, FileListDelegate {
    private let rootVC = RootViewController()
    private let splitVC = NSSplitViewController()
    let sidebarVC = SidebarViewController()
    let fileListVC = FileListViewController()
    private var sidebarItem: NSSplitViewItem!
    private let addressBar = AddressBarView()
    private var commandBar: CommandBarView!
    private let statusBar = StatusBarView()

    private(set) var currentURL: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var keyMonitor: Any?
    var onClose: (() -> Void)?

    init(url: URL) {
        currentURL = url.standardizedFileURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        commandBar = CommandBarView(sortMenu: { [unowned self] in self.makeSortMenu() },
                                    viewMenu: { [unowned self] in self.makeViewMenu() },
                                    moreMenu: { [unowned self] in self.makeMoreMenu() })
        buildLayout()
        window.contentViewController = rootVC
        window.setContentSize(NSSize(width: 1100, height: 680))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.initialFirstResponder = fileListVC.tableView

        sidebarVC.delegate = self
        fileListVC.delegate = self
        addressBar.breadcrumb.onNavigate = { [weak self] url in
            self?.navigate(to: url)
            self?.focusFileList()
        }
        addressBar.breadcrumb.onCancel = { [weak self] in self?.focusFileList() }
        installKeyMonitor()
        navigate(to: currentURL, record: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 560
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: fileListVC)
        contentItem.minimumThickness = 300
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)
        splitVC.splitView.dividerStyle = .thin
        splitVC.splitView.autosaveName = "MainSplit"
        rootVC.addChild(splitVC)

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

    private func focusFileList() {
        window?.makeFirstResponder(fileListVC.tableView)
    }

    /// Windows habits that are not menu shortcuts: Alt+Up/Left/Right and F5.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if window.firstResponder is NSText { return event }   // typing in a text field
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let inTree = window.firstResponder === self.sidebarVC.outline
            if mods == .option && event.keyCode == 126 { self.goUp(nil); return nil }                 // ⌥↑
            if mods == .option && event.keyCode == 123 && !inTree { self.goBack(nil); return nil }    // ⌥←
            if mods == .option && event.keyCode == 124 && !inTree { self.goForward(nil); return nil } // ⌥→
            if mods.isEmpty && event.keyCode == 96 { self.refresh(nil); return nil }                   // F5
            return event
        }
    }

    // MARK: - Navigation (main view only)

    private var parentURL: URL? {
        currentURL.path == "/" ? nil : currentURL.deletingLastPathComponent()
    }

    func navigate(to url: URL, record: Bool = true, select: URL? = nil) {
        let url = url.standardizedFileURL
        if record && url != currentURL {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }
        currentURL = url
        fileListVC.load(url, select: select)
        updateChrome()
    }

    private func updateChrome() {
        window?.title = FileManager.default.displayName(atPath: currentURL.path)
        window?.representedURL = currentURL
        addressBar.update(url: currentURL, canGoBack: !backStack.isEmpty,
                          canGoForward: !forwardStack.isEmpty, canGoUp: parentURL != nil)
    }

    private func updateStatus() {
        let selected = fileListVC.selectedItems
        let files = selected.filter { !$0.isFolder }
        let size: Int64? = files.isEmpty ? nil : files.compactMap(\.size).reduce(0, +)
        statusBar.update(total: fileListVC.items.count, selected: selected.count, selectedSize: size)
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = backStack.popLast() else { NSSound.beep(); return }
        forwardStack.append(currentURL)
        navigate(to: previous, record: false, select: currentURL)
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forwardStack.popLast() else { NSSound.beep(); return }
        backStack.append(currentURL)
        navigate(to: next, record: false, select: currentURL)
    }

    @objc func goUp(_ sender: Any?) {
        guard let parent = parentURL else { NSSound.beep(); return }
        navigate(to: parent, select: currentURL)
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

    @objc func openSelection(_ sender: Any?) {
        fileListVC.openSelection()
    }

    // MARK: - Sidebar

    @objc func toggleSidebarPane(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
    }

    @objc func revealInTree(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebarVC.reveal(currentURL)
    }

    // MARK: - Settings

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Settings.shared.showHiddenFiles.toggle()
    }

    @objc func toggleFilesInTree(_ sender: Any?) {
        Settings.shared.hideFilesInTree.toggle()
    }

    // MARK: - Small helpers (read-only)

    @objc func selectAllFiles(_ sender: Any?) {
        window?.makeFirstResponder(fileListVC.tableView)
        fileListVC.tableView.selectAll(nil)
    }

    @objc func copyPath(_ sender: Any?) {
        let selected = fileListVC.selectedItems.map(\.url)
        let paths = (selected.isEmpty ? [currentURL] : selected).map(\.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func openInTerminal(_ sender: Any?) {
        let selected = fileListVC.selectedItems
        let target = (selected.count == 1 && selected[0].isFolder) ? selected[0].url : currentURL
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

    // MARK: - Command bar menus

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
        menu.addItem(NSMenuItem(title: "Seitenleiste", action: #selector(toggleSidebarPane(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Vorschaubereich (kommt in Meilenstein 3)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Versteckte Dateien anzeigen", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Dateien im Baum ausblenden", action: #selector(toggleFilesInTree(_:)), keyEquivalent: ""))
        return menu
    }

    private func makeMoreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Alles auswählen", action: #selector(selectAllFiles(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Pfad kopieren", action: #selector(copyPath(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Im Terminal öffnen", action: #selector(openInTerminal(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        for title in ["Als ZIP komprimieren", "Entpacken", "Tags", "Informationen", "Rückgängig"] {
            menu.addItem(NSMenuItem(title: title + " (kommt in Meilenstein 2)", action: nil, keyEquivalent: ""))
        }
        return menu
    }

    // MARK: - Menu state

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goUp(_:)): return parentURL != nil
        case #selector(openSelection(_:)): return !fileListVC.selectedItems.isEmpty
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

    func fileList(_ list: FileListViewController, openFolder url: URL) {
        navigate(to: url)
    }

    func fileListDidChange(_ list: FileListViewController) {
        updateStatus()
    }
}
