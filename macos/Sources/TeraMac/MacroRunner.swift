import AppKit
import TeraCore

/// TTL マクロを別スレッドで動かし、端末ウインドウとのやりとりをつなぐ (Tera Term の ttpmacro と DDE の代わり)
final class MacroRunner: TTLHost {
    private weak var session: SessionWindowController?
    private(set) var interp: TTLInterpreter!
    let path: String
    private var statusPanel: NSPanel?
    private var statusLabel: NSTextField?
    /// setdlgpos で決めた位置 (左上, 画面座標で上から)
    private var dialogPos: (x: Int, y: Int, position: Int?)?

    init(path: String, params: [String] = [], session: SessionWindowController) throws {
        self.session = session
        self.path = path
        interp = try TTLInterpreter(path: path, host: self, params: params)
        interp.setComReady(session.isConnected)
    }

    func start(done: @escaping (String?) -> Void) {
        let t = Thread { [self] in
            var err: String?
            do { try interp.run() } catch { err = "\(error)" }
            DispatchQueue.main.async {
                self.closeStatusPanel()
                // connect でつなぎ直したウインドウからも外す
                if self.session?.macro === self { self.session?.macro = nil }
                done(err)
            }
        }
        t.stackSize = 8 << 20
        t.start()
    }

    func cancel() { interp.cancelled = true }

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

    func ttlSendBroadcast(_ bytes: [UInt8], multicastName: String?) {
        onMain {
            for s in SessionWindowController.all where multicastName == nil || s.multicastName == multicastName {
                s.macroSend(bytes, mode: .compat)
            }
        }
    }

    func ttlSetMulticastName(_ name: String) { onMain { session?.multicastName = name } }

    func ttlSendFile(_ path: String, binary: Bool) -> Bool {
        onMain { session?.macroSendFile(path, binary: binary) ?? false }
    }

    func ttlRecvFile(_ path: String, binary: Bool, autoStopSec: Int) -> Bool {
        guard let s = session else { return false }
        guard onMain({ s.beginRecvFile(path) }) else { return false }
        // 受信が止まってから autoStopSec 秒 (0 なら止めるまで) 待つ
        while !interp.cancelled {
            Thread.sleep(forTimeInterval: 0.1)
            let (active, idle) = onMain { (s.isReceivingFile, s.recvFileIdleSeconds) }
            if !active { break }
            if autoStopSec > 0 && idle >= Double(autoStopSec) { break }
            if !onMain({ s.isConnected }) { break }
        }
        onMain { s.endRecvFile() }
        return true
    }

    // MARK: - 接続

    func ttlConnect(_ param: String, cygwin: Bool) -> Bool {
        onMain {
            guard let s = session else { return false }
            if cygwin { return s.connect(.shell) }
            let (spec, password) = MacroRunner.parseConnect(param)
            guard let sp = spec else { return false }
            return s.connect(sp, password: password)
        }
    }

    func ttlLinkNewWindow() -> Bool {
        onMain {
            let old = session
            let c = SessionWindowController(settings: old?.settings ?? TermSettings.load())
            c.showWindow(nil)
            if old?.macro === self { old?.macro = nil }
            c.macro = self
            session = c
            return true
        }
    }

    func ttlIsConnecting() -> Bool { onMain { session?.isConnecting ?? false } }

    /// connect のパラメータ (Tera Term のコマンドライン) を読む。/passwd= は自動ログインに使う
    static func parseConnect(_ param: String) -> (ConnectionSpec?, String?) {
        var password: String?
        var rest: [String] = []
        for w in param.split(separator: " ").map(String.init) {
            let l = w.lowercased()
            if l.hasPrefix("/passwd=") {
                password = String(w.dropFirst(8))
                    .replacingOccurrences(of: "@", with: " ")   // Tera Term では空白を @ で書く
            } else if l.hasPrefix("/auth=") || l.hasPrefix("/ask4passwd") || l.hasPrefix("/2") || l.hasPrefix("/ssh-") {
                continue
            } else {
                rest.append(w)
            }
        }
        return (ConnectionSpec.parse(rest.joined(separator: " ")), password)
    }

    func ttlDisconnect(confirm: Bool) { onMain { session?.disconnect() } }

    func ttlCloseTT() {
        DispatchQueue.main.async {
            self.session?.disconnect(silent: true)
            self.session?.window?.close()
        }
    }

    func ttlIsConnected() -> Bool { onMain { session?.isConnected ?? false } }

    // MARK: - 画面

    func ttlShowTT(_ mode: Int) {
        onMain {
            guard let w = session?.window else { return }
            switch mode {
            case -1: w.orderOut(nil)
            case 0: w.miniaturize(nil)
            case 1: w.deminiaturize(nil); w.makeKeyAndOrderFront(nil)
            default: break   // TEK / ログウインドウはない
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
    func ttlChangeDir(_ path: String) { onMain { session?.transferDir = path } }
    func ttlRestoreSetup(_ path: String) { onMain { session?.macroRestoreSetup(path) } }
    func ttlSetEcho(_ on: Bool) { onMain { session?.settings.localEcho = on } }

    // MARK: - ログ

    func ttlLogOpen(_ path: String, options: TTLLogOptions) -> Bool {
        onMain { session?.startLog(path: path, options: options) ?? false }
    }
    func ttlLogClose() { onMain { session?.stopLog() } }
    func ttlLogPause() { onMain { session?.logPaused = true } }
    func ttlLogStart() { onMain { session?.logPaused = false } }
    func ttlLogWrite(_ s: [UInt8]) { onMain { session?.writeLogRaw(s) } }
    func ttlLogInfo() -> String? { onMain { session?.logPath } }
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
        // 転送が終わるまで待つ (Tera Term の IdTTLWaitCmndResult)
        let done = DispatchSemaphore(value: 0)
        var ok = false
        let started = onMain {
            session?.startTransfer(k, files: files, binaryFlag: bin, xmodemOption: xopt) { r in ok = r; done.signal() } ?? false
        }
        if !started { return nil }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            if interp.cancelled { onMain { session?.cancelTransfer() } }
        }
        return ok ? 1 : 0
    }

    func ttlScp(send: Bool, from: String, to: String) -> Bool {
        guard let s = session, let args = onMain({ s.scpArguments(send: send, from: from, to: to) }) else {
            onMain { session?.macroNotice("SCP は SSH 接続のときだけ使えます") }
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let ok = p.terminationStatus == 0
        onMain { session?.macroNotice(ok ? "SCP \(send ? "送信" : "受信"): \(from) → \(to.isEmpty ? "(既定)" : to)" : "SCP に失敗しました: \(from)") }
        return ok
    }

    // MARK: - シリアル

    private func serial<T>(_ f: (SerialConnection) -> T) -> T? {
        onMain { (session?.connection as? SerialConnection).map(f) }
    }

    func ttlSetBaud(_ baud: Int) -> Bool { serial { $0.setBaud(baud) } ?? false }
    func ttlSetDTR(_ on: Bool) { _ = serial { $0.setModemLine(TIOCM_DTR, on) } }
    func ttlSetRTS(_ on: Bool) { _ = serial { $0.setModemLine(TIOCM_RTS, on) } }
    func ttlSetFlowCtrl(_ mode: Int) -> Bool { serial { $0.setFlow(mode) } ?? false }
    func ttlSetSerialDelay(char: Int?, line: Int?) -> Bool {
        serial { c -> Bool in
            if let v = char, v >= 0 { c.charDelayMs = v; session?.settings.charDelayMs = v }
            if let v = line, v >= 0 { c.lineDelayMs = v; session?.settings.lineDelayMs = v }
            return true
        } ?? false
    }
    func ttlGetModemStatus() -> Int? { serial { $0.modemStatus() } ?? nil }
    func ttlGetHostname() -> String? { onMain { session?.hostnameForMacro } }

    // MARK: - ダイアログ

    private func place(_ w: NSWindow) {
        guard let p = dialogPos else { w.center(); return }
        let screen = (session?.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let f = w.frame
        var x = CGFloat(p.x), yTop = CGFloat(p.y)
        if let pos = p.position {
            let base: NSRect = pos >= 6 ? (session?.window?.frame ?? screen) : screen
            let left = base.minX, right = base.maxX - f.width
            let topY = screen.maxY - base.maxY, bottomY = screen.maxY - base.minY - f.height
            switch pos {
            case 1, 6: x += left; yTop += topY
            case 2, 7: x += right; yTop += topY
            case 3, 8: x += left; yTop += bottomY
            case 4, 9: x += right; yTop += bottomY
            default: x += base.midX - f.width / 2; yTop += screen.maxY - base.midY - f.height / 2
            }
        }
        w.setFrameTopLeftPoint(NSPoint(x: x, y: screen.maxY - yTop))
    }

    private func runAlert(_ a: NSAlert) -> NSApplication.ModalResponse {
        a.layout()
        place(a.window)
        return a.runModal()
    }

    func ttlMessageBox(_ text: String, title: String) -> Bool {
        onMain {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.addButton(withTitle: "OK")
            return runAlert(a) == .alertFirstButtonReturn
        }
    }

    func ttlInputBox(_ text: String, title: String, defaultValue: String, secret: Bool) -> String? {
        onMain {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            let f: NSTextField = secret ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                                        : NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            f.stringValue = defaultValue
            a.accessoryView = f
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "マクロを止める")
            a.window.initialFirstResponder = f
            return runAlert(a) == .alertFirstButtonReturn ? f.stringValue : nil
        }
    }

    func ttlYesNoBox(_ text: String, title: String) -> Int {
        onMain {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.addButton(withTitle: "はい")
            a.addButton(withTitle: "いいえ")
            a.addButton(withTitle: "マクロを止める")
            switch runAlert(a) {
            case .alertFirstButtonReturn: return 1
            case .alertSecondButtonReturn: return 0
            default: return -1
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

    func ttlSetDialogPos(x: Int, y: Int, position: Int?) {
        dialogPos = x == Int.min ? nil : (x, y, position)
    }

    func ttlListBox(_ text: String, title: String, items: [String], selected: Int, options: TTLListBoxOptions) -> Int {
        onMain {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            let w = CGFloat(options.size?.0 ?? 300), h = CGFloat(options.size?.1 ?? 160)
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
            a.addButton(withTitle: "キャンセル")
            a.addButton(withTitle: "マクロを止める")
            if options.doubleClick {
                ds.onDouble = { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
                table.target = ds
                table.doubleAction = #selector(ListSource.double(_:))
            }
            a.window.initialFirstResponder = table
            let r = runAlert(a)
            _ = ds
            switch r {
            case .alertFirstButtonReturn: return max(0, table.selectedRow)
            case .alertSecondButtonReturn: return -1
            default: return -2
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

    func ttlBeep() { onMain { NSSound.beep() } }
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
