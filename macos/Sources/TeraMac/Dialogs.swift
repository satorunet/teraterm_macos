import AppKit
import TeraCore

private func label(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.alignment = .right
    return l
}

private func popup(_ items: [String], _ selected: String) -> NSPopUpButton {
    let p = NSPopUpButton(frame: .zero, pullsDown: false)
    p.addItems(withTitles: items)
    if items.contains(selected) { p.selectItem(withTitle: selected) }
    return p
}

private func field(_ s: String, width: CGFloat = 220) -> NSTextField {
    let f = NSTextField(string: s)
    f.translatesAutoresizingMaskIntoConstraints = false
    f.widthAnchor.constraint(equalToConstant: width).isActive = true
    return f
}

/// シートの土台
class SheetDialog: NSObject {
    let panel: NSPanel
    private var parentWindow: NSWindow?
    let okButton = NSButton(title: "OK", target: nil, action: nil)
    let cancelButton = NSButton(title: "キャンセル", target: nil, action: nil)

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        okButton.keyEquivalent = "\r"
        okButton.target = self; okButton.action = #selector(ok)
        cancelButton.keyEquivalent = "\u{1B}"
        cancelButton.target = self; cancelButton.action = #selector(cancel)
    }

    func layout(_ body: NSView) {
        let buttons = NSStackView(views: [NSView(), cancelButton, okButton])
        buttons.orientation = .horizontal
        let root = NSStackView(views: [body, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
        ])
        panel.contentView = container
        panel.setContentSize(container.fittingSize)
    }

    func present(on w: NSWindow) {
        parentWindow = w
        w.beginSheet(panel, completionHandler: nil)
        retainSelf = self
    }
    private var retainSelf: SheetDialog?

    func close() {
        parentWindow?.endSheet(panel)
        retainSelf = nil
    }

    @objc func ok() {}
    @objc func cancel() {}
}

// MARK: - 新しい接続

final class ConnectDialog: SheetDialog, NSComboBoxDelegate {
    var serialOnly = false
    private var completion: ((ConnectionSpec?, String?) -> Void)?

    private let tcpRadio = NSButton(radioButtonWithTitle: "TCP/IP", target: nil, action: nil)
    private let serialRadio = NSButton(radioButtonWithTitle: "シリアル", target: nil, action: nil)
    private let shellRadio = NSButton(radioButtonWithTitle: "ローカルシェル (このMacのターミナル)", target: nil, action: nil)

    private let hostBox = NSComboBox()
    private let sshRadio = NSButton(radioButtonWithTitle: "SSH", target: nil, action: nil)
    private let telnetRadio = NSButton(radioButtonWithTitle: "Telnet", target: nil, action: nil)
    private let otherRadio = NSButton(radioButtonWithTitle: "その他 (生TCP)", target: nil, action: nil)
    private let portField = field("22", width: 70)
    private let userField = field(ConnHistory.lastUser, width: 160)
    private let passField: NSSecureTextField = {
        let f = NSSecureTextField(string: "")
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: 160).isActive = true
        f.placeholderString = "空なら端末で入力"
        return f
    }()
    private let keyField = field(ConnHistory.lastKeyFile, width: 220)

    private let portPopup = NSPopUpButton()
    private let baudPopup = popup(SerialPort.baudRates.map(String.init), "9600")
    private let dataPopup = popup(["8", "7"], "8")
    private let parityPopup = popup(["none", "odd", "even"], "none")
    private let stopPopup = popup(["1", "2"], "1")
    private let flowPopup = popup(["none", "xon/xoff", "rts/cts"], "none")

    private var tcpViews: [NSView] = []
    private var serialViews: [NSView] = []

    func begin(on w: NSWindow, completion: @escaping (ConnectionSpec?, String?) -> Void) {
        self.completion = completion
        build()
        present(on: w)
        panel.makeFirstResponder(serialOnly ? portPopup : hostBox)
    }

    private func build() {
        for r in [tcpRadio, serialRadio, shellRadio] { r.target = self; r.action = #selector(modeChanged) }
        for r in [sshRadio, telnetRadio, otherRadio] { r.target = self; r.action = #selector(serviceChanged) }

        hostBox.addItems(withObjectValues: ConnHistory.hosts)
        hostBox.stringValue = ConnHistory.hosts.first ?? ""
        hostBox.completes = true
        hostBox.translatesAutoresizingMaskIntoConstraints = false
        hostBox.widthAnchor.constraint(equalToConstant: 300).isActive = true
        hostBox.placeholderString = "ホスト名か IP アドレス"
        hostBox.delegate = self

        let svc = ConnHistory.lastService
        sshRadio.state = svc == "ssh" ? .on : .off
        telnetRadio.state = svc == "telnet" ? .on : .off
        otherRadio.state = svc == "raw" ? .on : .off
        portField.stringValue = svc == "ssh" ? "22" : "23"

        let keyButton = NSButton(title: "選ぶ…", target: self, action: #selector(chooseKey))

        // シリアル
        let ports = SerialPort.list()
        let last = ConnHistory.serial
        if ports.isEmpty {
            portPopup.addItem(withTitle: "(シリアルポートが見つかりません)")
            portPopup.isEnabled = false
        } else {
            for p in ports { portPopup.addItem(withTitle: p) }
            if ports.contains(last.path) { portPopup.selectItem(withTitle: last.path) }
        }
        let refresh = NSButton(title: "再検索", target: self, action: #selector(refreshPorts))
        baudPopup.selectItem(withTitle: String(last.baud))
        dataPopup.selectItem(withTitle: String(last.dataBits))
        parityPopup.selectItem(withTitle: last.parity)
        stopPopup.selectItem(withTitle: String(last.stopBits))
        flowPopup.selectItem(at: ["none", "xon", "rts"].firstIndex(of: last.flow) ?? 0)

        func row(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }
        func indent(_ v: NSView) -> NSView {
            let s = NSStackView(views: [NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 1)), v])
            s.orientation = .horizontal
            return s
        }

        let tcpGrid = NSGridView(views: [
            [label("ホスト:"), hostBox],
            [label("サービス:"), row([sshRadio, telnetRadio, otherRadio, label("  TCPポート:"), portField])],
            [label("ユーザー名:"), row([userField, label("パスワード:"), passField])],
            [label("秘密鍵:"), row([keyField, keyButton])],
        ])
        tcpGrid.rowSpacing = 8
        tcpGrid.column(at: 0).xPlacement = .trailing
        let serialGrid = NSGridView(views: [
            [label("ポート:"), row([portPopup, refresh])],
            [label("速度:"), row([baudPopup, label("データ:"), dataPopup, label("パリティ:"), parityPopup])],
            [label("ストップ:"), row([stopPopup, label("フロー制御:"), flowPopup])],
        ])
        serialGrid.rowSpacing = 8
        serialGrid.column(at: 0).xPlacement = .trailing
        tcpViews = [hostBox, sshRadio, telnetRadio, otherRadio, portField, userField, passField, keyField, keyButton]
        serialViews = [portPopup, refresh, baudPopup, dataPopup, parityPopup, stopPopup, flowPopup]

        var parts: [NSView] = []
        if !serialOnly { parts += [tcpRadio, indent(tcpGrid)] }
        parts += [serialRadio, indent(serialGrid)]
        if !serialOnly { parts.append(shellRadio) }
        let body = NSStackView(views: parts)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10

        let mode = serialOnly ? "serial" : ConnHistory.lastMode
        tcpRadio.state = mode == "tcp" ? .on : .off
        serialRadio.state = mode == "serial" ? .on : .off
        shellRadio.state = mode == "shell" ? .on : .off
        okButton.title = "接続"
        layout(body)
        modeChanged()
        serviceChanged()
    }

    func controlTextDidChange(_ obj: Notification) {}

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // 履歴の "user@host:port /telnet" を各欄に戻す
        DispatchQueue.main.async {
            let v = self.hostBox.stringValue
            guard let s = ConnectionSpec.parse(v) else { return }
            switch s {
            case .ssh(let h, let p, let u, let k):
                self.hostBox.stringValue = h; self.portField.stringValue = String(p)
                if !u.isEmpty { self.userField.stringValue = u }
                if !k.isEmpty { self.keyField.stringValue = k }
                self.sshRadio.state = .on; self.telnetRadio.state = .off; self.otherRadio.state = .off
            case .telnet(let h, let p):
                self.hostBox.stringValue = h; self.portField.stringValue = String(p)
                self.telnetRadio.state = .on; self.sshRadio.state = .off; self.otherRadio.state = .off
            case .rawTCP(let h, let p):
                self.hostBox.stringValue = h; self.portField.stringValue = String(p)
                self.otherRadio.state = .on; self.sshRadio.state = .off; self.telnetRadio.state = .off
            default: break
            }
            self.serviceChanged()
        }
    }

    @objc private func modeChanged() {
        let tcp = tcpRadio.state == .on
        let serial = serialRadio.state == .on
        for v in tcpViews { (v as? NSControl)?.isEnabled = tcp }
        for v in serialViews { (v as? NSControl)?.isEnabled = serial && !SerialPort.list().isEmpty }
        if tcp { serviceChanged() }
    }

    @objc private func serviceChanged() {
        let tcp = tcpRadio.state == .on
        let ssh = sshRadio.state == .on
        if ssh && portField.stringValue == "23" { portField.stringValue = "22" }
        if !ssh && portField.stringValue == "22" { portField.stringValue = "23" }
        userField.isEnabled = tcp && ssh
        passField.isEnabled = tcp && ssh
        keyField.isEnabled = tcp && ssh
    }

    @objc private func refreshPorts() {
        portPopup.removeAllItems()
        let ports = SerialPort.list()
        if ports.isEmpty { portPopup.addItem(withTitle: "(シリアルポートが見つかりません)") } else { portPopup.addItems(withTitles: ports) }
        modeChanged()
    }

    @objc private func chooseKey() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.showsHiddenFiles = true
        if p.runModal() == .OK, let u = p.url { keyField.stringValue = u.path }
    }

    override func ok() {
        var spec: ConnectionSpec?
        var password: String?
        if shellRadio.state == .on {
            spec = .shell
            ConnHistory.lastMode = "shell"
        } else if serialRadio.state == .on {
            guard portPopup.isEnabled, let path = portPopup.titleOfSelectedItem else { NSSound.beep(); return }
            var s = SerialParams()
            s.path = path
            s.baud = Int(baudPopup.titleOfSelectedItem ?? "9600") ?? 9600
            s.dataBits = Int(dataPopup.titleOfSelectedItem ?? "8") ?? 8
            s.parity = parityPopup.titleOfSelectedItem ?? "none"
            s.stopBits = Int(stopPopup.titleOfSelectedItem ?? "1") ?? 1
            s.flow = ["none", "xon", "rts"][max(0, flowPopup.indexOfSelectedItem)]
            ConnHistory.serial = s
            ConnHistory.lastMode = "serial"
            spec = .serial(s)
        } else {
            var host = hostBox.stringValue.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { NSSound.beep(); panel.makeFirstResponder(hostBox); return }
            var user = userField.stringValue.trimmingCharacters(in: .whitespaces)
            if let at = host.firstIndex(of: "@") {
                user = String(host[..<at]); host = String(host[host.index(after: at)...])
            }
            let port = Int(portField.stringValue) ?? 22
            let history: String
            if sshRadio.state == .on {
                spec = .ssh(host: host, port: port, user: user, keyFile: keyField.stringValue)
                password = passField.stringValue
                ConnHistory.lastService = "ssh"
                ConnHistory.lastUser = user
                ConnHistory.lastKeyFile = keyField.stringValue
                history = host
            } else if telnetRadio.state == .on {
                spec = .telnet(host: host, port: port)
                ConnHistory.lastService = "telnet"
                history = port == 23 ? "\(host) /telnet" : "\(host):\(port) /telnet"
            } else {
                spec = .rawTCP(host: host, port: port)
                ConnHistory.lastService = "raw"
                history = "\(host):\(port) /t=0"
            }
            ConnHistory.remember(host: history)
            ConnHistory.lastMode = "tcp"
        }
        close()
        completion?(spec, password)
    }

    override func cancel() {
        close()
        completion?(nil, nil)
    }
}

// 端末の設定は SetupSheet.swift (Tera Term: その他の設定)
