import AppKit

// MARK: - Buttons

enum BarButton {
    /// A flat toolbar-like button that shows its border only on hover. `title == nil` → icon only.
    static func configure(_ button: NSButton, symbol: String, title: String?, tip: String, action: Selector?, pointSize: CGFloat = 15) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.title = title ?? ""
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        button.toolTip = tip
        button.target = nil
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        if title == nil { button.widthAnchor.constraint(equalToConstant: 32).isActive = true }
    }

    static func make(symbol: String, title: String? = nil, tip: String, action: Selector?, pointSize: CGFloat = 15) -> NSButton {
        let b = NSButton()
        configure(b, symbol: symbol, title: title, tip: tip, action: action, pointSize: pointSize)
        return b
    }

    static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return box
    }
}

/// A button that opens a drop-down menu when clicked.
final class MenuButton: NSButton {
    var menuProvider: (() -> NSMenu)?

    static func make(symbol: String, title: String?, tip: String, provider: @escaping () -> NSMenu) -> MenuButton {
        let b = MenuButton()
        BarButton.configure(b, symbol: symbol, title: title, tip: tip, action: nil)
        b.target = b
        b.action = #selector(showMenu(_:))
        b.menuProvider = provider
        return b
    }

    @objc func showMenu(_ sender: Any?) {
        guard let menu = menuProvider?() else { return }
        let y = isFlipped ? bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: self)
    }
}

// MARK: - Address bar

final class AddressBarView: NSView {
    let backButton = BarButton.make(symbol: "arrow.left", tip: "Zurück (⌘[ oder ⌥←)", action: #selector(MainWindowController.goBack(_:)))
    let forwardButton = BarButton.make(symbol: "arrow.right", tip: "Vor (⌘] oder ⌥→)", action: #selector(MainWindowController.goForward(_:)))
    let upButton = BarButton.make(symbol: "arrow.up", tip: "Eine Ebene nach oben (⌘↑ oder ⌥↑)", action: #selector(MainWindowController.goUp(_:)))
    let refreshButton = BarButton.make(symbol: "arrow.clockwise", tip: "Aktualisieren (⌘R oder F5)", action: #selector(MainWindowController.refresh(_:)))
    let breadcrumb = BreadcrumbView()
    let searchField = NSSearchField()
    let contentToggle = NSButton()
    var onSearch: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.toolTip = "Sucht im aktuellen Ordner und allen Unterordnern nach Namen – mit „Inhalt“ auch im Text der Dateien (⌘F)"
        BarButton.configure(contentToggle, symbol: "doc.text.magnifyingglass", title: "Inhalt",
                            tip: "Auch im Inhalt von Dateien suchen (Texte, PDFs, Word, Excel …). Nutzt den Suchindex von macOS.",
                            action: #selector(contentToggled(_:)))
        contentToggle.target = self
        contentToggle.setButtonType(.pushOnPushOff)
        contentToggle.state = Settings.shared.searchContent ? .on : .off
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        let stack = NSStackView(views: [backButton, forwardButton, upButton, refreshButton, breadcrumb, searchField, contentToggle])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.setCustomSpacing(8, after: refreshButton)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        breadcrumb.setContentHuggingPriority(.defaultLow, for: .horizontal)
        breadcrumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func contentToggled(_ sender: NSButton) {
        Settings.shared.searchContent = sender.state == .on   // running searches restart by themselves
    }

    @objc private func settingsChanged() {
        contentToggle.state = Settings.shared.searchContent ? .on : .off
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        onSearch?(sender.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func clearSearch() { searchField.stringValue = "" }

    func update(url: URL, canGoBack: Bool, canGoForward: Bool, canGoUp: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        upButton.isEnabled = canGoUp
        breadcrumb.url = url
        searchField.placeholderString = "Durchsuchen: \(FileManager.default.displayName(atPath: url.path))"
    }
}

/// Clickable path segments. Clicking empty space turns it into a text field for typing a path.
final class BreadcrumbView: NSView, NSTextFieldDelegate {
    var onNavigate: ((URL) -> Void)?
    var onCancel: (() -> Void)?

    private let iconView = NSImageView()
    private let clip = NSView()
    private let stack = NSStackView()
    private let field = NSTextField()
    private var segmentURLs: [URL] = []
    private(set) var isEditing = false

    var url: URL? {
        didSet { rebuild() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.clipsToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.isHidden = true
        field.placeholderString = "Pfad eingeben, z. B. ~/Dokumente"

        addSubview(iconView)
        addSubview(clip)
        clip.addSubview(stack)
        addSubview(field)

        let leading = stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor)
        leading.priority = NSLayoutConstraint.Priority(500)   // if the path is too long, the left part slides out
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            clip.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clip.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            leading,
            stack.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isEditing ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isEditing ? 2 : 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        beginEditing()
    }

    // MARK: Segments

    private static func segments(for url: URL) -> [URL] {
        var list: [URL] = []
        var current = url.standardizedFileURL
        while true {
            list.insert(current, at: 0)
            if current.path == "/" { break }
            if (try? current.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true { break }
            current = current.deletingLastPathComponent()
        }
        return list
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        iconView.image = icon

        segmentURLs = Self.segments(for: url)
        let fm = FileManager.default
        for (index, segment) in segmentURLs.enumerated() {
            let button = NSButton(title: fm.displayName(atPath: segment.path), target: self, action: #selector(segmentClicked(_:)))
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.font = .systemFont(ofSize: 13)
            button.tag = index
            button.toolTip = segment.path
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(button)

            let chevron = NSButton()
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Unterordner")
            chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            chevron.imagePosition = .imageOnly
            chevron.bezelStyle = .accessoryBarAction
            chevron.showsBorderOnlyWhileMouseInside = true
            chevron.tag = index
            chevron.target = self
            chevron.action = #selector(chevronClicked(_:))
            chevron.toolTip = "Unterordner anzeigen"
            chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
            chevron.widthAnchor.constraint(equalToConstant: 18).isActive = true
            stack.addArrangedSubview(chevron)
        }
        needsLayout = true
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard sender.tag < segmentURLs.count else { return }
        onNavigate?(segmentURLs[sender.tag])
    }

    @objc private func chevronClicked(_ sender: NSButton) {
        guard sender.tag < segmentURLs.count else { return }
        let parent = segmentURLs[sender.tag]
        let next = sender.tag + 1 < segmentURLs.count ? segmentURLs[sender.tag + 1] : nil
        let menu = NSMenu()
        let folders = ((try? DirectoryReader.contents(of: parent, includeHidden: Settings.shared.showHiddenFiles)) ?? [])
            .filter(\.isFolder)
            .sorted(by: FileItem.folderFirstNameOrder)
        if folders.isEmpty {
            menu.addItem(NSMenuItem(title: "Keine Unterordner", action: nil, keyEquivalent: ""))
        }
        for folder in folders {
            let item = NSMenuItem(title: folder.name, action: #selector(menuNavigate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder.url
            let icon = folder.icon.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)   // menus keep small icons
            item.image = icon
            if let next, folder.url.standardizedFileURL == next { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    @objc private func menuNavigate(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onNavigate?(url) }
    }

    // MARK: Typing a path

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        clip.isHidden = true
        field.isHidden = false
        field.stringValue = url?.path ?? ""
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func endEditing() {
        guard isEditing else { return }
        isEditing = false
        field.isHidden = true
        clip.isHidden = false
        needsDisplay = true
    }

    private func commit() {
        var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://"), let u = URL(string: text) { text = u.path }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 1 { text = String(text.dropFirst().dropLast()) }
        guard !text.isEmpty else { cancel(); return }
        let path = (text as NSString).expandingTildeInPath
        let target = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "Pfad nicht gefunden"
            alert.informativeText = "„\(text)“ gibt es nicht. Bitte prüfe die Schreibweise."
            alert.alertStyle = .warning
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        endEditing()
        onNavigate?(isDir.boolValue ? target : target.deletingLastPathComponent())
    }

    private func cancel() {
        endEditing()
        onCancel?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicked somewhere else: go back to the clickable path.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditing, self.window?.firstResponder !== self.field.currentEditor() else { return }
            if self.window?.attachedSheet == nil { self.endEditing() }
        }
    }
}

// MARK: - Command bar

final class CommandBarView: NSView {
    private let stack = NSStackView()
    private let cutButton = BarButton.make(symbol: "scissors", tip: "Ausschneiden (⌘X)", action: #selector(MainWindowController.cut(_:)))
    private let copyButton = BarButton.make(symbol: "doc.on.doc", tip: "Kopieren (⌘C)", action: #selector(MainWindowController.copy(_:)))
    private let pasteButton = BarButton.make(symbol: "doc.on.clipboard", tip: "Einfügen (⌘V)", action: #selector(MainWindowController.paste(_:)))
    private let renameButton = BarButton.make(symbol: "character.cursor.ibeam", tip: "Umbenennen (F2)", action: #selector(MainWindowController.renameItem(_:)))
    private let shareButton = BarButton.make(symbol: "square.and.arrow.up", tip: "Teilen", action: #selector(MainWindowController.shareItems(_:)))
    private let trashButton = BarButton.make(symbol: "trash", tip: "In den Papierkorb legen (⌫)", action: #selector(MainWindowController.moveToTrash(_:)))
    private let undoButton = BarButton.make(symbol: "arrow.uturn.backward", tip: "Rückgängig (⌘Z)", action: Selector(("undo:")))
    private let previewButton = BarButton.make(symbol: "sidebar.right", title: "Vorschau", tip: "Vorschaubereich ein/aus (⌥⌘P)",
                                               action: #selector(MainWindowController.togglePreviewPane(_:)))

    init(newMenu: @escaping () -> NSMenu, sortMenu: @escaping () -> NSMenu, viewMenu: @escaping () -> NSMenu, moreMenu: @escaping () -> NSMenu) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let newButton = MenuButton.make(symbol: "plus.circle", title: "Neu", tip: "Neuer Ordner (⇧⌘N) oder neue Datei", provider: newMenu)
        let sort = MenuButton.make(symbol: "arrow.up.arrow.down", title: "Sortieren", tip: "Sortieren nach …", provider: sortMenu)
        let view = MenuButton.make(symbol: "rectangle.split.3x1", title: "Ansicht", tip: "Ansicht anpassen", provider: viewMenu)
        let more = MenuButton.make(symbol: "ellipsis.circle", title: nil, tip: "Weitere Befehle", provider: moreMenu)
        let reveal = BarButton.make(symbol: "scope", title: "Im Baum zeigen",
                                    tip: "Aktuellen Ordner in der Seitenleiste aufdecken (⌃⌘R)",
                                    action: #selector(MainWindowController.revealInTree(_:)))

        stack.addView(newButton, in: .leading)
        stack.addView(BarButton.separator(), in: .leading)
        for button in [cutButton, copyButton, pasteButton, renameButton, shareButton, trashButton] {
            stack.addView(button, in: .leading)
        }
        stack.addView(BarButton.separator(), in: .leading)
        stack.addView(sort, in: .leading)
        stack.addView(view, in: .leading)
        stack.addView(BarButton.separator(), in: .leading)
        stack.addView(undoButton, in: .leading)
        stack.addView(more, in: .leading)
        stack.addView(reveal, in: .trailing)
        stack.addView(previewButton, in: .trailing)
        previewButton.setButtonType(.pushOnPushOff)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPreviewVisible(_ visible: Bool) {
        previewButton.state = visible ? .on : .off
    }

    func update(hasSelection: Bool, canModify: Bool, canPaste: Bool, canUndo: Bool) {
        cutButton.isEnabled = canModify
        copyButton.isEnabled = hasSelection
        pasteButton.isEnabled = canPaste
        renameButton.isEnabled = canModify
        trashButton.isEnabled = canModify
        shareButton.isEnabled = true
        undoButton.isEnabled = canUndo
    }
}

// MARK: - Status bar

final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(total: Int, selected: Int, selectedSize: Int64?, searching: Bool? = nil) {
        var text = Format.count(total)
        if let searching { text = (searching ? "Suche läuft … " : "Suche fertig: ") + (total == 1 ? "1 Treffer" : "\(total) Treffer") }
        if selected > 0 {
            text += "     |     " + (selected == 1 ? "1 Element ausgewählt" : "\(selected) Elemente ausgewählt")
            if let selectedSize { text += "   " + Format.size(selectedSize) }
        }
        label.stringValue = text
    }
}
