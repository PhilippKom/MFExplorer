import AppKit
import Sparkle

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var instance: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        instance = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private var windowControllers: [MainWindowController] = []

    /// Sparkle: checks the appcast on GitHub for new versions and installs them.
    /// Not started in debug builds, so test runs never show update dialogs.
    private lazy var updaterController: SPUStandardUpdaterController = {
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        return SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    static var updater: SPUUpdater? { instance?.updaterController.updater }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FolderInfoPage.cleanUp()
        _ = updaterController
        NSApp.mainMenu = MainMenu.build()
        openWindow(at: startURL())
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        scheduleDebugSnapshot()
        if let path = UserDefaults.standard.string(forKey: "tabTest") { runTabTest(log: path) }
        if let path = UserDefaults.standard.string(forKey: "searchTest") { runSearchTest(log: path) }
        if let path = UserDefaults.standard.string(forKey: "selfTest") {
            selfTest = DebugSelfTest(logPath: path)
            selfTest?.run()
        }
        #endif
    }

    #if DEBUG
    private var selfTest: DebugSelfTest?

    /// Test: search `-searchTestWord` in the start folder, wait until finished, write results + Fundstelle.
    private func runSearchTest(log path: String) {
        let word = UserDefaults.standard.string(forKey: "searchTestWord") ?? "Umsatz"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let controller = self?.windowControllers.first else { return }
            let list = controller.fileListVC
            controller.window?.makeKeyAndOrderFront(nil)
            let started = Date()
            list.startSearch(word, in: controller.currentURL)
            func poll() {
                if list.isSearchRunning && Date().timeIntervalSince(started) < 20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { poll() }
                    return
                }
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                _ = list.debugSearchReport()   // starts reading the lines
                if UserDefaults.standard.bool(forKey: "searchTestOpenLocation"), let hit = list.items.first(where: { !$0.isFolder }) {
                    // Simulates right-click > "Speicherort öffnen" on the first file.
                    let item = NSMenuItem()
                    item.representedObject = ActionContext(urls: [hit.url], folder: controller.currentURL)
                    controller.openContainingFolder(item)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let windows = self?.windowControllers ?? []
                        let newWindow = windows.last
                        let lines = [
                            "windows=\(windows.count) (erwartet 2)",
                            "altes Fenster sucht noch: \(controller.fileListVC.searchQuery != nil) treffer=\(controller.fileListVC.items.count)",
                            "neues Fenster Ordner: \(newWindow?.currentURL.path ?? "-") (erwartet \(hit.url.deletingLastPathComponent().path))",
                            "neues Fenster markiert: \(newWindow?.fileListVC.selectedItems.map(\.url.lastPathComponent) ?? []) (erwartet [\(hit.url.lastPathComponent)])",
                            "neues Fenster ist vorne: \(newWindow?.window?.isKeyWindow == true)",
                        ]
                        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                        NSApp.terminate(nil)
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let lines = ["running=\(list.isSearchRunning) after \(seconds)s"] + list.debugSearchReport()
                    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
            poll()
        }
    }

    /// Test: open 3 tabs, close one, check that the app and the other 2 tabs are still there.
    private func runTabTest(log path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let first = self.windowControllers.first else { return }
            first.newWindowForTab(nil)
            first.newWindowForTab(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let before = self.windowControllers.count
                self.windowControllers.last?.window?.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let after = self.windowControllers.count
                    let tabs = self.windowControllers.first?.window?.tabbedWindows?.count ?? 1
                    let ok = before == 3 && after == 2
                    try? "\(ok ? "PASS" : "FAIL") tabs before=\(before) after=\(after) tabGroup=\(tabs)".write(toFile: path, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Test helper: `-snapshotPath <file.png>` saves a picture of the window after launch.
    /// `-debugReveal YES` presses "Im Baum zeigen" first. Only in debug builds.
    private func scheduleDebugSnapshot() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "snapshotPath") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let controller = self?.windowControllers.first, let mainView = controller.window?.contentView else { return }
            if defaults.bool(forKey: "debugReveal") {
                controller.revealInTree(nil)
                controller.sidebarVC.outline.deselectAll(nil)   // selection looks black on these pictures
            }
            if let preview = defaults.string(forKey: "debugPreview") { controller.debugSetPreviewVisible(preview == "on") }
            if let query = defaults.string(forKey: "debugSearch") {
                controller.fileListVC.startSearch(query, in: controller.currentURL)
            }
            var view = mainView
            if defaults.bool(forKey: "debugSettings") {
                SettingsWindowController.show()
                if let settingsView = NSApp.windows.first(where: { $0.title == "Einstellungen" })?.contentView { view = settingsView }
            }
            if let name = defaults.string(forKey: "debugSelect") {
                controller.fileListVC.load(controller.currentURL, select: [controller.currentURL.appendingPathComponent(name)])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.8, defaults.double(forKey: "debugSnapDelay"))) {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Start folder: `-startPath <path>` launch argument (used for testing), otherwise from the settings.
    private func startURL() -> URL {
        let settings = Settings.shared
        var candidates: [String?] = [UserDefaults.standard.string(forKey: "startPath")]
        switch settings.startFolderMode {
        case "last": candidates.append(settings.lastFolderPath)
        case "custom": candidates.append(settings.startFolderPath)
        default: break
        }
        for case let raw? in candidates {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            if DirectoryReader.isDirectory(url) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show()
    }

    @objc func newWindow(_ sender: Any?) {
        let current = (NSApp.keyWindow?.windowController as? MainWindowController)?.currentURL
        openWindow(at: current ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Creates a window (used for new windows and new tabs) and keeps it alive until it is closed.
    func makeController(at url: URL, select: [URL] = []) -> MainWindowController {
        let controller = MainWindowController(url: url, select: select)
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        return controller
    }

    func openWindow(at url: URL, select: [URL] = []) {
        let previousWindow = NSApp.keyWindow ?? windowControllers.last?.window
        let controller = makeController(at: url, select: select)
        if let previous = previousWindow, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 26, y: previous.frame.maxY - 26))
        }
        controller.showWindow(nil)
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, object: Any? = nil) -> NSMenuItem {
            let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
            m.keyEquivalentModifierMask = mods
            m.representedObject = object
            return m
        }
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        let sep = { NSMenuItem.separator() }
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        submenu("MFExplorer", [
            item("Über MFExplorer", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("Nach Updates suchen …", #selector(AppDelegate.checkForUpdates(_:))),
            sep(),
            item("Einstellungen …", #selector(AppDelegate.showSettings(_:)), ","),
            sep(),
            item("MFExplorer ausblenden", #selector(NSApplication.hide(_:)), "h"),
            item("Andere ausblenden", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Alle einblenden", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            item("MFExplorer beenden", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let f2 = String(Character(UnicodeScalar(NSF2FunctionKey)!))
        let backspace = String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        submenu("Ablage", [
            item("Neues Fenster", #selector(AppDelegate.newWindow(_:)), "n"),
            item("Neuer Tab", #selector(NSResponder.newWindowForTab(_:)), "t"),
            item("Neuer Ordner", #selector(MainWindowController.newFolder(_:)), "n", [.command, .shift]),
            item("Neues Textdokument", #selector(MainWindowController.newTextFile(_:))),
            sep(),
            item("Öffnen", #selector(MainWindowController.openSelection(_:)), "o"),
            item("Umbenennen", #selector(MainWindowController.renameItem(_:)), f2, []),
            item("Eigenschaften", #selector(MainWindowController.showProperties(_:)), "i"),
            sep(),
            item("Als ZIP komprimieren", #selector(MainWindowController.compressItems(_:))),
            item("Entpacken", #selector(MainWindowController.extractItem(_:))),
            item("Teilen …", #selector(MainWindowController.shareItems(_:))),
            item("Im Finder zeigen", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .option]),
            sep(),
            item("In den Papierkorb legen", #selector(MainWindowController.moveToTrash(_:)), backspace),
            sep(),
            item("Fenster schließen", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Bearbeiten", [
            item("Rückgängig", Selector(("undo:")), "z"),
            item("Wiederholen", Selector(("redo:")), "z", [.command, .shift]),
            sep(),
            item("Ausschneiden", #selector(NSText.cut(_:)), "x"),
            item("Kopieren", #selector(NSText.copy(_:)), "c"),
            item("Einfügen", #selector(NSText.paste(_:)), "v"),
            item("Alles auswählen", #selector(NSText.selectAll(_:)), "a"),
            sep(),
            item("Pfad kopieren", #selector(MainWindowController.copyPath(_:)), "c", [.command, .option]),
            item("Suchen", #selector(MainWindowController.focusSearch(_:)), "f"),
            sep(),
            item("Vor dem Löschen nachfragen", #selector(MainWindowController.toggleConfirmTrash(_:))),
        ])
        submenu("Darstellung", ViewMode.allCases.map { mode in
            item(mode.title, #selector(MainWindowController.setViewMode(_:)), mode.shortcut, object: mode.rawValue)
        } + [
            sep(),
            item("Seitenleiste ausblenden", #selector(MainWindowController.toggleSidebarPane(_:)), "s", [.command, .control]),
            item("Versteckte Dateien anzeigen", #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item("Dateien im Baum ausblenden", #selector(MainWindowController.toggleFilesInTree(_:))),
            sep(),
            item("Vorschaubereich einblenden", #selector(MainWindowController.togglePreviewPane(_:)), "p", [.command, .option]),
            item("Schnellansicht (Leertaste)", #selector(MainWindowController.toggleQuickLook(_:))),
            sep(),
            item("Aktualisieren", #selector(MainWindowController.refresh(_:)), "r"),
        ])
        submenu("Gehe zu", [
            item("Zurück", #selector(MainWindowController.goBack(_:)), "["),
            item("Vor", #selector(MainWindowController.goForward(_:)), "]"),
            item("Übergeordneter Ordner", #selector(MainWindowController.goUp(_:)), up),
            sep(),
            item(fm.displayName(atPath: home.path), #selector(MainWindowController.goToPlace(_:)), "h", [.command, .shift], object: home),
            item(fm.displayName(atPath: home.appendingPathComponent("Desktop").path), #selector(MainWindowController.goToPlace(_:)), "d", [.command, .shift], object: home.appendingPathComponent("Desktop")),
            item(fm.displayName(atPath: home.appendingPathComponent("Documents").path), #selector(MainWindowController.goToPlace(_:)), "o", [.command, .shift], object: home.appendingPathComponent("Documents")),
            item(fm.displayName(atPath: home.appendingPathComponent("Downloads").path), #selector(MainWindowController.goToPlace(_:)), "l", [.command, .option], object: home.appendingPathComponent("Downloads")),
            sep(),
            item("Adresse eingeben …", #selector(MainWindowController.focusAddressBar(_:)), "l"),
            item("Im Baum zeigen", #selector(MainWindowController.revealInTree(_:)), "r", [.command, .control]),
        ])
        let windowMenu = submenu("Fenster", [
            item("Im Dock ablegen", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoomen", #selector(NSWindow.performZoom(_:))),
            sep(),
            item("Alle nach vorne bringen", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenu
        return main
    }
}
