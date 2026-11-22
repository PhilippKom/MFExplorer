#if DEBUG
import AppKit

/// Automatic test of the file operations. Only in debug builds, and only inside ~/ExplorerTest/_selftest.
/// Start with: open -n build/Debug/MacExplorer.app --args -selfTest <logfile>
final class DebugSelfTest {
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ExplorerTest/_selftest")
    private let fm = FileManager.default
    private let ops = FileOps.shared
    private var log: [String] = []
    private let logURL: URL
    private var steps: [(String, (@escaping () -> Void) -> Void)] = []

    init(logPath: String) { logURL = URL(fileURLWithPath: logPath) }

    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    private func exists(_ path: String) -> Bool { ops.exists(url(path)) }

    private func check(_ name: String, _ ok: Bool) {
        log.append((ok ? "PASS " : "FAIL ") + name)
    }

    private func step(_ name: String, _ body: @escaping (@escaping () -> Void) -> Void) {
        steps.append((name, body))
    }

    func run() {
        guard root.path.contains("/ExplorerTest/") else { return }
        FileOps.collectedErrors = []
        if fm.fileExists(atPath: root.path) { _ = try? ops.trash(root) }
        try? fm.createDirectory(at: url("A/sub"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: url("B"), withIntermediateDirectories: true)
        fm.createFile(atPath: url("A/file.txt").path, contents: Data(repeating: 65, count: 1_000_000))
        fm.createFile(atPath: url("A/sub/inner.txt").path, contents: Data("hallo".utf8))

        step("copy file to other folder") { next in
            self.ops.transfer([self.url("A/file.txt")], into: self.url("B"), kind: .copy) { _ in
                self.check("copy: target exists", self.exists("B/file.txt"))
                self.check("copy: source kept", self.exists("A/file.txt"))
                next()
            }
        }
        step("copy into same folder makes '- Kopie'") { next in
            self.ops.transfer([self.url("A/file.txt")], into: self.url("A"), kind: .copy) { _ in
                self.check("copy same folder: 'file - Kopie.txt'", self.exists("A/file - Kopie.txt"))
                next()
            }
        }
        step("move folder") { next in
            self.ops.transfer([self.url("A/sub")], into: self.url("B"), kind: .move) { _ in
                self.check("move: target has content", self.exists("B/sub/inner.txt"))
                self.check("move: source gone", !self.exists("A/sub"))
                next()
            }
        }
        step("undo move") { next in
            self.ops.undoManager.undo()
            self.check("undo move: back in A", self.exists("A/sub/inner.txt") && !self.exists("B/sub"))
            next()
        }
        step("redo move") { next in
            self.ops.undoManager.redo()
            self.check("redo move: in B again", self.exists("B/sub/inner.txt") && !self.exists("A/sub"))
            next()
        }
        step("rename + undo") { next in
            let renamed = self.ops.rename(self.url("B/file.txt"), to: "renamed.txt")
            self.check("rename: new name", renamed != nil && self.exists("B/renamed.txt") && !self.exists("B/file.txt"))
            DispatchQueue.main.async {
                self.ops.undoManager.undo()
                self.check("undo rename: old name back", self.exists("B/file.txt") && !self.exists("B/renamed.txt"))
                next()
            }
        }
        step("trash + undo") { next in
            self.ops.trashItems([self.url("B/file.txt")])
            self.check("trash: gone from folder", !self.exists("B/file.txt"))
            DispatchQueue.main.async {
                self.ops.undoManager.undo()
                self.check("undo trash: back from Trash", self.exists("B/file.txt"))
                next()
            }
        }
        step("new folders get unique names") { next in
            _ = self.ops.createFolder(in: self.url("B"))
            _ = self.ops.createFolder(in: self.url("B"))
            self.check("new folder: 'Neuer Ordner' and 'Neuer Ordner (2)'", self.exists("B/Neuer Ordner") && self.exists("B/Neuer Ordner (2)"))
            self.ops.undoManager.undo()
            self.check("undo only the last new folder", self.exists("B/Neuer Ordner") && !self.exists("B/Neuer Ordner (2)"))
            next()
        }
        step("copy folder recursively") { next in
            self.ops.transfer([self.url("A")], into: self.url("B"), kind: .copy) { _ in
                self.check("folder copy: content copied", self.exists("B/A/file.txt") && self.exists("B/A/file - Kopie.txt"))
                let size = (try? self.fm.attributesOfItem(atPath: self.url("B/A/file.txt").path)[.size] as? Int) ?? -1
                self.check("folder copy: file size correct (\(size))", size == 1_000_000)
                next()
            }
        }
        step("undo folder copy") { next in
            self.ops.undoManager.undo()
            self.check("undo copy: copy removed (to Trash)", !self.exists("B/A"))
            next()
        }
        step("zip") { next in
            self.ops.compress([self.url("A")]) { zip in
                self.check("zip: A.zip created (\(zip.lastPathComponent))", zip.lastPathComponent == "A.zip" && self.exists("A.zip"))
                next()
            }
        }
        step("extract") { next in
            self.ops.extract(self.url("A.zip")) { result in
                self.check("extract: 'A (2)' with content (\(result.lastPathComponent))", self.exists("A (2)/file.txt"))
                self.check("extract: no temp folder left", ((try? self.fm.contentsOfDirectory(atPath: self.root.path)) ?? []).allSatisfy { !$0.hasPrefix(".MacExplorer") })
                next()
            }
        }
        step("drop rules") { next in
            self.check("unique name keeps extension", self.ops.uniqueURL(in: self.url("B"), name: "file.txt", splitExtension: true).lastPathComponent == "file (2).txt")
            next()
        }
        runNext()
    }

    private func runNext() {
        guard !steps.isEmpty else { finish(); return }
        let (name, body) = steps.removeFirst()
        log.append("— " + name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            body { self.runNext() }
        }
    }

    private func finish() {
        for error in FileOps.collectedErrors ?? [] { log.append("ERROR-ALERT " + error) }
        let failed = log.filter { $0.hasPrefix("FAIL") }.count
        log.append(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        try? log.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
#endif
