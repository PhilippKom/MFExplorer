import AppKit
import QuickLookThumbnailing

enum ViewMode: String, CaseIterable {
    case details, medium, large, extraLarge

    var title: String {
        switch self {
        case .details: return "Details"
        case .medium: return "Mittelgroße Symbole"
        case .large: return "Große Symbole"
        case .extraLarge: return "Extra große Symbole"
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .details: return 16
        case .medium: return 48
        case .large: return 96
        case .extraLarge: return 160
        }
    }

    var itemSize: NSSize {
        NSSize(width: max(iconSize + 28, 96), height: iconSize + 48)
    }

    /// ⌘1 … ⌘4
    var shortcut: String {
        switch self {
        case .details: return "1"
        case .medium: return "2"
        case .large: return "3"
        case .extraLarge: return "4"
        }
    }
}

/// Thumbnails (pictures, PDFs, videos …) for the icon view, cached in memory.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private func key(_ url: URL, _ size: CGFloat) -> NSString { "\(Int(size))|\(url.path)" as NSString }

    func cached(_ url: URL, size: CGFloat) -> NSImage? { cache.object(forKey: key(url, size)) }

    func request(_ url: URL, size: CGFloat, scale: CGFloat, done: @escaping (NSImage) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache.setObject(image, forKey: self.key(url, size))
                done(image)
            }
        }
    }
}

/// One tile in the icon view: big icon (or thumbnail) with the name below.
final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")
    private(set) var url: URL?
    private var iconHeight: NSLayoutConstraint!
    private var iconWidth: NSLayoutConstraint!

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(wrappingLabelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addSubview(image)
        root.addSubview(label)
        iconWidth = image.widthAnchor.constraint(equalToConstant: 48)
        iconHeight = image.heightAnchor.constraint(equalToConstant: 48)
        NSLayoutConstraint.activate([
            iconWidth, iconHeight,
            image.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            image.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
        ])
        view = root
        imageView = image
        textField = label
    }

    func configure(_ item: FileItem, size: CGFloat, image: NSImage, dimmed: Bool) {
        url = item.url
        iconWidth.constant = size
        iconHeight.constant = size
        imageView?.image = image
        textField?.stringValue = item.name
        view.alphaValue = dimmed ? 0.5 : 1
        view.toolTip = item.name
        updateLook()
    }

    func setImage(_ image: NSImage) { imageView?.image = image }

    override var isSelected: Bool { didSet { updateLook() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateLook() } }

    private func updateLook() {
        let on = isSelected || highlightState == .forSelection
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
            view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        }
        view.layer?.borderWidth = on ? 1 : 0
    }
}

/// Invisible insertion marker (dropping between icons means "into this folder").
final class EmptyGapView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("EmptyGap")
}

final class IconCollectionView: NSCollectionView {
    var onOpen: (() -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var onSelectionChangedByMenu: (() -> Void)?
    private(set) var rightClickedIndex: Int?

    /// A clear frame around the whole view while dropping into the current folder.
    var dropHighlight = false {
        didSet {
            guard dropHighlight != oldValue, let scroll = enclosingScrollView else { return }
            scroll.wantsLayer = true
            scroll.layer?.borderWidth = dropHighlight ? 2 : 0
            scroll.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 36 || event.keyCode == 76) && mods.isEmpty { onOpen?(); return }
        if event.keyCode == 125 && mods == .command { onOpen?(); return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let path = indexPathForItem(at: point) { onDoubleClick?(path.item) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(path) {
                deselectAll(nil)
                selectItems(at: [path], scrollPosition: [])
            }
            rightClickedIndex = path.item
        } else {
            deselectAll(nil)
            rightClickedIndex = nil
        }
        onSelectionChangedByMenu?()
        return super.menu(for: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlight = false
        super.draggingExited(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropHighlight = false
        super.concludeDragOperation(sender)
    }
}
