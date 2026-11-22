import AppKit
import TeraCore

// 設定メニュー (vtwin.cpp OnSetupTerminal … OnSetupLoadKeyMap と TTSSH / TTProxy の設定)

extension SessionWindowController {
    // MARK: その他の設定シート (どれも同じシートで、始めのタブだけ違う)

    @objc func setupTerminal(_ sender: Any?) { openSetupSheet(.terminal) }
    @objc func setupWindow(_ sender: Any?) { openSetupSheet(.window) }
    @objc func setupFont(_ sender: Any?) { openSetupSheet(.font) }
    @objc func setupKeyboard(_ sender: Any?) { openSetupSheet(.keyboard) }
    @objc func setupSerialPort(_ sender: Any?) { openSetupSheet(.serial) }
    @objc func setupTCPIP(_ sender: Any?) { openSetupSheet(.tcpip) }
    @objc func setupGeneral(_ sender: Any?) { openSetupSheet(.general) }
    @objc func setupAdditional(_ sender: Any?) { openSetupSheet(.general) }
    /// ファイル > ディレクトリを変更… (TT5 では全般タブの「ファイル転送のフォルダ」)
    @objc func changeDirectory(_ sender: Any?) { openSetupSheet(.general) }

    func openSetupSheet(_ page: SetupSheet.Page) {
        guard let w = window, w.attachedSheet == nil else { NSSound.beep(); return }
        // 開いたときの端末の大きさ (ウインドウで変えたあとならそれ)
        var cur = settings
        cur.cols = term.cols
        cur.rows = term.rows
        let sheet = SetupSheet(settings: cur, session: self, page: page)
        sheet.begin(on: w) { [weak self, weak sheet] s in
            guard let self = self, let s = s, let sheet = sheet else { return }
            self.applySetup(s, serial: sheet.serial, fileDir: sheet.fileDir, opened: cur)
        }
    }

    /// OK のあとの処理 (externalsetup.cpp ExternalSetupPostProcess)。opened: シートを開いたときの ts
    func applySetup(_ newSettings: TermSettings, serial: SerialParams, fileDir: String, opened: TermSettings) {
        var s = newSettings
        // フォントだけ変えたときは桁数・行数をそのままにする (ChangeFont → DispChangeWinSize)
        if s.cols == opened.cols && s.rows == opened.rows { s.cols = term.cols; s.rows = term.rows }
        let resized = s.cols != term.cols || s.rows != term.rows
        applySettings(s)
        if resized || s.fontName != opened.fontName || s.fontSize != opened.fontSize { fitWindow(cols: s.cols, rows: s.rows) }
        applyRuntimeSettings()

        // シリアル: 開いているポートにそのままかける (CommResetSerial)。ポートは変えない
        if let sc = conn as? SerialConnection {
            let old = sc.params
            var p = serial
            p.path = old.path
            if p.baud != old.baud { sc.setBaud(p.baud) }
            if p.flow != sc.flow { sc.setFlow(["xon": 1, "rts": 2, "none": 3, "dsr": 4][p.flow] ?? 3) }
            if p.dataBits != old.dataBits || p.parity != old.parity || p.stopBits != old.stopBits {
                // SerialConnection はデータ長・パリティ・ストップビットを開いたあとに変えられないので開き直す
                connect(.serial(p), quiet: true)
            }
            ConnHistory.serial = p
        } else {
            ConnHistory.serial = serial
        }
        // 新しい接続のデフォルト
        if s.portType != opened.portType { ConnHistory.lastMode = s.portType == "serial" ? "serial" : "tcp" }
        // ファイル転送のフォルダ
        transferOptions.fileDir = fileDir
        TermSettings.saveFileDir(fileDir)
        s.save()
    }

    /// TermSettings のうち、applySettings でかからないもの (ウインドウの不透明度・ベル・ブレークの長さなど)
    func applyRuntimeSettings() {
        let s = settings
        if let sc = conn as? SerialConnection { sc.breakMs = s.sendBreakTime }
        if !s.enableScrollBuff { term.scrollbackLimit = 0 }
        if !s.answerback.isEmpty { term.answerback = String(decoding: s.answerbackBytes, as: UTF8.self) }
        switch s.beep.lowercased() {
        case "off": term.onBell = {}
        case "visual": term.onBell = { [weak self] in self?.visualBell() }
        default: term.onBell = { NSSound.beep() }
        }
        updateWindowAlpha()
        installAlphaObservers()
    }

    private func visualBell() {
        guard let v = window?.contentView else { return }
        let flash = NSView(frame: v.bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        v.addSubview(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { flash.removeFromSuperview() }
    }

    func updateWindowAlpha() {
        guard let w = window else { return }
        let a = w.isKeyWindow ? settings.alphaBlendActive : settings.alphaBlendInactive
        w.alphaValue = CGFloat(max(16, min(255, a))) / 255
    }

    private static var alphaObserved = Set<ObjectIdentifier>()
    private func installAlphaObservers() {
        guard let w = window, !Self.alphaObserved.contains(ObjectIdentifier(w)) else { return }
        Self.alphaObserved.insert(ObjectIdentifier(w))
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.updateWindowAlpha() }
        }
    }

    // MARK: TTSSH / TTProxy

    @objc func sshSetup(_ sender: Any?) { if let w = sheetWindow() { SSHSetupDialog().begin(on: w) } }
    @objc func sshAuthSetup(_ sender: Any?) { if let w = sheetWindow() { SSHAuthSetupDialog().begin(on: w) } }
    @objc func sshForwardSetup(_ sender: Any?) { if let w = sheetWindow() { SSHForwardSetupDialog().begin(on: w) } }
    @objc func sshKeyGenerate(_ sender: Any?) { if let w = sheetWindow() { SSHKeyGenDialog().begin(on: w) } }
    @objc func proxySetup(_ sender: Any?) { if let w = sheetWindow() { ProxySetupDialog().begin(on: w) } }

    private func sheetWindow() -> NSWindow? {
        guard let w = window, w.attachedSheet == nil else { NSSound.beep(); return nil }
        return w
    }

    // MARK: 設定の保存 / 読み込み

    /// 設定の保存 (vtwin.cpp OnSetupSave)
    @objc func saveSetup(_ sender: Any?) {
        guard let w = sheetWindow() else { return }
        let prev = TermSettings.setupFileName
        let p = NSSavePanel()
        p.title = "Tera Term: 設定の保存"
        p.allowedFileTypes = ["ini"]
        p.allowsOtherFileTypes = true
        p.directoryURL = URL(fileURLWithPath: (prev as NSString).deletingLastPathComponent)
        p.nameFieldStringValue = (prev as NSString).lastPathComponent
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self = self, r == .OK, let url = p.url else { return }
            let path = url.path
            let fm = FileManager.default
            if fm.fileExists(atPath: path) && !fm.isWritableFile(atPath: path) {
                let a = NSAlert()
                a.messageText = "Tera Term: エラー"
                a.informativeText = "TERATERM.INI に書き込み権限がありません"
                a.beginSheetModal(for: w)
                return
            }
            // 違うファイルに保存するときは、前のファイルの内容 (知らないセクションも) を引き継ぐ
            if path != prev && !fm.fileExists(atPath: path) && fm.fileExists(atPath: prev) { try? fm.copyItem(atPath: prev, toPath: path) }
            var s = self.settings
            s.cols = self.term.cols
            s.rows = self.term.rows
            var t = self.transferOptions
            t.fileDir = self.transferOptions.fileDir
            do {
                try TeraTermIniExport.write(settings: s, transfer: t, to: path)
                TermSettings.setupFileName = path
                UserDefaults.standard.set(path, forKey: "TeraTermIniPath")
            } catch {
                let a = NSAlert()
                a.messageText = "Tera Term: エラー"
                a.informativeText = "\(path)\n\(error.localizedDescription)"
                a.beginSheetModal(for: w)
            }
        }
    }

    /// 設定の読み込み (vtwin.cpp OnSetupRestore → RestoreSetup / ResetSetup)
    @objc func restoreSetup(_ sender: Any?) {
        guard let w = sheetWindow() else { return }
        let prev = TermSettings.setupFileName
        let p = NSOpenPanel()
        p.title = "Tera Term: 設定の読み込み"
        p.allowedFileTypes = ["ini", "INI"]
        p.allowsOtherFileTypes = true
        p.directoryURL = URL(fileURLWithPath: (prev as NSString).deletingLastPathComponent)
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self = self, r == .OK, let url = p.url else { return }
            guard let data = try? Data(contentsOf: url), let ini = IniFile(data: data) else {
                let a = NSAlert()
                a.messageText = "Tera Term: エラー"
                a.informativeText = "読み込めませんでした\n\(url.path)"
                a.beginSheetModal(for: w)
                return
            }
            TermSettings.setupFileName = url.path
            UserDefaults.standard.set(url.path, forKey: "TeraTermIniPath")
            self.restoreSetup(from: ini)
        }
    }

    /// INI の内容をこのウインドウにかけ、保存する
    func restoreSetup(from ini: IniFile) {
        let opened = settings
        let r = TeraTermIniImport.read(ini, base: settings)
        TeraTermIniImport.applyConnectionDefaults(r)
        var ssh = SSHSettings.load(); ssh.read(ini); ssh.save()
        var proxy = ProxySettings.load(); proxy.read(ini); proxy.save()
        let t = FileTransferOptions(ini: ini)
        let keepFileDir = ini.string("Tera Term", "FileDir") == nil
        let fileDir = keepFileDir ? transferOptions.fileDir : t.fileDir
        transferOptions = t
        // 端末の大きさは INI の TerminalSize にする (SetupTerm)
        var s = r.settings
        if ini.ints("Tera Term", "TerminalSize") == nil { s.cols = term.cols; s.rows = term.rows }
        var forced = opened
        forced.cols = -1   // applySetup の「大きさは変えていない」判定を外す
        applySetup(s, serial: r.serial ?? ConnHistory.serial, fileDir: fileDir, opened: forced)
    }

    // MARK: 設定フォルダ

    @objc func openSetupDirectory(_ sender: Any?) {
        guard let w = sheetWindow() else { return }
        SetupDirectoryDialog(session: self).begin(on: w)
    }

    // MARK: キーマップ読み込み

    @objc func loadKeyMap(_ sender: Any?) {
        guard let w = sheetWindow() else { return }
        let cur = TermSettings.keyCnfFileName
        let p = NSOpenPanel()
        p.title = "Tera Term:キーマップの読み込み"
        p.message = "キーボード設定ファイル (*.cnf)"
        p.allowedFileTypes = ["cnf", "CNF"]
        p.directoryURL = URL(fileURLWithPath: (cur as NSString).deletingLastPathComponent)
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url else { return }
            TermSettings.keyCnfFileName = url.path
            let warnings = KeyMap.load(path: url.path)
            if let first = warnings.first {
                let a = NSAlert()
                a.messageText = "Tera Term: Error in keyboard setup file"
                a.informativeText = ([first] + warnings.dropFirst().prefix(9)).joined(separator: "\n")
                a.beginSheetModal(for: w)
            }
        }
    }

    // MARK: メニューの有効・無効 (vtwin.cpp InitMenuPopup の設定メニュー)

    /// シリアルポート… はファイル送受信中と接続中は灰色。ほかの設定メニューは nil (いつも有効)
    func validateSetupMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(setupSerialPort(_:)), #selector(serialSetup(_:)):
            return !(transfer != nil || sendFileJob != nil || isConnecting)
        default:
            return nil
        }
    }
}

// MARK: - 設定フォルダ (setupdirdlg.cpp)

final class SetupDirectoryDialog: SheetDialog, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var rows: [(String, String)] = []
    private let table = NSTableView()
    private weak var session: SessionWindowController?

    init(session: SessionWindowController) {
        self.session = session
        super.init()
    }

    func begin(on w: NSWindow) {
        panel.title = "Tera Term: 設定フォルダ"
        cancelButton.isHidden = true
        let s = session?.settings ?? TermSettings.load()
        let ssh = SSHSettings.load()
        func exp(_ p: String) -> String {
            let e = (p as NSString).expandingTildeInPath
            return e.hasPrefix("/") || e.isEmpty ? e : (AppPaths.setupDirectory as NSString).appendingPathComponent(e)
        }
        var r: [(String, String)] = [
            ("Tera Term設定ファイル", TermSettings.setupFileName),
            ("キーボード設定ファイル", TermSettings.keyCnfFileName),
            ("SSH known_hostsファイル", exp(ssh.knownHostsRW)),
        ]
        if !ssh.knownHostsRO.isEmpty { r.append(("SSH known_hostsファイル", exp(ssh.knownHostsRO))) }
        r += [
            ("CurrentDirectry", FileManager.default.currentDirectoryPath),
            ("HomeDir", AppPaths.setupDirectory),
            ("ExeDir", (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent }) ?? Bundle.main.bundlePath),
        ]
        if let d = session?.transferDir { r.append(("File Transfer Dir", d)) }
        if let d = session?.logDirectory { r.append(("LogDir(General)", d)) }
        if !s.logDefaultPath.isEmpty { r.append(("Default log save folder", exp(s.logDefaultPath))) }
        if let l = session?.logPath { r.append(("LogDir(Terminal)", (l as NSString).deletingLastPathComponent)) }
        r.append(("Broadcast history file", (AppPaths.setupDirectory as NSString).appendingPathComponent("broadcast.log")))
        rows = r

        for (id, title, wdt) in [("name", "name", 180.0), ("path", "path/file", 440.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = CGFloat(wdt)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.toolTip = "Right click to open submenu"
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.doubleAction = #selector(openFolder)
        table.target = self
        let sc = NSScrollView()
        sc.documentView = table
        sc.hasVerticalScroller = true
        sc.borderType = .bezelBorder
        sc.translatesAutoresizingMaskIntoConstraints = false
        sc.widthAnchor.constraint(equalToConstant: 640).isActive = true
        sc.heightAnchor.constraint(equalToConstant: 300).isActive = true
        layout(sc)
        present(on: w)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let f = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "name" ? rows[row].0 : rows[row].1)
        f.lineBreakMode = .byTruncatingMiddle
        return f
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard r >= 0 else { return }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rows[r].1, isDirectory: &isDir)
        let open = NSMenuItem(title: "Open file", action: exists && !isDir.boolValue ? #selector(openFile) : nil, keyEquivalent: "")
        open.target = self
        let folder = NSMenuItem(title: "Open folder (with Finder)", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        let copy = NSMenuItem(title: "Send path to clipboard", action: #selector(copyPath), keyEquivalent: "")
        copy.target = self
        menu.addItem(open); menu.addItem(folder); menu.addItem(copy)
    }

    private var targetRow: Int { table.clickedRow >= 0 ? table.clickedRow : table.selectedRow }

    @objc private func openFile() {
        let r = targetRow
        guard r >= 0 else { return }
        LogViewer.open(rows[r].1, settings: session?.settings ?? TermSettings.load())
    }
    @objc private func openFolder() {
        let r = targetRow
        guard r >= 0 else { return }
        let p = rows[r].1
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
            if isDir.boolValue { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (p as NSString).deletingLastPathComponent))
        }
    }
    @objc private func copyPath() {
        let r = targetRow
        guard r >= 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows[r].1, forType: .string)
    }

    override func ok() { close() }
    override func cancel() { close() }
}

/// ログ表示用エディタ (ViewlogEditor / ViewlogEditorArg) でファイルを開く
enum LogViewer {
    static func open(_ path: String, settings s: TermSettings) {
        let ed = (s.viewlogEditor as NSString).expandingTildeInPath
        let file = URL(fileURLWithPath: path)
        let cfg = NSWorkspace.OpenConfiguration()
        if ed.isEmpty || ed.lowercased() == "notepad.exe" || ed.hasSuffix(".app") {
            let app = ed.hasSuffix(".app") ? URL(fileURLWithPath: ed)
                : (NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: cfg, completionHandler: nil)
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ed)
            p.arguments = s.viewlogEditorArg.split(separator: " ").map(String.init) + [path]
            try? p.run()
        }
    }
}

// MARK: - KEYBOARD.CNF (ttset_keyboard.c の一部)

/// キーマップ。Tera Term のキーコード (PC のスキャンコード + 修飾キー) の割り当てを読む。
/// TerminalView から使えるよう、名前 → キーコードと [User keys] を持つ
enum KeyMap {
    struct UserKey { var keyCode: Int; var type: Int; var string: String }
    /// [セクション] の名前 → キーコード (off / 空は入れない)
    private(set) static var keys: [String: Int] = [:]
    private(set) static var userKeys: [UserKey] = []
    private(set) static var path: String?

    static let sections = ["VT editor keypad", "VT numeric keypad", "VT function keys", "X function keys", "Shortcut keys"]

    /// 読み込む。戻り値は警告 (キーコードの重複)
    @discardableResult
    static func load(path p: String) -> [String] {
        keys = [:]
        userKeys = []
        path = p
        guard let d = FileManager.default.contents(atPath: p), let ini = IniFile(data: d) else { return ["\(p) を読めません"] }
        var used: [Int: String] = [:]
        var warnings: [String] = []
        func take(_ code: Int, _ name: String) -> Bool {
            if let prev = used[code] {
                warnings.append("Keycode \(code) is used more than once")
                keys[prev] = nil   // 先のものを無効にする
            }
            used[code] = name
            return true
        }
        for sec in sections {
            for (k, v) in ini.keys(sec) {
                let t = v.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, t.lowercased() != "off", let code = Int(t) else { continue }
                if take(code, k) { keys[k] = code }
            }
        }
        for (k, v) in ini.keys("User keys") where k.lowercased().hasPrefix("user") {
            let parts = v.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map { String($0) }
            guard parts.count >= 3, let code = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            _ = take(code, k)
            userKeys.append(UserKey(keyCode: code, type: Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0, string: parts[2]))
        }
        return warnings
    }
}
