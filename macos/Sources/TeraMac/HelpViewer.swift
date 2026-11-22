import AppKit
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
// アプリでは Contents/Resources/help/{html/, teraterm.hhp, helpid.h} (scripts/bundle.sh がコピー)。
// 開発中 (swift build) は元のソースの doc/ja と teraterm/common を読む。
enum HelpViewer {
    /// help/ のフォルダ (html/ と teraterm.hhp, helpid.h が入る)
    static var root: String? {
        if let r = Bundle.main.resourcePath {
            let p = (r as NSString).appendingPathComponent("help")
            if FileManager.default.fileExists(atPath: p + "/html/index.html") { return p }
        }
        let p = sourceRoot.appendingPathComponent("doc/ja").path
        return FileManager.default.fileExists(atPath: p + "/html/index.html") ? p : nil
    }
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// HlpXxx → "html/menu/xxx.html#anchor"
    static let aliases: [String: String] = {
        guard let r = root, let d = FileManager.default.contents(atPath: r + "/teraterm.hhp") else { return [:] }
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
    }()

    /// helpid.h の番号 → HlpXxx
    static let ids: [Int: String] = {
        var paths: [String] = []
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

    /// ヘルプの目次 (HlpIndex)
    static func openIndex() { open(topic: "HlpIndex") }

    /// Tera Term のヘルプ ID の名前 (helpid.h の HlpXxx) で開く。知らない名前なら目次
    static func open(topic: String) {
        let rel = aliases[topic] ?? aliases["HlpIndex"] ?? "html/index.html"
        open(relativePath: rel)
    }

    /// helpid.h の番号で開く
    static func open(id: Int) { open(topic: ids[id] ?? "HlpIndex") }

    /// help/ からの相対パス (例: "html/menu/setup-font.html#xxx")
    static func open(relativePath rel: String) {
        guard let r = root else {
            NSWorkspace.shared.open(URL(string: "https://teratermproject.github.io/manual/5/ja/")!)
            return
        }
        let parts = rel.split(separator: "#", maxSplits: 1).map(String.init)
        var url = URL(fileURLWithPath: (r as NSString).appendingPathComponent(parts[0]))
        if parts.count > 1, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.fragment = parts[1]
            url = c.url ?? url
        }
        HelpWindowController.shared.show(url, readAccess: URL(fileURLWithPath: r))
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Tera Term ヘルプ"
        w.setFrameAutosaveName("TeraMacHelpWindow")
        super.init(window: w)
        w.isReleasedWhenClosed = false
        w.delegate = self
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]

        nav.target = self
        nav.action = #selector(navClicked(_:))
        let home = NSButton(title: "目次", target: self, action: #selector(goIndex))
        home.bezelStyle = .rounded
        let bar = NSStackView(views: [nav, home])
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

    func show(_ url: URL, readAccess: URL) {
        web.loadFileURL(url, allowingReadAccessTo: readAccess)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        updateNav()
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
        if let u = action.request.url, !u.isFileURL, u.scheme != "about" {
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
