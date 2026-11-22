import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Finds files whose *content* contains a word, using the search index macOS keeps anyway (Spotlight).
/// The app reads no files for this, so it does not slow the Mac down.
final class ContentSearch: NSObject {
    private var query: NSMetadataQuery?
    private var onFinish: (([URL]) -> Void)?

    func start(_ text: String, in root: URL, finish: @escaping ([URL]) -> Void) {
        stop()
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
        guard let predicate = NSPredicate(fromMetadataQueryString: "kMDItemTextContent == \"*\(escaped)*\"cd") else {
            finish([])
            return
        }
        let metadataQuery = NSMetadataQuery()
        metadataQuery.predicate = predicate
        metadataQuery.searchScopes = [root]
        NotificationCenter.default.addObserver(self, selector: #selector(gathered(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: metadataQuery)
        query = metadataQuery
        onFinish = finish
        if !metadataQuery.start() {
            stop()
            finish([])
        }
    }

    @objc private func gathered(_ notification: Notification) {
        guard let metadataQuery = query else { return }
        metadataQuery.disableUpdates()
        var urls: [URL] = []
        for index in 0..<min(metadataQuery.resultCount, 10_000) {
            if let item = metadataQuery.result(at: index) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        let finish = onFinish
        stop()
        finish?(urls)
    }

    func stop() {
        if let query {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
        }
        query = nil
        onFinish = nil
    }
}

/// The line of text where the search word was found ("Fundstelle").
enum Snippet {
    /// nil = the file type can't be read as text (e.g. Word) – the caller shows a general hint instead.
    static func find(_ word: String, in url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        guard let type = values?.contentType else { return nil }
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url),
                  let selection = document.findString(word, withOptions: [.caseInsensitive, .diacriticInsensitive]).first else { return nil }
            selection.extendForLineBoundaries()
            return shorten(selection.string ?? "", around: word)
        }
        guard type.conforms(to: .text), (values?.fileSize ?? 0) < 20_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        let text: String?
        if type.conforms(to: .rtf) {
            text = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
        }
        guard let text, let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        return shorten(String(text[text.lineRange(for: range)]), around: word)
    }

    /// One line, at most ~140 characters, with the word roughly in the middle.
    private static func shorten(_ line: String, around word: String) -> String {
        let flat = line.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 140, let range = flat.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return flat }
        let start = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 70, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "… " : "") + flat[start..<end] + (end < flat.endIndex ? " …" : "")
    }

    /// The line with the search word in bold on a yellow background.
    static func highlighted(_ text: String, word: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let nsRange = NSRange(found, in: text)
            result.addAttributes([
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45),
            ], range: nsRange)
            searchRange = found.upperBound..<text.endIndex
        }
        return result
    }
}
