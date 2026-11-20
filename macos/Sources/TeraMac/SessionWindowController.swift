import AppKit
import TeraCore

/// 1 つのウインドウ = 1 つの接続
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    let term: Terminal
    let termView: TerminalView
    var settings: TermSettings
    private(set) var spec: ConnectionSpec?
    private var conn: Connection?
    private var decoder: StreamDecoder
    private var connected = false
    private var remoteTitle: String?
    private var log: FileHandle?
    private(set) var logPath: String?
    private var logAtLineStart = true
    private var pendingPassword: String?
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
        var t = remoteTitle ?? spec?.title ?? "未接続"
        if spec != nil && !connected { t += " (切断)" }
        window?.title = "\(t) - TeraMac \(term.cols)x\(term.rows)"
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
    func connect(_ spec: ConnectionSpec, password: String? = nil) -> Bool {
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
        }
        if let tcp = c as? TCPConnection {
            tcp.onConnected = { [weak self] in self?.notice("\(spec.title) に接続しました") }
            notice("\(spec.title) に接続しています…")
        }
        pendingPassword = (password?.isEmpty ?? true) ? nil : password
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
        if case .serial(let p) = spec { notice("\(p.path) を開きました (\(p.baud) bps, \(p.dataBits)\(p.parity.prefix(1).uppercased())\(p.stopBits), フロー制御: \(p.flow))") }
        updateTitle()
        return true
    }

    var isConnected: Bool { connected }

    func disconnect(silent: Bool = false) {
        guard let c = conn else { return }
        conn = nil
        connected = false
        c.close()
        if !silent { notice("切断しました") }
        updateTitle()
    }

    /// 端末に案内を出す (相手には送らない)
    private func notice(_ s: String) {
        let prefix = term.cx == 0 ? "" : "\r\n"
        term.feed(prefix + "\u{1B}[0;36m[\(s)]\u{1B}[0m\r\n")
        termView.dataArrived()
    }

    // MARK: - 受信

    private func received(_ bytes: [UInt8]) {
        writeLog(bytes)
        let s = decoder.decode(bytes)
        guard !s.isEmpty else { return }
        term.feed(s)
        termView.dataArrived()
        macro?.received(s)
        if let pw = pendingPassword {
            recentOutput = String((recentOutput + s).suffix(200))
            let low = recentOutput.lowercased()
            if low.range(of: "password:\\s*$", options: .regularExpression) != nil ||
                low.range(of: "パスワード.*[:：]\\s*$", options: .regularExpression) != nil {
                pendingPassword = nil
                sendBytes(settings.encoding.encode(pw) + [0x0D], echo: false)
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
        stopLog()
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) || !append { fm.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return false }
        if append { h.seekToEndOfFile() }
        log = h
        logPath = path
        logAtLineStart = true
        return true
    }

    func stopLog() {
        log?.closeFile()
        log = nil
        logPath = nil
    }

    private static let tsFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "[yyyy-MM-dd HH:mm:ss.SSS] "
        return f
    }()

    private func writeLog(_ bytes: [UInt8]) {
        guard let h = log else { return }
        if !settings.logTimestamp {
            h.write(Data(bytes))
            return
        }
        var out = Data()
        let ts = Array(SessionWindowController.tsFormat.string(from: Date()).utf8)
        for b in bytes {
            if logAtLineStart { out.append(contentsOf: ts); logAtLineStart = false }
            out.append(b)
            if b == 0x0A { logAtLineStart = true }
        }
        h.write(out)
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

    func runMacro(url: URL) {
        guard macro == nil else { NSSound.beep(); return }
        guard let data = try? Data(contentsOf: url) else { return }
        let src = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) ?? ""
        do {
            let m = try MacroRunner(source: src, session: self, baseDir: url.deletingLastPathComponent())
            macro = m
            notice("マクロ開始: \(url.lastPathComponent)")
            m.start { [weak self] err in
                guard let self = self else { return }
                self.macro = nil
                self.setStatus(nil)
                if let e = err {
                    self.notice("マクロのエラー: \(e)")
                    let a = NSAlert()
                    a.messageText = "マクロのエラー"
                    a.informativeText = "\(url.lastPathComponent)\n\(e)"
                    a.beginSheetModal(for: self.window!)
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
