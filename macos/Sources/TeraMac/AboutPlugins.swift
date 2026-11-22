import AppKit

/// ヘルプの「TTProxyについて...」「TTSSHについて...」(TTProxy / TTSSH が Tera Termについて の前に入れる項目)。
/// Mac 版はどちらも同じ働きをアプリに組み込んでいる (SSH は macOS の OpenSSH を使う) ので、その旨と元の著作権を出す
enum AboutPlugins {
    private static func panel(title: String, icon: NSImage?, body: [NSView], width: CGFloat = 460) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = title
        p.isReleasedWhenClosed = false
        let ok = NSButton(title: "OK", target: nil, action: nil)
        ok.keyEquivalent = "\r"
        let closer = Closer(panel: p)
        ok.target = closer
        ok.action = #selector(Closer.close)
        var views = body
        if let i = icon {
            let iv = NSImageView(image: i)
            iv.widthAnchor.constraint(equalToConstant: 48).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 48).isActive = true
            views.insert(iv, at: 0)
        }
        let okRow = NSStackView(views: [NSView(), ok])
        views.append(okRow)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        okRow.translatesAutoresizingMaskIntoConstraints = false
        okRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        p.contentView = stack
        p.setContentSize(stack.fittingSize)
        p.center()
        objc_setAssociatedObject(p, &closerKey, closer, .OBJC_ASSOCIATION_RETAIN)
        NSApp.runModal(for: p)
        p.orderOut(nil)
    }
    private static var closerKey = 0

    private final class Closer: NSObject {
        weak var panel: NSPanel?
        init(panel: NSPanel) { self.panel = panel }
        @objc func close() { NSApp.stopModal() }
    }

    private static func label(_ s: String, bold: Bool = false, small: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: small ? 11 : 12)
        l.isSelectable = true
        l.preferredMaxLayoutWidth = 420
        return l
    }

    static func showTTProxy() {
        panel(title: "TTProxyについて", icon: NSApp.applicationIconImage, body: [
            label("TTProxy", bold: true),
            label("Copyright (C) 2003-2006 蛭子屋本舗\n蛭子屋本舗: http://yebisuya.dip.jp/Software/TTProxy/\n(C) 2006-2026 TeraTerm Project\nTeraTerm Project: https://teratermproject.github.io/"),
            label("Mac 版では、TTProxy と同じプロキシ接続 (HTTP / SOCKS4 / SOCKS4a / SOCKS5 / TELNET) をアプリに組み込んで使っています。", small: true),
        ])
    }

    /// TTSSH の「について」: 版と含まれるもの。接続中の SSH ならサーバーとホスト鍵の指紋 (MD5 / SHA256) も出す
    static func showTTSSH(session: SessionWindowController?) {
        let ssh = run("/usr/bin/ssh", ["-V"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let info = NSTextView()
        info.isEditable = false
        info.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = info
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        info.frame = NSRect(x: 0, y: 0, width: 420, height: 140)
        info.autoresizingMask = [.width]

        let md5 = NSButton(radioButtonWithTitle: "MD5", target: nil, action: nil)
        let sha = NSButton(radioButtonWithTitle: "SHA256", target: nil, action: nil)
        sha.state = .on
        func fill() {
            info.string = connectionText(session, hash: md5.state == .on ? "md5" : "sha256")
        }
        let toggler = Toggle(fill)
        for r in [md5, sha] { r.target = toggler; r.action = #selector(Toggle.fire) }
        fill()
        let hashRow = NSStackView(views: [NSTextField(labelWithString: "指紋のハッシュ:"), md5, sha])
        objc_setAssociatedObject(md5, &closerKey, toggler, .OBJC_ASSOCIATION_RETAIN)
        panel(title: "TTSSHについて", icon: NSApp.applicationIconImage, body: [
            label("TTSSH\nTera Term Secure Shell extension", bold: true),
            label("(C) 2004-2026 TeraTerm Project"),
            label("Includes:\nTTSSH 1.5.4, (C) 1998-2001 Robert O'Callahan\nIPv6 extention version 0.81, (C) 2000-2003 Jun-ya KATO", small: true),
            label("Mac 版では、SSH の接続に macOS の OpenSSH (ssh コマンド) を使っています。\nOpenSSH: \(ssh)", small: true),
            label("TeraTerm Project: https://teratermproject.github.io/", small: true),
            hashRow,
            scroll,
        ])
    }

    private final class Toggle: NSObject {
        let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        @objc func fire() { f() }
    }

    private static func connectionText(_ s: SessionWindowController?, hash: String) -> String {
        guard let s = s, s.isConnected, case .ssh(let host, let port, let user, _)? = s.spec else {
            return "SSH で接続していません。"
        }
        var out = "サーバー: \(host)\nポート: \(port)\n"
        if !user.isEmpty { out += "ユーザー: \(user)\n" }
        let name = port == 22 ? host : "[\(host)]:\(port)"
        let known = run("/usr/bin/ssh-keygen", ["-F", name, "-l", "-E", hash])
        let lines = known.split(separator: "\n").filter { !$0.hasPrefix("#") }
        if lines.isEmpty {
            out += "\nホスト鍵の指紋: (known_hosts にありません)"
        } else {
            out += "\nホスト鍵の指紋:\n" + lines.joined(separator: "\n")
        }
        return out
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

extension AppDelegate {
    @objc func showAboutTTProxy(_ sender: Any?) { AboutPlugins.showTTProxy() }
    @objc func showAboutTTSSH(_ sender: Any?) {
        let s = (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController) as? SessionWindowController
        AboutPlugins.showTTSSH(session: s)
    }
}
