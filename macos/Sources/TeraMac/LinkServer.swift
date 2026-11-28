import AppKit
import Network
import CoreImage
import TeraCore

/// iPhone / iPad (Tera Term SP) との連携: 近くの iPhone から接続先・開いている接続・マクロを取り込めるようにする。
/// 「iPhone / iPad と連携…」の画面で入にしたときだけ待つ (既定は切)
final class LinkServer {
    static let shared = LinkServer()
    private var listener: NWListener?
    private var channels: [TeraLink.Channel] = []
    /// 画面に出す出来事 (最後に何があったか)
    var onEvent: ((String) -> Void)?

    private let d = UserDefaults.standard
    var isEnabled: Bool {
        get { d.bool(forKey: "TeraLinkEnabled") }
        set { d.set(newValue, forKey: "TeraLinkEnabled"); newValue ? start() : stop() }
    }
    /// ペアリングのコード (QR コードに入れる。新しくすると、前のコードの iPhone はつながらなくなる)
    var code: String {
        if let c = d.string(forKey: "TeraLinkCode"), c.count == 6 { return c }
        let c = TeraLink.newCode()
        d.set(c, forKey: "TeraLinkCode")
        return c
    }
    func renewCode() {
        d.set(TeraLink.newCode(), forKey: "TeraLinkCode")
        if isEnabled { stop(); start() }
    }
    /// iPhone に渡してよいマクロのフォルダ (空なら、接続先に決めてあるマクロだけ)
    var macroFolder: String {
        get { d.string(forKey: "TeraLinkMacroFolder") ?? "" }
        set { d.set(newValue, forKey: "TeraLinkMacroFolder") }
    }
    var macName: String { Host.current().localizedName ?? "Mac" }

    /// 起動時: 入にしてあれば待ち始める
    func startIfEnabled() { if isEnabled { start() } }

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: TeraLink.parameters(code: code))
            l.service = NWListener.Service(name: macName, type: TeraLink.serviceType)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] s in
                if case .failed(let e) = s { self?.onEvent?("待てませんでした: \(e)"); self?.stop() }
            }
            l.start(queue: .main)
            listener = l
            onEvent?("待っています")
        } catch {
            onEvent?("待てませんでした: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        channels.forEach { $0.cancel() }; channels = []
        onEvent?("止めました")
    }

    private func accept(_ c: NWConnection) {
        let ch = TeraLink.Channel(c)
        ch.onState = { [weak self, weak ch] s in
            switch s {
            case .ready: self?.onEvent?("iPhone / iPad がつながりました")
            case .failed, .cancelled: self?.channels.removeAll { $0 === ch }
            default: break
            }
        }
        ch.onMessage = { [weak self, weak ch] data in
            guard let self = self, let ch = ch, let req = try? JSONDecoder().decode(TeraLink.Request.self, from: data) else { return }
            ch.send(self.answer(req))
        }
        channels.append(ch)
        ch.start()
    }

    // MARK: 答え

    private func answer(_ r: TeraLink.Request) -> TeraLink.Response {
        var out = TeraLink.Response(cmd: r.cmd)
        out.macName = macName
        switch r.cmd {
        case "hosts":
            out.hosts = MenuStore.shared.entries.compactMap { e in
                guard let h = Self.linkHost(e.spec(withUser: true), name: e.name) else { return nil }
                var x = h
                x.macro = e.macroFile.isEmpty ? "" : (e.macroFile as NSString).lastPathComponent
                return x
            }
            onEvent?("接続先 \(out.hosts?.count ?? 0) 件を渡しました")
        case "sessions":
            out.sessions = SessionWindowController.all.filter { $0.isConnected }.compactMap { Self.linkHost($0.spec, name: $0.window?.title ?? "") }
        case "macros":
            out.macros = allowedMacros().keys.sorted()
        case "file":
            if let n = r.name, let path = allowedMacros()[n], let data = FileManager.default.contents(atPath: path) {
                out.name = n
                out.file = data
                onEvent?("マクロ \(n) を渡しました")
            } else {
                out.error = "そのファイルは渡せません"
            }
        default:
            break
        }
        return out
    }

    /// 渡してよいマクロ (名前 → パス): 接続先のマクロと、決めたフォルダの .ttl
    private func allowedMacros() -> [String: String] {
        var m: [String: String] = [:]
        for e in MenuStore.shared.entries where !e.macroFile.isEmpty {
            let p = (e.macroFile as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: p) { m[(p as NSString).lastPathComponent] = p }
        }
        let dir = (macroFolder as NSString).expandingTildeInPath
        if !dir.isEmpty, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for n in names where n.lowercased().hasSuffix(".ttl") { m[n] = dir + "/" + n }
        }
        return m
    }

    static func linkHost(_ spec: ConnectionSpec?, name: String) -> TeraLink.Host? {
        switch spec {
        case .ssh(let h, let p, let u, _): return TeraLink.Host(name: name, host: h, port: p, proto: "ssh", user: u)
        case .telnet(let h, let p): return TeraLink.Host(name: name, host: h, port: p, proto: "telnet", user: "")
        default: return nil
        }
    }

    /// QR コードの絵
    func qrImage(size: CGFloat) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(TeraLink.pairURL(macName: macName, code: code).utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage else { return nil }
        let k = size / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// 「iPhone / iPad と連携…」の画面
final class LinkWindowController: NSWindowController {
    static let shared = LinkWindowController()
    private let toggle = NSButton(checkboxWithTitle: "iPhone / iPad (Tera Term SP) からの連携を受け付ける", target: nil, action: nil)
    private let qr = NSImageView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "iPhone / iPad と連携"
        super.init(window: w)
        w.isReleasedWhenClosed = false
        let s = LinkServer.shared
        toggle.target = self; toggle.action = #selector(toggled)
        toggle.state = s.isEnabled ? .on : .off
        let info = NSTextField(wrappingLabelWithString: "iPhone / iPad の Tera Term SP で「Mac と連携」を開き、iPhone のカメラでこの QR コードを読むか、下のコードを入れてください。同じ Wi-Fi でなくても、近くにあればつながります (インターネットや iCloud は使いません)。接続先・開いている接続・マクロを iPhone に取り込めます。パスワードは渡しません。")
        info.preferredMaxLayoutWidth = 410
        info.textColor = .secondaryLabelColor
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.widthAnchor.constraint(equalToConstant: 200).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 200).isActive = true
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        let renew = NSButton(title: "新しいコードにする", target: self, action: #selector(renewCode))
        let folderButton = NSButton(title: "渡すマクロのフォルダ…", target: self, action: #selector(chooseFolder))
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [toggle, info, qr, codeLabel, renew, NSStackView(views: [folderButton, folderLabel]), status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        w.contentView = stack
        s.onEvent = { [weak self] m in self?.status.stringValue = m }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        let s = LinkServer.shared
        let on = s.isEnabled
        qr.image = on ? s.qrImage(size: 400) : nil
        qr.alphaValue = on ? 1 : 0.2
        codeLabel.stringValue = on ? s.code.prefix(3) + " " + s.code.suffix(3) : "--- ---"
        folderLabel.stringValue = s.macroFolder.isEmpty ? "(接続先に決めてあるマクロだけ)" : (s.macroFolder as NSString).abbreviatingWithTildeInPath
    }

    @objc private func toggled() {
        LinkServer.shared.isEnabled = toggle.state == .on
        refresh()
    }
    @objc private func renewCode() {
        LinkServer.shared.renewCode()
        refresh()
    }
    @objc private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "選択"
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let u = p.url else { return }
            LinkServer.shared.macroFolder = u.path
            self?.refresh()
        }
    }
}
