import AppKit

/// "Hilfe → Feedback senden …": opens the user's mail program with a prepared message.
/// Nothing is sent by the app itself – the user sees the draft and sends it (or not).
enum Feedback {
    /// Recipient, set in Config/Info.plist (key MFFeedbackEmail).
    static var address: String {
        #if DEBUG
        if let test = UserDefaults.standard.string(forKey: "feedbackAddress") { return test }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "MFFeedbackEmail") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "MFExplorer \(version) (Build \(build)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    static var subject: String {
        "Feedback zu MFExplorer \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
    }

    static var body: String {
        """
        Hallo,

        (Schreib hier, was dir aufgefallen ist oder was du dir wünschst.)



        ––––––––––
        \(versionLine)
        """
    }

    static var mailURL: URL? {
        guard !address.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return URL(string: "mailto:\(address)?subject=\(enc(subject))&body=\(enc(body))")
    }

    static func send() {
        if let url = mailURL,
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
           NSWorkspace.shared.open(url) {
            return
        }
        showFallback()
    }

    /// No mail program set up (or no address): show the address so it can be copied.
    private static func showFallback() {
        let alert = NSAlert()
        if address.isEmpty {
            alert.messageText = "Feedback ist noch nicht eingerichtet."
            alert.informativeText = "In dieser Version ist noch keine Feedback-Adresse hinterlegt."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.messageText = "Kein Mail-Programm gefunden"
        alert.informativeText = "Schreib dein Feedback gern an:\n\(address)\n\nBitte gib dazu deine Version an: \(versionLine)"
        alert.addButton(withTitle: "Adresse kopieren")
        alert.addButton(withTitle: "Schließen")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
    }

    #if DEBUG
    /// `-feedbackTest <log>`: writes the prepared mail (without opening anything) and quits.
    static func runTest(log: String) {
        var lines = ["address=\(address)", "url=\(mailURL?.absoluteString ?? "nil")"]
        if let url = mailURL, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for q in comps.queryItems ?? [] { lines.append("\(q.name)=\(q.value ?? "")") }
            lines.append("mailApp=\(NSWorkspace.shared.urlForApplication(toOpen: url)?.lastPathComponent ?? "keins")")
        }
        try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
    #endif
}

extension AppDelegate {
    @objc func sendFeedback(_ sender: Any?) { Feedback.send() }
}
