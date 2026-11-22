import AppKit
import TeraCore

// 設定メニューの「その他の設定」シート (Tera Term 5 の CAddSettingPropSheetDlg, addsetting.cpp)。
// 端末… / ウィンドウ… / フォント… / キーボード… / シリアルポート… / TCP/IP… / 全般… / その他の設定… は
// どれもこのシートを開き、始めのタブだけが違う。OK ですべてのタブの後処理をする (ExternalSetupPostProcess)。

// MARK: - 部品

enum SetupUI {
    /// Windows のアクセスキー "(&X)" / "&" を外す (Mac のダイアログには出さない)
    static func t(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "\\(&.\\)", with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: "&&", with: "\u{1}").replacingOccurrences(of: "&", with: "").replacingOccurrences(of: "\u{1}", with: "&")
        return r
    }
    static func label(_ s: String, right: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: t(s))
        if right { l.alignment = .right }
        return l
    }
    static func check(_ s: String) -> NSButton { NSButton(checkboxWithTitle: t(s), target: nil, action: nil) }
    static func radio(_ s: String, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
        NSButton(radioButtonWithTitle: t(s), target: target, action: action)
    }
    static func button(_ s: String, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
        let b = NSButton(title: t(s), target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }
    static func popup(_ items: [String]) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items.map(t))
        return p
    }
    static func field(width: CGFloat = 220) -> NSTextField {
        let f = NSTextField(string: "")
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }
    static func secure(width: CGFloat = 220) -> NSSecureTextField {
        let f = NSSecureTextField(string: "")
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }
    static func row(_ v: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: v)
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = align
        return s
    }
    static func column(_ v: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView(views: v)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }
    static func grid(_ rows: [[NSView]], leading: Bool = false) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 6
        g.columnSpacing = leading ? 16 : 8
        if g.numberOfColumns > 0 { g.column(at: 0).xPlacement = leading ? .leading : .trailing }
        for i in 0..<g.numberOfRows { g.row(at: i).yPlacement = .center }
        return g
    }
    static func box(_ title: String, _ content: NSView) -> NSBox {
        let b = NSBox()
        b.title = t(title)
        b.titleFont = .systemFont(ofSize: 11)
        b.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        // contentView は自動レイアウトで大きさが決まらないので、箱そのものに載せる
        b.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: b.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: b.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -10),
        ])
        return b
    }
    static func indent(_ v: NSView, by w: CGFloat = 18) -> NSView {
        let sp = NSView()
        sp.translatesAutoresizingMaskIntoConstraints = false
        sp.widthAnchor.constraint(equalToConstant: w).isActive = true
        return row([sp, v], spacing: 0)
    }
}

// MARK: - TERATERM.INI の書き出し用

/// 既存の .ini の行を残したまま、キーを書き換える (WritePrivateProfileString と同じ)
final class IniDocument {
    private var lines: [String]

    init(text: String = "") {
        lines = text.isEmpty ? [] : text.components(separatedBy: .newlines)
        while lines.last == "" { lines.removeLast() }
    }

    convenience init(contentsOf path: String) {
        var text = ""
        if let d = FileManager.default.contents(atPath: path) {
            let b = [UInt8](d.prefix(3))
            if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE { text = String(data: d, encoding: .utf16LittleEndian) ?? "" }
            else if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { text = String(data: d, encoding: .utf16BigEndian) ?? "" }
            else { text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .shiftJIS) ?? "" }
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        self.init(text: text)
    }

    private func sectionRange(_ section: String) -> Range<Int>? {
        let want = "[" + section.lowercased() + "]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == want }) else { return nil }
        var end = start + 1
        while end < lines.count && !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        return start..<end
    }

    /// value が nil ならキーを消す
    func set(_ section: String, _ key: String, _ value: String?) {
        if sectionRange(section) == nil {
            guard value != nil else { return }
            if !lines.isEmpty && lines.last != "" { lines.append("") }
            lines.append("[\(section)]")
        }
        let r = sectionRange(section)!
        let idx = (r.lowerBound + 1..<r.upperBound).first { i in
            let l = lines[i]
            guard let eq = l.firstIndex(of: "="), !l.hasPrefix(";") else { return false }
            return l[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame
        }
        if let i = idx {
            if let v = value { lines[i] = "\(key)=\(v)" } else { lines.remove(at: i) }
        } else if let v = value {
            // セクションの最後の空でない行のあと
            var at = r.upperBound
            while at > r.lowerBound + 1 && lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert("\(key)=\(v)", at: at)
        }
    }

    func removeSection(_ section: String) {
        if let r = sectionRange(section) { lines.removeSubrange(r) }
    }

    var text: String { lines.joined(separator: "\r\n") + "\r\n" }

    /// Tera Term と同じく UTF-16LE (BOM 付き) で書く
    func write(to path: String) throws {
        var d = Data([0xFF, 0xFE])
        d.append(text.data(using: .utf16LittleEndian)!)
        try d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// MARK: - その他の設定シート

final class SetupSheet: SheetDialog, NSTabViewDelegate, NSTextFieldDelegate {
    /// タブ (addsetting.cpp の順。Cygwin の場所は Mac のローカルシェル。Plugin / Debug / TEK は無い)
    enum Page: Int, CaseIterable {
        case general, ui, sequence, copyPaste, visual, log, localShell, encoding, font, theme, keyboard, mouse, tcpip, terminal, serial, window
        var title: String {
            switch self {
            case .general: return "全般"
            case .ui: return "UI"
            case .localShell: return "ローカルシェル"
            case .sequence: return "制御シーケンス"
            case .copyPaste: return "コピーと貼り付け"
            case .visual: return "表示"
            case .log: return "ログ"
            case .encoding: return "エンコーディング"
            case .font: return "フォント"
            case .theme: return "テーマ"
            case .keyboard: return "キーボード"
            case .mouse: return "マウス"
            case .tcpip: return "TCP/IP"
            case .terminal: return "端末"
            case .serial: return "シリアルポート"
            case .window: return "ウィンドウ"
            }
        }
    }

    private(set) var s: TermSettings
    /// シリアルポートの設定 (ConnHistory.serial / 開いているポート)
    private(set) var serial: SerialParams
    /// ファイル転送のフォルダ (ts.FileDir)
    private(set) var fileDir: String
    private let startPage: Page
    private weak var session: SessionWindowController?
    private var completion: ((TermSettings?) -> Void)?
    private let tabView = NSTabView()
    private var binders: [(load: () -> Void, store: () -> Void)] = []
    private var schemes: [ColorScheme] = []

    init(settings: TermSettings, session: SessionWindowController? = nil, page: Page = .general) {
        s = settings
        self.session = session
        startPage = page
        if let sc = session?.conn as? SerialConnection { serial = sc.params } else { serial = ConnHistory.serial }
        fileDir = session?.transferOptions.fileDir ?? settings.fileDir
        super.init()
        if let sc = session?.conn as? SerialConnection { serial.flow = sc.flow }
    }

    /// 以前の SetupDialog(settings:) と同じ呼び方 (端末タブから)
    convenience init(settings: TermSettings) { self.init(settings: settings, session: nil, page: .terminal) }

    func begin(on w: NSWindow, completion: @escaping (TermSettings?) -> Void) {
        self.completion = completion
        panel.title = "Tera Term: その他の設定"
        build()
        selectPage(at: Page.allCases.firstIndex(of: startPage) ?? 0)
        present(on: w)
        if let dir = ProcessInfo.processInfo.environment["TERAMAC_SETUP_SNAPSHOT"] { snapshotTabs(dir) }
    }

    /// 自己テスト: すべてのタブの絵を dir/setup-<番号>-<名前>.png に書く
    private func snapshotTabs(_ dir: String) {
        let restore = tabView.indexOfTabViewItem(tabView.selectedTabViewItem!)
        for (i, p) in Page.allCases.enumerated() {
            selectPage(at: i)
            guard let v = panel.contentView else { continue }
            v.layoutSubtreeIfNeeded()
            v.display()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/setup-\(i)-\(p).png"))
        }
        selectPage(at: restore)
        // TTSSH / TTProxy のダイアログも
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        func snap(_ d: SheetDialog, _ name: String) {
            guard let v = d.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.layoutSubtreeIfNeeded()
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            d.cancel()
        }
        let d1 = SSHSetupDialog(); d1.begin(on: w); snap(d1, "ssh")
        let d2 = SSHAuthSetupDialog(); d2.begin(on: w); snap(d2, "sshauth")
        let d3 = SSHForwardSetupDialog(); d3.begin(on: w); snap(d3, "sshfwd")
        let d4 = SSHKeyGenDialog(); d4.begin(on: w); snap(d4, "keygen")
        let d5 = ProxySetupDialog(); d5.begin(on: w); snap(d5, "proxy")
        let d6 = ForwardEditDialog(spec: ForwardSpec(kind: .local)); d6.begin(on: w) { _ in }; snap(d6, "fwdedit")
        // 設定の保存 → 読み込みで同じになるか
        var t = self.s
        t.cols = 132; t.rows = 50; t.encoding = .sjis; t.encodingSend = .eucjp; t.recvNewline = "AUTODETECT"
        t.boldColor = ColorPair(0x123456, 0x654321); t.answerback = "abc\\0d"; t.titleFormat = 5; t.beep = "visual"
        t.ansi16 = (0..<16).map { TermSettings.rgb($0 * 10, 0, 255 - $0) }
        let path = dir + "/export.ini"
        try? TeraTermIniExport.write(settings: t, transfer: FileTransferOptions(), to: path)
        if let d = FileManager.default.contents(atPath: path), let ini = IniFile(data: d) {
            let r = TeraTermIniImport.read(ini, base: TermSettings()).settings
            let ok = r.cols == 132 && r.rows == 50 && r.encoding == .sjis && r.encodingSend == .eucjp && r.recvNewline == "AUTODETECT"
                && r.boldColor.iniString == t.boldColor.iniString && r.answerback == t.answerback && r.titleFormat == 5 && r.beep == "visual"
                && r.ansi16.map { $0.map(TermSettings.rgbString) } == t.ansi16.map { $0.map(TermSettings.rgbString) }
                && r.fontName == t.fontName
            try? (ok ? "ROUNDTRIP OK" : "ROUNDTRIP FAIL \(r.fontName) \(r.fontSize)").write(toFile: dir + "/roundtrip.txt", atomically: true, encoding: .utf8)
        }
    }

    private func build() {
        tabView.delegate = self
        for p in Page.allCases {
            let item = NSTabViewItem(identifier: p.rawValue)
            item.label = p.title
            let content = page(p)
            let host = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
                content.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
                content.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -16),
                content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -12),
            ])
            item.view = host
            tabView.addTabViewItem(item)
        }
        // 一番大きいタブに合わせる
        var size = NSSize(width: 640, height: 300)
        for item in tabView.tabViewItems {
            if let v = item.view?.subviews.first {
                let f = v.fittingSize
                size.width = max(size.width, f.width + 32)
                size.height = max(size.height, f.height + 24)
            }
        }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        // Windows の Tera Term と同じく、上に 2 段のタブ (Win32 の複数行タブ)
        tabView.tabViewType = .noTabsNoBorder
        tabBar.onSelect = { [unowned self] i in self.selectPage(at: i) }
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.widthAnchor.constraint(equalToConstant: max(size.width + 2, tabBar.minimumWidth + 8)).isActive = true
        for b in binders { b.load() }
        refresh()
        layout(tabBar)
    }

    private lazy var tabBar = MultiRowTabView(titles: Page.allCases.map(\.title), rows: 2, content: tabView)

    private func selectPage(at i: Int) {
        tabView.selectTabViewItem(at: i)
        tabBar.selectedIndex = i
    }

    // MARK: 項目と ts の対応

    @discardableResult
    private func bind(_ c: NSButton, _ kp: WritableKeyPath<TermSettings, Bool>, invert: Bool = false) -> NSButton {
        c.target = self; c.action = #selector(changed(_:))
        binders.append((load: { [unowned self] in c.state = (self.s[keyPath: kp] != invert) ? .on : .off },
                        store: { [unowned self] in self.s[keyPath: kp] = (c.state == .on) != invert }))
        return c
    }
    private func cb(_ title: String, _ kp: WritableKeyPath<TermSettings, Bool>, invert: Bool = false) -> NSButton {
        bind(SetupUI.check(title), kp, invert: invert)
    }
    private func pop(_ titles: [String], _ values: [String], _ kp: WritableKeyPath<TermSettings, String>) -> NSPopUpButton {
        let p = SetupUI.popup(titles)
        p.target = self; p.action = #selector(changed(_:))
        binders.append((load: { [unowned self] in
            let v = self.s[keyPath: kp].lowercased()
            p.selectItem(at: values.firstIndex { $0.lowercased() == v } ?? 0)
        }, store: { [unowned self] in self.s[keyPath: kp] = values[max(0, p.indexOfSelectedItem)] }))
        return p
    }
    private func popInt(_ titles: [String], _ values: [Int], _ kp: WritableKeyPath<TermSettings, Int>) -> NSPopUpButton {
        let p = SetupUI.popup(titles)
        p.target = self; p.action = #selector(changed(_:))
        binders.append((load: { [unowned self] in p.selectItem(at: values.firstIndex(of: self.s[keyPath: kp]) ?? 0) },
                        store: { [unowned self] in self.s[keyPath: kp] = values[max(0, p.indexOfSelectedItem)] }))
        return p
    }
    private func num(_ kp: WritableKeyPath<TermSettings, Int>, width: CGFloat = 60, range: ClosedRange<Int> = 0...Int.max) -> NSTextField {
        let f = SetupUI.field(width: width)
        f.delegate = self
        binders.append((load: { [unowned self] in f.stringValue = String(self.s[keyPath: kp]) },
                        store: { [unowned self] in
                            if let v = Int(f.stringValue.trimmingCharacters(in: .whitespaces)) {
                                self.s[keyPath: kp] = min(range.upperBound, max(range.lowerBound, v))
                            } }))
        return f
    }
    private func text(_ kp: WritableKeyPath<TermSettings, String>, width: CGFloat = 220) -> NSTextField {
        let f = SetupUI.field(width: width)
        f.delegate = self
        binders.append((load: { [unowned self] in f.stringValue = self.s[keyPath: kp] },
                        store: { [unowned self] in self.s[keyPath: kp] = f.stringValue }))
        return f
    }
    private func custom(load: @escaping () -> Void, store: @escaping () -> Void) { binders.append((load: load, store: store)) }

    @objc private func changed(_ sender: Any?) {
        if let b = sender as? NSButton, b === boldCheckWindow || b === boldCheckVisual {
            let st = b.state
            boldCheckWindow.state = st; boldCheckVisual.state = st
        }
        refresh()
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }

    // 依存する項目の有効・無効 (各タブの OnCommand にあたる)
    private func refresh() {
        termResizeCheck.isEnabled = termIsWinCheck.state == .off
        scrollField.isEnabled = scrollCheck.state == .on
        confirmRButton.isEnabled = disableRButton.state == .off
        keywordField.isEnabled = confirmChangePasteCheck.state == .on
        keywordButton.isEnabled = confirmChangePasteCheck.state == .on
        confirmCRCheck.isEnabled = confirmChangePasteCheck.state == .on
        disableMouseCtrlCheck.isEnabled = mouseTrackCheck.state == .on
        let bin = logBinaryCheck.state == .on
        logPlainCheck.isEnabled = !bin
        logTimestampCheck.isEnabled = !bin
        logTimestampPopup.isEnabled = !bin && logTimestampCheck.state == .on
        for c in [logRotateSize, logRotateType, logRotateStep] as [NSControl] { c.isEnabled = logRotateCheck.state == .on }
        // エンコーディング
        sendPopup.isEnabled = differentCheck.state == .on
        if differentCheck.state == .off { sendPopup.selectItem(at: recvPopup.indexOfSelectedItem) }
        let all = TermEncoding.allCases
        let recv = all[max(0, recvPopup.indexOfSelectedItem)], send = all[max(0, sendPopup.indexOfSelectedItem)]
        let uni = recv == .utf8 || send == .utf8
        for c in [ambPopup, emojiCheck, boxCheck, punctCheck, middleDotCheck, decRadios[0], decRadios[1], decRadios[2]] as [NSControl] { c.isEnabled = uni }
        emojiPopup.isEnabled = uni && emojiCheck.state == .on
        kanaRecvCheck.isEnabled = recv == .jis
        kanaSendCheck.isEnabled = send == .jis
        kanjiInPopup.isEnabled = send == .jis
        kanjiOutPopup.isEnabled = send == .jis
        updateThemeControls()
        updateColorControls()
        updateAnsiControls()
        updateFontLabel()
    }

    // MARK: 各タブ

    private func page(_ p: Page) -> NSView {
        switch p {
        case .general: return generalPage()
        case .ui: return uiPage()
        case .localShell: return localShellPage()
        case .sequence: return sequencePage()
        case .copyPaste: return copyPastePage()
        case .visual: return visualPage()
        case .log: return logPage()
        case .encoding: return encodingPage()
        case .font: return fontPage()
        case .theme: return themePage()
        case .keyboard: return keyboardPage()
        case .mouse: return mousePage()
        case .tcpip: return tcpipPage()
        case .terminal: return terminalPage()
        case .serial: return serialPage()
        case .window: return windowPage()
        }
    }

    // 全般 (general_pp.cpp)
    private let fileDirField = SetupUI.field(width: 320)
    private func generalPage() -> NSView {
        let portPopup = pop(["TCP/IP", "Serial"], ["tcpip", "serial"], \.portType)
        let titleBits = ["ホスト/ポート名を表示する(&D)", "セッション番号を表示する(&N)", "&VT/TEK を表示する",
                         "タイトルとホスト名の場所を入れ換える(&T)", "TCP ポート番号を表示する(&P)", "シリアルポートのスピードを表示する(&R)"]
        var bitChecks: [NSButton] = []
        for (i, t) in titleBits.enumerated() {
            let c = SetupUI.check(t)
            c.target = self; c.action = #selector(changed(_:))
            custom(load: { [unowned self] in c.state = self.s.titleFormat & (1 << i) != 0 ? .on : .off },
                   store: { [unowned self] in
                       if c.state == .on { self.s.titleFormat |= 1 << i } else { self.s.titleFormat &= ~(1 << i) } })
            bitChecks.append(c)
        }
        fileDirField.stringValue = fileDir
        let dirButton = SetupUI.button("...", target: self, action: #selector(chooseFileDir))
        return SetupUI.column([
            cb("ブレーク送信のアクセラレータキーを無効にする(&S)", \.disableAcceleratorSendBreak),
            cb("ブロードキャストを受け入れる(&B)", \.acceptBroadcast),
            cb("最下行でだけ自動スクロールする(&U)", \.autoScrollOnlyInBottomLine),
            cb("ウィンドウサイズ変更時に表示内容をクリアする(&C)", \.clearOnResize),
            SetupUI.row([SetupUI.label("新しい接続のデフォルト(&C):"), portPopup]),
            SetupUI.box("タイトル形式", SetupUI.column(bitChecks, spacing: 4)),
            SetupUI.label("通知"),
            SetupUI.indent(cb("通知音", \.notifySound)),
            SetupUI.label("ファイル転送のフォルダ"),
            SetupUI.indent(SetupUI.row([fileDirField, dirButton])),
        ], spacing: 8)
    }

    @objc private func chooseFileDir() {
        let p = NSOpenPanel()
        p.message = "新しいディレクトリを選択してください"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: FileTransferPaths.fileDirectory(fileDirField.stringValue))
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { self.fileDirField.stringValue = u.path } }
    }

    // 制御シーケンス (addsetting.cpp CSequencePropPageDlg)
    private let mouseTrackCheck = SetupUI.check("マウスイベント通知要求を受け入れる(&M)")
    private let disableMouseCtrlCheck = SetupUI.check("Controlキーを押している間はマウスイベントを通知しない(&D)")
    private func sequencePage() -> NSView {
        bind(mouseTrackCheck, \.mouseEventTracking)
        bind(disableMouseCtrlCheck, \.disableMouseTrackingByCtrl)
        return SetupUI.column([
            mouseTrackCheck,
            SetupUI.indent(disableMouseCtrlCheck),
            SetupUI.grid([
                [SetupUI.label("ウィンドウタイトルの変更要求を受け入れる(&T)"),
                 pop(["無効", "上書き", "前に追加", "後に追加"], ["off", "overwrite", "ahead", "last"], \.acceptTitleChangeRequest)],
                [SetupUI.label("ウィンドウタイトルの報告要求(&I)"),
                 pop(["無視", "応答", "空白"], ["ignore", "accept", "empty"], \.titleReportSequence)],
            ]),
            cb("ウィンドウ操作制御シーケンス(&W)", \.windowCtrlSequence),
            cb("ウィンドウ情報報告シーケンス(&R)", \.windowReportSequence),
            cb("カーソル形状/点滅変更制御シーケンス(&C)", \.cursorCtrlSequence),
            SetupUI.row([SetupUI.label("リモートからのクリップボードアクセス(&L)"),
                         pop(["無効", "書込のみ", "読込のみ", "読込/書込"], ["off", "write", "read", "on"], \.clipboardAccessFromRemote)]),
            cb("リモートからのクリップボードアクセスを通知する(&N)", \.notifyClipboardAccess),
            cb("リモートからのスクロールバッファの消去を受け入れる(&S)", \.clearScrollBufferFromRemote),
            cb("印字開始シーケンスを無効化(&I)", \.printerCtrlSequence, invert: true),
            SetupUI.row([SetupUI.label("ベル(&B)"), pop(["無視", "サウンド", "ビジュアルベル"], ["off", "on", "visual"], \.beep)]),
        ], spacing: 8)
    }

    // コピーと貼り付け (addsetting.cpp CCopypastePropPageDlg)
    private let disableRButton = SetupUI.check("右クリックでの貼り付けを無効にする(&D)")
    private let confirmRButton = SetupUI.check("右クリックでの貼り付けを確認する(&C)")
    private let confirmChangePasteCheck = SetupUI.check("危険なクリップボードの貼り付けを確認する(&P)")
    private let confirmCRCheck = SetupUI.check("改行を含む貼り付けをいつも確認する")
    private let keywordField = SetupUI.field(width: 300)
    private lazy var keywordButton = SetupUI.button("...", target: self, action: #selector(chooseKeywordFile))
    private func copyPastePage() -> NSView {
        bind(disableRButton, \.rightClickPaste, invert: true)
        bind(confirmRButton, \.confirmPasteMouseRButton)
        bind(confirmChangePasteCheck, \.confirmChangePaste)
        bind(confirmCRCheck, \.confirmChangePasteCR)
        keywordField.delegate = self
        custom(load: { [unowned self] in self.keywordField.stringValue = self.s.confirmChangePasteStringFile },
               store: { [unowned self] in self.s.confirmChangePasteStringFile = self.keywordField.stringValue })
        return SetupUI.column([
            cb("継続行コピーを有効にする(&L)", \.continuedLineCopy),
            disableRButton,
            SetupUI.indent(confirmRButton),
            cb("中クリックでの貼り付けを無効にする(&M)", \.disablePasteMouseMButton),
            cb("左クリックでのみ選択を開始する(&O)", \.selectOnlyByLButton),
            cb("貼り付け時に末尾の改行を削除する(&T)", \.trimTrailingNLOnPaste),
            cb("ブラケットペーストは制御文字を含むときだけ囲む", \.bracketedControlOnly),
            confirmChangePasteCheck,
            SetupUI.indent(confirmCRCheck),
            SetupUI.indent(SetupUI.row([SetupUI.label("キーワードファイル(&S)"), keywordField, keywordButton])),
            SetupUI.row([SetupUI.label("区切り文字(&I)"), text(\.delimList, width: 320)]),
            SetupUI.row([SetupUI.label("貼り付けの行間遅延(&A)"), num(\.pasteDelayPerLine, range: 0...5000), SetupUI.label("ミリ秒")]),
            cb("マウスでウィンドウ選択時の文字選択を有効にする(&B)", \.selectOnActivate),
            cb("マウスで文字選択時、自動でクリップボードへのコピーを行う(&Y)", \.copyOnSelect),
        ], spacing: 8)
    }

    @objc private func chooseKeywordFile() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["txt"]
        p.allowsOtherFileTypes = true
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { self.keywordField.stringValue = u.path; self.refresh() } }
    }

    // 表示 (addsetting.cpp CVisualPropPageDlg)
    private let boldCheckVisual = SetupUI.check("太字属性フォントを有効にする")
    private var ansiWork: [NSColor] = []
    private let ansiPopup = SetupUI.popup((0..<16).map(String.init))
    private let ansiR = SetupUI.field(width: 44), ansiG = SetupUI.field(width: 44), ansiB = SetupUI.field(width: 44)
    private let ansiSample = NSTextField(labelWithString: "  ABCDEFG abcdefg 0123456789  ")
    private func alphaRow(_ title: String, _ kp: WritableKeyPath<TermSettings, Int>) -> NSView {
        let f = num(kp, width: 50, range: 0...255)
        let sl = NSSlider(value: 255, minValue: 0, maxValue: 255, target: nil, action: nil)
        sl.translatesAutoresizingMaskIntoConstraints = false
        sl.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let ttl = SetupUI.label(title)
        let sync = SliderSync(field: f, slider: sl)
        syncs.append(sync)
        custom(load: { [unowned self] in sl.integerValue = self.s[keyPath: kp]; sync.update() }, store: {})
        return SetupUI.row([ttl, f, sl])
    }
    private var syncs: [SliderSync] = []
    private func visualPage() -> NSView {
        bind(boldCheckVisual, \.enableBold)
        ansiPopup.target = self; ansiPopup.action = #selector(ansiSelected)
        for f in [ansiR, ansiG, ansiB] { f.delegate = self; f.target = self; f.action = #selector(ansiEdited) }
        ansiSample.drawsBackground = true
        ansiSample.isBezeled = true
        custom(load: { [unowned self] in self.ansiWork = self.s.ansi16 ?? Array(Palette.colors.prefix(16)); self.ansiSelected() },
               store: { [unowned self] in
                   let std = Array(Palette.colors.prefix(16))
                   self.s.ansi16 = self.ansiWork.map(TermSettings.rgbString) != std.map(TermSettings.rgbString) ? self.ansiWork : nil
               })
        return SetupUI.column([
            SetupUI.label("ウィンドウの不透明度"),
            SetupUI.indent(alphaRow("アクテイブ時(&A)", \.alphaBlendActive)),
            SetupUI.indent(alphaRow("非アクティブ時(&C)", \.alphaBlendInactive)),
            SetupUI.row([SetupUI.label("マウスカーソル(&M)"),
                         pop(["ARROW", "IBEAM", "CROSS", "HAND"], ["ARROW", "IBEAM", "CROSS", "HAND"], \.mouseCursor)]),
            SetupUI.row([SetupUI.label("AN&SIカラー"), ansiPopup, SetupUI.label("赤(&R)"), ansiR, SetupUI.label("緑(&G)"), ansiG,
                         SetupUI.label("青(&B)"), ansiB]),
            SetupUI.indent(ansiSample),
            SetupUI.row([SetupUI.label("フォントの品質(&F)"),
                         pop(["デフォルト", "アンチエイリアスなし", "アンチエイリアス"], ["default", "nonantialiased", "antialiased"], \.fontQuality)]),
            SetupUI.label("Character attributes"),
            SetupUI.indent(SetupUI.grid([
                [cb("太字属性色を有効にする(&O)", \.enableBoldAttrColor), boldCheckVisual],
                [cb("下線属性色を有効にする", \.underlineAttrColor), cb("下線属性に下線を付加する", \.underlineAttrFont)],
                [cb("点滅属性色を有効にする(&L)", \.enableBlinkAttrColor), cb("反転属性色を有効にする(&V)", \.enableReverseAttrColor)],
                [cb("URL属性色を有効にする(&U)", \.enableURLColor), cb("URL文字列に下線を付加する(&U)", \.urlUnderline)],
                [cb("ANSIカラーを有効にする(&N)", \.enableANSIColor), NSGridCell.emptyContentView],
            ], leading: true)),
        ], spacing: 8)
    }
    @objc private func ansiSelected() {
        let i = max(0, ansiPopup.indexOfSelectedItem)
        guard i < ansiWork.count else { return }
        let (r, g, b) = TermSettings.rgbComponents(ansiWork[i])
        ansiR.stringValue = String(r); ansiG.stringValue = String(g); ansiB.stringValue = String(b)
        updateAnsiControls()
    }
    @objc private func ansiEdited() {
        let i = max(0, ansiPopup.indexOfSelectedItem)
        guard i < ansiWork.count, let r = Int(ansiR.stringValue), let g = Int(ansiG.stringValue), let b = Int(ansiB.stringValue) else { return }
        ansiWork[i] = TermSettings.rgb(r, g, b)
        updateAnsiControls()
    }
    private func updateAnsiControls() {
        let i = max(0, ansiPopup.indexOfSelectedItem)
        guard i < ansiWork.count else { return }
        ansiSample.backgroundColor = bgColorForSample
        ansiSample.textColor = ansiWork[i]
    }
    private var bgColorForSample: NSColor { workColors.first?.bg ?? s.bg }

    // ログ (log_pp.cpp)
    private let logBinaryCheck = SetupUI.check("バイナリ(&R)")
    private let logPlainCheck = SetupUI.check("プレーンテキスト(&P)")
    private let logTimestampCheck = SetupUI.check("タイムスタンプ(&T)")
    private lazy var logTimestampPopup = pop(["ローカルタイム", "UTC", "経過時間(Logging)", "経過時間(Connection)"],
                                             ["Local", "UTC", "LoggingElapsed", "ConnectionElapsed"], \.logTimestampType)
    private let logRotateCheck = SetupUI.check("ログのローテート(&L)")
    /// LogRotateSize はバイトで持ち、画面には単位 (Byte/KB/MB) で割った値を出す (log_pp.cpp)
    private lazy var logRotateSize: NSTextField = {
        let f = SetupUI.field(width: 80)
        f.delegate = self
        custom(load: { [unowned self] in
            var v = self.s.logRotateSize
            for _ in 0..<max(0, self.s.logRotateSizeType) { v /= 1024 }
            f.stringValue = String(v)
        }, store: { [unowned self] in
            guard let v = Int(f.stringValue.trimmingCharacters(in: .whitespaces)), v >= 0 else { return }
            var b = v
            for _ in 0..<max(0, self.logRotateType.indexOfSelectedItem) { b *= 1024 }
            self.s.logRotateSize = b
        })
        return f
    }()
    private lazy var logRotateType = popInt(["Byte", "KB", "MB"], [0, 1, 2], \.logRotateSizeType)
    private lazy var logRotateStep = num(\.logRotateStep, width: 50)
    private let logEditorField = SetupUI.field(width: 300)
    private let logNameCombo = NSComboBox()
    private let logPathField = SetupUI.field(width: 300)
    private func logPage() -> NSView {
        bind(logBinaryCheck, \.logBinary)
        bind(logPlainCheck, \.logTypePlainText)
        bind(logTimestampCheck, \.logTimestamp)
        bind(logRotateCheck, \.logRotate.asBool)
        logEditorField.delegate = self
        custom(load: { [unowned self] in self.logEditorField.stringValue = self.s.viewlogEditor },
               store: { [unowned self] in self.s.viewlogEditor = self.logEditorField.stringValue })
        logEditorField.placeholderString = "テキストエディット"
        logNameCombo.addItems(withObjectValues: ["teraterm.log", "%H%M%S.log", "%y%m%d%H%M%S.log", "%Y%m%d_%H%M%S.log", "%y%m%d_%H%M%S.log",
                                                 "teraterm_%y%m%d%H%M%S.log", "%y%m%d_%H%M%S_&h.log", "%Y%m%d_%H%M%S_%z.log",
                                                 "%y%m%d_%H%M%S_%z.log", "%Y%m%dT%H%M%S%z.log"])
        logNameCombo.translatesAutoresizingMaskIntoConstraints = false
        logNameCombo.widthAnchor.constraint(equalToConstant: 300).isActive = true
        custom(load: { [unowned self] in self.logNameCombo.stringValue = self.s.logDefaultName },
               store: { [unowned self] in self.s.logDefaultName = self.logNameCombo.stringValue })
        custom(load: { [unowned self] in self.logPathField.stringValue = self.s.logDefaultPath },
               store: { [unowned self] in self.s.logDefaultPath = self.logPathField.stringValue })
        return SetupUI.column([
            SetupUI.label("ログ表示用エディタ"),
            SetupUI.indent(SetupUI.grid([
                [SetupUI.label("実行ファイル(&E)"), SetupUI.row([logEditorField, SetupUI.button("...", target: self, action: #selector(chooseEditor))])],
                [SetupUI.label("引き数(&R)"), text(\.viewlogEditorArg, width: 300)],
            ])),
            SetupUI.label("標準ログファイル名(strftimeフォーマット可) (&F)"),
            SetupUI.indent(logNameCombo),
            SetupUI.label("標準のログ保存先フォルダ(&S)"),
            SetupUI.indent(SetupUI.row([logPathField, SetupUI.button("...", target: self, action: #selector(chooseLogDir))])),
            cb("自動的にログ採取を開始する(&U)", \.logAutoStart),
            SetupUI.box("Log option", SetupUI.grid([
                [logBinaryCheck, cb("追記(&A)", \.logAppend)],
                [logPlainCheck, cb("ダイアログを非表示(&D)", \.logHideDialog)],
                [cb("現在バッファを含む(&C)", \.logIncludeScreenBuffer), NSGridCell.emptyContentView],
                [logTimestampCheck, logTimestampPopup],
            ], leading: true)),
            logRotateCheck,
            SetupUI.indent(SetupUI.row([SetupUI.label("サイズ(&i)"), logRotateSize, logRotateType, SetupUI.label("世代(&R)"), logRotateStep])),
        ], spacing: 8)
    }
    @objc private func chooseEditor() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { self.logEditorField.stringValue = u.path } }
    }
    @objc private func chooseLogDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { self.logPathField.stringValue = u.path } }
    }

    // エンコーディング (coding_pp.cpp)
    private let recvPopup = SetupUI.popup(TermEncoding.allCases.map { $0.rawValue })
    private let differentCheck = SetupUI.check("Tra&nsmit (Use different code)")
    private let sendPopup = SetupUI.popup(TermEncoding.allCases.map { $0.rawValue })
    private let ambPopup = SetupUI.popup(["1 Cell", "2 Cell"])
    private let emojiCheck = SetupUI.check("Override Emoji Characters width")
    private lazy var emojiPopup = popInt(["1 Cell", "2 Cell"], [1, 2], \.unicodeEmojiWidth)
    private let decRadios = [SetupUI.radio("UnicodeをDEC Special Graphicsへマッピングする"),
                             SetupUI.radio("DEC Special GraphicsをUnicodeへマッピングする"),
                             SetupUI.radio("DEC Special Graphicsをマッピングしない")]
    private let boxCheck = SetupUI.check("罫線素片(U+2500-U+257F)")
    private let punctCheck = SetupUI.check("Punctuation, Block Elements, Shade")
    private let middleDotCheck = SetupUI.check("中点(U+00B7,U+2024,U+2219)")
    private let kanaRecvCheck = SetupUI.check("半角カナ(&F)")
    private let kanaSendCheck = SetupUI.check("半角カナ(&D)")
    private lazy var kanjiInPopup = pop(["^[$@", "^[$B"], ["@", "B"], \.kanjiIn)
    private lazy var kanjiOutPopup = pop(["^[(B", "^[(J"], ["B", "J"], \.kanjiOut)
    private func encodingPage() -> NSView {
        let all = TermEncoding.allCases
        for p in [recvPopup, sendPopup, ambPopup] { p.target = self; p.action = #selector(changed(_:)) }
        differentCheck.target = self; differentCheck.action = #selector(changed(_:))
        bind(emojiCheck, \.unicodeEmojiOverride)
        bind(kanaRecvCheck, \.katakanaReceive7)
        bind(kanaSendCheck, \.katakanaSend7)
        for (i, r) in decRadios.enumerated() {
            r.target = self; r.action = #selector(decChanged(_:))
            custom(load: { [unowned self] in r.state = self.s.decSpMappingDir == i ? .on : .off },
                   store: { [unowned self] in if r.state == .on { self.s.decSpMappingDir = i } })
        }
        for (i, c) in [boxCheck, punctCheck, middleDotCheck].enumerated() {
            c.target = self; c.action = #selector(changed(_:))
            custom(load: { [unowned self] in c.state = self.s.unicodeToDecSpMapping & (1 << i) != 0 ? .on : .off },
                   store: { [unowned self] in
                       if c.state == .on { self.s.unicodeToDecSpMapping |= 1 << i } else { self.s.unicodeToDecSpMapping &= ~(1 << i) } })
        }
        custom(load: { [unowned self] in
            self.recvPopup.selectItem(at: all.firstIndex(of: self.s.encoding) ?? 0)
            self.sendPopup.selectItem(at: all.firstIndex(of: self.s.encodingSend) ?? 0)
            self.differentCheck.state = self.s.encoding != self.s.encodingSend ? .on : .off
            self.ambPopup.selectItem(at: self.s.ambiguousWide ? 1 : 0)
        }, store: { [unowned self] in
            self.s.encoding = all[max(0, self.recvPopup.indexOfSelectedItem)]
            self.s.encodingSend = self.differentCheck.state == .on ? all[max(0, self.sendPopup.indexOfSelectedItem)] : self.s.encoding
            self.s.ambiguousWide = self.ambPopup.indexOfSelectedItem == 1
        })
        return SetupUI.column([
            SetupUI.box("Encoding", SetupUI.grid([
                [SetupUI.label("R&eceive"), recvPopup],
                [differentCheck, sendPopup],
            ])),
            SetupUI.box("Unicode", SetupUI.grid([
                [SetupUI.label("Ambiguous Characters width"), ambPopup],
                [emojiCheck, emojiPopup],
            ])),
            SetupUI.box("DEC Special Graphics", SetupUI.column(decRadios + [SetupUI.indent(SetupUI.column([boxCheck, punctCheck, middleDotCheck]))])),
            SetupUI.box("JIS", SetupUI.grid([
                [SetupUI.label("Receive"), kanaRecvCheck],
                [SetupUI.label("Transmit"), SetupUI.row([kanaSendCheck, SetupUI.label("漢字イン(&N):"), kanjiInPopup,
                                                         SetupUI.label("漢字アウト(&O):"), kanjiOutPopup])],
            ])),
        ], spacing: 8)
    }
    @objc private func decChanged(_ sender: NSButton) {
        for r in decRadios where r !== sender { r.state = .off }
    }

    // フォント (font_pp.cpp)
    private let fontField = SetupUI.field(width: 280)
    private let spaceTop = SetupUI.field(width: 44), spaceBottom = SetupUI.field(width: 44)
    private let spaceLeft = SetupUI.field(width: 44), spaceRight = SetupUI.field(width: 44)
    private func fontPage() -> NSView {
        fontField.isEditable = false
        custom(load: { [unowned self] in
            self.spaceLeft.stringValue = String(self.s.fontDX)
            self.spaceRight.stringValue = String(self.s.fontDW - self.s.fontDX)
            self.spaceTop.stringValue = String(self.s.fontDY)
            self.spaceBottom.stringValue = String(self.s.fontDH - self.s.fontDY)
        }, store: { [unowned self] in
            let l = Int(self.spaceLeft.stringValue) ?? 0, r = Int(self.spaceRight.stringValue) ?? 0
            let t = Int(self.spaceTop.stringValue) ?? 0, b = Int(self.spaceBottom.stringValue) ?? 0
            (self.s.fontDX, self.s.fontDW, self.s.fontDY, self.s.fontDH) = (l, l + r, t, t + b)
        })
        let fontsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Fonts")
        let cross = SetupUI.grid([
            [NSGridCell.emptyContentView, spaceTop, NSGridCell.emptyContentView],
            [spaceLeft, SetupUI.label("Aa"), spaceRight],
            [NSGridCell.emptyContentView, spaceBottom, NSGridCell.emptyContentView],
        ])
        cross.column(at: 1).xPlacement = .center
        return SetupUI.column([
            SetupUI.label("VTウィンドウフォント(&V)"),
            SetupUI.indent(SetupUI.row([fontField, SetupUI.button("選択(&S)...", target: self, action: #selector(chooseFont))])),
            SetupUI.button("フォント設定/フォントフォルダ(\(fontsDir))を開く", target: self, action: #selector(openFontFolder)),
            cb("描画幅に合わせてリサイズしたフォントを描画(&W)", \.drawingResizedFont),
            SetupUI.box("文字間スペース", cross),
        ], spacing: 10)
    }
    private func updateFontLabel() {
        fontField.stringValue = "\(s.font.displayName ?? s.fontName), \(Int(s.fontSize))pt"
    }
    @objc private func chooseFont() {
        let fm = NSFontManager.shared
        fm.target = self
        fm.action = #selector(changeFontFromPanel(_:))
        fm.setSelectedFont(s.font, isMultiple: false)
        fm.fontPanel(true)?.makeKeyAndOrderFront(nil)
    }
    @objc func changeFontFromPanel(_ sender: Any?) {
        let f = NSFontManager.shared.convert(s.font)
        s.fontName = f.fontName
        s.fontSize = f.pointSize
        refresh()
    }
    @objc private func openFontFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Fonts")))
    }

    // テーマ (theme_pp.cpp)。下に Mac の配色の候補 (配色かんたん設定)
    private let themeEnableCheck = SetupUI.check("Enable")
    private lazy var themeEditorButton = SetupUI.button("Theme Editor", target: self, action: nil)
    private let fastSizeMoveCheck = SetupUI.check("ウィンドウ移動/リサイズ時テーマを一時的にdisableする")
    private let themeStartupPopup = SetupUI.popup(["使用しない", "固定テーマ(テーマファイル指定)", "ランダムテーマ"])
    private let themeFileField = SetupUI.field(width: 380)
    private lazy var themeFileButton = SetupUI.button("...", target: self, action: #selector(chooseThemeFile))
    private let bundledThemePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let schemePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let preview = SchemePreview()
    private let cursorWell = NSColorWell()
    private func themePage() -> NSView {
        // テーマ
        themeEnableCheck.target = self; themeEnableCheck.action = #selector(changed(_:))
        themeStartupPopup.target = self; themeStartupPopup.action = #selector(themeSettingChanged)
        themeFileField.delegate = self
        themeEditorButton.isEnabled = false   // テーマエディタ (themedlg.cpp) は未対応
        themeEditorButton.toolTip = "Mac 版では未対応です"
        bundledThemePopup.addItem(withTitle: "同梱のテーマ")
        for p in ThemeFile.bundledThemes() {
            let item = NSMenuItem(title: ThemeFile.storedName(for: p), action: nil, keyEquivalent: "")
            item.representedObject = p
            bundledThemePopup.menu?.addItem(item)
        }
        bundledThemePopup.target = self; bundledThemePopup.action = #selector(bundledThemeChosen)
        custom(load: { [unowned self] in
            let t = ThemeSettings.load()
            self.themeEnableCheck.state = ThemeRuntime.shared.enabled ? .on : .off
            self.fastSizeMoveCheck.state = t.fastSizeMove ? .on : .off
            self.themeStartupPopup.selectItem(at: t.bgEnable)
            self.themeFileField.stringValue = t.themeFile
        }, store: {})

        // Mac の配色の候補
        schemes = ColorScheme.presets + ColorScheme.terminalProfiles()
        schemePopup.addItem(withTitle: "使用しない")
        for (i, sc) in schemes.enumerated() {
            if i == ColorScheme.presets.count { schemePopup.menu?.addItem(.separator()) }
            let item = NSMenuItem(title: sc.name, action: nil, keyEquivalent: "")
            item.image = sc.swatch()
            item.tag = i
            schemePopup.menu?.addItem(item)
        }
        schemePopup.target = self
        schemePopup.action = #selector(schemeChosen)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 440).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 118).isActive = true
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.masksToBounds = true
        cursorWell.translatesAutoresizingMaskIntoConstraints = false
        cursorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        cursorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        cursorWell.target = self; cursorWell.action = #selector(changed(_:))
        custom(load: { [unowned self] in
            self.cursorWell.color = self.s.cursorColor
            if let i = self.schemes.firstIndex(where: { $0.name == self.s.themeName }) {
                self.schemePopup.selectItem(withTag: i)
            } else { self.schemePopup.selectItem(at: 0) }
        }, store: { [unowned self] in self.s.cursorColor = self.cursorWell.color })
        let note = NSTextField(wrappingLabelWithString: "配色を選ぶと、文字色・背景色・カーソルの色・ANSIカラーをその配色にします (OK で確定)。")
        note.preferredMaxLayoutWidth = 440
        return SetupUI.column([
            SetupUI.label("Theme"),
            SetupUI.indent(SetupUI.column([
                themeEnableCheck,
                themeEditorButton,
                fastSizeMoveCheck,
                SetupUI.label("Startup"),
                SetupUI.indent(SetupUI.column([
                    SetupUI.row([themeStartupPopup, bundledThemePopup]),
                    SetupUI.row([themeFileField, themeFileButton]),
                ])),
            ], spacing: 8)),
            SetupUI.indent(preview),
            SetupUI.box("配色 (Mac)", SetupUI.column([
                SetupUI.row([SetupUI.label("配色"), schemePopup, SetupUI.label("カーソルの色"), cursorWell]),
                note,
            ])),
        ], spacing: 10)
    }
    /// テーマタブの有効・無効 (theme_pp.cpp ArrangeControls / CBN_SELCHANGE)
    private func updateThemeControls() {
        let on = themeEnableCheck.state == .on
        let fixed = themeStartupPopup.indexOfSelectedItem == 1
        fastSizeMoveCheck.isEnabled = on
        themeStartupPopup.isEnabled = on
        themeFileField.isEnabled = on && fixed
        themeFileButton.isEnabled = on && fixed
        bundledThemePopup.isEnabled = on && fixed
    }
    @objc private func themeSettingChanged() { refresh() }
    @objc private func bundledThemeChosen() {
        guard let p = bundledThemePopup.selectedItem?.representedObject as? String else { return }
        themeFileField.stringValue = ThemeFile.storedName(for: p)
        refresh()
    }
    @objc private func chooseThemeFile() {
        let p = NSOpenPanel()
        p.title = "select theme file"
        p.allowedFileTypes = ["ini", "INI"]
        p.allowsOtherFileTypes = true
        let cur = ThemeFile.resolve(themeFileField.stringValue)
        p.directoryURL = URL(fileURLWithPath: cur.map { ($0 as NSString).deletingLastPathComponent } ?? ThemeFile.themeDirectory ?? NSHomeDirectory())
        p.beginSheetModal(for: panel) { r in
            if r == .OK, let u = p.url { self.themeFileField.stringValue = ThemeFile.storedName(for: u.path); self.refresh() }
        }
    }
    /// 見本に出すテーマ (固定テーマのときだけ。ランダムは毎回変わるので出さない)
    private var previewTheme: ThemeData? {
        guard themeEnableCheck.state == .on, themeStartupPopup.indexOfSelectedItem == 1,
              let path = ThemeFile.resolve(themeFileField.stringValue) else { return nil }
        if previewThemeCache?.path != path { previewThemeCache = ThemeFile.load(path, base: themeBase(s)) }
        return previewThemeCache
    }
    private var previewThemeCache: ThemeData?
    /// テーマの色の既定値 (テーマを当てる前の色)
    private func themeBase(_ cur: TermSettings) -> TermSettings {
        var b = cur
        if let bk = ThemeSettings.colorBackup { ThemeSettings.restore(bk, to: &b) }
        return b
    }
    /// OK: テーマの設定を保存し、変わっていればすぐ当てる (Tera Term は次の接続から。BGLoadThemeFile)
    private func applyThemeTab() {
        let old = ThemeSettings.load()
        var t = ThemeSettings()
        t.bgEnable = max(0, themeStartupPopup.indexOfSelectedItem)
        t.themeFile = themeFileField.stringValue.trimmingCharacters(in: .whitespaces)
        t.fastSizeMove = fastSizeMoveCheck.state == .on
        ThemeRuntime.shared.enabled = themeEnableCheck.state == .on
        if t.bgEnable != 0 {
            if t != old || ThemeRuntime.shared.current == nil {
                let base = themeBase(s)
                let path = t.bgEnable == 1 ? ThemeFile.resolve(t.themeFile) : ThemeFile.randomTheme()
                if let path = path {
                    let d = ThemeFile.load(path, base: base)
                    if ThemeSettings.colorBackup == nil { ThemeSettings.colorBackup = ThemeSettings.backup(s) }
                    d.colors.apply(to: &s)
                    ThemeRuntime.shared.set(d)
                }
            }
        } else if old.bgEnable != 0 {
            if let b = ThemeSettings.colorBackup { ThemeSettings.restore(b, to: &s); ThemeSettings.colorBackup = nil }
            ThemeRuntime.shared.set(nil)
        }
        t.save()
    }
    @objc private func schemeChosen() {
        guard schemePopup.indexOfSelectedItem > 0, let item = schemePopup.selectedItem else { s.themeName = ""; return }
        let sc = schemes[item.tag]
        s.themeName = sc.name
        workColors[0] = ColorPair(fg: sc.fg, bg: sc.bg)
        cursorWell.color = sc.cursor
        ansiWork = sc.ansi16 ?? Array(Palette.colors.prefix(16))
        refresh()
    }
    private func updatePreview() {
        if let th = previewTheme {
            preview.fg = th.colors.vt.fg
            preview.bg = th.colors.vt.bg
            preview.ansi = th.colors.ansi
            preview.background = th.background.isEnabled ? th.background : nil
        } else {
            preview.fg = workColors.first?.fg ?? s.fg
            preview.bg = workColors.first?.bg ?? s.bg
            if !ansiWork.isEmpty { preview.ansi = ansiWork }
            preview.background = nil
        }
        preview.cursor = cursorWell.color
        preview.font = NSFont(name: s.fontName, size: 12) ?? preview.font
    }

    // UI (ui_pp.cpp)。言語は macOS の設定に従うので日本語だけ。ダイアログフォントは Mac では変えられないので無い
    private func uiPage() -> NSView {
        let lang = SetupUI.popup(["日本語"])
        lang.isEnabled = false
        let note = NSTextField(wrappingLabelWithString: "Mac 版の表示言語は日本語です (メニューやダイアログの文字は macOS の設定に従います)。")
        note.preferredMaxLayoutWidth = 420
        note.textColor = .secondaryLabelColor
        let fontsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Fonts")
        let link = NSButton(title: "フォント設定/フォントフォルダ(\(fontsDir))を開く", target: self, action: #selector(openFontFolder))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.attributedTitle = NSAttributedString(string: link.title, attributes: [
            .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .font: NSFont.systemFont(ofSize: 13)])
        return SetupUI.column([
            SetupUI.label("UI言語(&L):"),
            SetupUI.indent(lang),
            SetupUI.indent(note),
            SetupUI.indent(link),
        ], spacing: 8)
    }

    // ローカルシェル (Cygwin タブ cygwin_pp の場所。CygTerm の SHELL / TERM / ENV_1 / ENV_2 / LOGIN_SHELL / HOME_CHDIR)
    private let shellField = SetupUI.field(width: 260)
    private let shellTermField = SetupUI.field(width: 260)
    private let shellEnv1Field = SetupUI.field(width: 260)
    private let shellEnv2Field = SetupUI.field(width: 260)
    private let loginShellCheck = SetupUI.check("LOGIN_SHELL")
    private let homeChdirCheck = SetupUI.check("HOME_CHDIR")
    private func localShellPage() -> NSView {
        shellField.placeholderString = LocalShellSettings.defaultShell
        shellEnv1Field.placeholderString = "名前=値"
        shellEnv2Field.placeholderString = "名前=値"
        custom(load: { [unowned self] in
            let l = LocalShellSettings.load()
            self.shellField.stringValue = l.shell.isEmpty ? LocalShellSettings.defaultShell : l.shell
            self.shellTermField.stringValue = l.term
            self.shellEnv1Field.stringValue = l.env1
            self.shellEnv2Field.stringValue = l.env2
            self.loginShellCheck.state = l.loginShell ? .on : .off
            self.homeChdirCheck.state = l.homeChdir ? .on : .off
        }, store: { [unowned self] in
            var l = LocalShellSettings()
            let sh = self.shellField.stringValue.trimmingCharacters(in: .whitespaces)
            l.shell = sh == LocalShellSettings.defaultShell ? "" : sh
            let term = self.shellTermField.stringValue.trimmingCharacters(in: .whitespaces)
            l.term = term.isEmpty ? "xterm-256color" : term
            l.env1 = self.shellEnv1Field.stringValue
            l.env2 = self.shellEnv2Field.stringValue
            l.loginShell = self.loginShellCheck.state == .on
            l.homeChdir = self.homeChdirCheck.state == .on
            l.save()
        })
        let shellButton = SetupUI.button("...", target: self, action: #selector(chooseShell))
        let note = NSTextField(wrappingLabelWithString: "ファイル > ローカルシェル で開くシェルの設定です (新しく開くときから)。")
        note.preferredMaxLayoutWidth = 420
        note.textColor = .secondaryLabelColor
        return SetupUI.column([
            SetupUI.box("ローカルシェル", SetupUI.column([
                SetupUI.grid([
                    [SetupUI.label("SHELL"), SetupUI.row([shellField, shellButton])],
                    [SetupUI.label("TERM"), shellTermField],
                    [SetupUI.label("ENV_1"), shellEnv1Field],
                    [SetupUI.label("ENV_2"), shellEnv2Field],
                ]),
                SetupUI.row([loginShellCheck, homeChdirCheck], spacing: 20),
            ], spacing: 10)),
            note,
        ], spacing: 10)
    }
    @objc private func chooseShell() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.directoryURL = URL(fileURLWithPath: "/bin")
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { self.shellField.stringValue = u.path } }
    }

    // キーボード (keyboard_pp.c)
    private func keyboardPage() -> NSView {
        SetupUI.column([
            SetupUI.box("DELを送信するキー:", SetupUI.column([
                cb("&Backspace キー", \.bsSendsDel), cb("&Delete キー", \.deleteKeySendsDel),
            ])),
            SetupUI.row([SetupUI.label("&Meta キー:"), pop(["off", "on", "left", "right"], ["off", "on", "left", "right"], \.metaKey),
                         SetupUI.label("(Option キー)")]),
            SetupUI.box("無効化するモード", SetupUI.column([
                cb("アプリケーションキーパッド(&A)", \.disableAppKeypad), cb("アプリケーションカーソル(&C)", \.disableAppCursor),
            ])),
        ], spacing: 10)
    }

    // マウス (mouse_pp.cpp)
    private func mousePage() -> NSView {
        SetupUI.column([
            cb("クリッカブルURLを有効にする(&E)", \.enableClickableUrl),
            SetupUI.row([SetupUI.label("ホイールのスクロール行数(&W)"), num(\.mouseWheelScrollLine, width: 50, range: 1...100)]),
        ], spacing: 10)
    }

    // TCP/IP (tcpip_pp.cpp)
    private func tcpipPage() -> NSView {
        let edit = SetupUI.button("ホストリストの編集", target: self, action: #selector(editHosts))
        return SetupUI.column([
            SetupUI.row([cb("新規接続時にホストリストに追加(&I)", \.historyList), edit]),
            SetupUI.row([cb("T&elnet", \.telnet), SetupUI.label("ポート#(&P):"), num(\.tcpPort, width: 70, range: 1...65535)]),
            SetupUI.row([SetupUI.label("Telnet &Keep-alive"), num(\.telKeepAliveInterval, width: 60), SetupUI.label("秒(0指定で無効)")]),
            cb("自動的にウィンドウを閉じる(&W)", \.autoWinClose),
            SetupUI.row([SetupUI.label("端末タイプ(&T):"), text(\.termType, width: 160)]),
        ], spacing: 10)
    }
    @objc private func editHosts() { HostListEditDialog().begin(on: panel) }

    // 端末 (term_pp.cpp)
    private let termIsWinCheck = SetupUI.check("= ウィンドウサイズ(&S):")
    private let termResizeCheck = SetupUI.check("自動的に調整(&W):")
    private let colsField = SetupUI.field(width: 50), rowsField = SetupUI.field(width: 50)
    private func terminalPage() -> NSView {
        bind(termIsWinCheck, \.termIsWin)
        bind(termResizeCheck, \.autoWinResize)
        for f in [colsField, rowsField] { f.delegate = self }
        custom(load: { [unowned self] in
            self.colsField.stringValue = String(self.s.cols); self.rowsField.stringValue = String(self.s.rows)
        }, store: { [unowned self] in
            // 0 以下は変えない。大きすぎるときは最大に
            if let c = Int(self.colsField.stringValue), c > 0 { self.s.cols = max(10, min(500, c)) }
            if let r = Int(self.rowsField.stringValue), r > 0 { self.s.rows = max(2, min(300, r)) }
        })
        let recv = pop(["CR", "CR+LF", "LF", "AUTO"], ["AUTO", "CR", "LF", "AUTODETECT"], \.recvNewline)
        let send = pop(["CR", "CR+LF", "LF"], ["CR", "CRLF", "LF"], \.sendNewline)
        let ids = ["VT100", "VT100J", "VT101", "VT102", "VT102J", "VT220", "VT220J", "VT282", "VT320", "VT382", "VT420", "VT520", "VT525", "dumb"]
        return SetupUI.column([
            SetupUI.box("端末サイズ(&T):", SetupUI.column([
                SetupUI.row([colsField, SetupUI.label("X"), rowsField]),
                termIsWinCheck, termResizeCheck,
            ])),
            SetupUI.box("改行コード", SetupUI.grid([[SetupUI.label("受信(&R):"), recv], [SetupUI.label("送信(&M):"), send]])),
            SetupUI.grid([
                [SetupUI.label("端末ID(&I):"), pop(ids, ids, \.terminalID)],
                [SetupUI.label("応答(&A):"), text(\.answerback, width: 200)],
            ]),
            cb("ローカルエコー(&L):", \.localEcho),
            cb("自動切り替え(VT<->TEK)(&U):", \.autoWinSwitch),
        ], spacing: 10)
    }

    // シリアルポート (serial_pp.cpp)
    private let portPopup = NSPopUpButton()
    private let baudCombo = NSComboBox()
    private let dataPopup = SetupUI.popup(["7 bit", "8 bit"])
    private let parityPopup = SetupUI.popup(["none", "odd", "even", "mark", "space"])
    private let stopPopup = SetupUI.popup(["1 bit", "2 bit"])
    private let flowPopup = SetupUI.popup(["Xon/Xoff", "RTS/CTS", "DSR/DTR", "none"])
    private let statusChecks = ["CTS", "DSR", "RING", "RLSD"].map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
    private let rtsCheck = NSButton(checkboxWithTitle: "RTS", target: nil, action: nil)
    private let dtrCheck = NSButton(checkboxWithTitle: "DTR", target: nil, action: nil)
    private let serialInfo = NSTextField(wrappingLabelWithString: "")
    private var statusTimer: Timer?
    private static let flowValues = ["xon", "rts", "dsr", "none"]
    private func serialPage() -> NSView {
        let open = session?.conn as? SerialConnection
        let ports = SerialPort.list()
        portPopup.addItems(withTitles: ports.isEmpty ? ["(シリアルポートが見つかりません)"] : ports)
        if !serial.path.isEmpty && !ports.contains(serial.path) { portPopup.addItem(withTitle: serial.path) }
        if !serial.path.isEmpty { portPopup.selectItem(withTitle: serial.path) }
        portPopup.isEnabled = open == nil && !ports.isEmpty   // 開いている間は変えられない
        baudCombo.addItems(withObjectValues: SerialPort.baudRates.map(String.init))
        baudCombo.stringValue = String(serial.baud)
        baudCombo.translatesAutoresizingMaskIntoConstraints = false
        baudCombo.widthAnchor.constraint(equalToConstant: 110).isActive = true
        dataPopup.selectItem(at: serial.dataBits == 7 ? 0 : 1)
        parityPopup.selectItem(withTitle: serial.parity)
        stopPopup.selectItem(at: serial.stopBits == 2 ? 1 : 0)
        flowPopup.selectItem(at: Self.flowValues.firstIndex(of: serial.flow) ?? 3)
        for c in statusChecks { c.isEnabled = false }
        for c in [rtsCheck, dtrCheck] {
            c.target = self; c.action = #selector(modemLineChanged(_:)); c.state = .on
            c.isEnabled = open != nil && open?.flow == "none"
        }
        serialInfo.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        serialInfo.preferredMaxLayoutWidth = 260
        if let o = open {
            serialInfo.stringValue = "\(o.params.path)\n開いています\n\(serial.baud) bps \(serial.dataBits)\(serial.parity.prefix(1).uppercased())\(serial.stopBits)"
            statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollModem() }
        } else {
            serialInfo.stringValue = ports.isEmpty ? "" : "ポートは開いていません。\n設定は次にシリアルポートを開くときに使います。"
        }
        let grid = SetupUI.grid([
            [SetupUI.label("ポート(&P):"), portPopup],
            [SetupUI.label("スピード(&E):"), baudCombo],
            [SetupUI.label("データ(&D):"), dataPopup],
            [SetupUI.label("パリティ(&A):"), parityPopup],
            [SetupUI.label("ストップビット(&S):"), stopPopup],
            [SetupUI.label("フロー制御(&F):"), flowPopup],
        ])
        let delay = SetupUI.box("送信遅延", SetupUI.row([
            num(\.charDelayMs, width: 50, range: 0...9999), SetupUI.label("ミリ秒/字(&C)"),
            num(\.lineDelayMs, width: 50, range: 0...9999), SetupUI.label("ミリ秒/行(&L)"),
        ]))
        let status = SetupUI.column([SetupUI.row(statusChecks), SetupUI.row([rtsCheck, dtrCheck])])
        return SetupUI.row([SetupUI.column([grid, delay], spacing: 12), SetupUI.column([serialInfo, status], spacing: 12)],
                           spacing: 24, align: .top)
    }
    private func pollModem() {
        guard let o = session?.conn as? SerialConnection, let st = o.modemStatus() else { return }
        for (i, c) in statusChecks.enumerated() { c.state = st & (1 << i) != 0 ? .on : .off }
    }
    @objc private func modemLineChanged(_ sender: NSButton) {
        guard let o = session?.conn as? SerialConnection else { return }
        o.setModemLine(sender === rtsCheck ? TIOCM_RTS : TIOCM_DTR, sender.state == .on)
    }

    // ウィンドウ (win_pp.cpp)
    private let cursorRadios = [SetupUI.radio("四角(&L):"), SetupUI.radio("垂直線(&V):"), SetupUI.radio("下線(&O):")]
    private let scrollCheck = SetupUI.check("スクロールバッファ(&S):")
    private lazy var scrollField = num(\.scrollback, width: 80, range: 0...1_000_000)
    private let boldCheckWindow = SetupUI.check("太字を有効(&D)")
    private let textRadio = SetupUI.radio("文字(&X)")
    private let backRadio = SetupUI.radio("背景(&K)")
    private let attrPopup = SetupUI.popup(["標準", "太字", "点滅", "反転", "URL", "下線"])
    private let rgbSliders = (0..<3).map { _ in NSSlider(value: 0, minValue: 0, maxValue: 255, target: nil, action: nil) }
    private let rgbLabels = (0..<3).map { _ in NSTextField(labelWithString: "0") }
    private let sampleView = ColorSampleView()
    /// 編集中の色 (標準, 太字, 点滅, 反転, URL, 下線)
    private var workColors: [ColorPair] = []
    private static let attrKeys: [WritableKeyPath<TermSettings, ColorPair>] = [\.boldColor, \.blinkColor, \.reverseColor, \.urlColor, \.underlineColor]
    private func windowPage() -> NSView {
        bind(scrollCheck, \.enableScrollBuff)
        bind(boldCheckWindow, \.enableBold)
        for (i, r) in cursorRadios.enumerated() {
            r.target = self; r.action = #selector(cursorChanged(_:))
            let v = ["block", "vertical", "horizontal"][i]
            custom(load: { [unowned self] in r.state = self.s.cursorShape == v ? .on : .off },
                   store: { [unowned self] in if r.state == .on { self.s.cursorShape = v } })
        }
        custom(load: { [unowned self] in
            self.workColors = [ColorPair(fg: self.s.fg, bg: self.s.bg)] + Self.attrKeys.map { self.s[keyPath: $0] }
            self.textRadio.state = .on
        }, store: { [unowned self] in
            self.s.fg = self.workColors[0].fg; self.s.bg = self.workColors[0].bg
            for (i, k) in Self.attrKeys.enumerated() { self.s[keyPath: k] = self.workColors[i + 1] }
        })
        for r in [textRadio, backRadio] { r.target = self; r.action = #selector(fgbgChanged(_:)) }
        attrPopup.target = self; attrPopup.action = #selector(changed(_:))
        for sl in rgbSliders {
            sl.target = self; sl.action = #selector(rgbChanged)
            sl.translatesAutoresizingMaskIntoConstraints = false
            sl.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        for l in rgbLabels {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        sampleView.translatesAutoresizingMaskIntoConstraints = false
        sampleView.widthAnchor.constraint(equalToConstant: 200).isActive = true
        sampleView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let swap = SetupUI.button("色入れ替え(&W)", target: self, action: #selector(swapColors))
        let left = SetupUI.column([
            SetupUI.row([SetupUI.label("タイトル(&T):"), text(\.title, width: 200)]),
            SetupUI.box("カーソルの形", SetupUI.column(cursorRadios + [cb("カーソルを点滅", \.cursorBlink)])),
            cb("&16色モード(PC形式):", \.pcBoldColor),
            cb("1&6色モード(aixterm形式):", \.aixterm16Color),
            cb("&256色モード(xterm形式):", \.xterm256Color),
            SetupUI.row([scrollCheck, scrollField, SetupUI.label("行(&N)")]),
            boldCheckWindow,
        ], spacing: 8)
        let colorBox = SetupUI.box("カラー", SetupUI.column([
            SetupUI.row([textRadio, backRadio, SetupUI.label("属性(&A)"), attrPopup]),
            swap,
            SetupUI.row([SetupUI.label("赤(&R):"), rgbSliders[0], rgbLabels[0]]),
            SetupUI.row([SetupUI.label("緑(&G):"), rgbSliders[1], rgbLabels[1]]),
            SetupUI.row([SetupUI.label("青(&B):"), rgbSliders[2], rgbLabels[2]]),
            cb("常に標準の背景色を使う(&U)", \.useNormalBGColor),
            sampleView,
        ], spacing: 6))
        return SetupUI.row([left, colorBox], spacing: 20, align: .top)
    }
    @objc private func cursorChanged(_ sender: NSButton) { for r in cursorRadios where r !== sender { r.state = .off } }
    @objc private func fgbgChanged(_ sender: NSButton) {
        for r in [textRadio, backRadio] where r !== sender { r.state = .off }
        refresh()
    }
    private var currentAttr: Int { max(0, attrPopup.indexOfSelectedItem) }
    private func updateColorControls() {
        guard currentAttr < workColors.count else { return }
        let p = workColors[currentAttr]
        let c = textRadio.state == .on ? p.fg : p.bg
        let (r, g, b) = TermSettings.rgbComponents(c)
        for (i, v) in [r, g, b].enumerated() { rgbSliders[i].integerValue = v; rgbLabels[i].stringValue = String(v) }
        sampleView.pair = p
        updatePreview()
    }
    @objc private func rgbChanged() {
        guard currentAttr < workColors.count else { return }
        let c = TermSettings.rgb(rgbSliders[0].integerValue, rgbSliders[1].integerValue, rgbSliders[2].integerValue)
        if textRadio.state == .on { workColors[currentAttr].fg = c } else { workColors[currentAttr].bg = c }
        refresh()
    }
    @objc private func swapColors() {
        guard currentAttr < workColors.count else { return }
        let p = workColors[currentAttr]
        workColors[currentAttr] = ColorPair(fg: p.bg, bg: p.fg)
        refresh()
    }

    // MARK: OK / キャンセル

    /// ログの標準ファイル名の確認 (log_pp.cpp の OnOK)
    private func validate() -> String? {
        let n = logNameCombo.stringValue
        if n.isEmpty || n.contains("/") || n.contains(":") { return "ログファイル名に使えない文字が含まれています。" }
        if n.utf8.count > 255 { return "ログファイル名が長すぎます。" }
        return nil
    }

    override func ok() {
        if let e = validate() {
            selectPage(at: Page.allCases.firstIndex(of: .log)!)
            let a = NSAlert()
            a.messageText = "Tera Term: エラー"
            a.informativeText = e
            a.beginSheetModal(for: panel)
            return
        }
        for b in binders { b.store() }
        applyThemeTab()
        s.optionAsMeta = s.metaKey.lowercased() != "off"
        // シリアルポート
        if portPopup.isEnabled, let p = portPopup.titleOfSelectedItem { serial.path = p }
        if let b = Int(baudCombo.stringValue.trimmingCharacters(in: .whitespaces)), b > 0 { serial.baud = b }
        serial.dataBits = dataPopup.indexOfSelectedItem == 0 ? 7 : 8
        serial.parity = parityPopup.titleOfSelectedItem ?? "none"
        serial.stopBits = stopPopup.indexOfSelectedItem == 1 ? 2 : 1
        serial.flow = Self.flowValues[max(0, flowPopup.indexOfSelectedItem)]
        fileDir = fileDirField.stringValue
        s.fileDir = fileDir
        finish()
        completion?(s)
    }

    override func cancel() {
        finish()
        completion?(nil)
    }

    private func finish() {
        statusTimer?.invalidate()
        statusTimer = nil
        NSFontManager.shared.fontPanel(false)?.orderOut(nil)
        close()
    }
}

/// 以前の名前 (main.swift のスナップショット自己テストが使う)
typealias SetupDialog = SetupSheet

private extension Int {
    /// LogRotate (0 / 1) をチェックボックスに
    var asBool: Bool {
        get { self != 0 }
        set { self = newValue ? 1 : 0 }
    }
}

/// 数値の欄とスライダーをつなぐ (表示タブの不透明度)
final class SliderSync: NSObject, NSTextFieldDelegate {
    let field: NSTextField
    let slider: NSSlider
    private weak var otherDelegate: NSTextFieldDelegate?
    init(field: NSTextField, slider: NSSlider) {
        self.field = field
        self.slider = slider
        super.init()
        slider.target = self
        slider.action = #selector(slid)
        otherDelegate = field.delegate
        field.delegate = self
    }
    @objc private func slid() { field.stringValue = String(slider.integerValue) }
    func update() { slider.integerValue = Int(field.stringValue) ?? slider.integerValue }
    func controlTextDidChange(_ obj: Notification) {
        update()
        otherDelegate?.controlTextDidChange?(obj)
    }
}

/// ウィンドウタブの見本 (IDC_DRAW_SAMPLE_AREA)
final class ColorSampleView: NSView {
    var pair = ColorPair(0xFFFFFF, 0x000000) { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        pair.bg.setFill()
        bounds.fill()
        NSColor.gray.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let s = NSAttributedString(string: "ABCdef123", attributes: [.font: font, .foregroundColor: pair.fg])
        let sz = s.size()
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }
}

/// ホストリストの編集 (EditHistoryDlg)
final class HostListEditDialog: SheetDialog, NSTableViewDataSource, NSTableViewDelegate {
    private var hosts = ConnHistory.hosts
    private let table = NSTableView()
    private let entry = SetupUI.field(width: 300)

    func begin(on w: NSWindow) {
        panel.title = "Tera Term: ホストリストの編集"
        let col = NSTableColumn(identifier: .init("h"))
        col.width = 300
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selected)
        let sc = NSScrollView()
        sc.documentView = table
        sc.hasVerticalScroller = true
        sc.borderType = .bezelBorder
        sc.translatesAutoresizingMaskIntoConstraints = false
        sc.widthAnchor.constraint(equalToConstant: 320).isActive = true
        sc.heightAnchor.constraint(equalToConstant: 200).isActive = true
        let buttons = SetupUI.column([
            SetupUI.button("追加(&A)", target: self, action: #selector(add)),
            SetupUI.button("置換(&R)", target: self, action: #selector(replace)),
            SetupUI.button("削除(&D)", target: self, action: #selector(remove)),
            SetupUI.button("上へ(&U)", target: self, action: #selector(up)),
            SetupUI.button("下へ(&N)", target: self, action: #selector(down)),
        ])
        layout(SetupUI.column([entry, SetupUI.row([sc, buttons], align: .top)], spacing: 8))
        present(on: w)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { hosts.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: hosts[row])
    }
    @objc private func selected() { if table.selectedRow >= 0 { entry.stringValue = hosts[table.selectedRow] } }
    @objc private func add() {
        let v = entry.stringValue.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        hosts.insert(v, at: max(0, table.selectedRow)); table.reloadData()
    }
    @objc private func replace() {
        let r = table.selectedRow, v = entry.stringValue.trimmingCharacters(in: .whitespaces)
        guard r >= 0, !v.isEmpty else { return }
        hosts[r] = v; table.reloadData()
    }
    @objc private func remove() {
        let r = table.selectedRow
        guard r >= 0 else { return }
        hosts.remove(at: r); table.reloadData()
    }
    @objc private func up() { move(-1) }
    @objc private func down() { move(1) }
    private func move(_ d: Int) {
        let r = table.selectedRow
        guard r >= 0, r + d >= 0, r + d < hosts.count else { return }
        hosts.swapAt(r, r + d); table.reloadData()
        table.selectRowIndexes([r + d], byExtendingSelection: false)
    }
    override func ok() { ConnHistory.hosts = hosts; close() }
    override func cancel() { close() }
}
