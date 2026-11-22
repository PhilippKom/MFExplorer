import AppKit

extension Notification.Name {
    static let clipboardChanged = Notification.Name("MacExplorer.clipboardChanged")
    /// Posted after every file operation, undo and redo (the tree refreshes itself).
    static let filesChanged = Notification.Name("MacExplorer.filesChanged")
}

/// What a file operation changed. Undo only ever moves things back or puts them into the Trash —
/// nothing is ever deleted permanently.
enum FileChange {
    case moved(from: URL, to: URL)
    case created(URL)
    case trashed(original: URL, trashURL: URL)
}

enum TransferKind { case copy, move }

struct OpError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Central place for every change to the file system. All changes are undoable (Cmd+Z).
final class FileOps {
    static let shared = FileOps()
    /// Own undo history for file operations. Every operation is its own step (independent of events).
    let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    private let fm = FileManager.default
    #if DEBUG
    /// Self-test: collect error messages instead of showing alerts.
    static var collectedErrors: [String]?
    #endif

    // MARK: - Helpers

    /// Exists, without following symlinks (a broken link still counts as "exists").
    func exists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    func isPlainFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
    }

    func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let x = (try? a.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject,
              let y = (try? b.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }

    @discardableResult
    func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        do {
            try fm.trashItem(at: url, resultingItemURL: &result)
        } catch {
            throw OpError(message: "„\(url.lastPathComponent)“ konnte nicht in den Papierkorb gelegt werden. Es wurde nichts gelöscht. (\(error.localizedDescription))")
        }
        return (result as URL?) ?? url
    }

    /// "Name.txt" → "Name (2).txt", "Name (3).txt" … (Windows style). `suffix` e.g. " - Kopie".
    func uniqueURL(in folder: URL, name: String, splitExtension: Bool, suffix: String = "", taken: Set<String> = []) -> URL {
        let ext = splitExtension ? (name as NSString).pathExtension : ""
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 1
        while true {
            var candidate = base + suffix
            if n > 1 { candidate += " (\(n))" }
            if !ext.isEmpty { candidate += "." + ext }
            let url = folder.appendingPathComponent(candidate)
            if !exists(url) && !taken.contains(url.path) { return url }
            n += 1
        }
    }

    func uniqueURL(for source: URL, in folder: URL, suffix: String = "", taken: Set<String> = []) -> URL {
        uniqueURL(in: folder, name: source.lastPathComponent, splitExtension: !isPlainFolder(source), suffix: suffix, taken: taken)
    }

    static func showErrors(_ title: String, _ messages: [String]) {
        guard !messages.isEmpty else { return }
        #if DEBUG
        if collectedErrors != nil { collectedErrors?.append(title + ": " + messages.joined(separator: " | ")); return }
        #endif
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        var text = messages.prefix(8).joined(separator: "\n\n")
        if messages.count > 8 { text += "\n\n… und \(messages.count - 8) weitere." }
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: - Undo

    func registerUndo(_ changes: [FileChange], name: String) {
        guard !changes.isEmpty else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { ops in ops.revert(changes, name: name) }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        NotificationCenter.default.post(name: .filesChanged, object: nil)
    }

    private func revert(_ changes: [FileChange], name: String) {
        var done: [FileChange] = []
        var errors: [String] = []
        for change in changes.reversed() {
            do {
                switch change {
                case .moved(let from, let to):
                    if exists(from) { throw OpError(message: "„\(from.lastPathComponent)“ gibt es dort schon wieder.") }
                    try fm.moveItem(at: to, to: from)
                    done.append(.moved(from: to, to: from))
                case .created(let url):
                    guard exists(url) else { continue }
                    let location = try trash(url)
                    done.append(.trashed(original: url, trashURL: location))
                case .trashed(let original, let trashURL):
                    if exists(original) { throw OpError(message: "„\(original.lastPathComponent)“ gibt es dort schon wieder.") }
                    try fm.moveItem(at: trashURL, to: original)
                    done.append(.moved(from: trashURL, to: original))
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        registerUndo(done, name: name)   // becomes "Wiederholen"
        Self.showErrors("Nicht alles konnte rückgängig gemacht werden.", errors)
    }

    /// Small "Umbenennen" dialog (used in the tree and the icon view). nil = cancelled.
    static func askNewName(for url: URL) -> String? {
        let alert = NSAlert()
        alert.messageText = "Umbenennen"
        alert.informativeText = "Neuer Name für „\(url.lastPathComponent)“:"
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Umbenennen")
        alert.addButton(withTitle: "Abbrechen").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        alert.layout()
        if let editor = field.currentEditor() ?? (alert.window.makeFirstResponder(field) ? field.currentEditor() : nil) {
            let name = url.lastPathComponent as NSString
            let ext = name.pathExtension
            let length = ext.isEmpty ? name.length : name.length - (ext as NSString).length - 1
            editor.selectedRange = NSRange(location: 0, length: max(0, length))
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: - Simple operations (fast, on the main thread)

    func trashItems(_ urls: [URL]) {
        var changes: [FileChange] = []
        var errors: [String] = []
        for url in urls {
            do {
                let location = try trash(url)
                changes.append(.trashed(original: url, trashURL: location))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        registerUndo(changes, name: "In den Papierkorb legen")
        Self.showErrors("Fehler beim Löschen", errors)
    }

    /// Returns the new URL, or nil if nothing was renamed.
    func rename(_ url: URL, to newName: String) -> URL? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return nil }
        if name.contains("/") || name.contains(":") || name == "." || name == ".." {
            Self.showErrors("Ungültiger Name", ["Ein Name darf kein „/“ und kein „:“ enthalten."])
            return nil
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        let onlyCaseChanged = target.path.lowercased() == url.path.lowercased()
        if exists(target) && !onlyCaseChanged {
            Self.showErrors("Name schon vergeben", ["Es gibt hier bereits ein Element mit dem Namen „\(name)“."])
            return nil
        }
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            Self.showErrors("Umbenennen nicht möglich", [error.localizedDescription])
            return nil
        }
        registerUndo([.moved(from: url, to: target)], name: "Umbenennen")
        return target
    }

    func createFolder(in folder: URL) -> URL? {
        let url = uniqueURL(in: folder, name: "Neuer Ordner", splitExtension: false)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            Self.showErrors("Ordner konnte nicht erstellt werden", [error.localizedDescription])
            return nil
        }
        registerUndo([.created(url)], name: "Neuer Ordner")
        return url
    }

    func createTextFile(in folder: URL) -> URL? {
        let url = uniqueURL(in: folder, name: "Neues Textdokument.txt", splitExtension: true)
        guard fm.createFile(atPath: url.path, contents: Data()) else {
            Self.showErrors("Datei konnte nicht erstellt werden", ["Keine Schreibrechte in diesem Ordner?"])
            return nil
        }
        registerUndo([.created(url)], name: "Neues Textdokument")
        return url
    }

    // MARK: - Tags

    func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    func setTags(_ map: [URL: [String]]) {
        var previous: [URL: [String]] = [:]
        var errors: [String] = []
        for (url, tags) in map {
            previous[url] = self.tags(of: url)
            do { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) } catch { errors.append(error.localizedDescription) }
        }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { ops in ops.setTags(previous) }
        undoManager.setActionName("Tags ändern")
        undoManager.endUndoGrouping()
        NotificationCenter.default.post(name: .filesChanged, object: nil)
        Self.showErrors("Tags konnten nicht gesetzt werden", errors)
    }

    // MARK: - Copy / move with conflict questions and progress

    struct TransferItem {
        let source: URL
        let destination: URL
        let replacing: URL?
    }

    private enum ConflictAction { case replace, skip, keepBoth }

    private func describe(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let what = isPlainFolder(url) ? "Ordner" : Format.size(Int64(v?.fileSize ?? 0))
        return "\(what), geändert am \(Format.date(v?.contentModificationDate))"
    }

    /// nil = user pressed "Abbrechen".
    private func askConflict(existing: URL, incoming: URL, offerApplyAll: Bool) -> (ConflictAction, Bool)? {
        let alert = NSAlert()
        alert.messageText = "„\(existing.lastPathComponent)“ gibt es im Ziel schon."
        alert.informativeText = """
            Vorhanden: \(describe(existing))
            Neu: \(describe(incoming))

            Bei „Ersetzen“ kommt das vorhandene Element in den Papierkorb.
            """
        alert.icon = NSWorkspace.shared.icon(forFile: existing.path)
        alert.addButton(withTitle: "Beide behalten")
        alert.addButton(withTitle: "Ersetzen")
        alert.addButton(withTitle: "Überspringen")
        alert.addButton(withTitle: "Abbrechen").keyEquivalent = "\u{1b}"
        if offerApplyAll {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Für alle weiteren Konflikte übernehmen"
        }
        let response = alert.runModal()
        let all = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.keepBoth, all)
        case .alertSecondButtonReturn: return (.replace, all)
        case .alertThirdButtonReturn: return (.skip, all)
        default: return nil
        }
    }

    /// Decides where every item goes and asks about name conflicts. nil = cancelled.
    func plan(_ sources: [URL], into folder: URL, kind: TransferKind) -> [TransferItem]? {
        let folder = folder.standardizedFileURL
        var items: [TransferItem] = []
        var taken = Set<String>()
        var remembered: ConflictAction?
        var errors: [String] = []

        for raw in sources {
            let source = raw.standardizedFileURL
            let parent = source.deletingLastPathComponent().standardizedFileURL
            if source.path == folder.path || folder.path.hasPrefix(source.path + "/") {
                errors.append("„\(source.lastPathComponent)“ kann nicht in sich selbst \(kind == .copy ? "kopiert" : "verschoben") werden.")
                continue
            }
            if parent.path == folder.path {
                if kind == .move { continue }   // already here
                let destination = uniqueURL(for: source, in: folder, suffix: " - Kopie", taken: taken)
                taken.insert(destination.path)
                items.append(TransferItem(source: source, destination: destination, replacing: nil))
                continue
            }
            var destination = folder.appendingPathComponent(source.lastPathComponent)
            var replacing: URL?
            if exists(destination) || taken.contains(destination.path) {
                let action: ConflictAction
                if let remembered {
                    action = remembered
                } else {
                    guard let answer = askConflict(existing: destination, incoming: source, offerApplyAll: sources.count > 1) else { return nil }
                    action = answer.0
                    if answer.1 { remembered = answer.0 }
                }
                switch action {
                case .skip:
                    continue
                case .replace where !taken.contains(destination.path) && !source.path.hasPrefix(destination.path + "/"):
                    replacing = destination
                case .replace, .keepBoth:
                    destination = uniqueURL(for: source, in: folder, taken: taken)
                }
            }
            taken.insert(destination.path)
            items.append(TransferItem(source: source, destination: destination, replacing: replacing))
        }
        Self.showErrors("Hinweis", errors)
        return items
    }

    /// Copies or moves `sources` into `folder`. Big jobs show a progress window with "Abbrechen".
    func transfer(_ sources: [URL], into folder: URL, kind: TransferKind, completion: (([URL]) -> Void)? = nil) {
        guard let items = plan(sources, into: folder, kind: kind), !items.isEmpty else { return }
        let verb = kind == .copy ? "Kopieren" : "Verschieben"
        let job = ProgressJob(title: "\(verb) nach „\(FileManager.default.displayName(atPath: folder.path))“", itemCount: items.count)
        let panel = ProgressPanel(job: job)
        panel.showAfterDelay()

        DispatchQueue.global(qos: .userInitiated).async {
            let instant = items.map { kind == .move && self.sameVolume($0.source.deletingLastPathComponent(), folder) }
            let sizes = items.indices.map { instant[$0] ? Int64(0) : Self.totalSize(of: items[$0].source) }
            job.setTotal(sizes.reduce(0, +))

            var changes: [FileChange] = []
            var errors: [String] = []
            var results: [URL] = []
            for (index, item) in items.enumerated() {
                if job.isCancelled { break }
                job.beginItem(index, name: item.source.lastPathComponent)
                do {
                    if let old = item.replacing {
                        let location = try self.trash(old)
                        changes.append(.trashed(original: old, trashURL: location))
                    }
                    if instant[index] {
                        try self.fm.moveItem(at: item.source, to: item.destination)
                        changes.append(.moved(from: item.source, to: item.destination))
                    } else {
                        try self.copyWithProgress(item.source, to: item.destination, job: job)
                        changes.append(.created(item.destination))
                        if kind == .move {
                            let location = try self.trash(item.source)
                            changes.append(.trashed(original: item.source, trashURL: location))
                        }
                    }
                    results.append(item.destination)
                } catch {
                    if !job.isCancelled { errors.append("„\(item.source.lastPathComponent)“: \(error.localizedDescription)") }
                }
                job.endItem(addingBytes: sizes[index])
            }
            DispatchQueue.main.async {
                panel.close()
                self.registerUndo(changes, name: verb)
                Self.showErrors("Beim \(verb) gab es Probleme", errors)
                completion?(results)
            }
        }
    }

    static func totalSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let v = try? url.resourceValues(forKeys: Set(keys))
        if v?.isRegularFile == true { return Int64(v?.fileSize ?? 0) }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let child as URL in e {
                let cv = try? child.resourceValues(forKeys: Set(keys))
                if cv?.isRegularFile == true { total += Int64(cv?.fileSize ?? 0) }
            }
        }
        return total
    }

    private func copyWithProgress(_ source: URL, to destination: URL, job: ProgressJob) throws {
        guard let state = copyfile_state_alloc() else { throw OpError(message: "Kopieren konnte nicht starten.") }
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyProgressCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(job).toOpaque())
        // ACL | STAT | XATTR | DATA | RECURSIVE | EXCL (never overwrite) | NOFOLLOW_SRC | CLONE (instant on APFS)
        let bits: [UInt32] = [0, 1, 2, 3, 15, 17, 18, 24]
        let flags = copyfile_flags_t(bits.reduce(UInt32(0)) { $0 | (UInt32(1) << $1) })
        let result = copyfile(source.path, destination.path, state, flags)
        if result != 0 {
            let code = errno
            if exists(destination) { _ = try? trash(destination) }   // remove our half-finished copy
            if job.isCancelled { throw OpError(message: "Abgebrochen") }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    // MARK: - ZIP

    func compress(_ urls: [URL], completion: ((URL) -> Void)? = nil) {
        guard let first = urls.first else { return }
        let folder = first.deletingLastPathComponent()
        let name: String
        if urls.count == 1 {
            name = (isPlainFolder(first) ? first.lastPathComponent : (first.lastPathComponent as NSString).deletingPathExtension) + ".zip"
        } else {
            name = "Archiv.zip"
        }
        let target = uniqueURL(in: folder, name: name, splitExtension: true)
        let process = Process()
        if urls.count == 1 {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, target.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = folder
            process.arguments = ["-r", "-y", "-q", target.path] + urls.map(\.lastPathComponent)
        }
        runTool(process, title: "Komprimieren …", cleanup: target) { ok in
            guard ok else { return }
            self.registerUndo([.created(target)], name: "Komprimieren")
            completion?(target)
        }
    }

    func extract(_ zip: URL, completion: ((URL) -> Void)? = nil) {
        let folder = zip.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".MacExplorer-Entpacken-\(UUID().uuidString)")
        do { try fm.createDirectory(at: temp, withIntermediateDirectories: false) } catch {
            Self.showErrors("Entpacken nicht möglich", [error.localizedDescription]); return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, temp.path]
        runTool(process, title: "Entpacken …", cleanup: temp) { ok in
            guard ok else { return }
            let contents = ((try? self.fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
            do {
                let result: URL
                if contents.count == 1 {
                    // The archive holds one folder or file: put it right next to the ZIP.
                    result = self.uniqueURL(for: contents[0], in: folder)
                    try self.fm.moveItem(at: contents[0], to: result)
                    _ = try? self.trash(temp)
                } else {
                    let base = (zip.lastPathComponent as NSString).deletingPathExtension
                    result = self.uniqueURL(in: folder, name: base, splitExtension: false)
                    try self.fm.moveItem(at: temp, to: result)
                }
                self.registerUndo([.created(result)], name: "Entpacken")
                completion?(result)
            } catch {
                Self.showErrors("Entpacken nicht möglich", [error.localizedDescription])
            }
        }
    }

    private func runTool(_ process: Process, title: String, cleanup: URL, done: @escaping (Bool) -> Void) {
        let job = ProgressJob(title: title, itemCount: 1)
        job.onCancel = { if process.isRunning { process.terminate() } }
        let panel = ProgressPanel(job: job)
        panel.showAfterDelay()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 && !job.isCancelled {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    message = String(data: data, encoding: .utf8) ?? "Fehler \(process.terminationStatus)"
                }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                panel.close()
                let ok = message == nil && !job.isCancelled
                if !ok, self.exists(cleanup) { _ = try? self.trash(cleanup) }
                if let message { Self.showErrors("Vorgang fehlgeschlagen", [message]) }
                done(ok)
            }
        }
    }
}

// MARK: - Progress

private let copyProgressCallback: copyfile_callback_t = { what, stage, state, source, _, context in
    guard let context else { return COPYFILE_CONTINUE }
    let job = Unmanaged<ProgressJob>.fromOpaque(context).takeUnretainedValue()
    if job.isCancelled { return COPYFILE_QUIT }
    if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        job.setFileProgress(Int64(copied))
    } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH {
        var info = stat()
        if let source, lstat(source, &info) == 0 { job.fileFinished(bytes: Int64(info.st_size)) }
    } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START, let source {
        job.setCurrentFile((String(cString: source) as NSString).lastPathComponent)
    } else if stage == COPYFILE_ERR {
        return COPYFILE_QUIT
    }
    return COPYFILE_CONTINUE
}

/// Thread-safe progress counters shared between the worker and the progress window.
final class ProgressJob {
    let title: String
    let itemCount: Int
    var onCancel: (() -> Void)?
    private let lock = NSLock()
    private var total: Int64 = 0
    private var itemBase: Int64 = 0      // bytes of finished items
    private var fileBase: Int64 = 0      // bytes of finished files inside the current item
    private var fileProgress: Int64 = 0
    private var itemIndex = 0
    private var currentName = ""
    private var cancelled = false

    init(title: String, itemCount: Int) {
        self.title = title
        self.itemCount = itemCount
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
        onCancel?()
    }

    func setTotal(_ bytes: Int64) { lock.withLock { total = bytes } }

    func beginItem(_ index: Int, name: String) {
        lock.withLock { itemIndex = index; currentName = name; fileBase = 0; fileProgress = 0 }
    }

    func endItem(addingBytes bytes: Int64) {
        lock.withLock { itemBase += bytes; fileBase = 0; fileProgress = 0 }
    }

    func setCurrentFile(_ name: String) { lock.withLock { currentName = name } }
    func setFileProgress(_ bytes: Int64) { lock.withLock { fileProgress = bytes } }
    func fileFinished(bytes: Int64) { lock.withLock { fileBase += bytes; fileProgress = 0 } }

    struct Snapshot { let done: Int64; let total: Int64; let index: Int; let name: String }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(done: itemBase + fileBase + fileProgress, total: total, index: itemIndex, name: currentName) }
    }
}

/// Small window with a progress bar. Only appears if the job takes longer than half a second.
final class ProgressPanel: NSObject {
    private let job: ProgressJob
    private var panel: NSPanel?
    private var timer: Timer?
    private var finished = false
    private let bar = NSProgressIndicator()
    private let nameLabel = NSTextField(labelWithString: "")
    private let bytesLabel = NSTextField(labelWithString: "")

    init(job: ProgressJob) {
        self.job = job
    }

    func showAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if !finished { show() }
        }
    }

    private func show() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 140),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = job.title
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let titleLabel = NSTextField(labelWithString: job.title)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textColor = .secondaryLabelColor
        bytesLabel.textColor = .secondaryLabelColor
        bytesLabel.font = .systemFont(ofSize: 11)
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [titleLabel, nameLabel, bar, bytesLabel, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(12, after: bytesLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        cancel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20).isActive = true

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        update()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update() {
        let s = job.snapshot()
        nameLabel.stringValue = job.itemCount > 1 ? "Element \(s.index + 1) von \(job.itemCount): \(s.name)" : s.name
        if s.total > 0 {
            if bar.isIndeterminate { bar.isIndeterminate = false; bar.stopAnimation(nil) }
            bar.doubleValue = min(1, Double(s.done) / Double(s.total))
            bytesLabel.stringValue = "\(Format.size(s.done)) von \(Format.size(s.total))"
        } else {
            bytesLabel.stringValue = ""
        }
    }

    @objc private func cancelPressed(_ sender: Any?) {
        job.cancel()
        nameLabel.stringValue = "Wird abgebrochen …"
    }

    func close() {
        finished = true
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Clipboard (Cut / Copy / Paste)

/// Copy puts the files on the normal clipboard (Finder can paste them too).
/// Cut is remembered here; pasting after a cut moves instead of copying.
final class FileClipboard {
    static let shared = FileClipboard()
    private var cutURLs: Set<URL> = []
    private var cutChangeCount = -1

    func write(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        cutURLs = cut ? Set(urls.map(\.standardizedFileURL)) : []
        cutChangeCount = pb.changeCount
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    var isCutActive: Bool {
        !cutURLs.isEmpty && NSPasteboard.general.changeCount == cutChangeCount
    }

    func isCut(_ url: URL) -> Bool {
        isCutActive && cutURLs.contains(url.standardizedFileURL)
    }

    var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func readURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func finishCut() {
        cutURLs = []
        NSPasteboard.general.clearContents()
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }
}

// MARK: - Drag & drop rules (shared by the list and the tree)

enum DropRules {
    static func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func hasPromises(_ info: NSDraggingInfo) -> Bool {
        let types = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return !(info.draggingPasteboard.types ?? []).filter(types.contains).isEmpty
    }

    /// Same drive = move, other drive = copy. Option forces copy, Command forces move.
    static func kind(for urls: [URL], into folder: URL, info: NSDraggingInfo) -> TransferKind {
        let mods = NSEvent.modifierFlags
        if mods.contains(.option) { return .copy }
        if mods.contains(.command) { return .move }
        let mask = info.draggingSourceOperationMask
        if !mask.contains(.move) && !mask.contains(.generic) { return .copy }
        guard let first = urls.first else { return .copy }
        return FileOps.shared.sameVolume(first.deletingLastPathComponent(), folder) ? .move : .copy
    }

    static func operation(_ info: NSDraggingInfo, into folder: URL) -> NSDragOperation {
        let list = urls(info)
        if list.isEmpty { return hasPromises(info) ? .copy : [] }
        let target = folder.standardizedFileURL.path
        for url in list {
            let path = url.standardizedFileURL.path
            if path == target || target.hasPrefix(path + "/") { return [] }
        }
        let kind = kind(for: list, into: folder, info: info)
        if kind == .move && list.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == target }) { return [] }
        return kind == .copy ? .copy : .move
    }

    /// While dragging over our list or tree, show each file as a clean row (icon + name), like Windows.
    static func showAsRows(_ info: NSDraggingInfo, in view: NSView, width: CGFloat, rowHeight: CGFloat) {
        info.draggingFormation = .list
        let size = NSSize(width: width, height: rowHeight)
        info.enumerateDraggingItems(options: [.clearNonenumeratedImages], for: view, classes: [NSURL.self],
                                    searchOptions: [.urlReadingFileURLsOnly: true]) { item, _, _ in
            guard let url = (item.item as? NSURL) as URL? else { return }
            item.draggingFrame = NSRect(origin: item.draggingFrame.origin, size: size)
            item.imageComponentsProvider = { rowImage(for: url, size: size) }
        }
    }

    private static func rowImage(for url: URL, size: NSSize) -> [NSDraggingImageComponent] {
        let icon = NSDraggingImageComponent(key: .icon)
        icon.contents = NSWorkspace.shared.icon(forFile: url.path)
        icon.frame = NSRect(x: 4, y: (size.height - 16) / 2, width: 16, height: 16)

        let name = FileManager.default.displayName(atPath: url.path)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let textSize = (name as NSString).size(withAttributes: attributes)
        let width = min(ceil(textSize.width), size.width - 30)
        let text = NSImage(size: NSSize(width: width, height: ceil(textSize.height)), flipped: false) { rect in
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var attrs = attributes
            attrs[.paragraphStyle] = style
            (name as NSString).draw(in: rect, withAttributes: attrs)
            return true
        }
        let label = NSDraggingImageComponent(key: .label)
        label.contents = text
        label.frame = NSRect(x: 26, y: (size.height - text.size.height) / 2, width: text.size.width, height: text.size.height)
        return [icon, label]
    }

    static func accept(_ info: NSDraggingInfo, into folder: URL, completion: (([URL]) -> Void)? = nil) -> Bool {
        let list = urls(info)
        if !list.isEmpty {
            let kind = kind(for: list, into: folder, info: info)
            // Let the drag finish first, then ask questions / show progress.
            DispatchQueue.main.async {
                FileOps.shared.transfer(list, into: folder, kind: kind, completion: completion)
            }
            return true
        }
        // Files "promised" by other apps (e.g. Mail attachments): receive into a temp folder, then move in.
        guard let receivers = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
              !receivers.isEmpty,
              let temp = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        else { return false }
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
        var received: [URL] = []
        var finished = 0
        let queue = OperationQueue()
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: temp, options: [:], operationQueue: queue) { url, error in
                DispatchQueue.main.async {
                    if error == nil { received.append(url) }
                    finished += 1
                    if finished == expected {
                        FileOps.shared.transfer(received, into: folder, kind: .move, completion: completion)
                    }
                }
            }
        }
        return true
    }
}
