import AppKit
import TeraCore
import WebKit

// Tera Term のヘルプ (doc/ja/html。Tera Term と同じ BSD ライセンス: html/about/copyright.html) をアプリの中で見る。
//
//   HelpViewer.openIndex()                              // ヘルプ > 目次
//   HelpViewer.open(topic: "HlpMenuSetupAdditionalTheme")  // ダイアログの「ヘルプ」ボタン
//   HelpViewer.open(id: 43024)                           // helpid.h の番号でも可
//
// 名前 → ファイルの対応は Tera Term の CHM と同じものを使う:
//   doc/ja/teraterm.hhp の [ALIAS] (HlpXxx=html\menu\xxx.html) と
//   teraterm/common/helpid.h (#define HlpXxx 番号。hhp の [MAP] が読み込むもの)。
// アプリでは Contents/Resources/help/{ja,en}/{html/, teraterm.hhp} と help/helpid.h (scripts/bundle.sh がコピー)。
// 開発中 (swift build) は元のソースの doc/ja・doc/en と teraterm/common を読む。
// 日本語で表示しているときは ja、ほかの言語では en を使う
enum HelpViewer {
    /// 使うヘルプの言語 ("ja" / "en")
    static var language: String { Lang.isJapanese ? "ja" : "en" }

    /// どちらのマニュアルを見るか。
    /// Mac 版マニュアル (Resources/help-mac: Tera Term Mac だけの説明を章立てでまとめたもの) と、
    /// 従来のマニュアル (本家 Tera Term のヘルプそのまま。Windows 版の説明。参考用) を完全に分けて持つ
    enum Edition: String { case mac, upstream }
    static var edition: Edition {
        get { Edition(rawValue: UserDefaults.standard.string(forKey: "HelpEdition") ?? "") ?? .mac }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "HelpEdition") }
    }

    /// その言語のヘルプのフォルダ (アプリの中 → 開発中のソース)。無ければ nil
    /// アプリ: Mac 版は help/<言語>、従来のマニュアルは help/upstream/<言語>。開発中: macos/Resources/help-mac と doc/
    static func root(for l: String, edition e: Edition = edition) -> String? {
        let fm = FileManager.default
        var cands: [String] = []
        if let r = Bundle.main.resourcePath {
            cands.append((r as NSString).appendingPathComponent(e == .mac ? "help/" + l : "help/upstream/" + l))
        }
        cands.append(sourceRoot.appendingPathComponent(e == .mac ? "macos/Resources/help-mac/" + l : "doc/" + l).path)
        return cands.first { fm.fileExists(atPath: $0 + "/html/index.html") }
    }

    /// ヘルプのフォルダ (html/ と teraterm.hhp が入る)。今の言語のものが無ければもう一方
    static var root: String? {
        let langs = language == "ja" ? ["ja", "en"] : ["en", "ja"]
        for l in langs { if let p = root(for: l) { return p } }
        // 前の版の並び (help/html)
        if let r = Bundle.main.resourcePath {
            let p = (r as NSString).appendingPathComponent("help")
            if FileManager.default.fileExists(atPath: p + "/html/index.html") { return p }
        }
        return nil
    }
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// HlpXxx → "html/menu/xxx.html#anchor" (ヘルプのフォルダごとに覚えておく)
    private static var aliasCache: [String: [String: String]] = [:]
    static var aliases: [String: String] {
        guard let r = root else { return [:] }
        if let c = aliasCache[r] { return c }
        let a = readAliases(r)
        aliasCache[r] = a
        return a
    }
    private static func readAliases(_ r: String) -> [String: String] {
        guard let d = FileManager.default.contents(atPath: r + "/teraterm.hhp") else { return [:] }
        // hhp は Shift_JIS。[ALIAS] の行は ASCII
        let text = String(data: d, encoding: .shiftJIS) ?? String(decoding: d, as: UTF8.self)
        var out: [String: String] = [:]
        var inAlias = false
        for raw in text.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { inAlias = l.lowercased() == "[alias]"; continue }
            guard inAlias, let eq = l.firstIndex(of: "=") else { continue }
            out[String(l[..<eq]).trimmingCharacters(in: .whitespaces)] =
                l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        }
        return out
    }

    /// helpid.h の番号 → HlpXxx (help/helpid.h。前の版は help/ の中のヘルプと同じ所)
    static let ids: [Int: String] = {
        var paths: [String] = []
        if let r = Bundle.main.resourcePath { paths.append((r as NSString).appendingPathComponent("help/helpid.h")) }
        if let r = root { paths.append(r + "/helpid.h") }
        paths.append(sourceRoot.appendingPathComponent("teraterm/common/helpid.h").path)
        guard let d = paths.lazy.compactMap({ FileManager.default.contents(atPath: $0) }).first else { return [:] }
        var out: [Int: String] = [:]
        for l in String(decoding: d, as: UTF8.self).components(separatedBy: .newlines) {
            let f = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 3, f[0] == "#define", let n = Int(f[2]) else { continue }
            if out[n] == nil { out[n] = String(f[1]) }
        }
        return out
    }()

    /// ヘルプの目次。Mac 版マニュアルは章立てのトップページ、従来のマニュアルは本家の目次
    static func openIndex() {
        if edition == .mac, let r = root { return open(relativePath: HelpModernStyle.homePage(helpRoot: r)) }
        open(topic: "HlpIndex")
    }

    /// Tera Term のヘルプ ID の名前 (helpid.h の HlpXxx) で開く。知らない名前なら目次
    static func open(topic: String) {
        let rel = aliases[topic] ?? aliases["HlpIndex"] ?? "html/index.html"
        open(relativePath: rel)
    }

    /// file URL (#anchor 付き)
    static func fileURL(_ dir: String, _ rel: String) -> URL {
        let parts = rel.split(separator: "#", maxSplits: 1).map(String.init)
        var url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(parts.first ?? "index.html"))
        if parts.count > 1, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.fragment = parts[1]
            url = c.url ?? url
        }
        return url
    }
    /// 読んでよい範囲: そのヘルプのフォルダ
    static func readRoot(for dir: String) -> URL {
        if let r = Bundle.main.resourcePath {
            let h = (r as NSString).appendingPathComponent("help")
            if dir.hasPrefix(h + "/") { return URL(fileURLWithPath: h, isDirectory: true) }
        }
        return URL(fileURLWithPath: sourceRoot.path, isDirectory: true)
    }

    /// helpid.h の番号で開く
    static func open(id: Int) { open(topic: ids[id] ?? "HlpIndex") }

    /// help/ からの相対パス (例: "html/menu/setup-font.html#xxx")
    static func open(relativePath rel: String) {
        guard let r = root else {
            NSWorkspace.shared.open(URL(string: "https://teratermproject.github.io/manual/5/\(language)/")!)
            return
        }
        HelpWindowController.shared.show(fileURL(r, rel), readAccess: readRoot(for: r))
    }
}

/// ヘルプのウインドウ (ひとつだけ。戻る / 進む / 目次)
final class HelpWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    static let shared = HelpWindowController()
    private let web: WKWebView
    private let nav = NSSegmentedControl(images: [NSImage(named: NSImage.goBackTemplateName)!, NSImage(named: NSImage.goForwardTemplateName)!],
                                         trackingMode: .momentary, target: nil, action: nil)

    private init() {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: cfg)
        // 読み込みの合間に白い背景が見えないように、ビューの背景は描かない (ウインドウの背景色が見える。ダークモードでも暗いまま)
        web.setValue(false, forKey: "drawsBackground")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = Lang.m("MENU_HELP_WINDOW_TITLE", "Tera Term ヘルプ")
        w.setFrameAutosaveName("TeraMacHelpWindow")
        super.init(window: w)
        w.isReleasedWhenClosed = false
        w.delegate = self
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]

        nav.target = self
        nav.action = #selector(navClicked(_:))
        let home = NSButton(title: Lang.t("Tera Term", "MENU_HELP_INDEX", "目次"), target: self, action: #selector(goIndex))
        home.bezelStyle = .rounded
        // 見た目: クラシック (今までどおり) / モダン
        styleSwitch.segmentCount = 2
        styleSwitch.trackingMode = .selectOne
        styleSwitch.target = self
        styleSwitch.action = #selector(styleChanged(_:))
        let bar = NSStackView(views: [nav, home, NSView(), styleSwitch])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let content = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        content.addSubview(web)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var home: NSButton? { (window?.contentView?.subviews.first as? NSStackView)?.views.dropFirst().first as? NSButton }
    private let styleSwitch = NSSegmentedControl()
    /// Mac 版マニュアル / 従来のマニュアル (Windows 版)
    private func updateStyleSwitch() {
        styleSwitch.setLabel(Lang.m("HELP_EDITION_MAC", "Mac 版マニュアル"), forSegment: 0)
        styleSwitch.setLabel(Lang.m("HELP_EDITION_UPSTREAM", "従来のマニュアル (Windows 版)"), forSegment: 1)
        styleSwitch.selectedSegment = HelpViewer.edition == .mac ? 0 : 1
    }
    @objc private func styleChanged(_ s: NSSegmentedControl) {
        HelpViewer.edition = s.selectedSegment == 0 ? .mac : .upstream
        scriptsKey = nil
        HelpViewer.openIndex()   // 中身が別のマニュアルなので、そのマニュアルの目次を開く
    }

    func show(_ url: URL, readAccess: URL) {
        // 言語を変えたあとでも「目次」ボタンを今の言語に
        home?.title = Lang.t("Tera Term", "MENU_HELP_INDEX", "目次")
        updateStyleSwitch()
        if let r = HelpViewer.root { installScripts(upstreamRoot: URL(fileURLWithPath: r, isDirectory: true)) }
        web.loadFileURL(url, allowingReadAccessTo: readAccess)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        updateNav()
    }

    /// ヘルプの画像はアプリに入れていない (アプリを小さくするため)。画像が手元に無いときは、
    /// 本家が公開している同じヘルプ (teratermproject.github.io/manual/5/<言語>/) の同じパスから読む。
    /// ネットにつながっていないときは画像だけが出ない (代わりの文字 alt が出る)
    private var scriptsKey: String?
    private func installScripts(upstreamRoot helpRoot: URL) {
        let htmlRoot = helpRoot.appendingPathComponent("html", isDirectory: true).absoluteString
        let key = htmlRoot + "#" + HelpViewer.edition.rawValue + Lang.current
        guard key != scriptsKey else { return }
        scriptsKey = key
        let lang = helpRoot.lastPathComponent == "en" || helpRoot.path.hasSuffix("/doc/en") ? "en" : "ja"
        let web = "https://teratermproject.github.io/manual/5/\(lang)/"
        let js = """
        (function () {
          var root = \(Self.jsString(htmlRoot)), web = \(Self.jsString(web));
          function fix(img) {
            var s = img.getAttribute('src') ? img.src : '';
            if (s.indexOf(root) !== 0) return;
            img.addEventListener('error', function once() {
              img.removeEventListener('error', once);
              img.src = web + s.substring(root.length);
            });
            if (img.complete && img.naturalWidth === 0) img.src = web + s.substring(root.length);
          }
          Array.prototype.forEach.call(document.images, fix);
        })();
        """
        let ucc = self.web.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if HelpViewer.edition == .mac {
            let toc = HelpModernStyle.toc(helpRoot: helpRoot.path)
            let modern = HelpModernStyle.js(
                tocJSON: HelpModernStyle.jsonString(toc),
                indexURL: HelpModernStyle.jsString(helpRoot.appendingPathComponent(HelpModernStyle.homePage(helpRoot: helpRoot.path)).absoluteString),
                homeTitle: HelpModernStyle.jsString(Lang.m("HELP_EDITION_MAC", "Mac 版マニュアル")),
                searchPlaceholder: HelpModernStyle.jsString(Lang.m("HELP_SEARCH", "目次を検索")),
                prev: HelpModernStyle.jsString("← " + Lang.m("HELP_PREV", "前へ")),
                next: HelpModernStyle.jsString(Lang.m("HELP_NEXT", "次へ") + " →"))
            ucc.addUserScript(WKUserScript(source: HelpModernStyle.earlyJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            ucc.addUserScript(WKUserScript(source: modern, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }
    private static func jsString(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        return d.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    @objc private func navClicked(_ s: NSSegmentedControl) {
        if s.selectedSegment == 0 { web.goBack() } else { web.goForward() }
    }
    @objc private func goIndex() { HelpViewer.openIndex() }

    private func updateNav() {
        nav.setEnabled(web.canGoBack, forSegment: 0)
        nav.setEnabled(web.canGoForward, forSegment: 1)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let t = webView.title, !t.isEmpty { window?.title = t }
        updateNav()
    }

    /// ヘルプの外 (http など) は既定のブラウザで開く
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // ヘルプの中の「要望・お知らせを送る」ボタン
        if let u = action.request.url, u.scheme == "tthelp-feedback" {
            decisionHandler(.cancel)
            FeedbackPanel.show()
            return
        }
        if let u = action.request.url, !u.isFileURL, u.scheme != "about" {
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
