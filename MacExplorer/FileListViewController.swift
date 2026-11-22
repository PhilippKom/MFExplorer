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

    /// Like Windows: dragging starts only on the icon or the name. Anywhere else draws a selection rectangle.
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
        if event.clickCount > 1 || isOnName(point, row: row) {
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

/// The details view: a table with sortable, resizable, reorderable columns.
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
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
    ]

    weak var delegate: FileListDelegate?
    let tableView = FileTableView()
    private let scrollView = NSScrollView()
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
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
        rowMenu.delegate = self
        tableView.menu = rowMenu
        tableView.autosaveName = "FileListColumns"
        tableView.autosaveTableColumns = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.onOpen = { [weak self] in self?.openSelection() }

        // Drag & drop
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        tableView.registerForDraggedTypes([.fileURL] + promiseTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic, .link, .delete], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular

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
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        nc.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        watcher?.cancel()
    }

    @objc private func settingsChanged() { reload() }

    @objc private func clipboardChanged() {
        guard !isRenaming else { return }
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
    }

    // MARK: - Loading

    /// Shows the contents of `url`. `select` highlights items (e.g. the folder you came from),
    /// `rename` starts renaming the first of them (used for "Neuer Ordner").
    func load(_ url: URL, select: [URL] = [], rename: Bool = false, preserveSelection: Bool = false) {
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
        guard let folderURL else { return }
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
        tableView.reloadData()

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
        default: text = ""
        }
        cell.textField?.stringValue = text
        cell.textField?.alignment = id == "size" ? .right : .left
        cell.textField?.textColor = .secondaryLabelColor
        cell.alphaValue = dimmed ? 0.5 : 1
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

    // MARK: - Renaming in place (F2)

    func beginRename(_ url: URL? = nil) {
        guard let target = (url ?? selectedItems.first?.url)?.standardizedFileURL,
              let row = items.firstIndex(where: { $0.url.standardizedFileURL == target }) else { NSSound.beep(); return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
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
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()   // show the normal name again
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
        if !cancelled { delegate?.fileList(self, rename: url, to: newName) }
    }

    // MARK: - Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < items.count, !isRenaming else { return nil }
        return items[row].url as NSURL
    }

    private func dropTarget(row: Int, operation: NSTableView.DropOperation) -> URL? {
        if operation == .on, row >= 0, row < items.count, items[row].isFolder { return items[row].url }
        return folderURL
    }

    func tableView(_ tableView: NSTableView, updateDraggingItemsForDrag info: NSDraggingInfo) {
        let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        DropRules.showAsRows(info, in: tableView, width: nameColumn?.width ?? 300, rowHeight: tableView.rowHeight)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if !(operation == .on && row >= 0 && row < items.count && items[row].isFolder) {
            tableView.setDropRow(-1, dropOperation: .on)   // highlight the whole list = current folder
        }
        guard let target = dropTarget(row: row, operation: operation) else { return [] }
        let result = DropRules.operation(info, into: target)
        if result.isEmpty && row >= 0 {
            // Can't drop on that folder (e.g. onto itself) – try the current folder instead.
            tableView.setDropRow(-1, dropOperation: .on)
            guard let folderURL else { return [] }
            return DropRules.operation(info, into: folderURL)
        }
        return result
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let target = dropTarget(row: row, operation: dropOperation) else { return false }
        let intoCurrent = target.standardizedFileURL == folderURL?.standardizedFileURL
        return DropRules.accept(info, into: target) { [weak self] results in
            guard let self, intoCurrent, let folder = self.folderURL else { return }
            self.load(folder, select: results)
        }
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
        // Right-click: like Windows, a click on an unselected item selects just that item.
        let row = tableView.clickedRow
        var clicked: FileItem?
        if row >= 0, row < items.count {
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            clicked = items[row]
        } else {
            tableView.deselectAll(nil)
        }
        delegate?.fileList(self, buildMenu: menu, clicked: clicked)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
    }
}
