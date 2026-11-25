import AppKit
import TeraCore

/// 要望・お知らせボックス。気づいたことを匿名で送る (返事はできない伝言)。
/// 送り先は Google フォーム (Tera Term Mac 要望・お知らせ)。名前やメールアドレスは聞かない。
/// 送信元の IP アドレスは Google に届くので、画面にもそう書く
enum Feedback {
    /// フォームの送信先と欄の番号 (フォームの「事前入力した URL」の entry.NNN)
    static let formResponseURL = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSdzihdyyYEKkEQMjgmghRpUn-2TSUnxCVRyLAOB5y_W-WeVwA/formResponse")!
    static let viewFormURL = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSdzihdyyYEKkEQMjgmghRpUn-2TSUnxCVRyLAOB5y_W-WeVwA/viewform")!
    static let entryKind = "entry.1972926900"      // 種類 (記述式)
    static let entryMessage = "entry.1020017825"   // 内容 (段落)
    static let entryEnvironment = "entry.773350443" // 環境 (記述式)
    static let maxLength = 4000

    /// 種類。フォームには画面の言語によらず日本語で送る (受け取る人が読みやすいように)
    static let kinds: [(key: String, ja: String)] = [("FEEDBACK_KIND_REQUEST", "要望"), ("FEEDBACK_KIND_BUG", "不具合"), ("FEEDBACK_KIND_OTHER", "その他")]

    /// 添える環境: "Tera Term Mac 0.5.1 / macOS 14.5 / Apple Silicon / ja_JP"
    static var environment: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        // Rosetta で動いているか (sysctl.proc_translated)
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        let arch = rosetta ? "Apple Silicon (Rosetta)" : "Intel"
        #endif
        return "Tera Term Mac \(v) / macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) / \(arch) / \((Lang.current as NSString).deletingPathExtension)"
    }

    /// フォームへ送る。完了は main で (成功なら true)
    static func send(kind: String, message: String, includeEnvironment: Bool, completion: @escaping (Bool) -> Void) {
        var c = URLComponents()
        c.queryItems = [
            URLQueryItem(name: entryKind, value: kind),
            URLQueryItem(name: entryMessage, value: String(message.prefix(maxLength))),
            URLQueryItem(name: entryEnvironment, value: includeEnvironment ? environment : ""),
        ]
        var req = URLRequest(url: formResponseURL, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // + と & などをきちんと逃がす (URLComponents は + を逃がさない)
        let body = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let ok = err == nil && ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }
}

/// 送る画面 (ひとつだけ)
final class FeedbackPanel: NSObject, NSTextViewDelegate {
    static let shared = FeedbackPanel()
    private var panel: NSPanel?
    private let kindPopup = NSPopUpButton()
    private let textView = NSTextView()
    private let envCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let envLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    static func show() { shared.open() }

    private func open() {
        if let p = panel { p.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.title = Lang.m("FEEDBACK_TITLE", "要望・お知らせを送る")
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 420, height: 340)

        let intro = NSTextField(wrappingLabelWithString: Lang.m("FEEDBACK_INTRO",
            "気づいたことや要望を、匿名で開発者に伝えられます。返事はできませんが、今後の改善の参考にします。"))
        let note = NSTextField(wrappingLabelWithString: Lang.m("FEEDBACK_PRIVACY",
            "名前やメールアドレスは送りません。送り先は Google フォームで、送った端末の IP アドレスは Google に届きます。パスワードなどの大事な情報は書かないでください。"))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)

        kindPopup.removeAllItems()
        kindPopup.addItems(withTitles: Feedback.kinds.map { Lang.m($0.key, $0.ja) })
        let kindRow = NSStackView(views: [NSTextField(labelWithString: Lang.m("FEEDBACK_KIND", "種類:")), kindPopup])

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.delegate = self
        textView.string = ""
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        envCheck.title = Lang.m("FEEDBACK_INCLUDE_ENV", "アプリと macOS の版を添える")
        envCheck.state = .on
        envLabel.stringValue = Feedback.environment
        envLabel.textColor = .secondaryLabelColor
        envLabel.font = .systemFont(ofSize: 11)

        sendButton.title = Lang.m("FEEDBACK_SEND", "送る")
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.isEnabled = false
        let cancel = NSButton(title: Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"), target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let buttons = NSStackView(views: [spinner, NSView(), cancel, sendButton])

        let stack = NSStackView(views: [intro, kindRow, scroll, envCheck, envLabel, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        for v in [intro, scroll, note, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        p.contentView = stack
        for v in [intro, scroll, note, buttons] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        p.center()
        panel = p
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func textDidChange(_ notification: Notification) {
        sendButton.isEnabled = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func close() { panel?.orderOut(nil) }

    @objc private func send() {
        let msg = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        let kind = Feedback.kinds[max(0, kindPopup.indexOfSelectedItem)].ja
        sendButton.isEnabled = false
        spinner.startAnimation(nil)
        Feedback.send(kind: kind, message: msg, includeEnvironment: envCheck.state == .on) { [weak self] ok in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            self.sendButton.isEnabled = true
            let a = NSAlert()
            if ok {
                a.messageText = Lang.m("FEEDBACK_SENT", "送りました。ありがとうございました。")
                a.runModal()
                self.textView.string = ""
                self.sendButton.isEnabled = false
                self.close()
            } else {
                a.messageText = Lang.m("FEEDBACK_FAILED", "送れませんでした。")
                a.informativeText = Lang.m("FEEDBACK_FAILED_INFO", "ネットワークの接続を確かめて、もう一度送ってください。ブラウザのフォームから送ることもできます。")
                a.addButton(withTitle: Lang.t("Tera Term", "BTN_OK", "OK"))
                a.addButton(withTitle: Lang.m("FEEDBACK_OPEN_BROWSER", "ブラウザで開く"))
                if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Feedback.viewFormURL) }
            }
        }
    }
}
