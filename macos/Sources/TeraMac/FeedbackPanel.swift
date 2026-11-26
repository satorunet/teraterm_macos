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

    /// もう 1 つの送り方: GitHub の Issues (返事・やりとりができる。GitHub のアカウントが要る)。
    /// ブラウザで新しい Issue の画面を開き、書いた内容と環境を本文に入れておく (送るのは利用者がブラウザで押したとき)
    static let issuesNewURL = "https://github.com/teraterm-mac/teraterm-mac/issues/new"
    static func openIssue(message: String) {
        var body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > 3000 { body = String(body.prefix(3000)) }
        body += (body.isEmpty ? "" : "\n\n") + "---\n" + environment
        var c = URLComponents(string: issuesNewURL)!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        if let u = c.url { NSWorkspace.shared.open(u) }
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

/// 送る画面 (ひとつだけ)。LINE のようなトーク画面で、送るとロボットの「てらたーむくん」がすぐ返事をする。
/// 何度でも続けて送れる
final class FeedbackPanel: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let shared = FeedbackPanel()
    private var panel: NSPanel?
    private let kindPopup = NSPopUpButton()
    private let textView = FeedbackInputTextView()
    private let envCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private let talk = NSStackView()
    private let talkScroll = NSScrollView()
    private var typingRow: NSView?

    /// LINE っぽい色
    static let talkBG = NSColor(srgbRed: 0x8C / 255.0, green: 0xAB / 255.0, blue: 0xD8 / 255.0, alpha: 1)
    static let mineBG = NSColor(srgbRed: 0x8D / 255.0, green: 0xE0 / 255.0, blue: 0x55 / 255.0, alpha: 1)
    static let robotName = Lang.m("FEEDBACK_ROBOT_NAME", "てらたーむくん")

    static func show() { shared.open() }

    private func open() {
        if let p = panel { p.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); p.makeFirstResponder(textView); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.title = Lang.m("FEEDBACK_TITLE", "要望・お知らせを送る")
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 360, height: 420)
        p.delegate = self
        p.appearance = NSAppearance(named: .aqua)

        // 上: 相手の名前と、送り先の説明 (小さく)
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(srgbRed: 0.23, green: 0.27, blue: 0.36, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "🤖 " + Lang.m("FEEDBACK_HEADER", "Tera Term Macにお気軽メッセージをどうぞ！"))
        title.font = .boldSystemFont(ofSize: 14)
        title.textColor = .white
        let sub = NSTextField(wrappingLabelWithString: Lang.m("FEEDBACK_PRIVACY",
            "内容は公開されません、開発者だけに届きます。"))
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = NSColor.white.withAlphaComponent(0.75)
        let hs = NSStackView(views: [title, sub])
        hs.orientation = .vertical
        hs.alignment = .leading
        hs.spacing = 3
        hs.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        hs.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(hs)
        NSLayoutConstraint.activate([hs.topAnchor.constraint(equalTo: header.topAnchor), hs.bottomAnchor.constraint(equalTo: header.bottomAnchor),
                                     hs.leadingAnchor.constraint(equalTo: header.leadingAnchor), hs.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                                     sub.widthAnchor.constraint(equalTo: hs.widthAnchor, constant: -24)])

        // まんなか: トーク
        talk.orientation = .vertical
        talk.alignment = .leading
        talk.spacing = 10
        talk.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        talk.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(talk)
        talkScroll.documentView = doc
        talkScroll.hasVerticalScroller = true
        talkScroll.drawsBackground = true
        talkScroll.backgroundColor = FeedbackPanel.talkBG
        talkScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: talkScroll.contentView.widthAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: talkScroll.contentView.heightAnchor),
            talk.topAnchor.constraint(equalTo: doc.topAnchor), talk.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            talk.trailingAnchor.constraint(equalTo: doc.trailingAnchor), talk.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
        ])

        // 下: 種類・版を添える・GitHub、入力欄と送るボタン
        kindPopup.removeAllItems()
        kindPopup.addItems(withTitles: Feedback.kinds.map { Lang.m($0.key, $0.ja) })
        kindPopup.controlSize = .small
        kindPopup.font = .systemFont(ofSize: 11)
        envCheck.title = Lang.m("FEEDBACK_INCLUDE_ENV", "アプリと macOS の版を添える")
        envCheck.state = .on
        envCheck.controlSize = .small
        envCheck.font = .systemFont(ofSize: 11)
        envCheck.toolTip = Feedback.environment
        let issues = NSButton(title: Lang.m("FEEDBACK_ISSUES_BUTTON", "GitHub の Issues で送る…"), target: self, action: #selector(openIssues))
        issues.isBordered = false
        issues.font = .systemFont(ofSize: 11)
        issues.contentTintColor = .linkColor
        issues.toolTip = Lang.m("FEEDBACK_ISSUES_NOTE",
            "返事がほしいときや、やりとりしながら直したいときは「GitHub の Issues で送る」を使ってください (GitHub のアカウントが要ります)。書いた内容はブラウザの Issue の画面に入ります。")
        let opts = NSStackView(views: [kindPopup, envCheck, NSView(), issues])
        opts.spacing = 8

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.delegate = self
        textView.onSend = { [weak self] in self?.send() }
        textView.textContainerInset = NSSize(width: 4, height: 6)
        let inputScroll = NSScrollView()
        inputScroll.hasVerticalScroller = true
        inputScroll.documentView = textView
        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = true
        inputScroll.backgroundColor = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
        textView.backgroundColor = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
        inputScroll.wantsLayer = true
        inputScroll.layer?.cornerRadius = 14
        inputScroll.layer?.masksToBounds = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        inputScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        textView.placeholder = Lang.m("FEEDBACK_PLACEHOLDER", "メッセージを入力 (Enter で送信、Shift+Enter で改行)")

        sendButton.title = Lang.m("FEEDBACK_SEND", "送る")
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.isEnabled = false
        let inputRow = NSStackView(views: [inputScroll, sendButton])
        inputRow.alignment = .centerY
        inputRow.spacing = 8

        let bottom = NSStackView(views: [opts, inputRow])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 6
        bottom.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        bottom.wantsLayer = true
        bottom.layer?.backgroundColor = NSColor.white.cgColor
        for v in [opts, inputRow] { v.translatesAutoresizingMaskIntoConstraints = false }

        let root = NSStackView(views: [header, talkScroll, bottom])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        p.contentView = root
        for v in [header, talkScroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        for v in [opts, inputRow] { v.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -20).isActive = true }
        talkScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        talkScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        addRobot(typing: true, Lang.m("FEEDBACK_ROBOT_HELLO", "やっほー！Tera Term Mac つかってくれてありがとう🙌\n「ここ使いにくい…」「こんなのほしい！」とか、なんでも気軽に送ってね。読むのは開発者だけだよ。\nお返事はボクの自動返信だけで、ひとりひとりには返せないけど、ちゃんと届いてるから安心してね！"))
        p.center()
        panel = p
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }


    /// TERAMAC_FEEDBACKSNAP=<png>: 送らずにトークの見た目だけ作って写す
    static func debugSnap(_ path: String) {
        shared.open()
        let m = shared.addMine("接続先の一覧をフォルダで分けられるとうれしいです！", tag: Lang.m("FEEDBACK_KIND_REQUEST", "要望"))
        m.markRead()
        shared.addRobot(Lang.m("FEEDBACK_ROBOT_THANKS", "ご意見アリガトウ！改善ニ役立テマス！"))
        shared.addMine("あと、もう1つ。", tag: Lang.m("FEEDBACK_KIND_BUG", "不具合"))
        shared.showTyping()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let w = shared.panel { SelfTest.snapWindow(w, path) }
            exit(0)
        }
    }

    func textDidChange(_ notification: Notification) {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = !empty
    }

    @objc private func close() { panel?.orderOut(nil) }

    @objc private func openIssues() {
        Feedback.openIssue(message: textView.string)
    }

    @objc private func send() {
        let msg = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        let k = Feedback.kinds[max(0, kindPopup.indexOfSelectedItem)]
        let kind = k.ja
        let mine = addMine(msg, tag: Lang.m(k.key, k.ja))
        textView.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification))
        showTyping()
        Feedback.send(kind: kind, message: msg, includeEnvironment: envCheck.state == .on) { [weak self] ok in
            guard let self = self else { return }
            self.hideTyping()
            if ok {
                mine.markRead()
                self.addRobot(Lang.m("FEEDBACK_ROBOT_THANKS", "ご意見アリガトウ！改善ニ役立テマス！"))
            } else {
                mine.markFailed()
                self.textView.string = msg
                self.textDidChange(Notification(name: NSText.didChangeNotification))
                self.addRobot(Lang.m("FEEDBACK_ROBOT_FAILED", "アレレ…送レマセンデシタ。\nネットワークヲ 確カメテ、モウ一度 送ッテネ。"), link: (Lang.m("FEEDBACK_OPEN_BROWSER", "ブラウザで開く"), Feedback.viewFormURL))
            }
        }
    }

    // MARK: - トークの行

    private static var timeText: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "H:mm"; return f.string(from: Date())
    }

    @discardableResult private func addMine(_ text: String, tag: String? = nil) -> FeedbackMineRow {
        let row = FeedbackMineRow(text: text, tag: tag, time: FeedbackPanel.timeText)
        append(row, trailing: true)
        return row
    }

    private func addRobot(typing: Bool = false, _ text: String, link: (String, URL)? = nil) {
        guard typing else {
            append(FeedbackRobotRow(text: text, time: FeedbackPanel.timeText, link: link), trailing: false)
            return
        }
        // タイピングしているように 1 文字ずつ出す (少し「・・・」を見せてから)
        let row = FeedbackRobotRow(text: "・・・", time: "", link: nil)
        append(row, trailing: false)
        let chars = Array(text)
        var n = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak row] in
            Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { t in
                guard let self = self, let row = row else { t.invalidate(); return }
                n = min(chars.count, n + 1)
                row.setText(String(chars[0..<n]))
                if n == chars.count { t.invalidate(); row.setTime(FeedbackPanel.timeText) }
                self.scrollToEnd()
            }
        }
    }

    private func showTyping() {
        let r = FeedbackRobotRow(text: "・・・", time: "", link: nil)
        typingRow = r
        append(r, trailing: false)
    }

    private func hideTyping() {
        typingRow?.removeFromSuperview()
        typingRow = nil
    }

    private func append(_ row: NSView, trailing: Bool) {
        row.translatesAutoresizingMaskIntoConstraints = false
        talk.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: talk.widthAnchor, constant: -20).isActive = true
        talk.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { self.scrollToEnd() }
    }

    private func scrollToEnd() {
        guard let doc = talkScroll.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - talkScroll.contentView.bounds.height)))
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// 入力欄: Enter で送る、Shift / Option + Enter で改行 (変換中の Enter は変換の確定)
final class FeedbackInputTextView: NSTextView {
    var onSend: (() -> Void)?
    /// 空のときに薄く出す文字 (文字を打った瞬間に消えるよう、自分で描く。変換中の文字も入っていれば出さない)
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5)
        (placeholder as NSString).draw(at: NSPoint(x: x, y: textContainerInset.height), withAttributes: attrs)
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !hasMarkedText() && event.modifierFlags.intersection([.shift, .option]).isEmpty {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }
}

/// ふきだし
private final class Bubble: NSView {
    private(set) var label = NSTextField(wrappingLabelWithString: "")
    init(text: String, tag: String? = nil, color: NSColor, textColor: NSColor = .black, maxWidth: CGFloat = 250) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 15
        label.stringValue = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = textColor
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = maxWidth
        addSubview(label)
        // 種類 (要望・不具合・その他) を小さな札にして本文の上に
        var top = topAnchor, topGap: CGFloat = 8
        if let t = tag {
            let chip = NSTextField(labelWithString: " " + t + " ")
            chip.font = .boldSystemFont(ofSize: 10)
            chip.textColor = .white
            chip.wantsLayer = true
            chip.drawsBackground = true
            chip.backgroundColor = NSColor(srgbRed: 0.18, green: 0.55, blue: 0.20, alpha: 1)
            chip.layer?.cornerRadius = 4
            chip.layer?.masksToBounds = true
            chip.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chip)
            NSLayoutConstraint.activate([chip.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                                         chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                                         chip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)])
            top = chip.bottomAnchor; topGap = 4
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: top, constant: topGap), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

private func smallLabel(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: 10)
    l.textColor = NSColor.white.withAlphaComponent(0.9)
    return l
}

/// 自分の行 (右・緑)。送れたら「既読」が付く
final class FeedbackMineRow: NSView {
    private let status = smallLabel("")
    init(text: String, tag: String?, time: String) {
        super.init(frame: .zero)
        let bubble = Bubble(text: text, tag: tag, color: FeedbackPanel.mineBG)
        let meta = NSStackView(views: [status, smallLabel(time)])
        meta.orientation = .vertical
        meta.alignment = .trailing
        meta.spacing = 0
        let row = NSStackView(views: [NSView(), meta, bubble])
        row.alignment = .bottom
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func markRead() { status.stringValue = Lang.m("FEEDBACK_READ", "既読") }
    func markFailed() { status.stringValue = Lang.m("FEEDBACK_NOT_SENT", "未送信"); status.textColor = NSColor(srgbRed: 1, green: 0.85, blue: 0.85, alpha: 1) }
}

/// てらたーむくんの行 (左・白、アイコンと名前つき)
private final class FeedbackRobotRow: NSView {
    private var link: URL?
    private var bubble: Bubble!
    private var timeLabel: NSTextField!
    func setText(_ s: String) { bubble.label.stringValue = s }
    func setTime(_ s: String) { timeLabel.stringValue = s }
    init(text: String, time: String, link: (String, URL)?) {
        super.init(frame: .zero)
        let icon = NSTextField(labelWithString: "🤖")
        icon.font = .systemFont(ofSize: 22)
        icon.alignment = .center
        let iconBox = NSView()
        iconBox.wantsLayer = true
        iconBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        iconBox.layer?.cornerRadius = 18
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        NSLayoutConstraint.activate([iconBox.widthAnchor.constraint(equalToConstant: 36), iconBox.heightAnchor.constraint(equalToConstant: 36),
                                     icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor), icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor)])
        let name = smallLabel(FeedbackPanel.robotName)
        let bubble = Bubble(text: text, color: .white)
        self.bubble = bubble
        var bubbleViews: [NSView] = [bubble]
        if let (title, url) = link {
            self.link = url
            let b = NSButton(title: title, target: self, action: #selector(openLink))
            b.bezelStyle = .rounded
            b.controlSize = .small
            bubbleViews.append(b)
        }
        timeLabel = smallLabel(time)
        let line = NSStackView(views: bubbleViews + [timeLabel, NSView()])
        line.alignment = .bottom
        line.spacing = 4
        let col = NSStackView(views: [name, line])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        let row = NSStackView(views: [iconBox, col])
        row.alignment = .top
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openLink() { if let u = link { NSWorkspace.shared.open(u) } }
}
