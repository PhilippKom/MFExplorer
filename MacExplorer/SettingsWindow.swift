import AppKit
import SwiftUI

struct SettingsView: View {
    private let s = Settings.shared
    @State private var refresh = 0   // forces redraw after a change

    private func binding(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { _ = refresh; return get() }, set: { set($0); refresh += 1 })
    }

    private var startMode: Binding<String> {
        Binding(get: { _ = refresh; return s.startFolderMode }, set: { s.startFolderMode = $0; refresh += 1 })
    }

    private var viewMode: Binding<String> {
        Binding(get: { _ = refresh; return s.defaultViewMode }, set: { s.defaultViewMode = $0; refresh += 1 })
    }

    var body: some View {
        Form {
            Section("Start") {
                Picker("Neue Fenster öffnen", selection: startMode) {
                    Text("Benutzerordner").tag("home")
                    Text("Zuletzt geöffneten Ordner").tag("last")
                    Text("Bestimmten Ordner").tag("custom")
                }
                if s.startFolderMode == "custom" {
                    HStack {
                        Text(s.startFolderPath ?? "Noch kein Ordner gewählt")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Ordner wählen …") { chooseStartFolder() }
                    }
                }
                Picker("Standardansicht", selection: viewMode) {
                    Text("Details").tag("details")
                    Text("Mittelgroße Symbole").tag("medium")
                    Text("Große Symbole").tag("large")
                    Text("Extra große Symbole").tag("extraLarge")
                }
            }
            Section("Anzeige") {
                Toggle("Versteckte Dateien anzeigen", isOn: binding({ s.showHiddenFiles }, { s.showHiddenFiles = $0 }))
                Toggle("Dateiendungen immer anzeigen (z. B. „Bericht.docx“)", isOn: binding({ s.showAllExtensions }, { s.showAllExtensions = $0 }))
                Toggle("Dateien im Baum ausblenden (nur Ordner zeigen)", isOn: binding({ s.hideFilesInTree }, { s.hideFilesInTree = $0 }))
            }
            Section("Löschen") {
                Toggle("Vor dem Verschieben in den Papierkorb nachfragen", isOn: binding({ s.confirmTrash }, { s.confirmTrash = $0 }))
                Picker("Rückschritt-Taste ⌫", selection: binding({ s.backspaceGoesBack }, { s.backspaceGoesBack = $0 })) {
                    Text("In den Papierkorb legen (Mac)").tag(false)
                    Text("Zurück zum vorigen Ordner (Windows)").tag(true)
                }
                Text("Die Entf-Taste (fn + ⌫) legt immer in den Papierkorb.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tastenkürzel") {
                Toggle("Windows-Kürzel mit ctrl (Strg) zusätzlich aktivieren", isOn: binding({ s.windowsShortcuts }, { s.windowsShortcuts = $0 }))
                Text("ctrl+C/X/V kopieren, ausschneiden, einfügen · ctrl+Z/Y rückgängig/wiederholen · ctrl+A alles · ctrl+F suchen · ctrl+L Adresse · ctrl+T neuer Tab · ctrl+W Tab schließen · ctrl+N neues Fenster · ctrl+⇧+N neuer Ordner · ctrl+D löschen. Die ⌘-Kürzel funktionieren weiterhin.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseStartFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Wählen"
        if panel.runModal() == .OK, let url = panel.url {
            s.startFolderPath = url.path
            refresh += 1
        }
    }
}

final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show() {
        if shared == nil { shared = SettingsWindowController() }
        shared?.window?.center()
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Einstellungen"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}
