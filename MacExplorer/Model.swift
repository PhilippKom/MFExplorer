import AppKit

extension Notification.Name {
    static let settingsChanged = Notification.Name("MacExplorer.settingsChanged")
    static let favoritesChanged = Notification.Name("MacExplorer.favoritesChanged")
}

/// App settings, stored in UserDefaults. Every change is broadcast so all windows update.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var showHiddenFiles: Bool {
        get { defaults.bool(forKey: "showHiddenFiles") }
        set { defaults.set(newValue, forKey: "showHiddenFiles"); NotificationCenter.default.post(name: .settingsChanged, object: nil) }
    }

    /// Ask before moving to the Trash (can be switched off in the dialog).
    var confirmTrash: Bool {
        get { defaults.object(forKey: "confirmTrash") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "confirmTrash") }
    }

    var hideFilesInTree: Bool {
        get { defaults.bool(forKey: "hideFilesInTree") }
        set { defaults.set(newValue, forKey: "hideFilesInTree"); NotificationCenter.default.post(name: .settingsChanged, object: nil) }
    }

    private func flag(_ key: String, default value: Bool = false) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    private func setFlag(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    /// Show "Bericht.docx" instead of "Bericht" for every file.
    var showAllExtensions: Bool {
        get { flag("showAllExtensions") }
        set { setFlag("showAllExtensions", newValue) }
    }

    /// ⌫ goes back (Windows) instead of moving to the Trash.
    var backspaceGoesBack: Bool {
        get { flag("backspaceGoesBack") }
        set { setFlag("backspaceGoesBack", newValue) }
    }

    /// Ctrl+C / Ctrl+V / Ctrl+Z … work like on Windows (in addition to ⌘).
    var windowsShortcuts: Bool {
        get { flag("windowsShortcuts") }
        set { setFlag("windowsShortcuts", newValue) }
    }

    /// "home", "last" or "custom".
    var startFolderMode: String {
        get { defaults.string(forKey: "startFolderMode") ?? "home" }
        set { defaults.set(newValue, forKey: "startFolderMode") }
    }

    var startFolderPath: String? {
        get { defaults.string(forKey: "startFolderPath") }
        set { defaults.set(newValue, forKey: "startFolderPath") }
    }

    var lastFolderPath: String? {
        get { defaults.string(forKey: "lastFolderPath") }
        set { defaults.set(newValue, forKey: "lastFolderPath") }
    }

    /// View for new windows: "details", "medium", "large", "extraLarge".
    var defaultViewMode: String {
        get { defaults.string(forKey: "defaultViewMode") ?? "details" }
        set { defaults.set(newValue, forKey: "defaultViewMode") }
    }

    var favorites: [URL] {
        get { (defaults.stringArray(forKey: "favorites") ?? []).map { URL(fileURLWithPath: $0) } }
        set {
            defaults.set(newValue.map(\.path), forKey: "favorites")
            NotificationCenter.default.post(name: .favoritesChanged, object: nil)
        }
    }
}

/// One file or folder with the details shown in the lists.
final class FileItem {
    static let resourceKeys: [URLResourceKey] = [
        .localizedNameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
        .fileSizeKey, .localizedTypeDescriptionKey, .tagNamesKey,
    ]

    let url: URL
    let name: String
    /// A real folder you can navigate into (app bundles and other packages count as files).
    let isFolder: Bool
    let isHidden: Bool
    let modified: Date?
    let created: Date?
    let accessed: Date?
    let size: Int64?
    let typeName: String
    let tags: [String]

    private var cachedIcon: NSImage?
    var icon: NSImage {
        if let cachedIcon { return cachedIcon }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        cachedIcon = image
        return image
    }

    init(url: URL) {
        self.url = url
        let v = try? url.resourceValues(forKeys: Set(FileItem.resourceKeys))
        var directory = v?.isDirectory ?? false
        if v?.isSymbolicLink == true {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) { directory = isDir.boolValue }
        }
        isFolder = directory && !(v?.isPackage ?? false)
        // Folders keep their translated names ("Schreibtisch"); files optionally always show the extension.
        name = (!isFolder && Settings.shared.showAllExtensions) ? url.lastPathComponent : (v?.localizedName ?? url.lastPathComponent)
        isHidden = v?.isHidden ?? url.lastPathComponent.hasPrefix(".")
        modified = v?.contentModificationDate
        created = v?.creationDate
        accessed = v?.contentAccessDate
        size = directory ? nil : v?.fileSize.map { Int64($0) }
        typeName = isFolder ? "Ordner" : (v?.localizedTypeDescription ?? "Datei")
        tags = v?.tagNames ?? []
    }

    /// Compare two items by a column key ("name", "modified", "type", "size", "created", "accessed").
    static func compare(_ a: FileItem, _ b: FileItem, key: String) -> ComparisonResult {
        func dates(_ x: Date?, _ y: Date?) -> ComparisonResult {
            (x ?? .distantPast).compare(y ?? .distantPast)
        }
        switch key {
        case "modified": return dates(a.modified, b.modified)
        case "created": return dates(a.created, b.created)
        case "accessed": return dates(a.accessed, b.accessed)
        case "type": return a.typeName.localizedStandardCompare(b.typeName)
        case "tags": return a.tags.joined(separator: ",").localizedStandardCompare(b.tags.joined(separator: ","))
        case "size":
            let x = a.size ?? -1, y = b.size ?? -1
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        default: return a.name.localizedStandardCompare(b.name)
        }
    }

    /// Folders first, then by name like Windows ("Datei 2" before "Datei 10").
    static func folderFirstNameOrder(_ a: FileItem, _ b: FileItem) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

enum DirectoryReader {
    static func contents(of url: URL, includeHidden: Bool) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: FileItem.resourceKeys, options: options)
        return urls.map(FileItem.init)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

enum Format {
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("ddMMyyyyHHmm")
        return f
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }

    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func count(_ n: Int) -> String {
        n == 1 ? "1 Element" : "\(n) Elemente"
    }
}

/// Small factories for table cells (used by the tree and the file list).
enum Cells {
    static func iconCell(_ id: String) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(id)
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    static func textCell(_ id: String) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(id)
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
