import AppKit
import TeraCore

/// コマンドのブロードキャスト (broadcast.cpp)。モードレスで 1 つだけ。
/// リアルタイム: 入力欄で押したキーを、選んだウインドウにそのまま送る (送り先のキーボード入力として扱う)。
/// リアルタイムでないとき: 「送信」で入力欄の文字を選んだウインドウに送る (受け取る側は AcceptBroadcast のときだけ送信)
final class BroadcastWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSComboBoxDelegate {
    static var shared: BroadcastWindow?

    private let panel: NSPanel
    private weak var parent: SessionWindowController?
    private let combo = NSComboBox()
    private let realtime = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_BROADCAST_REALTIME", "リアルタイム"), target: nil, action: nil)
    private let history = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_BROADCAST_HISTORY", "ヒストリ"), target: nil, action: nil)
    private let crlf = NSButton(radioButtonWithTitle: "CRLF", target: nil, action: nil)
    private let cr = NSButton(radioButtonWithTitle: "CR", target: nil, action: nil)
    private let lf = NSButton(radioButtonWithTitle: "LF", target: nil, action: nil)
    private let enterKey = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_BROADCAST_ENTER", "Enterキー"), target: nil, action: nil)
    // 本家は「このプロセスのみに送信」。Mac 版はウインドウ単位なので別の文言
    private let parentOnly = NSButton(checkboxWithTitle: Lang.m("MENU_BROADCAST_PARENTONLY", "このウィンドウのみに送信"), target: nil, action: nil)
    private let submitLabel = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_BROADCAST_SUBMIT_KEY_LABEL", "送信キー") + ":")
    private let submitKey = NSPopUpButton()
    private let table = NSTableView()
    private var windows: [SessionWindowController] = []
    private var selected: Set<ObjectIdentifier> = []
    private var timer: Timer?
    private var keyMonitor: Any?

    private static let d = UserDefaults.standard

    static func show(from session: SessionWindowController) {
        if let b = shared {
            b.panel.makeKeyAndOrderFront(nil)
            return
        }
        let b = BroadcastWindow(parent: session)
        shared = b
        b.panel.makeKeyAndOrderFront(nil)
        b.panel.makeFirstResponder(b.combo)
    }

    private init(parent: SessionWindowController) {
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 230),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = Lang.t("Tera Term", "DLG_BROADCAST_TITLE", "Tera Term: コマンドのブロードキャスト")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        build()
        // 親ウインドウのすぐ上 (左をそろえる)
        if let w = parent.window, let screen = w.screen?.visibleFrame {
            var y = w.frame.maxY
            if y + panel.frame.height > screen.maxY { y = screen.maxY - panel.frame.height }
            panel.setFrameOrigin(NSPoint(x: w.frame.minX, y: y))
        } else {
            panel.center()
        }
        panel.minSize = NSSize(width: panel.frame.width * 0.4, height: panel.frame.height * 0.5)
        reloadWindows()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollWindows() }
        installKeyMonitor()
    }

    private func build() {
        combo.translatesAutoresizingMaskIntoConstraints = false
        combo.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        combo.delegate = self
        combo.completes = false
        loadHistory()
        let send = NSButton(title: Lang.t("Tera Term", "DLG_BROADCAST_SUBMIT", "送信"), target: self, action: #selector(submit(_:)))
        let close = NSButton(title: Lang.t("Tera Term", "DLG_BROADCAST_CLOSE", "閉じる"), target: self, action: #selector(closePanel(_:)))
        close.keyEquivalent = "\u{1B}"

        realtime.state = .on
        history.state = BroadcastWindow.d.bool(forKey: "broadcastCommandHistory") ? .on : .off
        enterKey.state = .on
        for b in [realtime, enterKey, crlf, cr, lf] { b.target = self }
        realtime.action = #selector(updateEnabled)
        enterKey.action = #selector(updateEnabled)
        for r in [crlf, cr, lf] { r.action = #selector(newlineChanged(_:)) }
        switch parent?.settings.sendNewline ?? "CR" {
        case "CRLF": crlf.state = .on
        case "LF": lf.state = .on
        default: cr.state = .on
        }
        submitKey.addItems(withTitles: ["None", "Enter", "Ctrl+M"])
        submitKey.selectItem(withTitle: BroadcastWindow.d.string(forKey: "broadcastSubmitKey") ?? "None")
        submitKey.target = self
        submitKey.action = #selector(submitKeyChanged)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("t"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        func tt(_ key: String, _ def: String) -> String { Lang.t("Tera Term", key, def) }
        let selectAll = tt("CMENU_BROADCAST_SELECT_ALL", "すべて選択") + " / " + tt("CMENU_BROADCAST_UNSELECT_ALL", "すべて選択解除")
        for (t, a) in [(tt("CMENU_BROADCAST_FOREGROUND", "選択ウィンドウを前面へ"), #selector(bringFront)),
                       (tt("CMENU_BROADCAST_MINIMIZE", "選択ウィンドウを最小化"), #selector(minimizeSelected)),
                       (selectAll, #selector(toggleAll)), (tt("CMENU_BROADCAST_INVERSE", "選択状態を反転"), #selector(invertSelection)),
                       (tt("CMENU_BROADCAST_REFRESH", "ウィンドウ一覧の更新"), #selector(refreshList))] {
            let it = NSMenuItem(title: t, action: a, keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let top = NSStackView(views: [combo, send, close])
        let nl = NSStackView(views: [crlf, cr, lf])
        let nlBox = NSBox()
        nlBox.title = Lang.m("MENU_BROADCAST_NEWLINE", "改行")
        nlBox.contentView = nl
        let options = NSStackView(views: [realtime, history, nlBox, enterKey, parentOnly, NSStackView(views: [submitLabel, submitKey])])
        options.orientation = .vertical
        options.alignment = .leading
        let body = NSStackView(views: [options, scroll])
        body.alignment = .top
        body.distribution = .fill
        let root = NSStackView(views: [top, body])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.contentView = root
        panel.setContentSize(root.fittingSize)
        updateEnabled()
    }

    /// リアルタイムなら、ほかのオプションは使えない
    @objc private func updateEnabled() {
        let rt = realtime.state == .on
        for c in [history, enterKey, parentOnly, submitKey] as [NSControl] { c.isEnabled = !rt }
        submitLabel.textColor = rt ? .disabledControlTextColor : .labelColor
        for r in [crlf, cr, lf] { r.isEnabled = !rt && enterKey.state == .on }
    }

    /// 改行のラジオは、このウインドウの送信の改行コード (Setup > 端末) もすぐ変える
    @objc private func newlineChanged(_ sender: NSButton) {
        guard let p = parent else { return }
        var s = p.settings
        s.sendNewline = sender === crlf ? "CRLF" : (sender === lf ? "LF" : "CR")
        p.applySettings(s)
    }

    @objc private func submitKeyChanged() {
        BroadcastWindow.d.set(submitKey.titleOfSelectedItem ?? "None", forKey: "broadcastSubmitKey")
    }

    // MARK: - 送り先の一覧

    private func reloadWindows() {
        windows = SessionWindowController.all
        table.reloadData()
        var idx = IndexSet()
        for (i, w) in windows.enumerated() where selected.contains(ObjectIdentifier(w)) { idx.insert(i) }
        table.selectRowIndexes(idx, byExtendingSelection: false)
    }

    private func pollWindows() {
        if SessionWindowController.all.count != windows.count { reloadWindows() } else { table.reloadData() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { windows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let l = NSTextField(labelWithString: windows[row].window?.title ?? "")
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selected = Set(table.selectedRowIndexes.compactMap { $0 < windows.count ? ObjectIdentifier(windows[$0]) : nil })
    }

    private var targets: [SessionWindowController] {
        table.selectedRowIndexes.compactMap { $0 < windows.count ? windows[$0] : nil }
    }

    @objc private func bringFront() { targets.forEach { $0.window?.orderFront(nil) }; panel.makeFirstResponder(combo) }
    @objc private func minimizeSelected() { targets.forEach { $0.window?.miniaturize(nil) } }
    @objc private func toggleAll() {
        if table.selectedRowIndexes.isEmpty { table.selectAll(nil) } else { table.deselectAll(nil) }
    }
    @objc private func invertSelection() {
        var idx = IndexSet()
        for i in 0..<windows.count where !table.selectedRowIndexes.contains(i) { idx.insert(i) }
        table.selectRowIndexes(idx, byExtendingSelection: false)
    }
    @objc private func refreshList() { reloadWindows() }

    // MARK: - リアルタイム: 入力欄のキーを送り先のウインドウへ

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]) { [weak self] e in
            guard let self = self, e.window === self.panel else { return e }
            if e.type != .keyDown { return self.handleMouse(e) }
            let editing = self.panel.firstResponder is NSText && (self.panel.firstResponder as? NSText)?.delegate === self.combo
            guard editing else { return e }
            if self.realtime.state == .on {
                // Shift+Insert (BroadcastEditProc WM_KEYDOWN: intercept Shift-INS) と ⌘V は送り先へ貼り付け (SendCB)
                let flags = e.modifierFlags.intersection([.shift, .control, .option, .command])
                if (e.keyCode == 114 && flags == .shift) || (flags == .command && e.charactersIgnoringModifiers?.lowercased() == "v") {
                    self.pasteToTargets()
                    return nil
                }
                if e.modifierFlags.contains(.command) { return e }   // ほかの ⌘ の操作は入力欄で
                // IME で変換中: 入力欄 (BroadcastFieldEditor) に渡す。確定した文字は insertText で送り先へ (WM_IME_COMPOSITION)
                if self.fieldEditor.hasMarkedText() { return e }
                // 文字のキー (修飾なし・Shift だけ) も入力欄に渡して IME を通す。制御キーなどはそのまま送り先のキー入力に
                if BroadcastWindow.isTextKey(e) { return e }
                for t in self.targets { t.termView.keyDown(with: e) }
                if e.keyCode == 36 || e.keyCode == 76 { self.combo.stringValue = "" }
                return nil
            }
            // 送信キー: Enter / Ctrl+M で「送信」
            let key = self.submitKey.titleOfSelectedItem ?? "None"
            let isEnter = (e.keyCode == 36 || e.keyCode == 76) && !e.modifierFlags.contains(.control)
            let isCtrlM = e.modifierFlags.contains(.control) && e.charactersIgnoringModifiers?.lowercased() == "m"
            if (key == "Enter" && isEnter) || (key == "Ctrl+M" && isCtrlM) {
                self.submit(nil)
                return nil
            }
            return e
        }
    }

    /// リアルタイムのとき、入力欄での右クリック・中クリックは送り先へ貼り付け (BroadcastEditProc WM_RBUTTONUP / WM_MBUTTONUP)。
    /// DisablePasteMouseRButton / DisablePasteMouseMButton (CPF_DISABLE_RBUTTON / CPF_DISABLE_MBUTTON) なら何もしない
    private func handleMouse(_ e: NSEvent) -> NSEvent? {
        guard realtime.state == .on else { return e }
        let p = combo.convert(e.locationInWindow, from: nil)
        guard combo.bounds.contains(p) else { return e }
        let isRight = e.type == .rightMouseDown || e.type == .rightMouseUp
        if !isRight && e.buttonNumber != 2 { return e }
        let disabled = isRight ? !(parent?.settings.rightClickPaste ?? true) : (parent?.settings.disablePasteMouseMButton ?? true)
        if (e.type == .rightMouseUp || e.type == .otherMouseUp) && !disabled { pasteToTargets() }
        return nil   // WM_RBUTTONDOWN / WM_MBUTTONDOWN も入力欄には渡さない (コンテキストメニューを出さない)
    }

    /// SendCB: クリップボードの文字を CBPreparePaste(dlg, FALSE, FALSE, FALSE) で整え、選んだウインドウに文字として送る。
    /// 改行の確認は各ウインドウではなくこのダイアログで行う (5.3)
    private func pasteToTargets() {
        guard var s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
        let st = parent?.settings ?? TermSettings.load()
        if st.trimTrailingNLOnPaste {   // CPF_TRIM_TRAILING_NL
            while let c = s.last, c == "\r" || c == "\n" || c == "\r\n" { s.removeLast() }
        }
        // CheckClipboardContentW (AddCR = FALSE)
        if st.confirmChangePaste {
            var confirm = s.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" })
            if !confirm, let words = st.confirmChangePasteWords() { confirm = words.contains { s.contains($0) } }
            if confirm {
                let f = combo.convert(combo.bounds, to: nil)
                let near = panel.convertPoint(toScreen: NSPoint(x: f.minX, y: f.minY))
                guard let edited = PasteConfirmDialog.run(text: s, over: panel, near: near) else { return }
                s = edited
            }
        }
        // 改行を CR のみに正規化 (ブラケットはしない)
        s = s.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        guard !s.isEmpty else { return }
        for t in targets { t.termView.onSendText?(s) }   // PostMessage WM_CHAR / WM_UNICHAR
    }

    /// IME を通す文字のキー
    private static func isTextKey(_ e: NSEvent) -> Bool {
        if !e.modifierFlags.intersection([.control, .option, .command, .function]).isEmpty { return false }
        guard let c = e.characters?.unicodeScalars.first else { return false }
        // 0xF700- は矢印・ファンクションキー
        return c.value >= 0x20 && c.value != 0x7F && !(0xF700...0xF8FF).contains(c.value)
    }

    /// 入力欄の編集 (リアルタイムのときは確定した文字を送り先へ送り、入力欄には残さない)
    private lazy var fieldEditor: BroadcastFieldEditor = {
        let f = BroadcastFieldEditor()
        f.isFieldEditor = true
        f.onInsert = { [weak self] text in
            guard let self = self, self.realtime.state == .on else { return false }
            for t in self.targets { t.termView.onSendText?(text) }
            return true
        }
        return f
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as AnyObject?) === combo ? fieldEditor : nil
    }

    // MARK: - 送信

    @objc private func submit(_ sender: Any?) {
        if realtime.state == .on {
            // リアルタイムのときの「送信」は改行だけ送る
            for t in targets { t.receiveBroadcast("\n") }
            combo.stringValue = ""
            return
        }
        var text = String(combo.stringValue.prefix(255))
        if history.state == .on {
            addHistory(text)
            BroadcastWindow.d.set(true, forKey: "broadcastCommandHistory")
        } else {
            BroadcastWindow.d.set(false, forKey: "broadcastCommandHistory")
        }
        if enterKey.state == .on { text += "\r" }
        let dest: [SessionWindowController] = parentOnly.state == .on ? [parent].compactMap { $0 } : targets
        for t in dest { t.receiveBroadcast(text) }
    }

    @objc private func closePanel(_ sender: Any?) { panel.orderOut(nil) }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        BroadcastWindow.shared = nil
    }

    // MARK: - ヒストリ (broadcast.log の [BroadcastCommands]、新しい順、重複なし、MaxBroadcatHistory (既定 99) 件まで)

    /// HistoryStoreCreate(ts.MaxBroadcatHistory)
    private var maxHistory: Int { max(0, parent?.settings.maxBroadcatHistory ?? 99) }

    private static var historyPath: String { (AppPaths.setupDirectory as NSString).appendingPathComponent("broadcast.log") }

    private func readHistory() -> [String] {
        guard let t = try? String(contentsOfFile: BroadcastWindow.historyPath, encoding: .utf8) else { return [] }
        var out: [(Int, String)] = []
        for line in t.components(separatedBy: .newlines) {
            guard line.hasPrefix("Command"), let eq = line.firstIndex(of: "=") else { continue }
            let n = Int(line[line.index(line.startIndex, offsetBy: 7)..<eq]) ?? 0
            out.append((n, String(line[line.index(after: eq)...])))
        }
        return out.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    private func loadHistory() {
        combo.removeAllItems()
        combo.addItems(withObjectValues: Array(readHistory().prefix(maxHistory)))
    }

    private func addHistory(_ s: String) {
        guard !s.isEmpty else { return }
        var h = readHistory().filter { $0 != s }
        h.insert(s, at: 0)
        h = Array(h.prefix(maxHistory))
        var out = "[BroadcastCommands]\n"
        for (i, c) in h.enumerated() { out += "Command\(i + 1)=\(c)\n" }
        try? out.write(toFile: BroadcastWindow.historyPath, atomically: true, encoding: .utf8)
        loadHistory()
    }
}

extension SessionWindowController {
    /// ブロードキャストコマンド
    @objc func broadcastCommand(_ sender: Any?) { BroadcastWindow.show(from: self) }

    /// BroadCastReceive: 接続中で AcceptBroadcast のときだけ、ローカルエコーなしで 1 行ごとに少し待って送る
    func receiveBroadcast(_ text: String) {
        guard connected, settings.acceptBroadcast else { return }
        sendPasteText(text, echo: false)
    }
}

/// ブロードキャストの入力欄の編集 (broadcast.cpp BroadcastEditProc の WM_CHAR / WM_IME_COMPOSITION)
final class BroadcastFieldEditor: NSTextView {
    /// 確定した文字。true を返したら入力欄には残さない
    var onInsert: ((String) -> Bool)?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        super.insertText(string, replacementRange: replacementRange)
        if !text.isEmpty, onInsert?(text) == true {
            self.string = ""   // 入力した文字が入力欄に残らないように捨てる
        }
    }
}
