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
    private var decoder: StreamDecoder
    private var connected = false
    private var remoteTitle: String?
    private var log: FileHandle?
    private(set) var logPath: String?
    private var logAtLineStart = true
    /// マクロの logopen のオプション
    private var logOptions = TTLLogOptions()
    private var logStarted = Date()
    private var connectedAt = Date()
    var logPaused = false
    var logAutoClose = false
    private var logRotateSize = 0
    private var logRotateCount = 1
    // マクロ用
    var multicastName = ""
    var macroTitle: String? { didSet { updateTitle() } }
    var transferDir: String?
    /// ファイル転送 (XMODEM / ZMODEM など)。動いている間は受信したデータをこちらに渡す
    private(set) var transfer: FileTransfer?
    /// Tera Term の TERATERM.INI にあたる転送の設定 (マクロの指定がつぎの転送にも残る)
    var transferOptions = FileTransferOptions()
    private var recvFile: FileHandle?
    private var recvFileLast = Date()
    /// 自動ログイン: プロンプトが出たら順に答える (TeraTerm Menu の自動ログイン)
    struct LoginStep { var prompt: String; var response: String }
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
        if spec != nil && !connected { t += " (切断)" }
        window?.title = "\(t) - Tera Term Mac \(term.cols)x\(term.rows)"
        window?.tab.title = remoteTitle ?? spec?.title ?? "未接続"
    }

    // MARK: - 接続

    func showConnectDialog() {
        guard let w = window else { return }
        let dlg = ConnectDialog()
        dlg.begin(on: w) { [weak self] spec, password in
            guard let self = self, let spec = spec else { return }
            self.connect(spec, password: password)
        }
    }

    @discardableResult
    func connect(_ spec: ConnectionSpec, password: String? = nil, loginSteps steps: [LoginStep] = []) -> Bool {
        disconnect(silent: true)
        self.spec = spec
        remoteTitle = nil
        let c = makeConnection(spec, cols: term.cols, rows: term.rows)
        if let sc = c as? SerialConnection { sc.charDelayMs = settings.charDelayMs; sc.lineDelayMs = settings.lineDelayMs }
        c.onData = { [weak self] b in self?.received(b) }
        c.onClose = { [weak self, weak c] msg in
            guard let self = self, c === self.conn else { return }
            self.connected = false
            self.conn = nil
            self.notice(msg.map { "切断されました: \($0)" } ?? "切断されました")
            self.updateTitle()
            self.macro?.connectionChanged()
            if self.logAutoClose { self.stopLog() }
        }
        if let tcp = c as? TCPConnection {
            tcp.onConnected = { [weak self] in self?.notice("\(spec.title) に接続しました") }
            notice("\(spec.title) に接続しています…")
        }
        loginSteps = steps
        if let pw = password, !pw.isEmpty, steps.isEmpty { loginSteps = [LoginStep(prompt: "password:", response: pw)] }
        recentOutput = ""
        do {
            try c.start()
        } catch {
            notice(error.localizedDescription)
            let a = NSAlert()
            a.messageText = "接続できませんでした"
            a.informativeText = error.localizedDescription
            if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
            updateTitle()
            return false
        }
        conn = c
        connected = true
        connectedAt = Date()
        macro?.connectionChanged()
        if case .serial(let p) = spec { notice("\(p.path) を開きました (\(p.baud) bps, \(p.dataBits)\(p.parity.prefix(1).uppercased())\(p.stopBits), フロー制御: \(p.flow))") }
        updateTitle()
        return true
    }

    var isConnected: Bool { connected }
    /// 接続を始めたが、まだつながっていない (TCP の名前解決中など)
    var isConnecting: Bool { false }

    func disconnect(silent: Bool = false) {
        guard let c = conn else { return }
        conn = nil
        connected = false
        c.close()
        if !silent { notice("切断しました") }
        updateTitle()
        macro?.connectionChanged()
        if logAutoClose { stopLog() }
    }

    /// 端末に案内を出す (相手には送らない)
    private func notice(_ s: String) {
        let prefix = term.cx == 0 ? "" : "\r\n"
        term.feed(prefix + "\u{1B}[0;36m[\(s)]\u{1B}[0m\r\n")
        termView.dataArrived()
    }

    // MARK: - 受信

    private func received(_ bytes: [UInt8]) {
        if let t = transfer, t.isRunning {
            t.feed(bytes)
            return
        }
        if let f = recvFile {
            f.write(Data(bytes))
            recvFileLast = Date()
            return
        }
        if !logOptions.plainText || logOptions.binary { writeLog(bytes) }
        let s = decoder.decode(bytes)
        guard !s.isEmpty else { return }
        term.feed(s)
        termView.dataArrived()
        if let step = loginSteps.first {
            recentOutput = String((recentOutput + s).suffix(300))
            let tail = recentOutput.lowercased().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let prompt = step.prompt.lowercased().trimmingCharacters(in: .whitespaces)
            var hit = !prompt.isEmpty && tail.hasSuffix(prompt)
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

    func sendBytes(_ b: [UInt8], echo: Bool) {
        guard !b.isEmpty else { return }
        guard let c = conn else {
            if echo && spec != nil && !connected && b == settings.sendNewlineBytes {
                // 切断中に Enter で再接続 (Tera Term の「自動再接続」に近い動き)
                if let sp = spec { connect(sp) }
            }
            return
        }
        c.write(b)
        if echo && settings.localEcho {
            var d = StreamDecoder(encoding: settings.encoding)
            var shown = d.decode(b)
            if b == settings.sendNewlineBytes { shown = "\r\n" }
            term.feed(shown)
            termView.dataArrived()
        }
    }

    // MARK: - ログ

    func startLog(path: String, append: Bool = true) -> Bool {
        var o = TTLLogOptions()
        o.append = append
        o.binary = true
        o.timestamp = settings.logTimestamp
        return startLog(path: path, options: o)
    }

    /// マクロの logopen (Tera Term のオプション付き)
    func startLog(path: String, options o: TTLLogOptions) -> Bool {
        let append = o.append
        stopLog()
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) || !append { fm.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return false }
        if append { h.seekToEndOfFile() }
        log = h
        logPath = path
        logAtLineStart = true
        logOptions = o
        logPaused = false
        logStarted = Date()
        if o.includeScreenBuffer {
            let text = term.scrollbackText + term.screenText
            writeLogRaw(Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        }
        return true
    }

    func stopLog() {
        log?.closeFile()
        log = nil
        logPath = nil
        logOptions = TTLLogOptions()
        logPaused = false
    }

    /// logwrite: そのまま書く
    func writeLogRaw(_ b: [UInt8]) {
        guard let h = log, !logPaused else { return }
        h.write(Data(b))
        rotateLogIfNeeded()
    }

    /// logrotate size N / rotate N / halt
    func setLogRotate(_ command: String) {
        let p = command.split(separator: " ")
        switch p.first {
        case "size": logRotateSize = Int(p.last ?? "") ?? 0
        case "rotate": logRotateCount = max(1, Int(p.last ?? "") ?? 1)
        default: logRotateSize = 0
        }
    }

    private func rotateLogIfNeeded() {
        guard logRotateSize > 0, let h = log, let path = logPath else { return }
        guard h.offsetInFile >= UInt64(logRotateSize) else { return }
        h.closeFile()
        let fm = FileManager.default
        try? fm.removeItem(atPath: "\(path).\(logRotateCount)")
        if logRotateCount > 1 {
            for i in stride(from: logRotateCount - 1, through: 1, by: -1) {
                try? fm.moveItem(atPath: "\(path).\(i)", toPath: "\(path).\(i + 1)")
            }
        }
        try? fm.moveItem(atPath: path, toPath: "\(path).1")
        fm.createFile(atPath: path, contents: nil)
        log = FileHandle(forWritingAtPath: path)
        logAtLineStart = true
    }

    private static let tsFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "[yyyy-MM-dd HH:mm:ss.SSS] "
        return f
    }()

    private func logTimestampText() -> [UInt8] {
        switch logOptions.timestampType {
        case 1:
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "[yyyy-MM-dd HH:mm:ss.SSS UTC] "
            return Array(f.string(from: Date()).utf8)
        case 2, 3:
            let t = Date().timeIntervalSince(logOptions.timestampType == 2 ? logStarted : connectedAt)
            let ms = Int(t * 1000)
            return Array(String(format: "[%d %02d:%02d:%02d.%03d] ", ms / 86_400_000, ms / 3_600_000 % 24, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000).utf8)
        default:
            return Array(SessionWindowController.tsFormat.string(from: Date()).utf8)
        }
    }

    private func writeLog(_ bytes: [UInt8]) {
        guard let h = log, !logPaused else { return }
        if !logOptions.timestamp {
            h.write(Data(bytes))
            rotateLogIfNeeded()
            return
        }
        var out = Data()
        let ts = logTimestampText()
        for b in bytes {
            if logAtLineStart { out.append(contentsOf: ts); logAtLineStart = false }
            out.append(b)
            if b == 0x0A { logAtLineStart = true }
        }
        h.write(out)
        rotateLogIfNeeded()
    }

    /// 端末に表示した文字 (エスケープシーケンスなし)。マクロと、プレーンテキストのログへ
    private func macroText(_ b: [UInt8]) {
        macro?.received(b)
        if log != nil && logOptions.plainText && !logOptions.binary { writeLog(b) }
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
        if log != nil {
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
            m.start { [weak self] err in
                guard let self = self else { return }
                self.macro = nil
                self.setStatus(nil)
                self.termView.keyboardEnabled = true
                if let e = err {
                    self.notice("マクロのエラーで止めました: \(e)")
                } else {
                    self.notice("マクロ終了")
                }
            }
        } catch {
            let a = NSAlert()
            a.messageText = "マクロを読めませんでした"
            a.informativeText = "\(error)"
            a.beginSheetModal(for: window!)
        }
    }


    // MARK: - マクロから使う

    /// send / sendtext / sendbinary
    func macroSend(_ b: [UInt8], mode: TTLSendMode) {
        var binary = mode == .binary
        if mode == .compat {
            // Tera Term と同じ判定: CR/LF 以外の制御文字 (最後の 1 バイトは除く) があるか、UTF-8 として読めなければバイナリ
            if b.dropLast().contains(where: { $0 < 0x20 && $0 != 0x0D && $0 != 0x0A }) { binary = true }
            if String(bytes: b, encoding: .utf8) == nil { binary = true }
        }
        if binary {
            sendBytes(b, echo: settings.localEcho ? true : false)
            return
        }
        let text = String(decoding: b, as: UTF8.self)
        var out: [UInt8] = []
        for (i, part) in text.components(separatedBy: "\r").enumerated() {
            if i > 0 { out += settings.sendNewlineBytes }
            out += settings.encoding.encode(part)
        }
        sendBytes(out, echo: true)
    }

    /// sendkcode: よく使うキーだけ (Tera Term の IBM PC キーコード)
    func macroSendKeyCode(_ code: Int, count: Int) {
        let map: [Int: [UInt8]] = [
            328: [0x1B, 0x5B, 0x41], 336: [0x1B, 0x5B, 0x42], 333: [0x1B, 0x5B, 0x43], 331: [0x1B, 0x5B, 0x44],
            28: [0x0D], 14: [0x08], 15: [0x09], 1: [0x1B], 339: [0x7F],
            59: [0x1B, 0x4F, 0x50], 60: [0x1B, 0x4F, 0x51], 61: [0x1B, 0x4F, 0x52], 62: [0x1B, 0x4F, 0x53],
        ]
        guard let seq = map[code] else { notice("sendkcode \(code) にはまだ対応していません"); return }
        for _ in 0..<max(1, count) { sendBytes(seq, echo: false) }
    }

    func macroSendFile(_ path: String, binary: Bool) -> Bool {
        guard let d = FileManager.default.contents(atPath: path) else { return false }
        if binary {
            sendBytes([UInt8](d), echo: false)
        } else {
            macroSend(Array(String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r").utf8), mode: .text)
        }
        return true
    }

    func beginRecvFile(_ path: String) -> Bool {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return false }
        recvFile = h
        recvFileLast = Date()
        return true
    }
    var isReceivingFile: Bool { recvFile != nil }
    var recvFileIdleSeconds: Double { Date().timeIntervalSince(recvFileLast) }
    func endRecvFile() { recvFile?.closeFile(); recvFile = nil }

    /// dispstr: 受信したように画面に出す (相手には送らない)
    func macroDisplay(_ b: [UInt8]) {
        let saved = term.onMacroText
        term.onMacroText = nil
        term.feed(String(decoding: b, as: UTF8.self))
        term.onMacroText = saved
        termView.dataArrived()
    }

    func macroNotice(_ s: String) { notice(s) }

    /// ファイル転送を始める。終わったら done(成功したか)
    func startTransfer(_ kind: FileTransferKind, files: [String], binaryFlag: Int, xmodemOption: Int,
                       done: @escaping (Bool) -> Void) -> Bool {
        guard connected, transfer == nil else { return false }
        transferOptions.applyMacroParameters(kind: kind, binaryFlag: binaryFlag, xmodemOption: xmodemOption)
        if case .serial(let p)? = spec { transferOptions.isTCPIP = false; transferOptions.baudRate = p.baud } else { transferOptions.isTCPIP = true }
        let dir = transferDir ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        let t = FileTransfer(kind: kind, files: files, receiveDir: dir, options: transferOptions) { [weak self] b in
            self?.conn?.write(b)
        }
        t.onMessage = { [weak self] m in self?.notice(m) }
        t.onFinish = { [weak self] ok in
            guard let self = self else { return }
            self.transfer = nil
            self.notice("\(kind.title): \(ok ? "完了しました" : "失敗しました")")
            done(ok)
        }
        transfer = t
        notice("\(kind.title) を始めます\(files.isEmpty ? "" : ": " + files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
        if !t.start() {
            transfer = nil
            notice("\(kind.title) を始められませんでした")
            return false
        }
        return true
    }

    func cancelTransfer() { transfer?.cancel() }

    var titleForMacro: String { window?.title ?? "" }

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

    /// callmenu: Tera Term のメニュー番号
    func macroCallMenu(_ id: Int) {
        let actions: [Int: () -> Void] = [
            50110: { self.newConnection(nil) }, 50003: { self.newConnection(nil) },
            50111: { self.duplicateSession(nil) }, 50010: { self.duplicateSession(nil) },
            50120: { self.toggleLog(nil) }, 50125: { self.stopLog() }, 50124: { self.logPaused.toggle() },
            50130: { self.sendFile(nil) },
            50190: { self.disconnect() }, 50009: { self.disconnect() },
            50199: { self.window?.performClose(nil) }, 50005: { self.window?.performClose(nil) },
            50200: { NSApp.terminate(nil) },
            50210: { self.termView.copy(nil) }, 50002: { self.termView.copy(nil) },
            50230: { self.termView.paste(nil) }, 50008: { self.termView.paste(nil) },
            50250: { self.clearScreen(nil) }, 50260: { self.clearBuffer(nil) },
            50280: { self.termView.selectAll(nil) }, 50290: { self.termView.selectAll(nil) },
            50310: { self.showTerminalSetup(nil) }, 50350: { self.serialSetup(nil) },
            50410: { self.resetTerminal(nil) }, 50430: { self.sendBreak(nil) }, 50001: { self.sendBreak(nil) },
            50470: { self.runMacroMenu(nil) },
        ]
        if let f = actions[id] { f() } else { notice("callmenu \(id) にはまだ対応していません") }
    }

    /// restoresetup: TERATERM.INI を読み込んでこのウインドウに使う
    func macroRestoreSetup(_ path: String) {
        guard let d = FileManager.default.contents(atPath: path), let ini = IniFile(data: d) else { return }
        let r = TeraTermIniImport.read(ini, base: settings)
        applySettings(r.settings)
    }

    @objc func stopMacro(_ sender: Any?) { macro?.cancel() }

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
        case #selector(stopMacro(_:)):
            return macro != nil
        case #selector(runMacroMenu(_:)):
            return macro == nil
        case #selector(toggleLog(_:)):
            item.title = log == nil ? "ログ開始…" : "ログ停止"
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
        macro?.cancel()
        disconnect(silent: true)
        stopLog()
        SessionWindowController.all.removeAll { $0 === self }
    }

    func windowDidResize(_ notification: Notification) { updateTitle() }
}
