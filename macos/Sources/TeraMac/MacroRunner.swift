import AppKit
import TeraCore

/// TTL マクロを別スレッドで動かし、端末ウインドウとのやりとりをつなぐ (Tera Term の ttpmacro と DDE の代わり)
final class MacroRunner: NSObject, TTLHost {
    private weak var session: SessionWindowController?
    private(set) var interp: TTLInterpreter!
    let path: String
    private var statusPanel: NSPanel?
    private var statusLabel: NSTextField?

    init(path: String, params: [String] = [], session: SessionWindowController) throws {
        self.session = session
        self.path = path
        super.init()
        interp = try TTLInterpreter(path: path, host: self, params: params)
        interp.setComReady(session.isConnected)
    }

    /// ウインドウから離れて (unlink・closett・ウインドウを閉じた) まだ動いているマクロ
    static var unlinked: [MacroRunner] = []

    func start() {
        let t = Thread { [self] in
            var err: String?
            do { try interp.run() } catch { err = "\(error)" }
            DispatchQueue.main.async {
                self.closeStatusPanel()
                self.closeMacroWindow()
                MacroRunner.unlinked.removeAll { $0 === self }
                // いまつながっているウインドウ (connect でつなぎ直したものを含む) から外す。logautoclose もここ
                self.session?.macroFinished(self, error: err)
                self.session = nil
            }
        }
        t.stackSize = 8 << 20
        t.start()
    }

    func cancel() { interp.cancelled = true }

    // MARK: - マクロウインドウ (ttpmacro の CCtrlWindow)

    private var macroWindow: NSPanel?
    private var macroWindowTimer: Timer?
    private var fileLabel: NSTextField?
    private var lineLabel: NSTextField?
    private var pauseButton: NSButton?
    private lazy var sourceLines: [String: [String]] = [:]

    /// 「マクロウインドウの表示」: ファイル名と実行中の行、「中断/開始」「終了」ボタン
    func showWindow() {
        if macroWindow == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            p.title = "MACRO - " + (path as NSString).lastPathComponent
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            let file = NSTextField(labelWithString: "")
            file.lineBreakMode = .byTruncatingTail
            let line = NSTextField(labelWithString: "")
            line.lineBreakMode = .byTruncatingTail
            line.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let pause = NSButton(title: "中断", target: self, action: #selector(togglePause(_:)))
            let end = NSButton(title: "終了", target: self, action: #selector(endMacro(_:)))
            let buttons = NSStackView(views: [pause, end])
            let stack = NSStackView(views: [file, line, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
            for v in [file, line] { v.widthAnchor.constraint(equalToConstant: 350).isActive = true }
            p.contentView = stack
            p.setContentSize(stack.fittingSize)
            if let w = session?.window { p.setFrameTopLeftPoint(NSPoint(x: w.frame.minX + 20, y: w.frame.maxY - 20)) } else { p.center() }
            macroWindow = p; fileLabel = file; lineLabel = line; pauseButton = pause
            macroWindowTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshWindow() }
        }
        refreshWindow()
        macroWindow?.deminiaturize(nil)
        macroWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshWindow() {
        let pr = interp.progress
        let file = pr.file.isEmpty ? path : pr.file
        fileLabel?.stringValue = file
        if sourceLines[file] == nil {
            sourceLines[file] = (try? String(contentsOfFile: file, encoding: .utf8))?.components(separatedBy: .newlines) ?? []
        }
        let lines = sourceLines[file] ?? []
        let text = pr.line >= 1 && pr.line <= lines.count ? lines[pr.line - 1] : ""
        lineLabel?.stringValue = ":\(pr.line):\(text)"
    }

    @objc private func togglePause(_ sender: NSButton) {
        interp.paused.toggle()
        sender.title = interp.paused ? "開始" : "中断"
    }

    @objc private func endMacro(_ sender: Any?) {
        interp.paused = false
        cancel()
    }

    func closeMacroWindow() {
        macroWindowTimer?.invalidate(); macroWindowTimer = nil
        macroWindow?.close(); macroWindow = nil
    }

    /// 端末に表示した文字 (メインスレッドから)
    func received(_ utf8: [UInt8]) { interp.feed(utf8) }

    func connectionChanged() { interp.setComReady(session?.isConnected ?? false) }

    private func onMain<T>(_ f: () -> T) -> T {
        if Thread.isMainThread { return f() }
        return DispatchQueue.main.sync(execute: f)
    }

    // MARK: - エラー

    func ttlError(message: String, line: Int, lineText: String, file: String, range: Range<Int>) -> Bool {
        onMain {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "マクロのエラー: \(message)"
            a.informativeText = "\(file) \(line) 行目\n\(lineText)"
            a.addButton(withTitle: "マクロを止める")
            a.addButton(withTitle: "続ける")
            return a.runModal() == .alertFirstButtonReturn
        }
    }

    // MARK: - 送受信

    func ttlSend(_ bytes: [UInt8], mode: TTLSendMode) {
        onMain { session?.macroSend(bytes, mode: mode) }
    }

    func ttlSendBreak() { onMain { session?.sendBreak(nil) } }

    func ttlSendKCode(_ keyCode: Int, count: Int) {
        onMain { session?.macroSendKeyCode(keyCode, count: count) }
    }

    /// sendbroadcast / sendmulticast (broadcast.cpp): 文字列として送る。ローカルエコーはしない
    func ttlSendBroadcast(_ bytes: [UInt8], multicastName: String?) {
        onMain {
            for s in SessionWindowController.all where multicastName == nil || s.multicastName == multicastName {
                s.macroSend(bytes, mode: .text, echo: false)
            }
        }
    }

    func ttlSetMulticastName(_ name: String) { onMain { session?.multicastName = name } }

    /// sendfile: 送り終わるまで待つ (IdTTLWaitCmndEnd)。マクロを止めても送信は続く
    func ttlSendFile(_ path: String, binary: Bool) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let started = onMain { session?.macroSendFile(path, binary: binary) { done.signal() } ?? false }
        if !started { return false }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            if interp.cancelled { break }
        }
        return true
    }

    func ttlRecvFile(_ path: String, binary: Bool, autoStopSec: Int) -> Bool {
        ttlRecvFileResult(path, autoStopSec: autoStopSec) == 1
    }

    /// recvfile (raw.c): 1 = 自動停止 (接続中), 0 = キャンセル・切断, nil = 始められなかった
    func ttlRecvFileResult(_ path: String, autoStopSec: Int) -> Int? {
        waitTransfer { s, done in
            s.startTransfer(.rawRecv, files: [path], binaryFlag: 1, xmodemOption: 0, autoStopSec: autoStopSec, done: done)
        }
    }

    // MARK: - 接続

    /// connect / cygconnect (ttdde.c CmdConnect: ParseParam で今の設定に重ねてから接続)。
    /// 接続を始めたら true。つながったか (result 2 / 1) は connectionChanged と ttlIsConnecting で TTL 側が待つ
    func ttlConnect(_ param: String, cygwin: Bool) -> Bool {
        onMain {
            guard let s = session else { return false }
            if cygwin { return s.connect(.shell, quiet: true) }
            let cl = TTCommandLine.parse(param)
            if let t = cl.title { s.macroTitle = t }
            if let d = cl.fileDir, FileManager.default.fileExists(atPath: d) { s.transferDir = d }
            if TTCommandLine.tokens(param).contains(where: { $0.lowercased() == "/shell" }) { return s.connect(.shell, quiet: true) }
            guard let spec = ConnectionSpec.from(cl, base: s.spec) else {
                if s.spec == nil && !s.isConnected {
                    // ホストの指定がない: Tera Term を引数なしで起動したときと同じく接続ダイアログ
                    s.connectDialogOpen = true
                    s.showConnectDialog { [weak s] in s?.connectDialogOpen = false }
                    return true
                }
                return false
            }
            var password = cl.password
            if cl.ask4passwd, case .ssh = spec {
                // /ask4passwd: パスワードを聞く (自動ログインの代わり)
                password = askPassword(spec.title)
                if password == nil { return false }
            }
            var steps: [SessionWindowController.LoginStep] = []
            if let pw = password, !pw.isEmpty, case .ssh = spec {
                if cl.auth == "publickey" {
                    // /passwd= は鍵のパスフレーズ
                    steps = [.init(prompt: "passphrase for( key)?.*:\\s*$", response: pw, regex: true)]
                } else {
                    steps = [.init(prompt: "password:", response: pw)]
                }
            }
            return s.connect(spec, password: nil, loginSteps: steps, sshArgs: ConnectionSpec.sshArguments(cl),
                             timeout: cl.timeout, telnetBinary: cl.telBin ?? false, quiet: true)
        }
    }

    private func askPassword(_ host: String) -> String? {
        let a = NSAlert()
        a.messageText = "SSH 認証"
        a.informativeText = "\(host) のパスワード"
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    /// unlink / closett のあとの connect: 新しいウインドウを開いてマクロをつなぐ (TTWinExec で ttermpro を起動)
    func ttlLinkNewWindow() -> Bool {
        onMain {
            let old = session
            let c = SessionWindowController(settings: old?.settings ?? TermSettings.load())
            c.showWindow(nil)
            if let o = old, o.macro === self { o.macroDetached(self) }
            MacroRunner.unlinked.removeAll { $0 === self }
            c.macro = self
            session = c
            return true
        }
    }

    func ttlIsConnecting() -> Bool { onMain { session?.isConnecting ?? false } }

    /// unlink: ウインドウから離れる (ウインドウはそのまま)
    func ttlUnlink() { onMain { detach() } }

    /// いまのウインドウから離れる。マクロは動き続ける (利用者が「マクロを止める」で止められるように覚えておく)
    private func detach() {
        if let s = session { s.macroDetached(self) }
        session = nil
        if !MacroRunner.unlinked.contains(where: { $0 === self }) { MacroRunner.unlinked.append(self) }
    }

    /// 端末ウインドウが閉じられた: マクロは止めずにリンクを外す (testlink 0, waitevent 2)
    func sessionClosed() {
        detach()
        interp.endLink()
    }

    /// disconnect (PostMessage なのでマクロは待たない)。確認を出すときはメインスレッドで後から
    func ttlDisconnect(confirm: Bool) {
        if confirm {
            DispatchQueue.main.async { [weak s = session] in s?.macroDisconnect(confirm: true) }
        } else {
            onMain { session?.macroDisconnect(confirm: false) }
        }
    }

    /// closett: ウインドウを閉じる (確認なし)。マクロは止めずにリンクを外す
    func ttlCloseTT() {
        onMain {
            guard let s = session else { return }
            detach()
            DispatchQueue.main.async {
                s.disconnect(silent: true)
                s.window?.close()
            }
        }
    }

    func ttlIsConnected() -> Bool { onMain { session?.isConnected ?? false } }

    // MARK: - 画面

    func ttlShowTT(_ mode: Int) {
        onMain {
            guard let sess = session, let w = sess.window else { return }
            let tek = sess.tekWindow?.window
            let log = sess.logProgressWindow?.window
            switch mode {
            case -1: w.orderOut(nil)
            case 0: w.miniaturize(nil)
            case 1: w.deminiaturize(nil); w.makeKeyAndOrderFront(nil)
            // TEK ウインドウ: 2 隠す 3 最小化 4 開く・元に戻す 5 閉じる
            case 2: tek?.orderOut(nil)
            case 3: tek?.miniaturize(nil)
            case 4: let t = sess.openTEKWindow().window; t?.deminiaturize(nil); t?.makeKeyAndOrderFront(nil)
            case 5: sess.closeTEKWindow()
            // ログ記録中ウインドウ: 6 隠す 7 最小化 8 元に戻す
            case 6: log?.orderOut(nil)
            case 7: log?.miniaturize(nil)
            case 8: log?.deminiaturize(nil); log?.orderFront(nil)
            default: break
            }
        }
    }

    func ttlSetTitle(_ s: String) { onMain { session?.macroTitle = s } }
    func ttlGetTitle() -> String { onMain { session?.titleForMacro ?? "" } }

    func ttlClearScreen(_ mode: Int) {
        onMain {
            switch mode {
            case 0: session?.clearScreen(nil)
            case 1: session?.clearBuffer(nil); session?.clearScreen(nil)
            default: break
            }
        }
    }

    func ttlDispStr(_ bytes: [UInt8]) { onMain { session?.macroDisplay(bytes) } }
    func ttlEnableKeyboard(_ on: Bool) { onMain { session?.termView.keyboardEnabled = on } }

    func ttlGetTTPos() -> [Int]? {
        onMain {
            guard let w = session?.window, let v = session?.termView else { return nil }
            let screenH = (w.screen ?? NSScreen.main)?.frame.maxY ?? 0
            let state = !w.isVisible ? 3 : (w.isMiniaturized ? 1 : (w.isZoomed ? 2 : 0))
            let f = w.frame
            let c = v.convert(v.bounds, to: nil)
            let cs = w.convertToScreen(c)
            return [state, Int(f.minX), Int(screenH - f.maxY), Int(f.width), Int(f.height),
                    Int(cs.minX), Int(screenH - cs.maxY), Int(cs.width), Int(cs.height)]
        }
    }

    func ttlCallMenu(_ id: Int) { onMain { session?.macroCallMenu(id) } }
    /// changedir: FileDir をそのまま書き換える (展開・存在確認は転送のとき)
    func ttlChangeDir(_ path: String) { onMain { session?.transferOptions.fileDir = path } }
    func ttlRestoreSetup(_ path: String) { onMain { session?.macroRestoreSetup(path) } }
    func ttlSetEcho(_ on: Bool) { onMain { session?.settings.localEcho = on } }

    // MARK: - ログ

    /// logopen (ttdde.c CmdLogOpen → FLogGetLogFilename → FLogOpen)。
    /// 名前に strftime・&h &p &u を展開し、相対パスはログのフォルダ (changedir のフォルダ、なければ書類) から
    func ttlLogOpen(_ name: String, options: TTLLogOptions) -> Bool {
        onMain {
            guard let s = session, s.teraLog == nil else { return false }
            let (h, p) = s.logHostAndPort
            let full = TeraLog.logFileName(name, logDir: s.logDirectory, host: h, port: p)
            return s.startLog(path: full, options: options)
        }
    }
    func ttlLogClose() { onMain { session?.stopLog() } }
    func ttlLogPause() { onMain { session?.logPaused = true } }
    func ttlLogStart() { onMain { session?.logPaused = false } }
    func ttlLogWrite(_ s: [UInt8]) { onMain { session?.writeLogString(s) } }
    func ttlLogInfo() -> (flags: Int, path: String)? {
        onMain { session?.teraLog.map { ($0.infoFlags, $0.path) } }
    }
    func ttlLogRotate(_ command: String) { onMain { session?.setLogRotate(command) } }
    func ttlLogAutoClose(_ on: Bool) { onMain { session?.logAutoClose = on } }

    // MARK: - ファイル転送

    func ttlTransfer(_ kind: TTLTransfer, files: [String], option: Int) -> Int? {
        let k: FileTransferKind
        var bin = 0, xopt = 0
        switch kind {
        case .xmodemSend: k = .xmodemSend; xopt = option
        case .xmodemRecv: k = .xmodemRecv; xopt = option & 0xFF; bin = option >> 8
        case .ymodemSend: k = .ymodemSend
        case .ymodemRecv: k = .ymodemRecv
        case .zmodemSend: k = .zmodemSend; bin = option
        case .zmodemRecv: k = .zmodemRecv
        case .kermitSend: k = .kermitSend
        case .kermitRecv: k = .kermitRecv
        case .kermitGet: k = .kermitGet
        case .kermitFinish: k = .kermitFinish
        case .bplusSend: k = .bplusSend
        case .bplusRecv: k = .bplusRecv
        case .quickvanSend: k = .quickvanSend
        case .quickvanRecv: k = .quickvanRecv
        }
        return waitTransfer { s, done in
            s.startTransfer(k, files: files, binaryFlag: bin, xmodemOption: xopt, done: done)
        }
    }

    /// 転送を始めて終わるまで待つ (Tera Term の IdTTLWaitCmndResult)。始められなければ nil (result は変えない)。
    /// マクロを止めても転送は止めない (Windows 版と同じ。転送パネルのキャンセルで止める)
    private func waitTransfer(_ start: (SessionWindowController, @escaping (Bool) -> Void) -> Bool) -> Int? {
        let done = DispatchSemaphore(value: 0)
        var ok = false
        let started = onMain { () -> Bool in
            guard let s = session else { return false }
            return start(s) { r in ok = r; done.signal() }
        }
        if !started { return nil }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            if interp.cancelled { return nil }
        }
        return ok ? 1 : 0
    }

    /// scpsend / scprecv: Tera Term と同じく始めたらすぐ戻る (終わるのを待たない)
    func ttlScp(send: Bool, from: String, to: String) -> Bool {
        onMain {
            guard let s = session, let args = s.scpArguments(send: send, from: from, to: to) else {
                // ttdde.c: "ttxssh.dll not support scp" と同じくエラーを出す (マクロの受信には入れない)
                let a = NSAlert()
                a.messageText = "Tera Term: scp command error"
                a.informativeText = "SCP は SSH 接続のときだけ使えます"
                a.runModal()
                return false
            }
            return s.runScp(args, label: send ? "SCP 送信" : "SCP 受信", file: from) { [weak s] ok in
                s?.macroNotice(ok ? "SCP \(send ? "送信" : "受信"): \(from) → \(to.isEmpty ? "(既定)" : to)" : "SCP に失敗しました: \(from)")
            }
        }
    }

    // MARK: - シリアル

    private func serial<T>(_ f: (SerialConnection) -> T) -> T? {
        onMain { (session?.connection as? SerialConnection).map(f) }
    }

    func ttlSetBaud(_ baud: Int) -> Bool { serial { $0.setBaud(baud) } ?? false }
    func ttlSetDTR(_ on: Bool) { _ = serial { $0.setModemLine(TIOCM_DTR, on) } }
    func ttlSetRTS(_ on: Bool) { _ = serial { $0.setModemLine(TIOCM_RTS, on) } }
    func ttlSetFlowCtrl(_ mode: Int) -> Bool { serial { $0.setFlow(mode) } ?? false }
    /// setserialdelaychar / line: シリアルなら result 1。シリアルでない・負の値なら result はそのまま (nil)
    func ttlSetSerialDelay(char: Int?, line: Int?) -> Bool? {
        serial { c -> Bool? in
            if let v = char { guard v >= 0 else { return nil }; c.charDelayMs = v; session?.settings.charDelayMs = v }
            if let v = line { guard v >= 0 else { return nil }; c.lineDelayMs = v; session?.settings.lineDelayMs = v }
            return true
        } ?? nil
    }
    func ttlGetModemStatus() -> Int? { serial { $0.modemStatus() } ?? nil }
    func ttlGetHostname() -> String? { onMain { session?.hostnameForMacro } }

    // MARK: - ダイアログ

    /// setdlgpos の位置 (メインスレッドだけで触る)
    private struct DialogPos { var x: Int; var y: Int; var position: Int; var offsetX: Int; var offsetY: Int }
    private var dialogPos: DialogPos?

    /// ダイアログを置く (ttmdlg.cpp SetDlgPosEX)。position 1〜5: 画面基準 6〜10: 端末ウインドウ基準、x / y は使わずに offset を足し、
    /// 画面からはみ出さないようにする。position なしなら x, y (左上、画面の上からの座標)。setdlgpos がなければ中央
    private func place(_ w: NSWindow) {
        guard let p = dialogPos else { w.center(); return }
        let term = session?.window
        let termUsable = term.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let screenObj = (termUsable ? term?.screen : nil) ?? NSScreen.main ?? NSScreen.screens.first
        let desk = screenObj?.visibleFrame ?? .zero
        let topY = (NSScreen.screens.first?.frame.maxY ?? desk.maxY)   // 上からの座標の基準
        let f = w.frame
        if p.position == 0 {
            w.setFrameTopLeftPoint(NSPoint(x: CGFloat(p.x), y: topY - CGFloat(p.y)))
            return
        }
        let base: NSRect
        var pos = p.position
        if pos <= 5 {
            base = desk
        } else {
            guard termUsable, let tf = term?.frame else { w.center(); return }   // 最小化・非表示なら固定位置
            base = tf
            pos -= 5
        }
        // 上からの座標で計算する
        let bx = base.minX, by = topY - base.maxY
        var nx: CGFloat, ny: CGFloat
        switch pos {
        case 1: nx = bx; ny = by
        case 2: nx = bx + base.width - f.width; ny = by
        case 3: nx = bx; ny = by + base.height - f.height
        case 4: nx = bx + base.width - f.width; ny = by + base.height - f.height
        default: nx = bx + base.width / 2 - f.width / 2; ny = by + base.height / 2 - f.height / 2
        }
        nx += CGFloat(p.offsetX)
        ny += CGFloat(p.offsetY)
        let dTop = topY - desk.maxY, dBottom = topY - desk.minY
        if nx + f.width > desk.maxX { nx = desk.maxX - f.width }
        if nx < desk.minX { nx = desk.minX }
        if ny + f.height > dBottom { ny = dBottom - f.height }
        if ny < dTop { ny = dTop }
        w.setFrameTopLeftPoint(NSPoint(x: nx, y: topY - ny))
    }

    private func runAlert(_ a: NSAlert) -> NSApplication.ModalResponse {
        a.layout()
        place(a.window)
        return a.runModal()
    }

    /// MessageBoxHaltScript: 「マクロを止めますか?」
    private func confirmHalt() -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "MACRO: confirmation"
        a.informativeText = "このマクロを止めますか?"
        a.addButton(withTitle: "はい")
        a.addButton(withTitle: "いいえ")
        a.buttons[1].keyEquivalent = "\r"
        a.buttons[0].keyEquivalent = ""
        return a.runModal() == .alertFirstButtonReturn
    }

    /// 「マクロを止める…」ボタン (Windows 版の閉じるボタン)。Esc でも押せる
    private func addHaltButton(_ a: NSAlert, esc: Bool) {
        let b = a.addButton(withTitle: "マクロを止める…")
        b.keyEquivalent = esc ? "\u{1b}" : ""
    }

    /// messagebox: 閉じる (Esc・マクロを止める…) は確認してからマクロを終わらせる (msgdlg.cpp OnClose)
    func ttlMessageBox(_ text: String, title: String) -> Bool {
        onMain {
            while true {
                let a = NSAlert()
                a.messageText = title
                a.informativeText = text
                a.addButton(withTitle: "OK")
                addHaltButton(a, esc: true)
                if runAlert(a) == .alertFirstButtonReturn { return true }
                if confirmHalt() { return false }
            }
        }
    }

    func ttlInputBox(_ text: String, title: String, defaultValue: String, secret: Bool) -> String? {
        onMain {
            var value = defaultValue
            while true {
                let a = NSAlert()
                a.messageText = title
                a.informativeText = text
                let f: NSTextField = secret ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                                            : NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                f.stringValue = value
                a.accessoryView = f
                a.addButton(withTitle: "OK")
                addHaltButton(a, esc: true)
                a.window.initialFirstResponder = f
                if runAlert(a) == .alertFirstButtonReturn { return f.stringValue }
                value = f.stringValue
                if confirmHalt() { return nil }
            }
        }
    }

    /// yesnobox: Esc は「いいえ」(OnCancel)。閉じる (マクロを止める…) は確認してから終わり
    func ttlYesNoBox(_ text: String, title: String) -> Int {
        onMain {
            while true {
                let a = NSAlert()
                a.messageText = title
                a.informativeText = text
                a.addButton(withTitle: "はい")
                let no = a.addButton(withTitle: "いいえ")
                no.keyEquivalent = "\u{1b}"
                addHaltButton(a, esc: false)
                switch runAlert(a) {
                case .alertFirstButtonReturn: return 1
                case .alertSecondButtonReturn: return 0
                default: if confirmHalt() { return -1 }
                }
            }
        }
    }

    func ttlStatusBox(_ text: String, title: String) {
        onMain {
            if statusPanel == nil {
                let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                                styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
                p.isFloatingPanel = true
                p.hidesOnDeactivate = false
                let l = NSTextField(wrappingLabelWithString: "")
                l.translatesAutoresizingMaskIntoConstraints = false
                p.contentView!.addSubview(l)
                NSLayoutConstraint.activate([
                    l.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor, constant: 16),
                    l.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor, constant: -16),
                    l.topAnchor.constraint(equalTo: p.contentView!.topAnchor, constant: 12),
                    l.bottomAnchor.constraint(equalTo: p.contentView!.bottomAnchor, constant: -12),
                ])
                statusPanel = p
                statusLabel = l
                place(p)
            }
            statusPanel?.title = title
            statusLabel?.stringValue = text
            let size = statusLabel?.sizeThatFits(NSSize(width: 400, height: 10000)) ?? .zero
            if let p = statusPanel {
                let top = p.frame.maxY
                p.setContentSize(NSSize(width: max(240, min(432, size.width + 32)), height: size.height + 24))
                p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: top))
                p.orderFront(nil)
            }
        }
    }

    private func closeStatusPanel() {
        statusPanel?.orderOut(nil)
        statusPanel = nil
        statusLabel = nil
    }

    func ttlCloseStatus() { onMain { closeStatusPanel() } }
    func ttlBringupBox() { onMain { statusPanel?.orderFrontRegardless() } }

    /// setdlgpos (メインスレッドで覚える)。開いている statusbox も動かす
    func ttlSetDialogPos(x: Int, y: Int, position: Int, offsetX: Int, offsetY: Int) {
        onMain {
            dialogPos = x == Int.min ? nil : DialogPos(x: x, y: y, position: position, offsetX: offsetX, offsetY: offsetY)
            if let p = statusPanel { place(p) }
        }
    }

    func ttlListBox(_ text: String, title: String, items: [String], selected: Int, options: TTLListBoxOptions) -> Int {
        onMain {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            // listboxsize は文字数 (ListDlg.cpp: 幅は文字の高さの半分 × 幅、高さは文字の高さ × 行数)
            let lineH = ceil(NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: NSFont.systemFontSize)))
            let w = options.size.map { CGFloat($0.0) * lineH / 2 } ?? 300
            let h = options.size.map { CGFloat($0.1) * lineH } ?? 160
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: max(200, w), height: max(80, h)))
            let table = NSTableView()
            let col = NSTableColumn(identifier: .init("item"))
            col.width = scroll.frame.width - 20
            table.addTableColumn(col)
            table.headerView = nil
            let ds = ListSource(items: items)
            table.dataSource = ds
            table.delegate = ds
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            table.reloadData()
            table.selectRowIndexes([selected], byExtendingSelection: false)
            table.scrollRowToVisible(selected)
            a.accessoryView = scroll
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1b}"
            addHaltButton(a, esc: false)
            if options.doubleClick {
                ds.onDouble = { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
                table.target = ds
                table.doubleAction = #selector(ListSource.double(_:))
            }
            a.window.initialFirstResponder = table
            while true {
                let r = runAlert(a)
                _ = ds
                switch r {
                case .alertFirstButtonReturn: return max(0, table.selectedRow)
                case .alertSecondButtonReturn: return -1
                default: if confirmHalt() { return -2 }
                }
            }
        }
    }

    func ttlFileNameBox(_ title: String, save: Bool, initialDir: String?) -> String? {
        onMain {
            let p: NSSavePanel
            if save {
                p = NSSavePanel()
            } else {
                let o = NSOpenPanel()
                o.canChooseFiles = true
                o.canChooseDirectories = false
                p = o
            }
            p.title = title
            p.message = title
            if let d = initialDir { p.directoryURL = URL(fileURLWithPath: d) }
            return p.runModal() == .OK ? p.url?.path : nil
        }
    }

    func ttlDirNameBox(_ title: String, initialDir: String?) -> String? {
        onMain {
            let o = NSOpenPanel()
            o.canChooseFiles = false
            o.canChooseDirectories = true
            o.canCreateDirectories = true
            o.title = title
            o.message = title
            if let d = initialDir { o.directoryURL = URL(fileURLWithPath: d) }
            return o.runModal() == .OK ? o.url?.path : nil
        }
    }

    // MARK: - そのほか

    func ttlGetClipboard() -> String? { onMain { NSPasteboard.general.string(forType: .string) } }

    func ttlSetClipboard(_ s: String) -> Bool {
        onMain {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(s, forType: .string)
        }
    }

    /// beep 0〜5 (MessageBeep の種類)。Mac のシステムサウンドで鳴らし分ける
    func ttlBeep(_ type: Int) {
        onMain {
            let name: String?
            switch type {
            case 1: name = "Glass"      // MB_ICONASTERISK (情報)
            case 2: name = "Funk"       // MB_ICONEXCLAMATION (警告)
            case 3: name = "Basso"      // MB_ICONHAND (エラー)
            case 4: name = "Purr"       // MB_ICONQUESTION
            default: name = nil         // 0 / 5: 既定の音
            }
            if let n = name, let s = NSSound(named: NSSound.Name(n)) { s.play() } else { NSSound.beep() }
        }
    }
    func ttlAppDirectory() -> String { Bundle.main.bundleURL.deletingLastPathComponent().path }
}

/// listbox の中身
private final class ListSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let items: [String]
    var onDouble: (() -> Void)?
    init(items: [String]) { self.items = items }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let t = NSTextField(labelWithString: items[row])
        t.lineBreakMode = .byTruncatingTail
        return t
    }
    @objc func double(_ sender: Any?) { onDouble?() }
}
