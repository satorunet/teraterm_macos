import AppKit
import TeraCore

/// 1 つのウインドウ = 1 つの接続
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    let term: Terminal
    let termView: TerminalView
    var settings: TermSettings
    private(set) var spec: ConnectionSpec?
    private var conn: Connection?
    var connection: Connection? { conn }
    /// ファイルのドラッグ&ドロップ (FileDrop.swift)
    lazy var dropSettings = DropSettings.load()
    lazy var dropState = DropState(confirm: dropSettings.confirmFileDragAndDrop)
    private var decoder: StreamDecoder
    private var connected = false
    /// connect したが、まだつながっていない (TCP の接続中・ssh がまだ何も出していない)
    private var connecting = false
    private var remoteTitle: String?
    /// ログ (filesys_log.cpp の LogVar)
    private(set) var teraLog: TeraLog?
    var logPath: String? { teraLog?.path }
    private var connectedAt = Date()
    var logPaused: Bool {
        get { teraLog?.paused ?? false }
        set { teraLog?.paused = newValue }
    }
    /// logautoclose (ttdde.c AutoLogClose): マクロが終わったら (DDE が切れたら) ログを閉じる
    var logAutoClose = false
    // マクロ用
    var multicastName = ""
    /// settitle / /W= のタイトル (Tera Term の ts.TitleW)。AcceptTitleChangeRequest=overwrite と同じくリモートのタイトルを消す
    var macroTitle: String? { didSet { remoteTitle = nil; updateTitle() } }
    /// connect の /timeout= など、ssh に渡す追加の引数
    private var sshExtraArgs: [String] = []
    /// ファイル転送のフォルダ (GetFileDir: FileDir を展開し、無ければダウンロード)。設定すると FileDir をそのまま書き換える
    var transferDir: String? {
        get { FileTransferPaths.fileDirectory(transferOptions.fileDir) }
        set { transferOptions.fileDir = newValue ?? "" }
    }
    /// ファイル転送 (XMODEM / ZMODEM / recvfile など)。動いている間は受信したデータをこちらに渡す
    private(set) var transfer: FileTransfer?
    /// Tera Term の ts にあたる転送の設定。TERATERM.INI があれば読む (マクロの指定がつぎの転送にも残る)
    var transferOptions = FileTransferOptions.loadTeraTermIni().options
    /// ZMODEM / B-Plus の自動起動 (ZmodemAuto / BPAuto)
    private var autoStartScanner = TransferAutoStartScanner()
    private var autoStartBypass = false
    /// ZMODEM 自動送信でファイルを選んでいる間に受けたデータ
    private var autoSendBuffer: [UInt8]?
    /// sendfile の送信中 (SendMem)
    private(set) var sendFileJob: SendFileJob?
    /// TalkStatus != IdTalkKeyb の間、キーボード・貼り付けを止めるために退避したハンドラ
    private var savedKeyHandlers: (text: ((String) -> Void)?, bytes: (([UInt8]) -> Void)?)?
    /// cv.DelayFlag = FALSE の間退避したシリアルの送信遅延
    private var savedSerialDelay: (char: Int, line: Int)?
    private var transferPanel: TransferProgressPanel?
    private var scpPanels: [TransferProgressPanel] = []
    private var scpJobs: [ScpJob] = []
    /// 自動ログイン: プロンプトが出たら順に答える (TeraTerm Menu の自動ログイン)
    struct LoginStep {
        var prompt: String
        var response: String
        /// prompt を (大文字小文字を区別しない) 正規表現として、受信の末尾に合わせる
        var regex = false
    }
    private var loginSteps: [LoginStep] = []
    private var recentOutput = ""
    var macro: MacroRunner?
    private var statusLabel: NSTextField?

    static var all: [SessionWindowController] = []

    init(settings: TermSettings = TermSettings.load()) {
        self.settings = settings
        term = Terminal(cols: settings.cols, rows: settings.rows)
        termView = TerminalView(term: term, settings: settings)
        decoder = StreamDecoder(encoding: settings.encoding)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.tabbingMode = .preferred
        super.init(window: win)
        win.delegate = self
        win.contentView = termView
        win.backgroundColor = settings.bg
        applyNewlineSettings()
        fitWindow(cols: settings.cols, rows: settings.rows)
        win.center()
        if let last = SessionWindowController.all.last?.window {
            win.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        win.makeFirstResponder(termView)

        term.onResponse = { [weak self] s in self?.sendBytes(Array(s.utf8), echo: false) }
        term.onTitle = { [weak self] t in self?.remoteTitle = t; self?.updateTitle() }
        term.onBell = { NSSound.beep() }
        term.onMacroText = { [weak self] b in self?.macroText(b) }
        termView.onSendText = { [weak self] s in self?.sendText(s) }
        termView.onSendBytes = { [weak self] b in self?.sendBytes(b, echo: true) }
        termView.onFilesDropped = { [weak self] paths, force in self?.filesDropped(paths, forceDialog: force) }
        termView.onResize = { [weak self] c, r in
            self?.conn?.resize(cols: c, rows: r)
            self?.updateTitle()
        }
        SessionWindowController.all.append(self)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyNewlineSettings() {
        term.recvCRasCRLF = settings.recvNewline == "CR"
        term.recvLFasCRLF = settings.recvNewline == "LF"
    }

    func fitWindow(cols: Int? = nil, rows: Int? = nil) {
        guard let w = window else { return }
        let size = termView.contentSize(cols: cols ?? term.cols, rows: rows ?? term.rows)
        let top = w.frame.maxY
        w.setContentSize(size)
        w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX, y: top))
        w.contentResizeIncrements = NSSize(width: termView.cellW, height: termView.cellH)
    }

    func applySettings(_ s: TermSettings) {
        let resize = s.cols != settings.cols || s.rows != settings.rows || s.fontName != settings.fontName || s.fontSize != settings.fontSize
        settings = s
        termView.settings = s
        decoder.encoding = s.encoding
        window?.backgroundColor = s.bg
        applyNewlineSettings()
        if let sc = conn as? SerialConnection { sc.charDelayMs = s.charDelayMs; sc.lineDelayMs = s.lineDelayMs }
        if resize {
            fitWindow(cols: s.cols, rows: s.rows)
            conn?.resize(cols: term.cols, rows: term.rows)
        }
        termView.needsDisplay = true
    }

    func updateTitle() {
        if let mt = macroTitle {
            window?.title = mt
            window?.tab.title = mt
            return
        }
        var t = remoteTitle ?? spec?.title ?? "未接続"
        if spec != nil && !connected && !connecting { t += " (切断)" }
        window?.title = "\(t) - Tera Term Mac \(term.cols)x\(term.rows)"
        window?.tab.title = remoteTitle ?? spec?.title ?? "未接続"
    }

    // MARK: - 接続

    func showConnectDialog(onEnd: (() -> Void)? = nil) {
        guard let w = window else { onEnd?(); return }
        let dlg = ConnectDialog()
        dlg.begin(on: w) { [weak self] spec, password in
            defer { onEnd?() }
            guard let self = self, let spec = spec else { return }
            self.connect(spec, password: password)
        }
    }

    /// 接続する。TCP と ssh は「つながった」ときに macro.connectionChanged() (Tera Term の SetDdeComReady(1))。
    /// sshArgs: ssh に足す引数 (/auth= /timeout= など)。timeout: TCP の接続を待つ秒数 (/timeout=、0 / nil は OS 任せ)
    @discardableResult
    func connect(_ spec: ConnectionSpec, password: String? = nil, loginSteps steps: [LoginStep] = [],
                 sshArgs: [String] = [], timeout: Int? = nil, telnetBinary: Bool = false, quiet: Bool = false) -> Bool {
        disconnect(silent: true)
        self.spec = spec
        remoteTitle = nil
        sshExtraArgs = sshArgs
        let c = makeConnection(spec, cols: term.cols, rows: term.rows, sshArgs: sshArgs, timeout: timeout, telnetBinary: telnetBinary)
        if let sc = c as? SerialConnection { sc.charDelayMs = settings.charDelayMs; sc.lineDelayMs = settings.lineDelayMs }
        c.onData = { [weak self] b in self?.received(b) }
        c.onClose = { [weak self, weak c] msg in
            guard let self = self, c === self.conn else { return }
            let wasConnecting = self.connecting
            self.connected = false
            self.connecting = false
            self.conn = nil
            self.transferConnectionLost()
            self.notice(msg.map { (wasConnecting ? "" : "切断されました: ") + $0 } ?? "切断されました")
            if wasConnecting && !quiet, let m = msg, let w = self.window {
                // cv.NoMsg (マクロの connect) のときは出さない
                let a = NSAlert()
                a.messageText = "接続できませんでした"
                a.informativeText = m
                a.beginSheetModal(for: w)
            }
            self.updateTitle()
            self.macro?.connectionChanged()
        }
        c.onConnected = { [weak self, weak c] in
            guard let self = self, c === self.conn, self.connecting else { return }
            self.connecting = false
            self.connected = true
            self.transfer?.isReady = true
            self.connectedAt = Date()
            self.teraLog?.connectedTime = self.connectedAt
            if c is TCPConnection { self.notice("\(spec.title) に接続しました") }
            self.updateTitle()
            self.macro?.connectionChanged()
        }
        if c is TCPConnection { notice("\(spec.title) に接続しています…") }
        loginSteps = steps
        if let pw = password, !pw.isEmpty, steps.isEmpty { loginSteps = [LoginStep(prompt: "password:", response: pw)] }
        recentOutput = ""
        do {
            try c.start()
        } catch {
            notice(error.localizedDescription)
            if !quiet {
                let a = NSAlert()
                a.messageText = "接続できませんでした"
                a.informativeText = error.localizedDescription
                if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
            }
            updateTitle()
            macro?.connectionChanged()
            return false
        }
        conn = c
        if c.waitsForConnection {
            connecting = true
            connected = false
            updateTitle()
            return true
        }
        connected = true
        transfer?.isReady = true
        connectedAt = Date()
        teraLog?.connectedTime = connectedAt
        macro?.connectionChanged()
        if case .serial(let p) = spec { notice("\(p.path) を開きました (\(p.baud) bps, \(p.dataBits)\(p.parity.prefix(1).uppercased())\(p.stopBits), フロー制御: \(p.flow))") }
        updateTitle()
        return true
    }

    var isConnected: Bool { connected }
    /// 接続を始めたが、まだつながっていない (TCP の接続中・ssh の接続中・接続ダイアログを出している)
    var isConnecting: Bool { connecting || connectDialogOpen }
    /// マクロの connect '' で出した接続ダイアログ
    var connectDialogOpen = false

    func disconnect(silent: Bool = false) {
        guard let c = conn else { return }
        conn = nil
        connected = false
        connecting = false
        transferConnectionLost()
        c.close()
        if !silent { notice("切断しました") }
        updateTitle()
        macro?.connectionChanged()
    }

    /// 端末に案内を出す (相手には送らない)。Tera Term にはない Mac 版の表示なので、
    /// マクロの受信 (wait など) にもログにも入れない (端末の CR/LF の状態も変えない)
    private func notice(_ s: String) {
        let saved = term.onMacroText
        term.onMacroText = nil
        defer { term.onMacroText = saved }
        let prefix = term.cx == 0 ? "" : "\r\n"
        term.feed(prefix + "\u{1B}[0;36m[\(s)]\u{1B}[0m\r\n")
        termView.dataArrived()
    }

    // MARK: - 受信

    private func received(_ bytes: [UInt8]) {
        var bytes = bytes
        // ファイル転送中はプロトコルへ。終わったときに読まれずに残った分は端末へ (cv.InBuff の残り)
        if autoSendBuffer != nil { autoSendBuffer! += bytes; return }
        if let t = transfer {
            bytes = t.feed(bytes)
            if bytes.isEmpty { return }
        }
        if transfer == nil && !autoStartBypass && (transferOptions.zmodemAuto || transferOptions.bplusAuto) {
            autoStartScanner.zmodemAuto = transferOptions.zmodemAuto
            autoStartScanner.bplusAuto = transferOptions.bplusAuto
            let r = autoStartScanner.scan(bytes)
            if let trig = r.trigger {
                if !r.display.isEmpty {
                    autoStartBypass = true
                    received(r.display)
                    autoStartBypass = false
                }
                startAutoTransfer(trig, rest: r.rest)
                return
            }
            bytes = r.display
            if bytes.isEmpty { return }
        }
        teraLog?.putBinary(bytes)   // バイナリのログは受信したそのまま (FLogPutBinary)
        let s = decoder.decode(bytes)
        guard !s.isEmpty else { return }
        term.feed(s)
        termView.dataArrived()
        if let step = loginSteps.first {
            recentOutput = String((recentOutput + s).suffix(300))
            let tail = recentOutput.lowercased().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let prompt = step.prompt.lowercased().trimmingCharacters(in: .whitespaces)
            var hit = step.regex ? tail.range(of: step.prompt, options: [.regularExpression, .caseInsensitive]) != nil
                                 : !prompt.isEmpty && tail.hasSuffix(prompt)
            // パスワードは日本語のプロンプトも受ける
            if !hit && prompt.contains("password") {
                hit = tail.range(of: "パスワード.*[:：]$", options: .regularExpression) != nil
            }
            if hit {
                loginSteps.removeFirst()
                recentOutput = ""
                sendBytes(settings.encoding.encode(step.response) + settings.sendNewlineBytes, echo: false)
            }
        }
    }

    // MARK: - 送信

    func sendText(_ s: String) {
        sendBytes(settings.encoding.encode(s), echo: true)
    }

    /// binary: Telnet の CR を CR NUL にするか (CommBinaryOut は CR LF も CR NUL LF。テキストは改行コードの設定どおり)。
    /// reconnect: 切断中の Enter で再接続する (キーボードだけ。マクロの send では再接続しない)
    func sendBytes(_ b: [UInt8], echo: Bool, binary: Bool = false, reconnect: Bool = true) {
        guard !b.isEmpty else { return }
        guard let c = conn else {
            if reconnect && echo && spec != nil && !connected && !connecting && b == settings.sendNewlineBytes {
                // 切断中に Enter で再接続 (Tera Term の「自動再接続」に近い動き)
                if let sp = spec { connect(sp) }
            }
            return
        }
        c.write(b, binary: binary)
        if echo && settings.localEcho {
            var d = StreamDecoder(encoding: settings.encoding)
            var shown = d.decode(b)
            if b == settings.sendNewlineBytes { shown = "\r\n" }
            term.feed(shown)
            termView.dataArrived()
        }
    }

    // MARK: - ログ

    /// メニューの「ログ開始」: バイナリ (受信したそのまま)
    func startLog(path: String, append: Bool = true) -> Bool {
        var o = TTLLogOptions()
        o.append = append
        o.binary = true
        return startLog(path: path, options: o)
    }

    /// FLogOpen。すでにログを取っていたら false (前のログはそのまま)
    func startLog(path: String, options o: TTLLogOptions) -> Bool {
        guard teraLog == nil else { return false }
        guard let l = TeraLog(path: path, options: o, connectedTime: connectedAt) else { return false }
        teraLog = l
        // CmdSetLogOpt で ts.LogTypePlainText が変わり、FixLogOption でバイナリなら off になる (BS をマクロに渡すかも変わる)
        term.logTypePlainText = l.options.plainText
        return true
    }

    func stopLog() {
        teraLog?.close()
        teraLog = nil
    }

    /// logwrite (FLogWriteStr): 一時停止中でも書く
    func writeLogString(_ utf8: [UInt8]) {
        guard let l = teraLog else { return }
        l.writeString(utf8, encoded: l.isBinary ? settings.encoding.encode(String(decoding: utf8, as: UTF8.self)) : nil)
    }

    /// logrotate size N / rotate N / halt (今のログだけ)
    func setLogRotate(_ command: String) { teraLog?.setRotate(command) }

    /// ログのフォルダ (GetTermLogDir: LogDefaultPath がなければ FileDir)。Mac 版は changedir のフォルダ、なければ書類フォルダ
    var logDirectory: String {
        if let d = transferDir, !d.isEmpty, FileManager.default.fileExists(atPath: d) { return d }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    /// &h &p に使う接続先 (ConvertLognameW: 接続しているときだけ)
    var logHostAndPort: (String?, Int?) {
        guard connected, let s = spec else { return (nil, nil) }
        switch s {
        case .ssh(let h, let p, _, _), .telnet(let h, let p), .rawTCP(let h, let p): return (h, p)
        case .serial(let sp): return ((sp.path as NSString).lastPathComponent, nil)
        case .shell: return (nil, nil)
        }
    }

    /// 端末に表示した文字 (エスケープシーケンスなし、改行は CheckEOL でそろえた UTF-8)。マクロとテキストのログへ (OutputLogUTF32)
    private func macroText(_ b: [UInt8]) {
        macro?.received(b)
        teraLog?.putText(b)
    }

    // MARK: - メニューの操作

    @objc func newConnection(_ sender: Any?) { showConnectDialog() }

    @objc func duplicateSession(_ sender: Any?) {
        let c = SessionWindowController(settings: settings)
        c.showWindow(nil)
        if let s = spec {
            if case .serial = s {
                c.showConnectDialog()   // 同じシリアルポートは 2 つ開けない
            } else {
                c.connect(s)
            }
        } else {
            c.showConnectDialog()
        }
    }

    @objc func disconnectSession(_ sender: Any?) { disconnect() }

    @objc func reconnect(_ sender: Any?) {
        if let s = spec { connect(s) }
    }

    @objc func toggleLog(_ sender: Any?) {
        if teraLog != nil {
            let p = logPath ?? ""
            stopLog()
            notice("ログを止めました: \(p)")
            return
        }
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        panel.nameFieldStringValue = "teramac_\(f.string(from: Date())).log"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let url = panel.url, let self = self else { return }
            if self.startLog(path: url.path, append: true) {
                self.notice("ログを開始しました: \(url.path)")
            }
        }
    }

    @objc func sendFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let self = self else { return }
            self.sendBytes([UInt8](data), echo: false)
            self.notice("\(url.lastPathComponent) を送信しました (\(data.count) バイト)")
        }
    }

    @objc func sendBreak(_ sender: Any?) { conn?.sendBreak() }

    @objc func resetTerminal(_ sender: Any?) {
        term.feed("\u{1B}c")
        termView.dataArrived()
    }

    @objc func clearScreen(_ sender: Any?) {
        term.clearScreen()
        termView.needsDisplay = true
    }

    @objc func clearBuffer(_ sender: Any?) {
        term.clearScrollback()
        termView.scrollToBottom()
        termView.needsDisplay = true
    }

    @objc func showTerminalSetup(_ sender: Any?) {
        let dlg = SetupDialog(settings: settings)
        dlg.begin(on: window!) { [weak self] s in
            guard let s = s else { return }
            self?.applySettings(s)
            s.save()
        }
    }

    @objc func serialSetup(_ sender: Any?) {
        let dlg = ConnectDialog()
        dlg.serialOnly = true
        dlg.begin(on: window!) { [weak self] spec, _ in
            guard let self = self, let spec = spec else { return }
            self.connect(spec)
        }
    }

    @objc func biggerFont(_ sender: Any?) { changeFont(by: 1) }
    @objc func smallerFont(_ sender: Any?) { changeFont(by: -1) }

    private func changeFont(by d: CGFloat) {
        var s = settings
        s.fontSize = max(8, min(48, s.fontSize + d))
        settings = s
        let (c, r) = (term.cols, term.rows)
        termView.settings = s
        fitWindow(cols: c, rows: r)
    }

    @objc func runMacroMenu(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["ttl", "txt"]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.runMacro(url: url)
        }
    }

    func runMacro(url: URL, params: [String] = []) {
        guard macro == nil else { NSSound.beep(); return }
        do {
            let m = try MacroRunner(path: url.path, params: params, session: self)
            macro = m
            notice("マクロ開始: \(url.lastPathComponent)")
            m.start()
        } catch {
            let a = NSAlert()
            a.messageText = "マクロを読めませんでした"
            a.informativeText = "\(error)"
            a.beginSheetModal(for: window!)
        }
    }


    // MARK: - マクロから使う

    /// send / sendtext / sendbinary (ttdde.c SendData / SendStringU8 / SendBinary)。
    /// echo: ローカルエコー (ts.LocalEcho) するか。sendbroadcast / sendmulticast はしない (broadcast.cpp)。
    /// 切断中は何も送らない (再接続しない)
    func macroSend(_ b: [UInt8], mode: TTLSendMode, echo: Bool = true) {
        var binary = mode == .binary
        if mode == .compat {
            // IsBinaryData: CR/LF 以外の 0x20 未満が 1 バイトでもあればバイナリ。UTF-8 として読めなくてもバイナリ
            if b.contains(where: { $0 < 0x20 && $0 != 0x0D && $0 != 0x0A }) { binary = true }
            if String(bytes: b, encoding: .utf8) == nil { binary = true }
        }
        if binary {
            sendBytes(b, echo: echo, binary: true, reconnect: false)
            return
        }
        let text = String(decoding: b, as: UTF8.self)
        var out: [UInt8] = []
        for (i, part) in text.components(separatedBy: "\r").enumerated() {
            if i > 0 { out += settings.sendNewlineBytes }
            out += settings.encoding.encode(part)
        }
        sendBytes(out, echo: echo, reconnect: false)
    }

    /// sendkcode (keyboard.c KeyCodeSend)。Tera Term のキーコード (IBM PC のスキャンコード。+512 Shift +1024 Ctrl +2048 Alt)。
    /// Mac には KEYBOARD.CNF がないので、既定の割り当て (IBMKEYB.CNF / VT のキー) と主なキーだけを送る。
    /// Enter は送信の改行コード、カーソルキーはアプリケーションカーソルモードに従う
    func macroSendKeyCode(_ code: Int, count: Int) {
        guard let seq = SessionWindowController.keyCodeSequence(code, appCursor: term.appCursor, appKeypad: term.appKeypad,
                                                                newline: settings.sendNewlineBytes) else {
            notice("sendkcode \(code) には対応していません")
            return
        }
        for _ in 0..<max(1, count) { sendBytes(seq, echo: false, reconnect: false) }
    }

    static func keyCodeSequence(_ code: Int, appCursor: Bool, appKeypad: Bool, newline: [UInt8]) -> [UInt8]? {
        let esc: UInt8 = 0x1B
        func csi(_ s: String) -> [UInt8] { [esc, 0x5B] + Array(s.utf8) }
        func ss3(_ s: String) -> [UInt8] { [esc, 0x4F] + Array(s.utf8) }
        func cur(_ c: String) -> [UInt8] { appCursor ? ss3(c) : csi(c) }
        // [VT editor keypad] [VT numeric keypad] [VT function keys] [X function keys] (IBMKEYB.CNF)
        switch code {
        case 328: return cur("A")
        case 336: return cur("B")
        case 333: return cur("C")
        case 331: return cur("D")
        case 338: return csi("2~")   // Insert
        case 327: return csi("1~")   // Find (Home)
        case 329: return csi("5~")   // Prev
        case 339: return csi("3~")   // Remove (Delete)
        case 335: return csi("4~")   // Select (End)
        case 337: return csi("6~")   // Next
        case 59: return ss3("P")
        case 60: return ss3("Q")
        case 61: return ss3("R")
        case 62: return ss3("S")
        case 63: return csi("15~")   // XF5
        case 64: return csi("17~")
        case 65: return csi("18~")
        case 66: return csi("19~")
        case 67: return csi("20~")
        case 68: return csi("21~")
        case 87: return csi("23~")
        case 88: return csi("24~")
        case 573: return csi("25~")
        case 574: return csi("26~")
        case 575: return csi("28~")  // Help
        case 576: return csi("29~")  // Do
        case 577: return csi("31~")
        case 578: return csi("32~")
        case 579: return csi("33~")
        case 580: return csi("34~")
        case 527: return csi("Z")    // XBackTab
        case 284: return appKeypad ? ss3("M") : newline   // NumEnter
        default: break
        }
        let numpad: [Int: (String, String)] = [82: ("0", "p"), 79: ("1", "q"), 80: ("2", "r"), 81: ("3", "s"), 75: ("4", "t"),
                                               76: ("5", "u"), 77: ("6", "v"), 71: ("7", "w"), 72: ("8", "x"), 73: ("9", "y"),
                                               78: ("+", "l"), 83: (".", "n"), 309: ("/", "o"), 55: ("*", "j"), 74: ("-", "m")]
        if let (n, a) = numpad[code] { return appKeypad ? ss3(a) : Array(n.utf8) }
        // そのほかのキー (VKey2KeyStr / OemKeyScan): US 配列のスキャンコード
        let shift = code & 512 != 0, ctrl = code & 1024 != 0, alt = code & 2048 != 0
        let scan = code & 0x1FF
        var out: [UInt8]
        switch scan {
        case 1: out = [esc]
        case 14: out = [0x08]
        case 15: out = shift ? csi("Z") : [0x09]
        case 28: out = newline
        case 57: out = [0x20]
        default:
            let rows: [(Int, String, String)] = [
                (2, "1234567890-=", "!@#$%^&*()_+"), (16, "qwertyuiop[]", "QWERTYUIOP{}"),
                (30, "asdfghjkl;'`", "ASDFGHJKL:\"~"), (43, "\\zxcvbnm,./", "|ZXCVBNM<>?"),
            ]
            var ch: Character?
            for (start, lower, upper) in rows {
                let i = scan - start
                if i >= 0 && i < lower.count {
                    ch = Array(shift ? upper : lower)[i]
                    break
                }
            }
            guard let c = ch, let v = c.asciiValue else { return nil }
            if ctrl {
                let u = Character(String(c).uppercased()).asciiValue ?? v
                guard u >= 0x40 && u <= 0x5F else { return nil }
                out = [u & 0x1F]
            } else {
                out = [v]
            }
        }
        if alt && scan != 28 { out = [esc] + out }   // Meta キーは ESC を前に付ける
        return out
    }

    /// sendfile (sendmem.cpp SendMemSendFile2)。相対パスは FileDir から。テキストは LoadFileWW と同じ読み方で
    /// 改行を CR にして端末の改行コード・文字コードで、バイナリはそのまま送る。SendfileDelay* の遅延とローカルエコー付き。
    /// 送り終わったら done。ファイルが読めなければ false (マクロはすぐ次へ)
    func macroSendFile(_ path: String, binary: Bool, done: @escaping () -> Void) -> Bool {
        let full = FileTransferPaths.resolve(path, fileDir: FileTransferPaths.fileDirectory(transferOptions.fileDir))
        guard let d = FileManager.default.contents(atPath: full) else { return false }
        let o = transferOptions
        let plan = SendFilePlan.make(data: d, binary: binary, delayType: o.sendfileDelayType,
                                     delayTick: o.sendfileDelayTick, sendSize: o.sendfileSize)
        let job = SendFileJob(plan: plan) { [weak self] chunk in
            // CommBinaryBuffOut / CommTextOutW は切断中は何もしない
            guard let self = self, self.conn != nil else { return }
            switch chunk {
            case .binary(let b): self.sendBytes(b, echo: true)
            case .text(let t): self.macroSend(Array(t.utf8), mode: .text)
            }
        }
        sendFileJob = job
        setTalkQuiet(true)   // TalkStatus = IdTalkSendMem
        // 進み具合 (Windows 版の「ファイル送信」ダイアログにあたる)
        let panel = transferPanel ?? TransferProgressPanel()
        transferPanel = panel
        let name = (full as NSString).lastPathComponent
        panel.onCancel = { [weak job] in job?.finish() }
        panel.show(title: "ファイル送信", over: window)
        panel.set(proto: binary ? "ファイル送信 (バイナリ)" : "ファイル送信", file: name, detail: "0 / \(job.totalBytes) バイト", percent: 0)
        job.onProgress = { [weak panel] sent, total in
            panel?.set(proto: binary ? "ファイル送信 (バイナリ)" : "ファイル送信", file: name,
                       detail: "\(sent) / \(total) バイト", percent: total > 0 ? Double(sent) * 100 / Double(total) : 100)
        }
        job.onFinish = { [weak self, weak job] in
            guard let self = self else { done(); return }
            if self.sendFileJob === job {
                self.sendFileJob = nil
                self.setTalkQuiet(false)
                self.transferPanel?.close()
            }
            done()
        }
        job.start()
        return true
    }

    /// scp を進み具合のパネル付きで動かす (ドロップの SCP、マクロの scpsend / scprecv)
    @discardableResult
    func runScp(_ args: [String], label: String, file: String, done: @escaping (Bool) -> Void) -> Bool {
        let job = ScpJob(arguments: args)
        let panel = TransferProgressPanel()
        scpPanels.append(panel)
        let name = (file as NSString).lastPathComponent
        panel.onCancel = { [weak job] in job?.cancel() }
        job.onProgress = { [weak panel] f, pc, detail in
            panel?.set(proto: label, file: f.isEmpty ? name : f, detail: detail, percent: pc)
        }
        job.onFinish = { [weak self, weak panel] ok in
            panel?.close()
            self?.scpPanels.removeAll { $0 === panel }
            done(ok)
        }
        guard job.start() else { panel.close(); scpPanels.removeAll { $0 === panel }; return false }
        scpJobs.append(job)
        panel.show(title: label, over: window)
        panel.set(proto: label, file: name, detail: "接続しています…", percent: nil)
        let originalDone = job.onFinish
        job.onFinish = { [weak self, weak job] ok in
            originalDone?(ok)
            self?.scpJobs.removeAll { $0 === job }
        }
        return true
    }

    /// dispstr (ttdde.c CmdDispStr: SendMemTextW, echo=TRUE, send=FALSE)。
    /// ローカルエコーと同じく端末を通すので、マクロの受信 (wait) とログにも入る。CR は送信の改行コードでエコーされる (ControlEcho)
    func macroDisplay(_ b: [UInt8]) {
        let text = String(decoding: b, as: UTF8.self)
        let nl: String
        switch settings.sendNewline {
        case "CRLF": nl = "\r\n"
        case "LF": nl = "\n"
        default: nl = "\r"
        }
        term.feed(text.replacingOccurrences(of: "\r", with: nl))
        termView.dataArrived()
    }

    func macroNotice(_ s: String) { notice(s) }

    /// ファイル転送を始める (filesys_proto.cpp の *Start*)。終わったら done(成功したか)。
    /// false: 始められなかった (転送中・sendfile 中・送信ファイルが開けない等。マクロの result は変えない)。
    /// 未接続でも Windows 版と同じく始める (cv.Ready = FALSE: 回線には何も出ず、プロトコルが自分で諦めるかキャンセルで 0)
    func startTransfer(_ kind: FileTransferKind, files: [String], binaryFlag: Int, xmodemOption: Int,
                       autoStopSec: Int? = nil, fromMacro: Bool = true,
                       done: @escaping (Bool) -> Void) -> Bool {
        // ProtoStart(): FileVar != NULL / FileSnedIsSending()
        guard transfer == nil, autoSendBuffer == nil, sendFileJob == nil else { return false }
        transferOptions.applyMacroParameters(kind: kind, binaryFlag: binaryFlag, xmodemOption: xmodemOption, autoStopSec: autoStopSec)
        if case .serial(let p)? = spec { transferOptions.isTCPIP = false; transferOptions.baudRate = p.baud } else { transferOptions.isTCPIP = true }
        let dir = FileTransferPaths.fileDirectory(transferOptions.fileDir)
        // 送信は他の送信と同じ conn.write (Telnet の IAC 二重化などは Connection 側)
        let t = FileTransfer(kind: kind, files: files, receiveDir: dir, options: transferOptions) { [weak self] b in
            // Tera Term の CommBinaryOut と同じく、転送データはバイナリとして書く (Telnet の CR NUL など)
            self?.conn?.write(b, binary: true)
        }
        t.isReady = connected
        t.showsMessages = !fromMacro   // マクロからは fv->NoMsg = TRUE
        t.onMessage = { [weak self] m in
            guard let self = self else { return }
            let a = NSAlert()
            a.messageText = "Tera Term: Error"
            a.informativeText = m
            if let w = self.window { a.beginSheetModal(for: w) } else { a.runModal() }
        }
        t.onProgress = { [weak self] p in self?.transferPanel?.update(p) }
        t.onFinish = { [weak self, weak t] ok in
            guard let self = self else { done(ok); return }
            if self.transfer === t { self.transfer = nil }
            self.endTransferUI()
            done(ok)
        }
        // 終わったあと読まれずに残った受信データは端末へ (feed の中で終わったときは received() が受け取る)
        t.onUnconsumedInput = { [weak self] b in self?.received(b) }
        transfer = t
        beginTransferUI(t)
        if !t.start() {
            // OpenProtoDlg 失敗 → ProtoEnd() (DdeCmnd 前なので result は変わらない)
            if transfer === t { transfer = nil }
            endTransferUI()
            return false
        }
        return true
    }

    /// 転送ダイアログの Cancel (ProtoDlgCancel)。プロトコルの中断手順のあと result 0
    func cancelTransfer() { transfer?.cancel() }
    @objc func cancelTransferMenu(_ sender: Any?) { cancelTransfer() }

    /// cv.DelayFlag = FALSE / TalkStatus = IdTalkQuiet と転送の進み具合のパネル
    private func beginTransferUI(_ t: FileTransfer) {
        setTalkQuiet(true)
        if let sc = conn as? SerialConnection, savedSerialDelay == nil {
            savedSerialDelay = (sc.charDelayMs, sc.lineDelayMs)
            sc.charDelayMs = 0
            sc.lineDelayMs = 0
        }
        let panel = transferPanel ?? TransferProgressPanel()
        transferPanel = panel
        panel.onCancel = { [weak self] in self?.cancelTransfer() }
        panel.show(title: t.kind.title, over: window)
    }

    /// ProtoEnd(): cv.DelayFlag = TRUE / TalkStatus = IdTalkKeyb
    private func endTransferUI() {
        if let d = savedSerialDelay {
            if let sc = conn as? SerialConnection { sc.charDelayMs = d.char; sc.lineDelayMs = d.line }
            savedSerialDelay = nil
        }
        transferPanel?.close()
        setTalkQuiet(false)
    }

    /// キーボード・貼り付けを止める / 戻す (TalkStatus)
    private func setTalkQuiet(_ quiet: Bool) {
        if quiet {
            guard savedKeyHandlers == nil else { return }
            savedKeyHandlers = (termView.onSendText, termView.onSendBytes)
            termView.onSendText = { _ in }
            termView.onSendBytes = { _ in }
        } else {
            guard transfer == nil, sendFileJob == nil, let k = savedKeyHandlers else { return }
            termView.onSendText = k.text
            termView.onSendBytes = k.bytes
            savedKeyHandlers = nil
        }
    }

    /// 回線が切れた (cv.Ready = FALSE)。転送は Windows 版と同じくそのまま (Parse されなくなり、
    /// タイムアウトでプロトコルが諦めるかキャンセルで終わる)。sendfile の残りは送られずに終わる
    private func transferConnectionLost() {
        transfer?.isReady = false
        sendFileJob?.finish()
    }

    /// ZMODEM / B-Plus の自動起動 (vtterm.c CANSeen / DLESeen)
    private func startAutoTransfer(_ trig: TransferAutoStartScanner.Trigger, rest: [UInt8]) {
        func run(_ kind: FileTransferKind, files: [String], rest: [UInt8]) {
            if startTransfer(kind, files: files, binaryFlag: transferOptions.xmodemBin ? 1 : 0, xmodemOption: 0,
                             fromMacro: false, done: { _ in }), let t = transfer {
                let left = t.feed(rest)
                if !left.isEmpty { received(left) }
            } else if !rest.isEmpty {
                received(rest)
            }
        }
        switch trig {
        case .zmodemReceive: run(.zmodemAutoRecv, files: [], rest: rest)
        case .bplusReceive: run(.bplusAutoRecv, files: [], rest: rest)
        case .zmodemSend:
            // ZMODEMStartSend(NULL, 0, TRUE): 送るファイルを選ぶ。選ばなければ CAN x8 + BS x10 を送って終わり
            guard transfer == nil, sendFileJob == nil else { received(rest); return }
            autoSendBuffer = rest
            let p = NSOpenPanel()
            p.title = "Tera Term: ZMODEM Send"
            p.allowsMultipleSelection = true
            p.canChooseDirectories = false
            p.directoryURL = URL(fileURLWithPath: FileTransferPaths.fileDirectory(transferOptions.fileDir))
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
                guard let self = self else { return }
                let buffered = self.autoSendBuffer ?? []
                self.autoSendBuffer = nil
                if r == .OK, !p.urls.isEmpty {
                    run(.zmodemAutoSend, files: p.urls.map { $0.path }, rest: buffered)
                } else {
                    self.conn?.write([UInt8](repeating: 0x18, count: 8) + [UInt8](repeating: 0x08, count: 10))
                    if !buffered.isEmpty { self.received(buffered) }
                }
            }
            if let w = window { p.beginSheetModal(for: w, completionHandler: finish) } else { finish(p.runModal()) }
        }
    }

    /// gettitle: ts.TitleW (settitle・/W= のタイトル。既定は TERATERM.INI の Title=Tera Term)。リモートのタイトルやウインドウの飾りは含まない
    var titleForMacro: String { macroTitle ?? "Tera Term" }

    var hostnameForMacro: String {
        guard connected, let s = spec else { return "" }
        switch s {
        case .ssh(let h, _, _, _), .telnet(let h, _), .rawTCP(let h, _): return h
        case .serial(let p): return (p.path as NSString).lastPathComponent
        case .shell: return ""
        }
    }

    /// scpsend / scprecv の scp コマンドの引数 (SSH 接続のときだけ)
    func scpArguments(send: Bool, from: String, to: String) -> [String]? {
        guard connected, case .ssh(let host, let port, let user, let key)? = spec else { return nil }
        var a = ["-o", "ControlPath=\(sshControlPath(host: host, port: port, user: user))", "-o", "BatchMode=yes"]
        if port != 22 { a += ["-P", String(port)] }
        if !key.isEmpty { a += ["-i", (key as NSString).expandingTildeInPath] }
        let remote = user.isEmpty ? host : "\(user)@\(host)"
        if send {
            a += [from, "\(remote):\(to)"]
        } else {
            let dest = to.isEmpty ? ((transferDir ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()) as NSString).appendingPathComponent((from as NSString).lastPathComponent) : to
            a += ["\(remote):\(from)", dest]
        }
        return a
    }

    /// callmenu: Tera Term のメニュー番号 (tt_res.h の ID_*)。Mac 版に同じ操作があるものだけ。
    /// TEK・マクロウインドウ・ヘルプなど Mac にないものは何もしない (Tera Term と同じく result は変えない)
    func macroCallMenu(_ id: Int) {
        let actions: [Int: () -> Void] = [
            50110: { self.newConnection(nil) }, 50003: { self.newConnection(nil) },
            50111: { self.duplicateSession(nil) }, 50010: { self.duplicateSession(nil) },
            50112: { SessionWindowController.openLocalShell(settings: self.settings) },   // Cygwin 接続 → ローカルシェル
            50120: { self.toggleLog(nil) }, 50125: { self.stopLog() }, 50124: { self.logPaused.toggle() },
            50122: { if let p = self.logPath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } },
            50123: { if let p = self.logPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } },
            50130: { self.sendFile(nil) },
            50190: { self.macroDisconnect(confirm: true) }, 50009: { self.macroDisconnect(confirm: true) },
            50199: { self.window?.performClose(nil) }, 50005: { self.window?.performClose(nil) },
            50200: { NSApp.terminate(nil) },
            50210: { self.termView.copy(nil) }, 50002: { self.termView.copy(nil) },
            50230: { self.termView.paste(nil) }, 50008: { self.termView.paste(nil) },
            50250: { self.clearScreen(nil) }, 50260: { self.clearBuffer(nil) },
            50280: { self.termView.selectAll(nil) }, 50290: { self.termView.selectAll(nil) },
            50310: { self.showTerminalSetup(nil) }, 50320: { self.showTerminalSetup(nil) }, 50330: { self.showTerminalSetup(nil) },
            50340: { self.showTerminalSetup(nil) }, 50370: { self.showTerminalSetup(nil) }, 50375: { self.showTerminalSetup(nil) },
            50350: { self.serialSetup(nil) }, 50360: { self.newConnection(nil) },
            50380: { self.settings.save() },
            50410: { self.resetTerminal(nil) }, 50411: { self.remoteTitle = nil; self.updateTitle() },
            50420: { (self.conn as? TCPConnection)?.sendAreYouThere() },
            50430: { self.sendBreak(nil) }, 50001: { self.sendBreak(nil) },
            50440: { if case .serial? = self.spec, let s = self.spec { self.connect(s) } },
            50470: { self.runMacroMenu(nil) },
            50990: { NSApp.orderFrontStandardAboutPanel(nil) },
        ]
        if let f = actions[id] { f() } else { notice("callmenu \(id) には対応していません") }
    }

    /// 新しいウインドウでローカルシェル
    static func openLocalShell(settings: TermSettings) {
        let c = SessionWindowController(settings: settings)
        c.showWindow(nil)
        c.connect(.shell)
    }

    /// restoresetup: TERATERM.INI を読み込んでこのウインドウに使う
    func macroRestoreSetup(_ path: String) {
        guard let d = FileManager.default.contents(atPath: path), let ini = IniFile(data: d) else { return }
        let r = TeraTermIniImport.read(ini, base: settings)
        applySettings(r.settings)
        // Tera Term と同じく転送の設定 (ts) も読み直す
        transferOptions = FileTransferOptions(ini: ini)
    }

    /// 利用者がマクロを止める。このウインドウにつながったマクロがなければ、ウインドウから離れた (unlink した) マクロを止める
    @objc func stopMacro(_ sender: Any?) {
        if let m = macro { m.cancel() } else { MacroRunner.unlinked.forEach { $0.cancel() } }
    }

    /// マクロがこのウインドウから離れた (終わった・unlink・closett・別のウインドウへ connect)。
    /// ttdde.c XTYP_DISCONNECT: logautoclose ならログを閉じる
    func macroDetached(_ m: MacroRunner) {
        guard macro === m else { return }
        macro = nil
        setStatus(nil)
        termView.keyboardEnabled = true
        if logAutoClose {
            stopLog()
            logAutoClose = false
        }
    }

    /// マクロが終わった
    func macroFinished(_ m: MacroRunner, error: String?) {
        guard macro === m else { return }
        macroDetached(m)
        if let e = error { notice("マクロのエラーで止めました: \(e)") } else { notice("マクロ終了") }
    }

    /// disconnect (vtwin.cpp Disconnect): TCP (SSH を含む) で confirm なら「切断しますか?」(ConfirmDisconnect=on)
    func macroDisconnect(confirm: Bool) {
        guard conn != nil else { return }
        let tcp: Bool
        switch spec {
        case .ssh?, .telnet?, .rawTCP?: tcp = true
        default: tcp = false
        }
        if confirm && tcp && connected {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "切断しますか?"
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "キャンセル")
            a.buttons[1].keyEquivalent = "\u{1b}"
            a.window.initialFirstResponder = a.buttons[1]
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        disconnect()
    }

    /// マクロの statusbox / dispstr 用の小さな表示
    func setStatus(_ s: String?) {
        if s == nil || s!.isEmpty {
            statusLabel?.removeFromSuperview(); statusLabel = nil; return
        }
        if statusLabel == nil {
            let l = NSTextField(labelWithString: "")
            l.drawsBackground = true
            l.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9)
            l.font = NSFont.systemFont(ofSize: 12)
            termView.addSubview(l)
            statusLabel = l
        }
        statusLabel!.stringValue = " " + s! + " "
        statusLabel!.sizeToFit()
        statusLabel!.setFrameOrigin(NSPoint(x: termView.bounds.width - statusLabel!.frame.width - 8, y: 8))
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(disconnectSession(_:)), #selector(sendBreak(_:)), #selector(sendFile(_:)):
            return connected
        case #selector(reconnect(_:)):
            return spec != nil && !connected
        case #selector(cancelTransferMenu(_:)):
            return transfer != nil
        case #selector(stopMacro(_:)):
            return macro != nil || !MacroRunner.unlinked.isEmpty
        case #selector(runMacroMenu(_:)):
            return macro == nil
        case #selector(toggleLog(_:)):
            item.title = teraLog == nil ? "ログ開始…" : "ログ停止"
            return true
        default:
            return true
        }
    }

    // MARK: - ウインドウ

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard connected, spec != nil else { return true }
        let a = NSAlert()
        a.messageText = "接続中です。切断して閉じますか?"
        a.addButton(withTitle: "閉じる")
        a.addButton(withTitle: "やめる")
        a.beginSheetModal(for: sender) { r in
            if r == .alertFirstButtonReturn {
                self.disconnect(silent: true)
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // OnClose(): FileSendEnd(); ProtoEnd() → 転送中のマクロの result は 0
        transfer?.abort()
        sendFileJob?.finish()
        transferPanel?.close()
        // マクロは止めずにリンクだけ外す (Tera Term の DDE 切断。testlink 0・waitevent 2 になる)
        if let m = macro { m.sessionClosed() }
        disconnect(silent: true)
        stopLog()
        SessionWindowController.all.removeAll { $0 === self }
    }

    func windowDidResize(_ notification: Notification) { updateTitle() }
}
