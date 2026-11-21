import AppKit

/// 「謝辞とライセンス」のウインドウ。元にしたソフトウェアとライセンスの全文をまとめて見せる
final class CreditsWindowController: NSWindowController {
    static let shared = CreditsWindowController()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "謝辞とライセンス - Tera Term Mac"
        w.minSize = NSSize(width: 420, height: 300)
        super.init(window: w)
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.textContainerInset = NSSize(width: 18, height: 16)
            tv.textStorage?.setAttributedString(CreditsWindowController.text())
        }
        w.contentView = scroll
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 元にしたソフトウェア (名前, 使っているところ, ライセンス, 著作権)
    static let components: [(String, String, String, String)] = [
        ("Tera Term", "アイコン・TTL マクロの処理系・ファイル転送 (XMODEM / YMODEM / ZMODEM / Kermit / B-Plus / Quick-VAN)",
         "BSD 3-Clause License", "Copyright (C) 1994-1998 T. Teranishi\n(C) 2004- TeraTerm Project"),
        ("鬼車 (Oniguruma) 6.9.10", "TTL マクロの正規表現 (waitregex・strmatch・strreplace など)",
         "BSD 2-Clause License", "Copyright (c) 2002-2021 K.Kosako"),
    ]

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
        add("Tera Term の macOS 版 (非公式)。TeraTerm Project とは関係のない個人の移植です。", body, secondary)
        add("Copyright (c) 2026 satorunet — MIT License", body, secondary, space: 18)

        add("元にしたソフトウェア", NSFont.boldSystemFont(ofSize: 14), space: 8)
        for (name, use, license, copyright) in components {
            add(name, NSFont.boldSystemFont(ofSize: 13), space: 2)
            add(use, body, space: 2)
            // 同じ段落の中の改行にする (段落の間隔を空けない)
            add("\(license)\u{2028}\(copyright.replacingOccurrences(of: "\n", with: "\u{2028}"))", small, secondary, space: 14)
        }

        add("ライセンス全文", NSFont.boldSystemFont(ofSize: 14), space: 8)
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
           let t = try? String(contentsOf: url, encoding: .utf8) {
            add(t, mono, secondary)
        } else {
            add("(LICENSE.txt が見つかりません)", small, secondary)
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

        let homepage = AboutWindowController.link("ホームページ (GitHub)", #selector(openHomepage(_:)), self)
        let credits = AboutWindowController.link("謝辞とライセンス", #selector(openCredits(_:)), self)
        let links = NSStackView(views: [homepage, label("・", small, .tertiaryLabelColor), credits])
        links.spacing = 4

        let stack = NSStackView(views: [
            icon,
            label("Tera Term Mac", NSFont.boldSystemFont(ofSize: 16)),
            label("バージョン \(version)" + (build.isEmpty ? "" : " (\(build))"), small),
            label("Tera Term の macOS 版 (非公式)", small),
            label("シリアル・SSH・Telnet・マクロ", small, .secondaryLabelColor),
            links,
            label("© 2026 satorunet · MIT License", small, .secondaryLabelColor),
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

    required init?(coder: NSCoder) { fatalError() }

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
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHomepage(_ sender: Any?) { NSWorkspace.shared.open(AppDelegate.homepage) }
    @objc private func openCredits(_ sender: Any?) { CreditsWindowController.shared.show() }
}
