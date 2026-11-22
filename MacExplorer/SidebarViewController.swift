import AppKit

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, openFolder url: URL)
    func sidebar(_ sidebar: SidebarViewController, buildMenu menu: NSMenu, node: TreeNode)
    func sidebarSelectionChanged(_ sidebar: SidebarViewController)
}

/// One row in the sidebar tree. Children of folders are loaded lazily on first expand.
final class TreeNode {
    enum Kind { case section, favorite, place, volume, entry }

    let kind: Kind
    let url: URL?
    var title: String
    var symbolName: String?
    var isFolder: Bool
    var isHiddenFile: Bool
    /// nil = not loaded yet.
    var children: [TreeNode]?

    private var cachedIcon: NSImage?

    init(section title: String) {
        kind = .section; url = nil; self.title = title
        isFolder = true; isHiddenFile = false; children = []
    }

    init(kind: Kind, url: URL, title: String, symbol: String? = nil, isFolder: Bool = true, hidden: Bool = false) {
        self.kind = kind; self.url = url; self.title = title
        symbolName = symbol; self.isFolder = isFolder; isHiddenFile = hidden
    }

    var icon: NSImage? {
        if let symbolName { return NSImage(systemSymbolName: symbolName, accessibilityDescription: title) }
        guard let url else { return nil }
        if cachedIcon == nil {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 16, height: 16)
            cachedIcon = image
        }
        return cachedIcon
    }

    /// (Re)reads the folder. Existing child nodes are reused so expanded subfolders stay expanded.
    func loadChildren() {
        guard kind != .section else { return }
        guard let url, isFolder else { children = []; return }
        let settings = Settings.shared
        var items = (try? DirectoryReader.contents(of: url, includeHidden: settings.showHiddenFiles)) ?? []
        if settings.hideFilesInTree { items = items.filter(\.isFolder) }
        items.sort(by: FileItem.folderFirstNameOrder)
        var existing: [URL: TreeNode] = [:]
        for child in children ?? [] { if let u = child.url { existing[u] = child } }
        children = items.map { item in
            if let node = existing[item.url], node.isFolder == item.isFolder {
                node.title = item.name
                node.isHiddenFile = item.isHidden
                return node
            }
            return TreeNode(kind: .entry, url: item.url, title: item.name, isFolder: item.isFolder, hidden: item.isHidden)
        }
    }

    func ensureChildren() -> [TreeNode] {
        if children == nil { loadChildren() }
        return children ?? []
    }

    /// Re-reads this node and every already-loaded descendant.
    func refreshLoaded() {
        guard kind != .section, children != nil else {
            children?.forEach { $0.refreshLoaded() }
            return
        }
        loadChildren()
        children?.forEach { $0.refreshLoaded() }
    }
}

final class SidebarOutlineView: NSOutlineView {
    var onActivate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 36 || event.keyCode == 76) && mods.isEmpty {
            onActivate?()
            return
        }
        super.keyDown(with: event)
    }
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var delegate: SidebarDelegate?
    let outline = SidebarOutlineView()

    private let favorites = TreeNode(section: "Favoriten")
    private let places = TreeNode(section: "Dieser Mac")
    private let drives = TreeNode(section: "Laufwerke")
    private var roots: [TreeNode] { [favorites, places, drives] }
    private var hoverNode: TreeNode?
    private var hoverTimer: Timer?

    var selectedNode: TreeNode? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? TreeNode : nil
    }

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.resizingMask = .autoresizingMask
        column.width = 240
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.onActivate = { [weak self] in
            guard let self else { return }
            self.activate(row: self.outline.selectedRow)
        }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        outline.registerForDraggedTypes([.fileURL] + promiseTypes)
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .move, .generic, .link, .delete], forLocal: false)
        outline.draggingDestinationFeedbackStyle = .regular

        scroll.documentView = outline
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildFavorites()
        buildPlaces()
        buildDrives()
        outline.reloadData()
        roots.forEach { outline.expandItem($0) }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        nc.addObserver(self, selector: #selector(favoritesChanged), name: .favoritesChanged, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: .filesChanged, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            ws.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        outline.sizeLastColumnToFit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Building the sections

    private func reuse(_ section: TreeNode, _ make: [(URL, () -> TreeNode)]) {
        var existing: [URL: TreeNode] = [:]
        for child in section.children ?? [] { if let u = child.url { existing[u] = child } }
        section.children = make.map { url, build in existing[url] ?? build() }
    }

    private func buildFavorites() {
        let fm = FileManager.default
        reuse(favorites, Settings.shared.favorites.map { url in
            (url, { TreeNode(kind: .favorite, url: url, title: fm.displayName(atPath: url.path)) })
        })
    }

    private func buildPlaces() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var list: [(URL, String)] = [
            (home, "house"),
            (home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            (home.appendingPathComponent("Documents"), "doc"),
            (home.appendingPathComponent("Downloads"), "arrow.down.circle"),
        ]
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if DirectoryReader.isDirectory(iCloud) { list.append((iCloud, "icloud")) }
        reuse(places, list.map { url, symbol in
            let title = url == iCloud ? "iCloud Drive" : fm.displayName(atPath: url.path)
            return (url, { TreeNode(kind: .place, url: url, title: title, symbol: symbol) })
        })
    }

    private func buildDrives() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        reuse(drives, urls.map { url in
            (url, {
                let v = try? url.resourceValues(forKeys: Set(keys))
                let symbol: String
                if v?.volumeIsLocal == false {
                    symbol = "network"
                } else if v?.volumeIsInternal == true && v?.volumeIsEjectable != true && v?.volumeIsRemovable != true {
                    symbol = "internaldrive"
                } else {
                    symbol = "externaldrive"
                }
                return TreeNode(kind: .volume, url: url, title: v?.volumeLocalizedName ?? url.lastPathComponent, symbol: symbol)
            })
        })
    }

    // MARK: - Updates (never collapse anything)

    @objc private func settingsChanged() { refreshLoaded() }

    @objc private func favoritesChanged() {
        buildFavorites()
        outline.reloadItem(favorites, reloadChildren: true)
    }

    @objc private func volumesChanged() {
        buildDrives()
        outline.reloadItem(drives, reloadChildren: true)
    }

    /// Re-reads everything that is already loaded, keeping expansion and scroll position.
    func refreshLoaded() {
        buildFavorites()
        buildDrives()
        roots.forEach { $0.refreshLoaded() }
        let visible = outline.visibleRect
        outline.reloadItem(nil, reloadChildren: true)
        outline.scrollToVisible(visible)
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return roots.count }
        return node.ensureChildren().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return roots[index] }
        return node.ensureChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TreeNode else { return false }
        return node.kind == .section || node.isFolder
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? TreeNode)?.kind == .section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? TreeNode)?.kind != .section
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        if node.kind == .section {
            let cell = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("Header"), owner: self) as? NSTableCellView
                ?? Cells.textCell("Header")
            cell.textField?.stringValue = node.title
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("Node"), owner: self) as? NSTableCellView
            ?? Cells.iconCell("Node")
        cell.textField?.stringValue = node.title
        cell.imageView?.image = node.icon
        cell.alphaValue = node.isHiddenFile ? 0.5 : 1
        cell.toolTip = node.url?.path
        return cell
    }

    /// Refresh a folder's contents each time it is opened, so the tree is never stale.
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode,
              node.kind != .section, node.children != nil else { return }
        node.loadChildren()
    }

    // MARK: - Opening

    @objc private func doubleClicked(_ sender: Any?) {
        activate(row: outline.clickedRow)
    }

    private func activate(row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? TreeNode, let url = node.url else { return }
        if node.isFolder {
            delegate?.sidebar(self, openFolder: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Show in tree

    private static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func contains(_ ancestor: String, _ path: String) -> Bool {
        if ancestor == path { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    /// Expands the tree down to `url` and selects it. Does not touch the main view.
    func reveal(_ url: URL) {
        let target = Self.resolved(url)
        let candidates = (places.children ?? []) + (drives.children ?? [])
        let best = candidates
            .compactMap { node -> (TreeNode, Int)? in
                guard let u = node.url else { return nil }
                let path = Self.resolved(u)
                return Self.contains(path, target) ? (node, path.count) : nil
            }
            .max { $0.1 < $1.1 }?.0
        guard var node = best else { NSSound.beep(); return }

        outline.expandItem(node.kind == .volume ? drives : places)
        while let u = node.url, Self.resolved(u) != target {
            outline.expandItem(node)
            guard let next = node.ensureChildren().first(where: { child in
                guard let cu = child.url else { return false }
                return Self.contains(Self.resolved(cu), target)
            }) else { break }
            node = next
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Center the row so it is easy to spot.
        let rect = outline.rect(ofRow: row)
        let clip = outline.visibleRect
        if !clip.contains(rect) {
            outline.scroll(NSPoint(x: 0, y: max(0, rect.midY - clip.height / 2)))
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? TreeNode, let url = node.url else { return }
        delegate?.sidebar(self, buildMenu: menu, node: node)

        guard node.isFolder else { return }
        menu.addItem(.separator())
        let isFavorite = Settings.shared.favorites.contains(url)
        let pin = NSMenuItem(title: isFavorite ? "Von Favoriten lösen" : "An Favoriten anheften",
                             action: #selector(toggleFavorite(_:)), keyEquivalent: "")
        pin.target = self
        pin.representedObject = url
        menu.addItem(pin)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        delegate?.sidebarSelectionChanged(self)
    }

    // MARK: - Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Only real entries can be dragged – never the shortcuts like "Dokumente" or whole drives.
        guard let node = item as? TreeNode, node.kind == .entry, let url = node.url else { return nil }
        return url as NSURL
    }

    /// Hovering over a closed folder during a drag opens it after a short moment.
    private func scheduleHoverExpand(_ node: TreeNode?) {
        guard node !== hoverNode else { return }
        hoverNode = node
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard let node, !outline.isItemExpanded(node) else { return }
        let timer = Timer(timeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self, self.hoverNode === node else { return }
            self.outline.expandItem(node)
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? TreeNode else { scheduleHoverExpand(nil); return [] }
        scheduleHoverExpand(node.kind == .section ? nil : node)

        if node === favorites {
            // Drop folders onto "Favoriten" to pin them.
            let urls = DropRules.urls(info)
            let current = Settings.shared.favorites
            let ok = !urls.isEmpty && urls.allSatisfy { DirectoryReader.isDirectory($0) && FileOps.shared.isPlainFolder($0) && !current.contains($0) }
            return ok ? .link : []
        }
        guard node.kind != .section, node.isFolder, let url = node.url else { return [] }
        if index != NSOutlineViewDropOnItemIndex {
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return DropRules.operation(info, into: url)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        scheduleHoverExpand(nil)
        guard let node = item as? TreeNode else { return false }
        if node === favorites {
            var list = Settings.shared.favorites
            let urls = DropRules.urls(info).filter { !list.contains($0) }
            let position = index >= 0 ? min(index, list.count) : list.count
            list.insert(contentsOf: urls, at: position)
            Settings.shared.favorites = list
            return true
        }
        guard let url = node.url else { return false }
        return DropRules.accept(info, into: url)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        scheduleHoverExpand(nil)
    }

    @objc private func toggleFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        var list = Settings.shared.favorites
        if let i = list.firstIndex(of: url) { list.remove(at: i) } else { list.append(url) }
        Settings.shared.favorites = list
    }
}
