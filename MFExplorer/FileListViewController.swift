import AppKit

protocol FileListDelegate: AnyObject {
    func fileList(_ list: FileListViewController, openFolder url: URL)
    func fileListDidChange(_ list: FileListViewController)
    func fileList(_ list: FileListViewController, rename url: URL, to name: String)
    func fileList(_ list: FileListViewController, buildMenu menu: NSMenu, clicked: FileItem?)
}

/// Semi-transparent selection rectangle.
private final class RubberBandView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}

final class FileTableView: NSTableView {
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 36 || event.keyCode == 76) && mods.isEmpty { onOpen?(); return }   // Enter
        if event.keyCode == 125 && mods == .command { onOpen?(); return }                       // Cmd+Down
        super.keyDown(with: event)
    }

    /// Dragging starts on the icon or the name, or anywhere on an already selected row. Elsewhere: selection rectangle.
    private func isOnName(_ point: NSPoint, row: Int) -> Bool {
        guard row >= 0 else { return false }
        let col = column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard col >= 0, let cell = view(atColumn: col, row: row, makeIfNecessary: false) as? NSTableCellView else { return true }
        let cellRect = cell.convert(cell.bounds, to: self)
        var right = cellRect.minX + 24
        if let text = cell.textField {
            let textRect = text.convert(text.bounds, to: self)
            right = textRect.minX + min(text.intrinsicContentSize.width, textRect.width) + 4
        }
        return point.x >= cellRect.minX && point.x <= right
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let mods = event.modifierFlags.intersection([.command, .shift])
        // Like Windows: an already selected row can be dragged from anywhere, and the whole selection moves.
        let onSelectedRow = row >= 0 && selectedRowIndexes.contains(row) && mods.isEmpty
        if event.clickCount > 1 || onSelectedRow || isOnName(point, row: row) {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        rubberBand(from: point, event: event, clickedRow: row)
    }

    private func rubberBand(from start: NSPoint, event: NSEvent, clickedRow: Int) {
        let mods = event.modifierFlags.intersection([.command, .shift])
        let initial = selectedRowIndexes
        let anchor = selectedRow
        let overlay = RubberBandView()
        var moved = false

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            autoscroll(with: next)
            let p = convert(next.locationInWindow, from: nil)
            if !moved && hypot(p.x - start.x, p.y - start.y) < 4 { continue }
            if !moved { moved = true; addSubview(overlay) }
            let rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            overlay.frame = rect
            let range = rows(in: rect)
            let hits = IndexSet(integersIn: range.location..<(range.location + range.length))
            if mods.contains(.command) {
                selectRowIndexes(initial.symmetricDifference(hits), byExtendingSelection: false)
            } else if mods.contains(.shift) {
                selectRowIndexes(initial.union(hits), byExtendingSelection: false)
            } else {
                selectRowIndexes(hits, byExtendingSelection: false)
            }
        }
        overlay.removeFromSuperview()
        guard !moved else { return }

        // A plain click without dragging.
        if clickedRow < 0 {
            if mods.isEmpty { deselectAll(nil) }
        } else if mods.contains(.command) {
            if initial.contains(clickedRow) { deselectRow(clickedRow) } else { selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: true) }
        } else if mods.contains(.shift), anchor >= 0 {
            selectRowIndexes(IndexSet(integersIn: min(anchor, clickedRow)...max(anchor, clickedRow)), byExtendingSelection: false)
        } else {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
    }
}

/// The main view: details table or icon grid, a folder's contents or search results.
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate {
    struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let visible: Bool
        var rightAligned = false
    }

    static let columns: [Column] = [
        Column(id: "name", title: "Name", width: 300, visible: true),
        Column(id: "modified", title: "Änderungsdatum", width: 150, visible: true),
        Column(id: "type", title: "Typ", width: 170, visible: true),
        Column(id: "size", title: "Größe", width: 90, visible: true, rightAligned: true),
        Column(id: "created", title: "Erstellungsdatum", width: 150, visible: false),
        Column(id: "accessed", title: "Zugriffsdatum", width: 150, visible: false),
        Column(id: "tags", title: "Tags", width: 120, visible: false),
        Column(id: "location", title: "Ordner", width: 260, visible: false),
        Column(id: "snippet", title: "Fundstelle", width: 380, visible: false),
    ]

    weak var delegate: FileListDelegate?
    let tableView = FileTableView()
    let iconView = IconCollectionView()
    private let scrollView = NSScrollView()
    private let iconScroll = NSScrollView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let messageButton = NSButton(title: "Festplattenvollzugriff erlauben …", target: nil, action: nil)
    private let messageStack = NSStackView()
    private let headerMenu = NSMenu()
    private let rowMenu = NSMenu()

    private(set) var items: [FileItem] = []
    private(set) var folderURL: URL?
    private var loadGeneration = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    private var renamingURL: URL?
    private var renameCancelled = false
    var isRenaming: Bool { renamingURL != nil }

    private(set) var viewMode: ViewMode = ViewMode(rawValue: Settings.shared.defaultViewMode) ?? .details
    private(set) var searchQuery: String?
    private(set) var isSearchRunning = false
    private var locationColumnWasHidden = true

    // Content search ("Inhalt")
    private let contentSearch = ContentSearch()
    private var searchesContent = false
    private var nameSearchDone = true
    private var contentSearchDone = true
    private var nameHits = Set<URL>()
    private var contentHits = Set<URL>()
    private enum SnippetState { case text(String), unreadable }
    private var snippets: [URL: SnippetState] = [:]
    private var snippetsLoading = Set<URL>()
    private let snippetQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    /// The view that has the keyboard focus in the current mode.
    var activeView: NSView { viewMode == .details ? tableView : iconView }

    private var selectedIndexes: IndexSet {
        if viewMode == .details { return tableView.selectedRowIndexes }
        return IndexSet(iconView.selectionIndexPaths.map(\.item))
    }

    var selectedItems: [FileItem] {
        selectedIndexes.compactMap { $0 < items.count ? items[$0] : nil }
    }

    private func setSelection(_ indexes: IndexSet, scroll: Bool = false) {
        if viewMode == .details {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            if scroll, let first = indexes.first { tableView.scrollRowToVisible(first) }
        } else {
            iconView.deselectAll(nil)
            let paths = Set(indexes.map { IndexPath(item: $0, section: 0) })
            iconView.selectItems(at: paths, scrollPosition: scroll ? .nearestHorizontalEdge : [])
            if scroll, let first = indexes.first { iconView.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .nearestHorizontalEdge) }
            delegate?.fileListDidChange(self)
        }
    }

    private func reloadViews(keepSelection: Bool = true) {
        let selection = keepSelection ? Set(selectedItems.map(\.url)) : []
        tableView.reloadData()
        iconView.reloadData()
        if keepSelection {
            setSelection(IndexSet(items.indices.filter { selection.contains(items[$0].url) }))
        }
    }

    // MARK: - View

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        for scroll in [scrollView, iconScroll] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
        }
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = tableView

        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 22
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false

        for info in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(info.id))
            column.title = info.title
            column.width = info.width
            column.minWidth = info.id == "name" ? 120 : 50
            column.isHidden = !info.visible
            column.sortDescriptorPrototype = NSSortDescriptor(key: info.id, ascending: true)
            if info.rightAligned { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
        rowMenu.delegate = self
        tableView.menu = rowMenu
        tableView.autosaveName = "FileListColumns"
        tableView.autosaveTableColumns = true
        // The search column is only shown while searching.
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location"))?.isHidden = true
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("snippet"))?.isHidden = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.onOpen = { [weak self] in self?.openSelection() }

        // Icon view
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        iconView.collectionViewLayout = layout
        iconView.isSelectable = true
        iconView.allowsMultipleSelection = true
        iconView.allowsEmptySelection = true
        iconView.backgroundColors = [.controlBackgroundColor]
        iconView.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        iconView.register(EmptyGapView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindInterItemGapIndicator,
                          withIdentifier: EmptyGapView.identifier)
        iconView.dataSource = self
        iconView.delegate = self
        iconView.menu = rowMenu
        iconView.onOpen = { [weak self] in self?.openSelection() }
        iconView.onDoubleClick = { [weak self] index in
            guard let self, index < self.items.count else { return }
            self.open([self.items[index]])
        }
        iconView.onSelectionChangedByMenu = { [weak self] in
            guard let self else { return }
            self.delegate?.fileListDidChange(self)
        }
        iconScroll.documentView = iconView

        // Drag & drop
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        for view in [tableView, iconView] as [NSView] {
            view.registerForDraggedTypes([.fileURL] + promiseTypes)
        }
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic, .link, .delete], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
        iconView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        iconView.setDraggingSourceOperationMask([.copy, .move, .generic, .link, .delete], forLocal: false)

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageButton.target = self
        messageButton.action = #selector(openPrivacySettings(_:))
        messageStack.orientation = .vertical
        messageStack.spacing = 10
        messageStack.addArrangedSubview(messageLabel)
        messageStack.addArrangedSubview(messageButton)
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.isHidden = true

        container.addSubview(scrollView)
        container.addSubview(iconScroll)
        container.addSubview(messageStack)
        for scroll in [scrollView, iconScroll] {
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: container.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            messageStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        view = container
        applyViewMode()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let defaults = UserDefaults.standard
        let key = defaults.string(forKey: "sortKey") ?? "name"
        let ascending = defaults.object(forKey: "sortAscending") as? Bool ?? true
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        nc.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        watcher?.cancel()
    }

    @objc private func settingsChanged() {
        if let searchQuery, let folderURL { startSearch(searchQuery, in: folderURL) } else { reload() }
    }

    @objc private func clipboardChanged() {
        guard !isRenaming else { return }
        reloadViews()
    }

    // MARK: - View mode (details / icons)

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let selection = selectedIndexes
        let hadFocus = view.window?.firstResponder === activeView
        viewMode = mode
        applyViewMode()
        iconView.reloadData()
        setSelection(selection, scroll: true)
        if hadFocus { view.window?.makeFirstResponder(activeView) }
    }

    private func applyViewMode() {
        let details = viewMode == .details
        scrollView.isHidden = !details
        iconScroll.isHidden = details
        if let layout = iconView.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = viewMode.itemSize
            layout.invalidateLayout()
        }
    }

    // MARK: - Loading

    /// Shows the contents of `url`. `select` highlights items (e.g. the folder you came from),
    /// `rename` starts renaming the first of them (used for "Neuer Ordner").
    func load(_ url: URL, select: [URL] = [], rename: Bool = false, preserveSelection: Bool = false) {
        if searchQuery != nil { endSearchMode() }
        let sameFolder = url == folderURL
        folderURL = url
        loadGeneration += 1
        let generation = loadGeneration
        let includeHidden = Settings.shared.showHiddenFiles
        var wanted = Set(select.map(\.standardizedFileURL))
        if preserveSelection { wanted.formUnion(selectedItems.map(\.url.standardizedFileURL)) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DirectoryReader.contents(of: url, includeHidden: includeHidden) }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.apply(result, select: wanted, scrollToTop: !preserveSelection && select.isEmpty)
                if !sameFolder || self.watcher == nil { self.watch(url) }
                if rename, let first = select.first { self.beginRename(first) }
            }
        }
    }

    func reload() {
        guard let folderURL, searchQuery == nil else { return }
        load(folderURL, preserveSelection: true)
    }

    private func apply(_ result: Result<[FileItem], Error>, select wanted: Set<URL>, scrollToTop: Bool) {
        switch result {
        case .success(let list):
            items = list
            sortItems()
            if items.isEmpty {
                showMessage("Dieser Ordner ist leer.", button: false)
            } else {
                messageStack.isHidden = true
            }
        case .failure(let error):
            items = []
            let code = (error as NSError).code
            if code == NSFileReadNoPermissionError {
                showMessage("Kein Zugriff auf diesen Ordner.\nmacOS erlaubt das erst nach deiner Freigabe.", button: true)
            } else if code == NSFileReadNoSuchFileError {
                showMessage("Dieser Ordner existiert nicht (mehr).", button: false)
            } else {
                showMessage("Der Ordner konnte nicht geöffnet werden.\n\(error.localizedDescription)", button: false)
            }
        }
        reloadViews(keepSelection: false)

        let rows = IndexSet(items.indices.filter { wanted.contains(items[$0].url.standardizedFileURL) })
        setSelection(rows, scroll: !rows.isEmpty)
        if rows.isEmpty, scrollToTop, !items.isEmpty {
            if viewMode == .details { tableView.scrollRowToVisible(0) } else { iconView.scroll(.zero) }
        }
        delegate?.fileListDidChange(self)
    }

    private func showMessage(_ text: String, button: Bool) {
        messageLabel.stringValue = text
        messageButton.isHidden = !button
        messageStack.isHidden = false
    }

    @objc private func openPrivacySettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reload automatically when something changes inside the folder (also from Finder or other apps).
    private func watch(_ url: URL) {
        watcher?.cancel()
        watcher = nil
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleReload(after delay: Double = 0.3) {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isRenaming { self.scheduleReload(after: 1); return }   // don't disturb typing
            self.reload()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Search

    /// Finds files and folders whose name contains `query`, in `root` and all subfolders.
    /// With the "Inhalt" switch on, also files whose content contains it (via the macOS search index).
    /// Results appear while the search is still running.
    func startSearch(_ query: String, in root: URL) {
        if searchQuery == nil {
            let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location"))
            locationColumnWasHidden = column?.isHidden ?? true
            column?.isHidden = false
        }
        contentSearch.stop()
        snippetQueue.cancelAllOperations()
        searchQuery = query
        searchesContent = Settings.shared.searchContent
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("snippet"))?.isHidden = !searchesContent
        folderURL = root
        loadGeneration += 1
        let generation = loadGeneration
        items = []
        nameHits = []
        contentHits = []
        snippets = [:]
        snippetsLoading = []
        nameSearchDone = false
        contentSearchDone = !searchesContent
        isSearchRunning = true
        messageStack.isHidden = true
        reloadViews(keepSelection: false)
        delegate?.fileListDidChange(self)

        let includeHidden = Settings.shared.showHiddenFiles
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: FileItem.resourceKeys,
                                                                   options: options, errorHandler: { _, _ in true }) else { return }
            var batch: [FileItem] = []
            var lastFlush = Date()
            var total = 0
            func flush(done: Bool) {
                let found = batch
                batch = []
                DispatchQueue.main.async {
                    guard let self, generation == self.loadGeneration else { return }
                    self.nameHits.formUnion(found.map(\.url.standardizedFileURL))
                    self.addSearchResults(found)
                    if done { self.nameSearchDone = true }
                    self.searchStateChanged(query)
                }
            }
            for case let url as URL in enumerator {
                if self?.loadGeneration != generation { return }
                if url.lastPathComponent.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    batch.append(FileItem(url: url))
                    total += 1
                    if total >= 10_000 { break }
                }
                if !batch.isEmpty && Date().timeIntervalSince(lastFlush) > 0.3 {
                    flush(done: false)
                    lastFlush = Date()
                }
            }
            flush(done: true)
        }

        guard searchesContent else { return }
        contentSearch.start(query, in: root) { [weak self] urls in
            DispatchQueue.global(qos: .userInitiated).async {
                let found = Self.filterContentHits(urls, root: root, includeHidden: includeHidden).map(FileItem.init)
                DispatchQueue.main.async {
                    guard let self, generation == self.loadGeneration else { return }
                    self.contentHits = Set(found.map(\.url.standardizedFileURL))
                    self.addSearchResults(found)
                    self.contentSearchDone = true
                    self.searchStateChanged(query)
                }
            }
        }
    }

    /// Spotlight also looks inside app bundles and hidden folders – leave those out, like the name search does.
    private static func filterContentHits(_ urls: [URL], root: URL, includeHidden: Bool) -> [URL] {
        let rootPath = root.standardizedFileURL.path
        var packageCache: [String: Bool] = [:]
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { return false }
            var parent = url.deletingLastPathComponent().standardizedFileURL
            while parent.path.count > rootPath.count {
                let isPackage = packageCache[parent.path] ?? ((try? parent.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false)
                packageCache[parent.path] = isPackage
                if isPackage { return false }
                parent = parent.deletingLastPathComponent()
            }
            if includeHidden { return true }
            let relative = path.dropFirst(rootPath.count + 1)
            return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
        }
    }

    private func addSearchResults(_ found: [FileItem]) {
        let known = Set(items.map(\.url.standardizedFileURL))
        let fresh = found.filter { !known.contains($0.url.standardizedFileURL) }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        sortItems()
        reloadViews()
    }

    private func searchStateChanged(_ query: String) {
        isSearchRunning = !(nameSearchDone && contentSearchDone)
        if !isSearchRunning && items.isEmpty {
            showMessage("Keine Treffer für „\(query)“.", button: false)
        }
        if searchesContent { tableView.reloadData(forRowIndexes: IndexSet(items.indices), columnIndexes: snippetColumnIndexes) }
        delegate?.fileListDidChange(self)
    }

    private var snippetColumnIndexes: IndexSet {
        let index = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("snippet"))
        return index >= 0 ? IndexSet(integer: index) : IndexSet()
    }

    /// Text for the "Fundstelle" column. The line is read only for rows that are actually visible.
    private func snippetCell(_ item: FileItem) -> NSAttributedString {
        func plain(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                                                          .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        }
        guard let query = searchQuery else { return plain("") }
        let url = item.url.standardizedFileURL
        if !contentHits.contains(url) {
            return plain(nameHits.contains(url) ? "Treffer im Namen" : "")
        }
        switch snippets[url] {
        case .text(let line)?: return Snippet.highlighted(line, word: query)
        case .unreadable?: return plain("Im Inhalt gefunden")
        case nil:
            loadSnippet(for: url, query: query)
            return plain("Wird gelesen …")
        }
    }

    private func loadSnippet(for url: URL, query: String) {
        guard !snippetsLoading.contains(url) else { return }
        snippetsLoading.insert(url)
        let generation = loadGeneration
        snippetQueue.addOperation { [weak self] in
            let line = Snippet.find(query, in: url)
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                self.snippets[url] = line.map { .text($0) } ?? .unreadable
                if let row = self.items.firstIndex(where: { $0.url.standardizedFileURL == url }) {
                    self.tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: self.snippetColumnIndexes)
                }
            }
        }
    }

    #if DEBUG
    /// Test helper: what the "Fundstelle" column shows for each result.
    func debugSearchReport() -> [String] {
        items.map { "\($0.url.lastPathComponent) | \(snippetCell($0).string)" }
    }
    #endif

    /// Leave search mode and show the folder again.
    func endSearch() {
        guard searchQuery != nil, let folderURL else { return }
        load(folderURL)
    }

    private func endSearchMode() {
        contentSearch.stop()
        snippetQueue.cancelAllOperations()
        searchQuery = nil
        isSearchRunning = false
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location"))?.isHidden = locationColumnWasHidden
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("snippet"))?.isHidden = true
    }

    // MARK: - Sorting

    var sortKey: String { tableView.sortDescriptors.first?.key ?? "name" }
    var sortAscending: Bool { tableView.sortDescriptors.first?.ascending ?? true }

    func setSort(key: String? = nil, ascending: Bool? = nil) {
        tableView.sortDescriptors = [NSSortDescriptor(key: key ?? sortKey, ascending: ascending ?? sortAscending)]
    }

    private func sortItems() {
        let key = sortKey, ascending = sortAscending
        items.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }   // folders always on top, like Windows
            var result = key == "location"
                ? a.url.deletingLastPathComponent().path.localizedStandardCompare(b.url.deletingLastPathComponent().path)
                : FileItem.compare(a, b, key: key)
            if result == .orderedSame { result = a.name.localizedStandardCompare(b.name) }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        UserDefaults.standard.set(sortKey, forKey: "sortKey")
        UserDefaults.standard.set(sortAscending, forKey: "sortAscending")
        let selected = Set(selectedItems.map(\.url))
        sortItems()
        reloadViews(keepSelection: false)
        setSelection(IndexSet(items.indices.filter { selected.contains(items[$0].url) }))
    }

    private func locationText(_ item: FileItem) -> String {
        let path = item.url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < items.count else { return nil }
        let item = items[row]
        let id = column.identifier.rawValue
        let dimmed = item.isHidden || FileClipboard.shared.isCut(item.url)
        if id == "name" {
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("NameCell"), owner: self) as? NSTableCellView
                ?? Cells.iconCell("NameCell")
            cell.textField?.isEditable = false
            cell.textField?.drawsBackground = false
            cell.textField?.stringValue = item.name
            cell.imageView?.image = item.icon
            cell.alphaValue = dimmed ? 0.5 : 1
            return cell
        }
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("TextCell"), owner: self) as? NSTableCellView
            ?? Cells.textCell("TextCell")
        let text: String
        switch id {
        case "modified": text = Format.date(item.modified)
        case "created": text = Format.date(item.created)
        case "accessed": text = Format.date(item.accessed)
        case "type": text = item.typeName
        case "size": text = Format.size(item.size)
        case "tags": text = item.tags.joined(separator: ", ")
        case "location": text = locationText(item)
        case "snippet":
            cell.textField?.alignment = .left
            cell.textField?.attributedStringValue = snippetCell(item)
            cell.toolTip = cell.textField?.stringValue
            cell.alphaValue = 1
            return cell
        default: text = ""
        }
        cell.toolTip = nil
        cell.textField?.stringValue = text
        cell.textField?.alignment = id == "size" ? .right : .left
        cell.textField?.textColor = .secondaryLabelColor
        cell.alphaValue = dimmed ? 0.5 : 1
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.fileListDidChange(self)
    }

    // MARK: - Icon view data

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        guard let tile = tile as? IconItem, indexPath.item < items.count else { return tile }
        let item = items[indexPath.item]
        let size = viewMode.iconSize
        let dimmed = item.isHidden || FileClipboard.shared.isCut(item.url)
        let thumbnails = ThumbnailCache.shared
        if !item.isFolder, let cached = thumbnails.cached(item.url, size: size) {
            tile.configure(item, size: size, image: cached, dimmed: dimmed)
        } else {
            tile.configure(item, size: size, image: NSWorkspace.shared.icon(forFile: item.url.path), dimmed: dimmed)
            if !item.isFolder {
                let url = item.url
                thumbnails.request(url, size: size, scale: view.window?.backingScaleFactor ?? 2) { [weak tile] image in
                    guard let tile, tile.url == url else { return }
                    tile.setImage(image)
                }
            }
        }
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: EmptyGapView.identifier, for: indexPath)
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        delegate?.fileListDidChange(self)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        delegate?.fileListDidChange(self)
    }

    // MARK: - Opening

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        open([items[row]])
    }

    func openSelection() { open(selectedItems) }

    private func open(_ list: [FileItem]) {
        for file in list where !file.isFolder { NSWorkspace.shared.open(file.url) }
        if let folder = list.first(where: \.isFolder) { delegate?.fileList(self, openFolder: folder.url) }
    }

    // MARK: - Renaming (F2)

    func beginRename(_ url: URL? = nil) {
        guard let target = (url ?? selectedItems.first?.url)?.standardizedFileURL,
              let row = items.firstIndex(where: { $0.url.standardizedFileURL == target }) else { NSSound.beep(); return }
        setSelection(IndexSet(integer: row), scroll: true)
        if viewMode != .details {
            // Icon view: ask in a small dialog.
            let original = items[row].url
            DispatchQueue.main.async { [weak self] in
                guard let self, let name = FileOps.askNewName(for: original) else { return }
                self.delegate?.fileList(self, rename: original, to: name)
            }
            return
        }
        let col = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard col >= 0, let cell = tableView.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renamingURL = items[row].url
        renameCancelled = false
        field.stringValue = items[row].url.lastPathComponent   // the real name, with extension
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .exterior
        field.delegate = self
        cell.alphaValue = 1
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let name = field.stringValue as NSString
            let ext = items[row].isFolder ? "" : name.pathExtension
            let length = ext.isEmpty ? name.length : name.length - (ext as NSString).length - 1
            editor.selectedRange = NSRange(location: 0, length: max(0, length))
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard isRenaming else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            view.window?.makeFirstResponder(tableView)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(tableView)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let url = renamingURL else { return }
        renamingURL = nil
        field.isEditable = false
        field.drawsBackground = false
        field.delegate = nil
        let newName = field.stringValue
        let cancelled = renameCancelled
        reloadViews()   // show the normal name again
        if !cancelled { delegate?.fileList(self, rename: url, to: newName) }
    }

    // MARK: - Drag & drop (details)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < items.count, !isRenaming else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, updateDraggingItemsForDrag info: NSDraggingInfo) {
        let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        DropRules.showAsRows(info, in: tableView, width: nameColumn?.width ?? 300, rowHeight: tableView.rowHeight)
    }

    private func dropTarget(index: Int, on: Bool) -> URL? {
        if on, index >= 0, index < items.count, items[index].isFolder { return items[index].url }
        return searchQuery == nil ? folderURL : nil   // search results: only drops onto folders
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        let onFolder = operation == .on && row >= 0 && row < items.count && items[row].isFolder
        if onFolder, let target = dropTarget(index: row, on: true) {
            let result = DropRules.operation(info, into: target)
            if !result.isEmpty { return result }
        }
        // Not on a folder (or not possible there): drop into the current folder, highlight the whole list.
        tableView.setDropRow(-1, dropOperation: .on)
        guard let folder = dropTarget(index: -1, on: false) else { return [] }
        return DropRules.operation(info, into: folder)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let target = dropTarget(index: row, on: dropOperation == .on) else { return false }
        return accept(info, into: target)
    }

    private func accept(_ info: NSDraggingInfo, into target: URL) -> Bool {
        let intoCurrent = searchQuery == nil && target.standardizedFileURL == folderURL?.standardizedFileURL
        return DropRules.accept(info, into: target) { [weak self] results in
            guard let self, intoCurrent, let folder = self.folderURL else { return }
            self.load(folder, select: results)
        }
    }

    // MARK: - Drag & drop (icons)

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        !isRenaming
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        indexPath.item < items.count ? items[indexPath.item].url as NSURL : nil
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath indexPathPointer: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation operationPointer: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let index = (indexPathPointer.pointee as IndexPath).item
        if operationPointer.pointee == .on, let target = dropTarget(index: index, on: true), index < items.count, items[index].isFolder {
            let result = DropRules.operation(info, into: target)
            if !result.isEmpty {
                iconView.dropHighlight = false
                return result
            }
        }
        operationPointer.pointee = .before
        guard let folder = dropTarget(index: -1, on: false) else { iconView.dropHighlight = false; return [] }
        let result = DropRules.operation(info, into: folder)
        iconView.dropHighlight = !result.isEmpty
        return result
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        iconView.dropHighlight = false
        guard let target = dropTarget(index: indexPath.item, on: dropOperation == .on) else { return false }
        return accept(info, into: target)
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === headerMenu {
            for column in tableView.tableColumns where column.identifier.rawValue != "name" {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
            return
        }
        var clicked: FileItem?
        if viewMode == .details {
            // Right-click: like Windows, a click on an unselected item selects just that item.
            let row = tableView.clickedRow
            if row >= 0, row < items.count {
                if !tableView.selectedRowIndexes.contains(row) {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                clicked = items[row]
            } else {
                tableView.deselectAll(nil)
            }
        } else if let index = iconView.rightClickedIndex, index < items.count {
            clicked = items[index]
        }
        delegate?.fileList(self, buildMenu: menu, clicked: clicked)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
    }
}
