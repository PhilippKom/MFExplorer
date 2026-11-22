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

/// Turns URLs into Quick Look items. (Folders are shown in our own FolderInfoPanel, not in Quick Look.)
final class PreviewBuilder {
    func cancel() {}

    func items(for urls: [URL], onUpdate: @escaping (PreviewItem) -> Void = { _ in }) -> [PreviewItem] {
        urls.map { PreviewItem(source: $0, url: $0, title: nil) }
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

// MARK: - Preview window (space bar)

/// Panel that handles space / Esc / arrow keys itself, before any view inside can swallow them.
final class QuickLookPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Our own "Schnellansicht": one window for everything.
/// Folders → item count, size and dates; files → the normal macOS preview. Several items → ←/→ to page.
final class QuickLookWindowController: NSObject, NSWindowDelegate {
    private var panel: QuickLookPanel?
    private var fileView: QLPreviewView?
    private var folderModel: FolderInfoModel?
    private var urls: [URL] = []
    private var index = 0
    /// ↑/↓ pressed: move the selection in the main window (which then calls show again).
    var onArrow: ((NSEvent) -> Void)?
    /// The window was closed: give the focus back to the main window.
    var onClose: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }
    var currentURL: URL? { index < urls.count ? urls[index] : nil }
    var showsFolder: Bool { folderModel != nil }

    func show(_ newURLs: [URL], over parent: NSWindow?) {
        guard !newURLs.isEmpty else { return }
        if newURLs == urls, isVisible { return }
        urls = newURLs
        index = 0
        let panel = self.panel ?? makePanel()
        display()
        if !panel.isVisible {
            if let parent {
                let frame = parent.frame
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            } else {
                panel.center()
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard isVisible else { return }
        panel?.close()   // → windowWillClose
    }

    /// Call once when the main window closes.
    func shutdown() {
        close()
        fileView?.close()
        fileView = nil
    }

    private func display() {
        guard let panel, let url = currentURL else { return }
        folderModel?.cancel()
        folderModel = nil
        let name = FileManager.default.displayName(atPath: url.path)
        panel.title = urls.count > 1 ? "\(name)  (\(index + 1) von \(urls.count))" : name

        if DirectoryReader.isDirectory(url) && FileOps.shared.isPlainFolder(url) {
            fileView?.previewItem = nil
            fileView?.isHidden = true
            let model = FolderInfoModel(url: url)
            folderModel = model
            let hosting = NSHostingView(rootView: FolderInfoView(model: model))
            install(hosting)
        } else {
            let view = fileView ?? {
                let view = QLPreviewView(frame: .zero, style: .normal)!
                view.shouldCloseWithWindow = false   // reused; closed once in shutdown()
                view.autostarts = true
                fileView = view
                return view
            }()
            view.isHidden = false
            install(view)
            view.previewItem = url as NSURL
        }
    }

    private func install(_ view: NSView) {
        guard let content = panel?.contentView else { return }
        for sub in content.subviews where sub !== view { sub.removeFromSuperview() }
        if view.superview !== content {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
    }

    private func page(_ step: Int) {
        guard urls.count > 1 else { return }
        index = (index + step + urls.count) % urls.count
        display()
    }

    private func makePanel() -> QuickLookPanel {
        let panel = QuickLookPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                                   styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 260)
        panel.contentView = NSView()
        panel.delegate = self
        panel.setFrameAutosaveName("QuickLookWindow")
        panel.onKey = { [weak self] event in
            guard let self else { return false }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return false }
            switch event.keyCode {
            case 49, 53: self.close(); return true          // space, Esc
            case 125, 126: self.onArrow?(event); return true  // ↓ ↑
            case 123: self.page(-1); return true             // ←
            case 124: self.page(1); return true              // →
            default: return false
            }
        }
        self.panel = panel
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        folderModel?.cancel()
        folderModel = nil
        fileView?.previewItem = nil
        urls = []
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}
