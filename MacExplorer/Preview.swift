import AppKit
import Quartz
import SwiftUI

/// One thing to show in Quick Look or the preview pane. Folders are shown as a small info page.
final class PreviewItem: NSObject, QLPreviewItem {
    let source: URL
    var previewItemURL: URL!
    var previewItemTitle: String!

    init(source: URL, url: URL, title: String?) {
        self.source = source
        previewItemURL = url
        previewItemTitle = title
    }
}

/// Builds an HTML page with folder facts (items, size, dates) that Quick Look can display.
enum FolderInfoPage {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacExplorer-Vorschau", isDirectory: true)

    /// Our own temporary pages from last time – safe to remove.
    static func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func iconData(_ url: URL) -> String {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let rect = NSRect(x: 0, y: 0, width: 128, height: 128)
        guard let rep = icon.bestRepresentation(for: rect, context: nil, hints: nil) else { return "" }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        rep.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])?.base64EncodedString() ?? ""
    }

    static func write(folder: URL, stats: FolderStats?) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let v = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let direct = (try? DirectoryReader.contents(of: folder, includeHidden: Settings.shared.showHiddenFiles))?.count
        func row(_ label: String, _ value: String) -> String {
            "<tr><td class=l>\(escape(label))</td><td>\(escape(value))</td></tr>"
        }
        var rows = row("Ort", folder.deletingLastPathComponent().path)
        rows += row("Elemente darin", direct.map { $0 == 1 ? "1 Element" : "\($0) Elemente" } ?? "kein Zugriff")
        if let stats {
            rows += row("Insgesamt", "\(stats.files) Dateien, \(stats.folders) Ordner")
            rows += row("Größe", "\(Format.size(stats.bytes)) (\(stats.bytes.formatted()) Bytes)")
            rows += row("Auf Datenträger", Format.size(stats.allocated))
        } else {
            rows += row("Größe", "Wird berechnet …")
        }
        rows += row("Erstellt", Format.date(v?.creationDate))
        rows += row("Geändert", Format.date(v?.contentModificationDate))

        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, sans-serif; margin: 0; padding: 32px 24px; text-align: center;
               background: Canvas; color: CanvasText; }
        img { width: 128px; height: 128px; }
        h1 { font-size: 20px; font-weight: 600; margin: 8px 0 20px; word-break: break-word; }
        table { margin: 0 auto; border-collapse: collapse; text-align: left; }
        td { padding: 4px 8px; vertical-align: top; word-break: break-word; }
        td.l { color: GrayText; text-align: right; white-space: nowrap; }
        </style></head><body>
        <img src="data:image/png;base64,\(iconData(folder))">
        <h1>\(escape(fm.displayName(atPath: folder.path)))</h1>
        <table>\(rows)</table>
        </body></html>
        """
        // A new file each time, so Quick Look never shows an old cached version.
        let file = directory.appendingPathComponent(UUID().uuidString + ".html")
        try? html.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

/// Turns URLs into preview items; folder sizes are computed in the background and then refreshed.
final class PreviewBuilder {
    private var generation = 0

    func cancel() { generation += 1 }

    func items(for urls: [URL], onUpdate: @escaping (PreviewItem) -> Void) -> [PreviewItem] {
        generation += 1
        let current = generation
        return urls.map { url in
            let isFolder = DirectoryReader.isDirectory(url) && FileOps.shared.isPlainFolder(url)
            guard isFolder else { return PreviewItem(source: url, url: url, title: nil) }
            let title = FileManager.default.displayName(atPath: url.path)
            let item = PreviewItem(source: url, url: FolderInfoPage.write(folder: url, stats: nil), title: title)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let stats = FolderStats.compute([url]) { self?.generation != current }
                DispatchQueue.main.async {
                    guard let self, self.generation == current else { return }
                    item.previewItemURL = FolderInfoPage.write(folder: url, stats: stats)
                    onUpdate(item)
                }
            }
            return item
        }
    }
}

/// Native folder facts for the preview pane.
final class FolderInfoModel: ObservableObject {
    let url: URL
    let directCount: Int?
    @Published var stats: FolderStats?
    private var cancelled = false

    init(url: URL) {
        self.url = url
        directCount = (try? DirectoryReader.contents(of: url, includeHidden: Settings.shared.showHiddenFiles))?.count
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = FolderStats.compute([url]) { self?.cancelled ?? true }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else { return }
                self.stats = stats
            }
        }
    }

    func cancel() { cancelled = true }
}

struct FolderInfoView: View {
    @ObservedObject var model: FolderInfoModel

    var body: some View {
        let v = try? model.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        ScrollView {
            VStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.url.path))
                    .resizable().frame(width: 96, height: 96)
                Text(FileManager.default.displayName(atPath: model.url.path))
                    .font(.title3.weight(.semibold)).multilineTextAlignment(.center).textSelection(.enabled)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    row("Elemente darin", model.directCount.map { $0 == 1 ? "1 Element" : "\($0) Elemente" } ?? "kein Zugriff")
                    if let stats = model.stats {
                        row("Insgesamt", "\(stats.files) Dateien, \(stats.folders) Ordner")
                        row("Größe", Format.size(stats.bytes))
                        row("Auf Datenträger", Format.size(stats.allocated))
                    } else {
                        row("Größe", "Wird berechnet …")
                    }
                    row("Erstellt", Format.date(v?.creationDate))
                    row("Geändert", Format.date(v?.contentModificationDate))
                }
                .font(.callout)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}

/// The preview pane on the right side of the window.
final class PreviewPaneViewController: NSViewController {
    private var previewView: QLPreviewView!
    private let message = NSTextField(wrappingLabelWithString: "")
    private let builder = PreviewBuilder()
    private var pending: DispatchWorkItem?
    private var shown: [URL]?
    private var folderView: NSView?
    private var folderModel: FolderInfoModel?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        previewView = QLPreviewView(frame: container.bounds, style: .normal)
        previewView.autostarts = false
        previewView.translatesAutoresizingMaskIntoConstraints = false
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewView)
        container.addSubview(message)
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: container.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            previewView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            message.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        view = container
        showMessage("Wähle eine Datei aus, um hier eine Vorschau zu sehen.")
    }

    // No close() here: QLPreviewView closes itself with its window (shouldCloseWithWindow).
    // Closing it a second time makes Quick Look abort the whole app.

    /// Called whenever the selection changes. Waits a moment so fast arrow-key scrolling stays smooth.
    func show(_ urls: [URL]) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.display(urls) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Forget what is shown (e.g. when the pane is hidden), so it reloads next time.
    func clear() {
        pending?.cancel()
        builder.cancel()
        removeFolderInfo()
        shown = nil
        previewView.previewItem = nil
    }

    private func removeFolderInfo() {
        folderModel?.cancel()
        folderModel = nil
        folderView?.removeFromSuperview()
        folderView = nil
    }

    private func showMessage(_ text: String) {
        removeFolderInfo()
        builder.cancel()
        previewView.previewItem = nil
        previewView.isHidden = true
        message.stringValue = text
        message.isHidden = false
    }

    private func display(_ urls: [URL]) {
        guard urls != shown else { return }
        shown = urls
        if urls.isEmpty {
            showMessage("Wähle eine Datei aus, um hier eine Vorschau zu sehen.")
            return
        }
        if urls.count > 1 {
            let bytes = urls.reduce(Int64(0)) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            showMessage("\(urls.count) Elemente ausgewählt\n\(Format.size(bytes)) (ohne Ordnerinhalte)")
            return
        }
        removeFolderInfo()
        if DirectoryReader.isDirectory(urls[0]) && FileOps.shared.isPlainFolder(urls[0]) {
            let model = FolderInfoModel(url: urls[0])
            let hosting = NSHostingView(rootView: FolderInfoView(model: model))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            folderModel = model
            folderView = hosting
            builder.cancel()
            previewView.previewItem = nil
            previewView.isHidden = true
            message.isHidden = true
            return
        }
        let items = builder.items(for: urls) { [weak self] item in
            guard let self, self.previewView.previewItem === item else { return }
            self.previewView.previewItem = item
            self.previewView.refreshPreviewItem()
        }
        message.isHidden = true
        previewView.isHidden = false
        previewView.previewItem = items.first
    }
}
