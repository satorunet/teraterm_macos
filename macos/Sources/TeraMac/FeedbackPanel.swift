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

/// 送る画面 (ひとつだけ)。ターミナル風の画面で、送るとロボットの「てらたーむくん」がすぐ返事をする。
/// 何度でも続けて送れる
final class FeedbackPanel: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let shared = FeedbackPanel()
    private var panel: NSPanel?
    private let kindPopup = NSPopUpButton()
    private let textView = FeedbackInputTextView()
    private let envCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let log = NSTextView()
    private let logScroll = NSScrollView()
    /// 送っている間に出すカーソル (log の中の場所)
    private var waitRange: NSRange?
    private var waitTimer: Timer?
    /// タイピング中の行 (続けて足す)
    private var typingTimer: Timer?

    // 端末の色 (Tera Term Mac の既定の画面に合わせる)
    static let bg = NSColor(srgbRed: 0x1E / 255.0, green: 0x1F / 255.0, blue: 0x22 / 255.0, alpha: 1)
    static let barBG = NSColor(srgbRed: 0x2A / 255.0, green: 0x2B / 255.0, blue: 0x2F / 255.0, alpha: 1)
    static let fg = NSColor(white: 0.86, alpha: 1)
    static let dim = NSColor(white: 0.5, alpha: 1)
    static let robot = NSColor(srgbRed: 0.35, green: 0.85, blue: 0.95, alpha: 1)
    static let me = NSColor(srgbRed: 0.45, green: 0.90, blue: 0.45, alpha: 1)
    static let tag = NSColor(srgbRed: 0.98, green: 0.85, blue: 0.35, alpha: 1)
    static let err = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.45, alpha: 1)
    /// てらたーむくんのセリフの中の「…」(例の言葉) の色
    static let quote = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.80, alpha: 1)
    static let mono = NSFont.monoSystemFont(ofSize: 13, weight: .regular)
    static let monoBold = NSFont.monoSystemFont(ofSize: 13, weight: .bold)
    static let robotName = Lang.m("FEEDBACK_ROBOT_NAME", "てらたーむくん")

    static func show() { shared.open() }

    private func open() {
        if let p = panel { p.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); p.makeFirstResponder(textView); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.title = Lang.m("FEEDBACK_TITLE", "要望・お知らせを送る")
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 440, height: 360)
        p.delegate = self
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = FeedbackPanel.bg

        // 上: 見出し (端末のタイトル行のように)
        let title = NSTextField(labelWithString: Lang.m("FEEDBACK_HEADER", "Tera Term Macにお気軽メッセージをどうぞ！"))
        title.font = FeedbackPanel.monoBold
        title.textColor = FeedbackPanel.fg
        let sub = NSTextField(wrappingLabelWithString: Lang.m("FEEDBACK_PRIVACY", "内容は公開されません、開発者だけに届きます。"))
        sub.font = .monoSystemFont(ofSize: 11, weight: .regular)
        sub.textColor = FeedbackPanel.dim
        let header = bar([title, sub], vertical: true)

        // まんなか: やりとりの記録 (端末の画面)
        log.isEditable = false
        log.isSelectable = true
        log.isRichText = true
        log.drawsBackground = true
        log.backgroundColor = FeedbackPanel.bg
        log.textContainerInset = NSSize(width: 10, height: 10)
        log.autoresizingMask = [.width]
        log.isVerticallyResizable = true
        log.textContainer?.widthTracksTextView = true
        logScroll.documentView = log
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = true
        logScroll.backgroundColor = FeedbackPanel.bg
        logScroll.borderType = .noBorder
        logScroll.scrollerStyle = .overlay

        // 下: 種類・版を添える・GitHub と、プロンプト付きの入力欄
        kindPopup.removeAllItems()
        kindPopup.addItems(withTitles: Feedback.kinds.map { Lang.m($0.key, $0.ja) })
        kindPopup.controlSize = .small
        kindPopup.font = .monoSystemFont(ofSize: 11, weight: .regular)
        envCheck.title = Lang.m("FEEDBACK_INCLUDE_ENV", "アプリと macOS の版を添える")
        envCheck.state = .on
        envCheck.controlSize = .small
        envCheck.font = .monoSystemFont(ofSize: 11, weight: .regular)
        envCheck.toolTip = Feedback.environment
        let issues = NSButton(title: Lang.m("FEEDBACK_ISSUES_BUTTON", "GitHub の Issues で送る…"), target: self, action: #selector(openIssues))
        issues.isBordered = false
        issues.font = .monoSystemFont(ofSize: 11, weight: .regular)
        issues.contentTintColor = FeedbackPanel.robot
        issues.toolTip = Lang.m("FEEDBACK_ISSUES_NOTE",
            "返事がほしいときや、やりとりしながら直したいときは「GitHub の Issues で送る」を使ってください (GitHub のアカウントが要ります)。書いた内容はブラウザの Issue の画面に入ります。")
        let opts = NSStackView(views: [kindPopup, envCheck, NSView(), issues])
        opts.spacing = 10

        let prompt = NSTextField(labelWithString: "$")
        prompt.font = FeedbackPanel.monoBold
        prompt.textColor = FeedbackPanel.me
        prompt.setContentHuggingPriority(.required, for: .horizontal)
        textView.isRichText = false
        textView.font = FeedbackPanel.mono
        textView.textColor = FeedbackPanel.fg
        textView.insertionPointColor = FeedbackPanel.me
        textView.drawsBackground = true
        textView.backgroundColor = FeedbackPanel.bg
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.delegate = self
        textView.onSend = { [weak self] in self?.send() }
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.placeholder = Lang.m("FEEDBACK_PLACEHOLDER", "メッセージを入力 (Enter で送信、Shift+Enter で改行)")
        textView.placeholderColor = FeedbackPanel.dim
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        let inputScroll = NSScrollView()
        inputScroll.documentView = textView
        inputScroll.hasVerticalScroller = true
        inputScroll.scrollerStyle = .overlay
        inputScroll.drawsBackground = true
        inputScroll.backgroundColor = FeedbackPanel.bg
        inputScroll.borderType = .noBorder
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        inputScroll.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let inputRow = NSStackView(views: [prompt, inputScroll])
        inputRow.alignment = .top
        inputRow.spacing = 6
        let bottom = bar([opts, inputRow], vertical: true)
        for v in [opts, inputRow] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -24).isActive = true }

        let line1 = separator(), line2 = separator()
        let root = NSStackView(views: [header, line1, logScroll, line2, bottom])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        p.contentView = root
        for v in [header, line1, logScroll, line2, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        sub.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -24).isActive = true
        logScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        logScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        p.center()
        panel = p
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        // 最初のあいさつ: 起動したときのように 1 行出してから、てらたーむくんがタイピングする
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        append([("Tera Term Mac \(ver) feedback\n", FeedbackPanel.dim, FeedbackPanel.mono)])
        addRobot(typing: true, Lang.m("FEEDBACK_ROBOT_HELLO", "やっほー！Tera Term Mac つかってくれてありがとう🙌\n「ここ使いにくい…」「こんなのほしい！」とか、なんでも気軽に送ってね。"))
    }

    private func bar(_ views: [NSView], vertical: Bool) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = vertical ? .vertical : .horizontal
        s.alignment = .leading
        s.spacing = 6
        s.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        s.wantsLayer = true
        s.layer?.backgroundColor = FeedbackPanel.barBG.cgColor
        return s
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.32, alpha: 1).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    func textDidChange(_ notification: Notification) {}

    @objc private func close() { panel?.orderOut(nil) }

    @objc private func openIssues() {
        Feedback.openIssue(message: textView.string)
    }

    @objc private func send() {
        let msg = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, waitRange == nil else { return }
        let k = Feedback.kinds[max(0, kindPopup.indexOfSelectedItem)]
        addMine(msg, tag: Lang.m(k.key, k.ja))
        textView.string = ""
        textView.needsDisplay = true
        showWaiting()
        Feedback.send(kind: k.ja, message: msg, includeEnvironment: envCheck.state == .on) { [weak self] ok in
            guard let self = self else { return }
            self.hideWaiting()
            if ok {
                self.append([(Lang.m("FEEDBACK_SENT_LINE", "送信しました") + "\n", FeedbackPanel.dim, FeedbackPanel.mono)])
                self.addRobot(Lang.m("FEEDBACK_ROBOT_THANKS", "ご意見アリガトウ！改善ニ役立テマス！"))
            } else {
                self.append([(Lang.m("FEEDBACK_SEND_ERROR_LINE", "送信できませんでした") + "\n", FeedbackPanel.err, FeedbackPanel.mono)])
                self.textView.string = msg
                self.textView.needsDisplay = true
                self.addRobot(Lang.m("FEEDBACK_ROBOT_FAILED", "アレレ…送レマセンデシタ。\nネットワークヲ 確カメテ、モウ一度 送ッテネ。"))
                self.appendLink(Lang.m("FEEDBACK_OPEN_BROWSER", "ブラウザで開く"), Feedback.viewFormURL)
            }
        }
    }

    // MARK: - 記録に書く

    private static var timeText: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f.string(from: Date())
    }

    private func append(_ parts: [(String, NSColor, NSFont)]) {
        guard let st = log.textStorage else { return }
        for (t, c, f) in parts { st.append(NSAttributedString(string: t, attributes: [.foregroundColor: c, .font: f])) }
        log.scrollToEndOfDocument(nil)
    }

    private func appendLink(_ title: String, _ url: URL) {
        guard let st = log.textStorage else { return }
        st.append(NSAttributedString(string: "→ ", attributes: [.foregroundColor: FeedbackPanel.dim, .font: FeedbackPanel.mono]))
        st.append(NSAttributedString(string: title, attributes: [.link: url, .font: FeedbackPanel.mono]))
        st.append(NSAttributedString(string: "\n", attributes: [.font: FeedbackPanel.mono]))
        log.scrollToEndOfDocument(nil)
    }

    /// 自分の行: [時刻] $ [種類] 本文
    private func addMine(_ text: String, tag: String?) {
        var parts: [(String, NSColor, NSFont)] = [("$ ", FeedbackPanel.me, FeedbackPanel.monoBold)]
        if let t = tag { parts.append(("[\(t)] ", FeedbackPanel.tag, FeedbackPanel.monoBold)) }
        parts.append((text + "\n", FeedbackPanel.fg, FeedbackPanel.mono))
        append(parts)
    }

    /// てらたーむくんの行: [時刻] てらたーむくん> 本文 (typing なら 1 文字ずつ)
    private func addRobot(typing: Bool = false, _ text: String) {
        append([("\(FeedbackPanel.robotName)> ", FeedbackPanel.robot, FeedbackPanel.monoBold)])
        let body = text + "\n"
        // 「」で囲んだところ (かっこも含む) は色を変える
        var colors: [NSColor] = []
        var inQuote = false
        for ch in body {
            if ch == "「" { inQuote = true }
            colors.append(inQuote ? FeedbackPanel.quote : FeedbackPanel.fg)
            if ch == "」" { inQuote = false }
        }
        let chars = Array(body)
        guard typing else {
            append(chars.indices.map { (String(chars[$0]), colors[$0], FeedbackPanel.mono) })
            return
        }
        var n = 0
        typingTimer?.invalidate()
        showWaiting()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.hideWaiting()
            self?.typingTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] t in
                guard let self = self, n < chars.count else { t.invalidate(); return }
                self.append([(String(chars[n]), colors[n], FeedbackPanel.mono)])
                n += 1
                if n == chars.count { t.invalidate() }
            }
        }
    }

    /// 待っている間の点滅するカーソル (▋)
    private func showWaiting() {
        guard waitRange == nil, let st = log.textStorage else { return }
        let r = NSRange(location: st.length, length: 1)
        st.append(NSAttributedString(string: "▋", attributes: [.foregroundColor: FeedbackPanel.robot, .font: FeedbackPanel.mono]))
        waitRange = r
        log.scrollToEndOfDocument(nil)
        var on = true
        waitTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let r = self.waitRange, let st = self.log.textStorage, NSMaxRange(r) <= st.length else { return }
            on.toggle()
            st.addAttribute(.foregroundColor, value: on ? FeedbackPanel.robot : FeedbackPanel.bg, range: r)
        }
    }

    private func hideWaiting() {
        waitTimer?.invalidate(); waitTimer = nil
        if let r = waitRange, let st = log.textStorage, NSMaxRange(r) <= st.length { st.deleteCharacters(in: r) }
        waitRange = nil
    }

    /// TERAMAC_FEEDBACKSNAP=<png>: 送らずに画面の見た目だけ作って写す
    static func debugSnap(_ path: String) {
        shared.open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
            shared.addMine("接続先の一覧をフォルダで分けられるとうれしいです！", tag: Lang.m("FEEDBACK_KIND_REQUEST", "要望"))
            shared.append([(Lang.m("FEEDBACK_SENT_LINE", "送信しました") + "\n", FeedbackPanel.dim, FeedbackPanel.mono)])
            shared.addRobot(Lang.m("FEEDBACK_ROBOT_THANKS", "ご意見アリガトウ！改善ニ役立テマス！"))
            shared.addMine("あと、もう1つ。", tag: Lang.m("FEEDBACK_KIND_BUG", "不具合"))
            shared.showWaiting()
            shared.textView.string = "書きかけのメッセージ"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let w = shared.panel { SelfTest.snapWindow(w, path) }
                exit(0)
            }
        }
    }
}

/// 入力欄: Enter で送る、Shift / Option + Enter で改行 (変換中の Enter は変換の確定)
final class FeedbackInputTextView: NSTextView {
    var onSend: (() -> Void)?
    /// 空のときに薄く出す文字 (文字を打った瞬間に消えるよう、自分で描く。変換中の文字も入っていれば出さない)
    var placeholder = ""
    var placeholderColor = NSColor.placeholderTextColor
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: placeholderColor]
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

