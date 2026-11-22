import AppKit
import SwiftUI

/// Size and content counts of files/folders (computed in the background).
struct FolderStats {
    var bytes: Int64 = 0
    var allocated: Int64 = 0
    var files = 0
    var folders = 0

    static func compute(_ urls: [URL], isCancelled: () -> Bool) -> FolderStats {
        var stats = FolderStats()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        func add(_ url: URL) {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                stats.folders += 1
            } else {
                stats.files += 1
                stats.bytes += Int64(v?.fileSize ?? 0)
                stats.allocated += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        for url in urls {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isDirectory == true else { add(url); continue }
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { continue }
            for case let child as URL in e {
                if isCancelled() { return stats }
                add(child)
            }
        }
        return stats
    }
}

final class PropertiesModel: ObservableObject {
    let urls: [URL]
    @Published var stats: FolderStats?
    private var cancelled = false

    init(urls: [URL]) { self.urls = urls }

    func start() {
        let urls = self.urls
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = FolderStats.compute(urls) { self?.cancelled ?? true }
            DispatchQueue.main.async { self?.stats = result }
        }
    }

    func cancel() { cancelled = true }
}

struct PropertiesView: View {
    @ObservedObject var model: PropertiesModel

    private var single: URL? { model.urls.count == 1 ? model.urls[0] : nil }
    private var values: URLResourceValues? {
        try? single?.resourceValues(forKeys: [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey,
                                              .contentAccessDateKey, .isHiddenKey, .isDirectoryKey, .isPackageKey, .tagNamesKey])
    }
    private var isFolderSelection: Bool {
        model.urls.contains { FileOps.shared.isPlainFolder($0) }
    }

    private func sizeText(_ bytes: Int64) -> String {
        "\(Format.size(bytes)) (\(bytes.formatted()) Bytes)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: single.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .folder))
                    .resizable().frame(width: 40, height: 40)
                Text(single.map { FileManager.default.displayName(atPath: $0.path) } ?? "\(model.urls.count) Elemente")
                    .font(.title3).textSelection(.enabled).lineLimit(2)
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                if let v = values {
                    row("Typ", v.isDirectory == true && v.isPackage != true ? "Ordner" : (v.localizedTypeDescription ?? "Datei"))
                }
                row("Ort", model.urls.first?.deletingLastPathComponent().path ?? "")
                if let stats = model.stats {
                    row("Größe", sizeText(stats.bytes))
                    row("Größe auf Datenträger", sizeText(stats.allocated))
                    if isFolderSelection {
                        row("Inhalt", "\(stats.files) Dateien, \(stats.folders) Ordner")
                    }
                } else {
                    row("Größe", "Wird berechnet …")
                }
            }
            if let v = values {
                Divider()
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("Erstellt", Format.date(v.creationDate))
                    row("Geändert", Format.date(v.contentModificationDate))
                    row("Letzter Zugriff", Format.date(v.contentAccessDate))
                }
                Divider()
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("Tags", (v.tagNames ?? []).isEmpty ? "–" : (v.tagNames ?? []).joined(separator: ", "))
                    row("Versteckt", v.isHidden == true ? "Ja" : "Nein")
                }
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Eigenschaften" window like on Windows.
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private static var openWindows: [PropertiesWindowController] = []
    private let model: PropertiesModel

    static func show(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = PropertiesWindowController(urls: urls)
        openWindows.append(controller)
        controller.showWindow(nil)
    }

    private init(urls: [URL]) {
        model = PropertiesModel(urls: urls)
        let hosting = NSHostingController(rootView: PropertiesView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = urls.count == 1
            ? "Eigenschaften von „\(FileManager.default.displayName(atPath: urls[0].path))“"
            : "Eigenschaften (\(urls.count) Elemente)"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        model.start()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        Self.openWindows.removeAll { $0 === self }
    }
}
