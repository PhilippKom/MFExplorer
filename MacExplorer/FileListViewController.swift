import AppKit

protocol FileListDelegate: AnyObject {
    func fileList(_ list: FileListViewController, openFolder url: URL)
    func fileListDidChange(_ list: FileListViewController)
}

final class FileTableView: NSTableView {
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 36 || event.keyCode == 76) && mods.isEmpty { onOpen?(); return }   // Enter
        if event.keyCode == 125 && mods == .command { onOpen?(); return }                       // Cmd+Down
        super.keyDown(with: event)
    }
}

/// The details view: a table with sortable, resizable, reorderable columns.
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
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
    ]

    weak var delegate: FileListDelegate?
    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let messageButton = NSButton(title: "Festplattenvollzugriff erlauben …", target: nil, action: nil)
    private let messageStack = NSStackView()

    private(set) var items: [FileItem] = []
    private(set) var folderURL: URL?
    private var loadGeneration = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
    }

    // MARK: - View

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
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
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
        tableView.autosaveName = "FileListColumns"
        tableView.autosaveTableColumns = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.onOpen = { [weak self] in self?.openSelection() }

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
        container.addSubview(messageStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            messageStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let defaults = UserDefaults.standard
        let key = defaults.string(forKey: "sortKey") ?? "name"
        let ascending = defaults.object(forKey: "sortAscending") as? Bool ?? true
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        watcher?.cancel()
    }

    @objc private func settingsChanged() { reload() }

    // MARK: - Loading

    /// Shows the contents of `url`. `select` highlights one item (e.g. the folder you came from).
    func load(_ url: URL, select: URL? = nil, preserveSelection: Bool = false) {
        let sameFolder = url == folderURL
        folderURL = url
        loadGeneration += 1
        let generation = loadGeneration
        let includeHidden = Settings.shared.showHiddenFiles
        let keep: Set<URL> = preserveSelection ? Set(selectedItems.map(\.url)) : []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DirectoryReader.contents(of: url, includeHidden: includeHidden) }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.apply(result, keep: keep, select: select, scrollToTop: !preserveSelection)
                if !sameFolder || self.watcher == nil { self.watch(url) }
            }
        }
    }

    func reload() {
        guard let folderURL else { return }
        load(folderURL, preserveSelection: true)
    }

    private func apply(_ result: Result<[FileItem], Error>, keep: Set<URL>, select: URL?, scrollToTop: Bool) {
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
        tableView.reloadData()

        var wanted = keep
        if let select { wanted.insert(select.standardizedFileURL) }
        let rows = IndexSet(items.indices.filter { wanted.contains(items[$0].url.standardizedFileURL) })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first {
            tableView.scrollRowToVisible(first)
        } else if scrollToTop, !items.isEmpty {
            tableView.scrollRowToVisible(0)
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

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
            var result = FileItem.compare(a, b, key: key)
            if result == .orderedSame { result = a.name.localizedStandardCompare(b.name) }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        UserDefaults.standard.set(sortKey, forKey: "sortKey")
        UserDefaults.standard.set(sortAscending, forKey: "sortAscending")
        let selected = Set(selectedItems.map(\.url))
        sortItems()
        tableView.reloadData()
        let rows = IndexSet(items.indices.filter { selected.contains(items[$0].url) })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < items.count else { return nil }
        let item = items[row]
        let id = column.identifier.rawValue
        if id == "name" {
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("NameCell"), owner: self) as? NSTableCellView
                ?? Cells.iconCell("NameCell")
            cell.textField?.stringValue = item.name
            cell.imageView?.image = item.icon
            cell.alphaValue = item.isHidden ? 0.5 : 1
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
        default: text = ""
        }
        cell.textField?.stringValue = text
        cell.textField?.alignment = id == "size" ? .right : .left
        cell.textField?.textColor = .secondaryLabelColor
        cell.alphaValue = item.isHidden ? 0.5 : 1
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
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

    // MARK: - Column header menu (show / hide columns)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in tableView.tableColumns where column.identifier.rawValue != "name" {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column
            item.state = column.isHidden ? .off : .on
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
    }
}
