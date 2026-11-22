import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        openWindow(at: startURL())
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        scheduleDebugSnapshot()
        if let path = UserDefaults.standard.string(forKey: "selfTest") {
            selfTest = DebugSelfTest(logPath: path)
            selfTest?.run()
        }
        #endif
    }

    #if DEBUG
    private var selfTest: DebugSelfTest?

    /// Test helper: `-snapshotPath <file.png>` saves a picture of the window after launch.
    /// `-debugReveal YES` presses "Im Baum zeigen" first. Only in debug builds.
    private func scheduleDebugSnapshot() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "snapshotPath") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let controller = self?.windowControllers.first, let view = controller.window?.contentView else { return }
            if defaults.bool(forKey: "debugReveal") { controller.revealInTree(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Start folder: `-startPath <path>` launch argument (used for testing), otherwise the home folder.
    private func startURL() -> URL {
        if let raw = UserDefaults.standard.string(forKey: "startPath") {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    @objc func newWindow(_ sender: Any?) {
        let current = (NSApp.keyWindow?.windowController as? MainWindowController)?.currentURL
        openWindow(at: current ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    func openWindow(at url: URL) {
        let controller = MainWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        if let previous = windowControllers.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 26, y: previous.frame.maxY - 26))
        }
        windowControllers.append(controller)
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

        submenu("MacExplorer", [
            item("Über MacExplorer", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            sep(),
            item("MacExplorer ausblenden", #selector(NSApplication.hide(_:)), "h"),
            item("Andere ausblenden", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Alle einblenden", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            item("MacExplorer beenden", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let f2 = String(Character(UnicodeScalar(NSF2FunctionKey)!))
        let backspace = String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        submenu("Ablage", [
            item("Neues Fenster", #selector(AppDelegate.newWindow(_:)), "n"),
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
            sep(),
            item("Vor dem Löschen nachfragen", #selector(MainWindowController.toggleConfirmTrash(_:))),
        ])
        submenu("Darstellung", [
            item("Seitenleiste ausblenden", #selector(MainWindowController.toggleSidebarPane(_:)), "s", [.command, .control]),
            item("Versteckte Dateien anzeigen", #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item("Dateien im Baum ausblenden", #selector(MainWindowController.toggleFilesInTree(_:))),
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
