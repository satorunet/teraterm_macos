import UIKit
import UniformTypeIdentifiers
import TeraCore

/// 1 つの接続の画面 (端末・キーの列・接続・マクロ)
final class SessionViewController: UIViewController, UIDocumentPickerDelegate {
    private var host: SPHost
    private let term = Terminal(cols: 80, rows: 24)
    private lazy var termView = TerminalView(term: term)
    private lazy var keyBar = KeyBar(term: termView)
    private var decoder = StreamDecoder(encoding: .utf8)
    private var conn: Connection?
    private(set) var connected = false
    private var macro: MacroRunner?
    private lazy var asker = SSHAlertAsker(presenter: self)

    init(host: SPHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        title = host.title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        termView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(termView)
        NSLayoutConstraint.activate([
            termView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            termView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            termView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // キーボードが出たら、その上まで (iOS 15 の keyboardLayoutGuide)
            termView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        let fs = UserDefaults.standard.double(forKey: "TeraSPFontSize")
        if fs > 0 { termView.fontSize = CGFloat(fs) }
        termView.onFontSizeChange = { UserDefaults.standard.set(Double($0), forKey: "TeraSPFontSize") }
        termView.accessory = keyBar
        termView.onSend = { [weak self] b in self?.conn?.write(b) }
        termView.onResize = { [weak self] c, r in
            guard let self = self else { return }
            self.term.resize(cols: c, rows: r)
            self.conn?.resize(cols: c, rows: r)
        }
        term.onResponseBytes = { [weak self] b in self?.conn?.write(b) }
        term.onTitle = { [weak self] _ in
            guard let self = self else { return }
            let t = self.term.windowTitle
            self.title = t.isEmpty ? self.host.title : t
        }
        term.onBell = { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        term.onClipboardWrite = { UIPasteboard.general.string = $0 }
        term.onMacroText = { [weak self] b in self?.macro?.received(b) }
        updateButtons()
        connect()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        termView.becomeFirstResponder()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { macro?.cancel(); conn?.close() }
    }

    // MARK: 接続

    private func connect() {
        connected = false
        let c: Connection
        switch host.proto {
        case .ssh:
            let s = SSH2Connection(host: host.host, port: host.port, user: host.user, keyFile: "", cols: term.cols, rows: term.rows)
            s.password = Keychain.get(host.id)
            s.asker = asker
            c = s
        case .telnet:
            c = TCPConnection(host: host.host, port: host.port, telnet: true, cols: term.cols, rows: term.rows)
        }
        c.onData = { [weak self] b in self?.received(b) }
        c.onConnected = { [weak self] in
            guard let self = self else { return }
            self.connected = true
            self.macro?.connectionChanged(true)
            self.updateButtons()
            // 接続先に決めてあるマクロを動かす
            if !self.host.macro.isEmpty { self.runMacro(path: SPPaths.macrosDir + "/" + self.host.macro) }
        }
        c.onClose = { [weak self] msg in
            guard let self = self else { return }
            self.connected = false
            self.macro?.connectionChanged(false)
            self.show("\r\n\u{1B}[33m[" + (msg ?? "切断しました") + "]\u{1B}[0m\r\n")
            self.updateButtons()
        }
        conn = c
        show("\u{1B}[36m[\(host.subtitle) に接続しています…]\u{1B}[0m\r\n")
        do { try c.start() } catch {
            show("\u{1B}[31m[" + error.localizedDescription + "]\u{1B}[0m\r\n")
        }
        updateButtons()
    }

    private func received(_ b: [UInt8]) {
        let s = decoder.decode(b)
        term.feed(s)
        termView.dataArrived()
    }

    /// 自分で画面に出す文字 (接続中の案内など)
    private func show(_ s: String) {
        term.feed(s)
        termView.dataArrived()
    }

    @objc private func reconnect() {
        conn?.close()
        decoder.reset()
        connect()
    }

    @objc private func disconnect() { conn?.close() }

    // MARK: メニュー

    private func updateButtons() {
        let menu = UIMenu(children: [
            UIAction(title: "マクロを実行…", image: UIImage(systemName: "play")) { [weak self] _ in self?.pickMacro() },
            UIAction(title: "マクロを止める", image: UIImage(systemName: "stop"), attributes: macro == nil ? .disabled : []) { [weak self] _ in self?.macro?.cancel() },
            UIAction(title: "貼り付け", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.termView.paste(nil) },
            UIAction(title: "画面をコピー", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.termView.copyScreen(nil) },
            UIAction(title: "文字を大きく", image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in self?.changeFont(1) },
            UIAction(title: "文字を小さく", image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in self?.changeFont(-1) },
            connected ? UIAction(title: "切断", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in self?.disconnect() }
                      : UIAction(title: "もう一度つなぐ", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reconnect() },
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu)
    }

    private func changeFont(_ d: CGFloat) {
        termView.fontSize += d
        UserDefaults.standard.set(Double(termView.fontSize), forKey: "TeraSPFontSize")
    }

    // MARK: マクロ

    private func pickMacro() {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        p.directoryURL = URL(fileURLWithPath: SPPaths.macrosDir)
        p.delegate = self
        present(p, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let u = urls.first else { return }
        runMacro(path: u.path)
    }

    private func runMacro(path: String) {
        macro?.cancel()
        let m = MacroRunner(session: self, terminal: term)
        macro = m
        m.onFinish = { [weak self] in self?.macro = nil; self?.updateButtons() }
        m.start(path: path, connected: connected)
        updateButtons()
    }

    // MARK: マクロから使うもの

    func macroSend(_ b: [UInt8]) { conn?.write(b) }
    func macroDisconnect() { conn?.close() }
    var hostName: String { host.host }
}

