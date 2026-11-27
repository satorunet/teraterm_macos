import AppKit
import TeraCore

/// 「謝辞とライセンス」のウインドウ。元にしたソフトウェアとライセンスの全文をまとめて見せる
final class CreditsWindowController: NSWindowController {
    static let shared = CreditsWindowController()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.minSize = NSSize(width: 420, height: 300)
        super.init(window: w)
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.textContainerInset = NSSize(width: 18, height: 16)
        }
        w.contentView = scroll
        fill()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 題と本文を今の言語で入れる
    private var builtLanguage = ""
    private func fill() {
        builtLanguage = Lang.current
        window?.title = Lang.m("MENU_CREDITS_TITLE", "謝辞とライセンス - Tera Term Mac")
        let tv = (window?.contentView as? NSScrollView)?.documentView as? NSTextView
        tv?.textStorage?.setAttributedString(CreditsWindowController.text())
    }

    func show() {
        if builtLanguage != Lang.current { fill() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 元にしたソフトウェア (名前, 使っているところ, ライセンス, 著作権)
    static var components: [(String, String, String, String)] { [
        ("Tera Term", Lang.m("MENU_CREDITS_TERATERM_USE", "アイコン・TTL マクロの処理系・ファイル転送 (XMODEM / YMODEM / ZMODEM / Kermit / B-Plus / Quick-VAN)"),
         "BSD 3-Clause License", "Copyright (C) 1994-1998 T. Teranishi\n(C) 2004- TeraTerm Project"),
        (Lang.m("MENU_CREDITS_ONIGURUMA", "鬼車 (Oniguruma) 6.9.10"), Lang.m("MENU_CREDITS_ONIGURUMA_USE", "TTL マクロの正規表現 (waitregex・strmatch・strreplace など)"),
         "BSD 2-Clause License", "Copyright (c) 2002-2021 K.Kosako"),
        ("Sparkle 2.9", Lang.m("MENU_CREDITS_SPARKLE_USE", "自動アップデート (アップデートの確認・ダウンロード・署名の確認・入れ替え)"),
         "MIT License", Lang.m("MENU_CREDITS_SPARKLE_COPYRIGHT", "Copyright (c) 2006-2013 Andy Matuschak ほか Sparkle の開発者")),
    ] }

    private static func text() -> NSAttributedString {
        let s = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let small = NSFont.systemFont(ofSize: 11)
        let secondary = NSColor.secondaryLabelColor
        func add(_ t: String, _ font: NSFont, _ color: NSColor = .labelColor, space: CGFloat = 4) {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = space
            s.append(NSAttributedString(string: t + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        add("Tera Term Mac", NSFont.boldSystemFont(ofSize: 17), space: 2)
        add(Lang.m("MENU_CREDITS_DESCRIPTION", "Tera Term の macOS 版。TeraTerm Project の Tera Term を fork し、独自に Mac へ移植したものです。原作者 T. Teranishi (寺西 高) 氏の公認を受け、TeraTerm Project とは別に開発しています。"), body, secondary)
        // 著作者は Tera Term の作者 (寺西 高 氏)。satorunet は Mac 版の開発者
        add(Lang.m("MENU_CREDITS_AUTHOR", "Tera Term の著作者: T. Teranishi (寺西 高)"), body, secondary, space: 2)
        add(Lang.m("MENU_CREDITS_DEVELOPER", "Tera Term Mac の開発: satorunet (Mac 版で追加したコードは MIT License)"), body, secondary, space: 18)

        add(Lang.m("MENU_CREDITS_BASED_ON", "元にしたソフトウェア"), NSFont.boldSystemFont(ofSize: 14), space: 8)
        for (name, use, license, copyright) in components {
            add(name, NSFont.boldSystemFont(ofSize: 13), space: 2)
            add(use, body, space: 2)
            // 同じ段落の中の改行にする (段落の間隔を空けない)
            add("\(license)\u{2028}\(copyright.replacingOccurrences(of: "\n", with: "\u{2028}"))", small, secondary, space: 14)
        }

        add(Lang.m("MENU_CREDITS_LICENSE_TEXT", "ライセンス全文"), NSFont.boldSystemFont(ofSize: 14), space: 8)
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
           let t = try? String(contentsOf: url, encoding: .utf8) {
            add(t, mono, secondary)
        } else {
            add(Lang.m("MENU_CREDITS_NO_LICENSE", "(LICENSE.txt が見つかりません)"), small, secondary)
        }
        return s
    }
}

/// 「Tera Term Mac について」の窓 (標準の About パネルではリンクから窓を開けないので自前で作る)
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = ""
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 中身を今の言語で作る (言語を変えたら、次に開くとき作り直す)
    private var builtLanguage = ""
    private func build() {
        guard let w = window else { return }
        builtLanguage = Lang.current
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        func label(_ t: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = font
            l.textColor = color
            l.alignment = .center
            return l
        }
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? ""
        let small = NSFont.systemFont(ofSize: 11)

        let homepage = AboutWindowController.link(Lang.m("MENU_ABOUT_HOMEPAGE", "ホームページ"), #selector(openHomepage(_:)), self)
        let credits = AboutWindowController.link(Lang.m("MENU_ABOUT_CREDITS", "謝辞とライセンス"), #selector(openCredits(_:)), self)
        let changes = AboutWindowController.link(Lang.m("MENU_ABOUT_CHANGES", "更新情報"), #selector(openChanges(_:)), self)
        let links = NSStackView(views: [homepage, label("・", small, .tertiaryLabelColor), changes,
                                        label("・", small, .tertiaryLabelColor), credits])
        links.spacing = 4

        let stack = NSStackView(views: [
            icon,
            label("Tera Term Mac", NSFont.boldSystemFont(ofSize: 16)),
            label(Lang.m("MENU_ABOUT_VERSION", "バージョン %s", version) + (build.isEmpty || build == version ? "" : " (\(build))"), small),
            label(Lang.m("MENU_ABOUT_SUBTITLE", "Tera Term の macOS 版 (原作者公認)"), small),
            label(Lang.m("MENU_ABOUT_FEATURES", "シリアル・SSH・Telnet・マクロ"), small, .secondaryLabelColor),
            links,
            label(Lang.m("MENU_ABOUT_AUTHOR", "Tera Term の著作者: T. Teranishi (寺西 高)"), small, .secondaryLabelColor),
            label(Lang.m("MENU_ABOUT_DEVELOPER", "開発: satorunet"), small, .secondaryLabelColor),
            // TeraTerm Project とは別に開発していることと、問い合わせ先 (TeraTerm Project にお願いしたこと)
            { () -> NSTextField in
                let l = NSTextField(wrappingLabelWithString: Lang.m("MENU_ABOUT_INDEPENDENT", "TeraTerm Project の Tera Term を fork し、独自に Mac へ移植したものです。TeraTerm Project とは別に開発しています。"))
                l.font = small
                l.textColor = .secondaryLabelColor
                l.alignment = .center
                l.preferredMaxLayoutWidth = 320
                return l
            }(),
            AboutWindowController.link(Lang.m("MENU_ABOUT_CONTACT", "Mac 版のお問い合わせ (GitHub Issues)"), #selector(openIssues(_:)), self),
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(14, after: stack.views[4])
        stack.setCustomSpacing(14, after: links)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 30, bottom: 20, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        w.center()
    }

    /// リンクのように見えるボタン
    static func link(_ title: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 11),
        ])
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    func show() {
        if builtLanguage != Lang.current { build() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHomepage(_ sender: Any?) { NSWorkspace.shared.open(AppDelegate.homepage) }
    @objc private func openCredits(_ sender: Any?) { CreditsWindowController.shared.show() }
    /// GitHub のリリースの一覧 (各版の更新情報)
    /// Mac 版のお問い合わせは Tera Term Mac の Issues へ (TeraTerm Project には送らない)
    static let issuesURL = URL(string: "https://github.com/teraterm-mac/teraterm-mac/issues")!
    @objc private func openIssues(_ sender: Any?) { NSWorkspace.shared.open(Self.issuesURL) }
    @objc private func openChanges(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/teraterm-mac/teraterm-mac/releases")!)
    }
}

