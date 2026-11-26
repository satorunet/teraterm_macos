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
            if let v = value { lines[i] = "\(key)=\(IniFile.quoteIfNeeded(v))" } else { lines.remove(at: i) }
        } else if let v = value {
            // セクションの最後の空でない行のあと
            var at = r.upperBound
            while at > r.lowerBound + 1 && lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert("\(key)=\(IniFile.quoteIfNeeded(v))", at: at)
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
    /// タブ (addsetting.cpp の順。Cygwin の場所は Mac のローカルシェル。Debug / TEK は無い。
    /// Plugin は Mac の組み込みプラグインの一覧 (TTMado の入/切) で、いちばん後ろ)
    enum Page: Int, CaseIterable {
        case general, ui, sequence, copyPaste, visual, log, localShell, encoding, font, theme, keyboard, mouse, tcpip, terminal, serial, window, plugins
        var title: String {
            switch self {
            case .general: return Lang.t("Tera Term", "DLG_TABSHEET_TITLE_GENERAL", "全般")
            case .ui: return "UI"
            case .localShell: return Lang.m("SETUP_TAB_LOCAL_SHELL", "ローカルシェル")
            case .sequence: return Lang.t("Tera Term", "DLG_TABSHEET_TITLE_SEQUENCE", "制御シーケンス")
            case .copyPaste: return Lang.t("Tera Term", "DLG_TABSHEET_TITLE_COPYPASTE", "コピーと貼り付け")
            case .visual: return Lang.t("Tera Term", "DLG_TABSHEET_TITLE_VISUAL", "表示")
            case .log: return Lang.t("Tera Term", "DLG_TABSHEET_TITLE_LOG", "ログ")
            case .encoding: return Lang.t("Tera Term", "DLG_TABSHEET_TITLE_ENCODING", "エンコーディング")
            case .font: return Lang.t("Tera Term", "DLG_TABSHEET_TITLE_FONT", "フォント")
            case .theme: return Lang.t("Tera Term", "DLG_TABSHEET_TITLE_THEME", "テーマ")
            case .keyboard: return Lang.t("Tera Term", "DLG_KEYB_TITLE", "キーボード")
            case .mouse: return Lang.t("Tera Term", "DLG_TABSHEET_TITLE_MOUSE", "マウス")
            case .tcpip: return Lang.t("Tera Term", "DLG_TCPIP_TITLE", "TCP/IP")
            case .terminal: return Lang.t("Tera Term", "DLG_TERM_TITLE", "端末")
            case .serial: return Lang.t("Tera Term", "DLG_SERIAL_TITLE", "シリアルポート")
            case .window: return Lang.t("Tera Term", "DLG_WIN_TITLE", "ウィンドウ")
            case .plugins: return Lang.m("SETUP_TAB_PLUGINS", "プラグイン")
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

    /// 開いている設定画面 (アプリ全体で 1 つ)
    static weak var current: SetupSheet?

    /// 開いている設定画面を前に出し、ページを切り替える
    func bringToFront(page: Page) {
        selectPage(at: Page.allCases.firstIndex(of: page) ?? 0)
        panel.makeKeyAndOrderFront(nil)
    }

    func begin(on w: NSWindow, completion: @escaping (TermSettings?) -> Void) {
        self.completion = completion
        panel.title = Lang.t("Tera Term", "DLG_TABSHEET_TITLE", "Tera Term: その他の設定")
        build()
        selectPage(at: Page.allCases.firstIndex(of: startPage) ?? 0)
        // 端末にくっつくシートではなく、別のウィンドウにする (動かして端末を見ながら設定できる)
        presentsAsWindow = true
        Self.current = self
        present(on: w)
        previewReady = true
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
        defer { livePreview() }
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
        let all = TermEncoding.guiList.map { $0.code }
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
        updateSpaceControls()
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
        case .plugins: return pluginsPage()
        }
    }

    // MARK: プラグイン (Mac 版の組み込みプラグイン)

    /// TTMado (タブ・窓割り) を使う
    private let ttMadoCheck = NSButton(checkboxWithTitle: TTMado.title, target: nil, action: nil)

    /// 本家の「プラグイン」タブの代わり: Mac 版はプラグインをアプリに組み込んでいるので、一覧と TTMado の入/切だけ
    private func pluginsPage() -> NSView {
        custom(load: { [unowned self] in self.ttMadoCheck.state = TTMado.isEnabled ? .on : .off }, store: {})
        func note(_ s: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 520
            return l
        }
        func info(_ name: String, _ desc: String) -> NSView {
            let n = SetupUI.label(name)
            n.font = .boldSystemFont(ofSize: 12)
            n.translatesAutoresizingMaskIntoConstraints = false
            n.widthAnchor.constraint(equalToConstant: 130).isActive = true
            let d = SetupUI.label(desc)
            d.textColor = .secondaryLabelColor
            return SetupUI.row([n, d], align: .firstBaseline)
        }
        ttMadoCheck.font = .boldSystemFont(ofSize: 12)
        let mado = SetupUI.column([
            SetupUI.row([ttMadoCheck, SetupUI.label(TTMado.summary)], align: .firstBaseline),
            SetupUI.indent(note(Lang.m("PLUGIN_TTMADO_NOTE", "切ると、分割している画面はタブに戻り、macOS のふつうのタブと同じ動きになります。すぐに効きます (再起動はいりません)。"))),
        ])
        let always = SetupUI.column([
            info("TTProxy", Lang.m("PLUGIN_TTPROXY_DESC", "プロキシ経由の接続 (HTTP / SOCKS / TELNET)")),
            info("TTXKanjiMenu", Lang.m("PLUGIN_TTXKANJIMENU_DESC", "漢字コードのメニュー")),
            info("TTXAlwaysOnTop", Lang.m("PLUGIN_TTXALWAYSONTOP_DESC", "常に手前に表示")),
            info("TeraTerm Menu", Lang.m("PLUGIN_TERATERMMENU_DESC", "メニューバーに常駐するランチャー")),
        ])
        return SetupUI.column([
            SetupUI.box(Lang.m("PLUGIN_SWITCHABLE", "入/切できるプラグイン"), mado),
            SetupUI.box(Lang.m("PLUGIN_BUILTIN", "いつも使うプラグイン (アプリに組み込み)"), always),
        ], spacing: 12)
    }

    // 全般 (general_pp.cpp)
    private let fileDirField = SetupUI.field(width: 320)
    private func generalPage() -> NSView {
        let portPopup = pop([Lang.t("Tera Term", "DLG_GEN_PORT_TCPIP", "TCP/IP"), Lang.t("Tera Term", "DLG_GEN_PORT_SERIAL", "Serial")], ["tcpip", "serial"], \.portType)
        let titleBits = [Lang.t("Tera Term", "DLG_TAB_GENERAL_TITLEFMT_DISPHOSTNAME", "ホスト/ポート名を表示する(&D)"), Lang.t("Tera Term", "DLG_TAB_GENERAL_TITLEFMT_DISPSESSION", "セッション番号を表示する(&N)"), Lang.t("Tera Term", "DLG_TAB_GENERAL_TITLEFMT_DISPVTTEK", "&VT/TEK を表示する"),
                         Lang.t("Tera Term", "DLG_TAB_GENERAL_TITLEFMT_SWAPHOSTTITLE", "タイトルとホスト名の場所を入れ換える(&T)"), Lang.t("Tera Term", "DLG_TAB_GENERAL_TITLEFMT_DISPTCPPORT", "TCP ポート番号を表示する(&P)"), Lang.t("Tera Term", "DLG_TAB_GENERAL_TITLEFMT_DISPSERIALSPEED", "シリアルポートのスピードを表示する(&R)")]
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
            cb(Lang.t("Tera Term", "DLG_TAB_GENERAL_DISABLESENDBREAK", "ブレーク送信のアクセラレータキーを無効にする(&S)"), \.disableAcceleratorSendBreak),
            cb(Lang.t("Tera Term", "DLG_TAB_GENERAL_ACCEPTBROADCAST", "ブロードキャストを受け入れる(&B)"), \.acceptBroadcast),
            cb(Lang.t("Tera Term", "DLG_TAB_GENERAL_AUTOSCROLL_ONLY_IN_BOTTOM_LINE", "最下行でだけ自動スクロールする(&U)"), \.autoScrollOnlyInBottomLine),
            cb(Lang.t("Tera Term", "DLG_TAB_GENERAL_CLEAR_ON_RESIZE", "ウィンドウサイズ変更時に表示内容をクリアする(&C)"), \.clearOnResize),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_GEN_PORT", "新しい接続のデフォルト(&C):")), portPopup]),
            SetupUI.box(Lang.t("Tera Term", "DLG_TAB_GENERAL_TITLEFMT_GROUP", "タイトル形式"), SetupUI.column(bitChecks, spacing: 4)),
            SetupUI.label(Lang.t("Tera Term", "DLG_TAB_GENERAL_NOTIFICATION_TITLE", "通知")),
            SetupUI.indent(cb(Lang.t("Tera Term", "DLG_TAB_GENERAL_NOTIFIY_SOUND", "通知音"), \.notifySound)),
            SetupUI.label(Lang.m("SETUP_FILE_TRANSFER_DIR", "ファイル転送のフォルダ")),
            SetupUI.indent(SetupUI.row([fileDirField, dirButton])),
        ], spacing: 8)
    }

    @objc private func chooseFileDir() {
        let p = NSOpenPanel()
        p.message = Lang.t("Tera Term", "DLG_SELECT_DIR_TITLE", "新しいディレクトリを選択してください")
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: FileTransferPaths.fileDirectory(fileDirField.stringValue))
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { self.fileDirField.stringValue = u.path } }
    }

    // 制御シーケンス (addsetting.cpp CSequencePropPageDlg)
    private let mouseTrackCheck = SetupUI.check(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_ACCEPT_MOUSE_EVENT_TRACKING", "マウスイベント通知要求を受け入れる(&M)"))
    private let disableMouseCtrlCheck = SetupUI.check(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_DISABLE_MOUSE_TRACKING_CTRL", "Controlキーを押している間はマウスイベントを通知しない(&D)"))
    private func sequencePage() -> NSView {
        bind(mouseTrackCheck, \.mouseEventTracking)
        bind(disableMouseCtrlCheck, \.disableMouseTrackingByCtrl)
        return SetupUI.column([
            mouseTrackCheck,
            SetupUI.indent(disableMouseCtrlCheck),
            SetupUI.grid([
                [SetupUI.label(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_ACCEPT_TITLE_CHANGING", "ウィンドウタイトルの変更要求を受け入れる(&T)")),
                 pop([Lang.t("Tera Term", "DLG_TAB_SEQUENCE_ACCEPT_TITLE_CHANGING_OFF", "無効"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_ACCEPT_TITLE_CHANGING_OVERWRITE", "上書き"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_ACCEPT_TITLE_CHANGING_AHEAD", "前に追加"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_ACCEPT_TITLE_CHANGING_LAST", "後に追加")], ["off", "overwrite", "ahead", "last"], \.acceptTitleChangeRequest)],
                [SetupUI.label(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_TITLE_REPORT", "ウィンドウタイトルの報告要求(&I)")),
                 pop([Lang.t("Tera Term", "DLG_TAB_SEQUENCE_TITLE_REPORT_IGNORE", "無視"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_TITLE_REPORT_ACCEPT", "応答"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_TITLE_REPORT_EMPTY", "空白")], ["ignore", "accept", "empty"], \.titleReportSequence)],
            ]),
            cb(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_WINDOW_CTRL", "ウィンドウ操作制御シーケンス(&W)"), \.windowCtrlSequence),
            cb(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_WINDOW_REPORT", "ウィンドウ情報報告シーケンス(&R)"), \.windowReportSequence),
            cb(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_CURSOR_CTRL", "カーソル形状/点滅変更制御シーケンス(&C)"), \.cursorCtrlSequence),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_CLIPBOARD_ACCESS", "リモートからのクリップボードアクセス(&L)")),
                         pop([Lang.t("Tera Term", "DLG_TAB_SEQUENCE_CLIPBOARD_ACCESS_OFF", "無効"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_CLIPBOARD_ACCESS_WRITE", "書込のみ"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_CLIPBOARD_ACCESS_READ", "読込のみ"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_CLIPBOARD_ACCESS_ON", "読込/書込")], ["off", "write", "read", "on"], \.clipboardAccessFromRemote)]),
            cb(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_CLIPBOARD_NOTIFY", "リモートからのクリップボードアクセスを通知する(&N)"), \.notifyClipboardAccess),
            cb(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_ACCEPT_CLEAR_SBUFF", "リモートからのスクロールバッファの消去を受け入れる(&S)"), \.clearScrollBufferFromRemote),
            cb(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_PRINT_START", "印字開始シーケンスを無効化(&I)"), \.printerCtrlSequence, invert: true),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_SEQUENCE_BEEP_LABEL", "ベル(&B)")), pop([Lang.t("Tera Term", "DLG_TAB_SEQUENCE_BEEP_DISABLE", "無視"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_BEEP_SOUND", "サウンド"), Lang.t("Tera Term", "DLG_TAB_SEQUENCE_BEEP_VISUALBELL", "ビジュアルベル")], ["off", "on", "visual"], \.beep)]),
        ], spacing: 8)
    }

    // コピーと貼り付け (addsetting.cpp CCopypastePropPageDlg)
    private let disableRButton = SetupUI.check(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_MOUSEPASTE", "右クリックでの貼り付けを無効にする(&D)"))
    private let confirmRButton = SetupUI.check(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_CONFIRMPASTE", "右クリックでの貼り付けを確認する(&C)"))
    private let confirmChangePasteCheck = SetupUI.check(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_CONFIRM_CHANGE_PASTE", "危険なクリップボードの貼り付けを確認する(&P)"))
    private let confirmCRCheck = SetupUI.check(Lang.m("SETUP_CONFIRM_PASTE_CR", "改行を含む貼り付けをいつも確認する"))
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
            cb(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_CONTINUE", "継続行コピーを有効にする(&L)"), \.continuedLineCopy),
            disableRButton,
            SetupUI.indent(confirmRButton),
            cb(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_MOUSEPASTEM", "中クリックでの貼り付けを無効にする(&M)"), \.disablePasteMouseMButton),
            cb(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_SELECTLBUTTON", "左クリックでのみ選択を開始する(&O)"), \.selectOnlyByLButton),
            cb(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_TRIM_TRAILING_NL", "貼り付け時に末尾の改行を削除する(&T)"), \.trimTrailingNLOnPaste),
            cb(Lang.m("SETUP_BRACKETED_CONTROL_ONLY", "ブラケットペーストは制御文字を含むときだけ囲む"), \.bracketedControlOnly),
            confirmChangePasteCheck,
            SetupUI.indent(confirmCRCheck),
            SetupUI.indent(SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_STRINGFILE", "キーワードファイル(&S)")), keywordField, keywordButton])),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_DELIMITER", "区切り文字(&I)")), text(\.delimList, width: 320)]),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_PASTEDELAY", "貼り付けの行間遅延(&A)")), num(\.pasteDelayPerLine, range: 0...5000), SetupUI.label(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_PASTEDELAY2", "ミリ秒"))]),
            cb(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_SELECT_ON_ACTIVATE", "マウスでウィンドウ選択時の文字選択を有効にする(&B)"), \.selectOnActivate),
            cb(Lang.t("Tera Term", "DLG_TAB_COPYPASTE_AUTO_TEXT_COPY", "マウスで文字選択時、自動でクリップボードへのコピーを行う(&Y)"), \.copyOnSelect),
        ], spacing: 8)
    }

    @objc private func chooseKeywordFile() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["txt"]
        p.allowsOtherFileTypes = true
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { self.keywordField.stringValue = u.path; self.refresh() } }
    }

    // 表示 (addsetting.cpp CVisualPropPageDlg)
    private let boldCheckVisual = SetupUI.check(Lang.t("Tera Term", "DLG_TAB_VISUAL_BOLD_FONT", "太字属性フォントを有効にする"))
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
        // addsetting.cpp OnCtlColor(IDC_SAMPLE_COLOR): 背景は透明 (ダイアログの地の色) で、選んだ色の文字を描く。
        // Windows のダイアログの地は明るいので、ダークモードでも明るい地にそろえる
        ansiSample.appearance = NSAppearance(named: .aqua)
        ansiSample.drawsBackground = true
        ansiSample.isBezeled = true
        custom(load: { [unowned self] in self.ansiWork = self.s.ansi16 ?? Array(Palette.colors.prefix(16)); self.ansiSelected() },
               store: { [unowned self] in
                   let std = Array(Palette.colors.prefix(16))
                   self.s.ansi16 = self.ansiWork.map(TermSettings.rgbString) != std.map(TermSettings.rgbString) ? self.ansiWork : nil
               })
        return SetupUI.column([
            SetupUI.label(Lang.t("Tera Term", "DLG_TAB_VISUAL_ALPHA", "ウィンドウの不透明度")),
            SetupUI.indent(alphaRow(Lang.t("Tera Term", "DLG_TAB_VISUAL_ALPHA_ACTIVE", "アクテイブ時(&A)"), \.alphaBlendActive)),
            SetupUI.indent(alphaRow(Lang.t("Tera Term", "DLG_TAB_VISUAL_ALPHA_INACTIVE", "非アクティブ時(&C)"), \.alphaBlendInactive)),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_VISUAL_MOUSE", "マウスカーソル(&M)")),
                         pop(["ARROW", "IBEAM", "CROSS", "HAND"], ["ARROW", "IBEAM", "CROSS", "HAND"], \.mouseCursor)]),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_VISUAL_ANSICOLOR", "AN&SIカラー")), ansiPopup, SetupUI.label(Lang.t("Tera Term", "DLG_TAB_VISUAL_RED", "赤(&R)")), ansiR, SetupUI.label(Lang.t("Tera Term", "DLG_TAB_VISUAL_GREEN", "緑(&G)")), ansiG,
                         SetupUI.label(Lang.t("Tera Term", "DLG_TAB_VISUAL_BLUE", "青(&B)")), ansiB]),
            SetupUI.indent(ansiSample),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_VISUAL_FONT_QUALITY", "フォントの品質(&F)")),
                         pop([Lang.t("Tera Term", "DLG_TAB_VISUAL_FONT_QUALITY_DEFAULT", "デフォルト"), Lang.t("Tera Term", "DLG_TAB_VISUAL_FONT_QUALITY_NONANTIALIASED", "アンチエイリアスなし"), Lang.t("Tera Term", "DLG_TAB_VISUAL_FONT_QUALITY_ANTIALIASED", "アンチエイリアス")], ["default", "nonantialiased", "antialiased"], \.fontQuality)]),
            SetupUI.label("Character attributes"),
            SetupUI.indent(SetupUI.grid([
                [cb(Lang.t("Tera Term", "DLG_TAB_VISUAL_BOLD_COLOR", "太字属性色を有効にする(&O)"), \.enableBoldAttrColor), boldCheckVisual],
                [cb(Lang.t("Tera Term", "DLG_TAB_VISUAL_UNDERLINE_COLOR", "下線属性色を有効にする"), \.underlineAttrColor), cb(Lang.t("Tera Term", "DLG_TAB_VISUAL_UNDERLINE_FONT", "下線属性に下線を付加する"), \.underlineAttrFont)],
                [cb(Lang.t("Tera Term", "DLG_TAB_VISUAL_BLINK", "点滅属性色を有効にする(&L)"), \.enableBlinkAttrColor), cb(Lang.t("Tera Term", "DLG_TAB_VISUAL_REVERSE", "反転属性色を有効にする(&V)"), \.enableReverseAttrColor)],
                [cb(Lang.t("Tera Term", "DLG_TAB_VISUAL_URL_COLOR", "URL属性色を有効にする(&U)"), \.enableURLColor), cb(Lang.t("Tera Term", "DLG_TAB_VISUAL_URL_FONT", "URL文字列に下線を付加する(&U)"), \.urlUnderline)],
                [cb(Lang.t("Tera Term", "DLG_TAB_VISUAL_ANSI", "ANSIカラーを有効にする(&N)"), \.enableANSIColor), NSGridCell.emptyContentView],
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
        ansiSample.backgroundColor = .windowBackgroundColor
        ansiSample.textColor = ansiWork[i]
    }

    // ログ (log_pp.cpp)
    private let logBinaryCheck = SetupUI.check(Lang.t("Tera Term", "DLG_FOPT_BINARY", "バイナリ(&R)"))
    private let logPlainCheck = SetupUI.check(Lang.t("Tera Term", "DLG_FOPT_PLAIN", "プレーンテキスト(&P)"))
    private let logTimestampCheck = SetupUI.check(Lang.t("Tera Term", "DLG_FOPT_TIMESTAMP", "タイムスタンプ(&T)"))
    private lazy var logTimestampPopup = pop([Lang.t("Tera Term", "DLG_FOPT_TIMESTAMP_LOCAL", "ローカルタイム"), "UTC", Lang.t("Tera Term", "DLG_FOPT_TIMESTAMP_ELAPSED_LOGGING", "経過時間(Logging)"), Lang.t("Tera Term", "DLG_FOPT_TIMESTAMP_ELAPSED_CONNECTION", "経過時間(Connection)")],
                                             ["Local", "UTC", "LoggingElapsed", "ConnectionElapsed"], \.logTimestampType)
    private let logRotateCheck = SetupUI.check(Lang.t("Tera Term", "DLG_TAB_LOG_ROTATE", "ログのローテート(&L)"))
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
        logEditorField.placeholderString = Lang.m("SETUP_LOG_EDITOR_PLACEHOLDER", "テキストエディット")
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
            SetupUI.label(Lang.t("Tera Term", "DLG_TAB_LOG_EDITOR", "ログ表示用エディタ")),
            SetupUI.indent(SetupUI.grid([
                [SetupUI.label(Lang.t("Tera Term", "DLG_TAB_LOG_EDITOR_EXE", "実行ファイル(&E)")), SetupUI.row([logEditorField, SetupUI.button("...", target: self, action: #selector(chooseEditor))])],
                [SetupUI.label(Lang.t("Tera Term", "DLG_TAB_LOG_EDITOR_ARG", "引き数(&R)")), text(\.viewlogEditorArg, width: 300)],
            ])),
            SetupUI.label(Lang.t("Tera Term", "DLG_TAB_LOG_FILENAME", "標準ログファイル名(strftimeフォーマット可) (&F)")),
            SetupUI.indent(logNameCombo),
            SetupUI.label(Lang.t("Tera Term", "DLG_TAB_LOG_FILEPATH", "標準のログ保存先フォルダ(&S)")),
            SetupUI.indent(SetupUI.row([logPathField, SetupUI.button("...", target: self, action: #selector(chooseLogDir))])),
            cb(Lang.t("Tera Term", "DLG_TAB_LOG_AUTOSTART", "自動的にログ採取を開始する(&U)"), \.logAutoStart),
            SetupUI.box("Log option", SetupUI.grid([
                [logBinaryCheck, cb(Lang.t("Tera Term", "DLG_FOPT_APPEND", "追記(&A)"), \.logAppend)],
                // Hide dialog → "Logging dialog state" のドロップダウン (ttermpro.rc IDC_OPT_LOGGINGDIALOG_DROPDOWN, 23aa80682 #1576)
                [logPlainCheck, NSGridCell.emptyContentView],
                [SetupUI.label(Lang.m("MISC_LOGGINGDIALOG", "ログ記録中ダイアログ")), popInt(LogDialog.showStateTitles, [0, 1, 2], \.logShowState)],
                [cb(Lang.t("Tera Term", "DLG_FOPT_ALLBUFFINFIRST", "現在バッファを含む(&C)"), \.logIncludeScreenBuffer), NSGridCell.emptyContentView],
                [logTimestampCheck, logTimestampPopup],
            ], leading: true)),
            logRotateCheck,
            SetupUI.indent(SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_LOG_ROTATE_SIZE_TEXT", "サイズ(&i)")), logRotateSize, logRotateType, SetupUI.label(Lang.t("Tera Term", "DLG_TAB_LOG_ROTATESTEP", "世代(&R)")), logRotateStep])),
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
    // coding_pp.cpp: ttlib_charset.cpp KanjiList の CodeStrGUI を並べる (#510 で 1 バイトの文字コードが増えた)
    private let recvPopup = SetupUI.popup(TermEncoding.guiList.map { $0.name })
    private let differentCheck = SetupUI.check("Tra&nsmit (Use different code)")
    private let sendPopup = SetupUI.popup(TermEncoding.guiList.map { $0.name })
    private let ambPopup = SetupUI.popup(["1 Cell", "2 Cell"])
    private let emojiCheck = SetupUI.check("Override Emoji Characters width")
    private lazy var emojiPopup = popInt(["1 Cell", "2 Cell"], [1, 2], \.unicodeEmojiWidth)
    private let decRadios = [SetupUI.radio(Lang.t("Tera Term", "DLG_CODING_DECSP_UNICODE_TO_DEC", "UnicodeをDEC Special Graphicsへマッピングする")),
                             SetupUI.radio(Lang.t("Tera Term", "DLG_CODING_DECSP_DEC_TO_UNICODE", "DEC Special GraphicsをUnicodeへマッピングする")),
                             SetupUI.radio(Lang.t("Tera Term", "DLG_CODING_DECSP_DO_NOT_MAP", "DEC Special Graphicsをマッピングしない"))]
    private let boxCheck = SetupUI.check(Lang.t("Tera Term", "DLG_CODING_UNICODE_TO_DEC_BOXDRAWING", "罫線素片(U+2500-U+257F)"))
    private let punctCheck = SetupUI.check(Lang.t("Tera Term", "DLG_CODING_UNICODE_TO_DEC_PUNCTUATION", "Punctuation, Block Elements, Shade"))
    private let middleDotCheck = SetupUI.check(Lang.t("Tera Term", "DLG_CODING_UNICODE_TO_DEC_MIDDLEDOT", "中点(U+00B7,U+2024,U+2219)"))
    private let kanaRecvCheck = SetupUI.check(Lang.t("Tera Term", "DLG_TERM_KANA", "半角カナ(&F)"))
    private let kanaSendCheck = SetupUI.check(Lang.t("Tera Term", "DLG_TERM_KANASEND", "半角カナ(&D)"))
    private lazy var kanjiInPopup = pop(["^[$@", "^[$B"], ["@", "B"], \.kanjiIn)
    private lazy var kanjiOutPopup = pop(["^[(B", "^[(J"], ["B", "J"], \.kanjiOut)
    private func encodingPage() -> NSView {
        let all = TermEncoding.guiList.map { $0.code }
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
            // 同じ文字コードが 2 つあるとき (CP1251) は本家と同じく後ろのもの
            self.recvPopup.selectItem(at: all.lastIndex(of: self.s.encoding) ?? 0)
            self.sendPopup.selectItem(at: all.lastIndex(of: self.s.encodingSend) ?? 0)
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
                [SetupUI.label("Transmit"), SetupUI.row([kanaSendCheck, SetupUI.label(Lang.t("Tera Term", "DLG_TERM_KIN", "漢字イン(&N):")), kanjiInPopup,
                                                         SetupUI.label(Lang.t("Tera Term", "DLG_TERM_KOUT", "漢字アウト(&O):")), kanjiOutPopup])],
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
            let v = { (f: NSTextField) in Int(f.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0 }
            let l = v(self.spaceLeft), r = v(self.spaceRight), t = v(self.spaceTop), b = v(self.spaceBottom)
            (self.s.fontDX, self.s.fontDW, self.s.fontDY, self.s.fontDH) = (l, l + r, t, t + b)
        })
        let fontsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Fonts")
        let cross = SetupUI.grid([
            [NSGridCell.emptyContentView, spaceCell(spaceTop), NSGridCell.emptyContentView],
            [spaceCell(spaceLeft), SetupUI.label("Aa"), spaceCell(spaceRight)],
            [NSGridCell.emptyContentView, spaceCell(spaceBottom), NSGridCell.emptyContentView],
        ])
        cross.column(at: 1).xPlacement = .center
        // 「戻す」ボタンは同じ行の右に置き、隠しても場所を空けたままにする (押したときに画面がずれないように)
        let spaceBox = SetupUI.row([cross, resetSpaceButton], spacing: 16)
        spaceBox.detachesHiddenViews = false
        let chooseButton = SetupUI.button(Lang.t("Tera Term", "DLG_TAB_FONT_BTN_SELECT", "選択(&S)..."), target: self, action: #selector(chooseFont))
        // 狭いときはフォント名の欄を縮め、ボタンは潰さない
        chooseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        resetFontButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        fontField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let fontRow = SetupUI.row([fontField, chooseButton, resetFontButton])
        fontRow.detachesHiddenViews = false
        return SetupUI.column([
            SetupUI.label(Lang.t("Tera Term", "DLG_TAB_FONT_VTWINFONT", "VTウィンドウフォント(&V)")),
            SetupUI.indent(fontRow),
            SetupUI.button(Lang.t("Tera Term", "DLG_TAB_FONT_FOLDER", "フォント設定/フォントフォルダ(%s)を開く", fontsDir), target: self, action: #selector(openFontFolder)),
            cb(Lang.t("Tera Term", "DLG_TAB_FONT_RESIZED_FONT", "描画幅に合わせてリサイズしたフォントを描画(&W)"), \.drawingResizedFont),
            SetupUI.box(Lang.t("Tera Term", "DLG_TAB_FONT_CHARACTER_SPACE", "文字間スペース"), spaceBox),
        ], spacing: 10)
    }
    // 文字間スペース: 各欄の横の上下ボタンで 1 ずつ変えられる。変えるとその場で端末に映る
    private var spaceSteppers: [ObjectIdentifier: NSStepper] = [:]
    private func spaceCell(_ f: NSTextField) -> NSView {
        f.delegate = self
        f.alignment = .right
        let st = NSStepper()
        st.minValue = -99; st.maxValue = 99; st.increment = 1
        st.valueWraps = false; st.autorepeat = true
        st.target = self; st.action = #selector(spaceStepped(_:))
        spaceSteppers[ObjectIdentifier(f)] = st
        let row = SetupUI.row([f, st], spacing: 2)
        return row
    }
    private var spaceFields: [NSTextField] { [spaceLeft, spaceRight, spaceTop, spaceBottom] }
    @objc private func spaceStepped(_ sender: NSStepper) {
        guard let f = spaceFields.first(where: { spaceSteppers[ObjectIdentifier($0)] === sender }) else { return }
        f.stringValue = String(sender.integerValue)
        refresh()
    }
    /// 既定の文字間スペース (左, 右, 上, 下)。同梱の TERATERM.INI を重ねた初期値
    private static let defaultSpace: [Int] = {
        let t = TermSettings.initial()
        return [t.fontDX, t.fontDW - t.fontDX, t.fontDY, t.fontDH - t.fontDY]
    }()
    private lazy var resetSpaceButton = SetupUI.button(
        Lang.m("SETUP_RESET_SPACE", "デフォルト (%s) に戻す", Self.defaultSpace.map(String.init).joined(separator: ", ")),
        target: self, action: #selector(resetSpace))
    @objc private func resetSpace() {
        for (f, v) in zip(spaceFields, Self.defaultSpace) { f.stringValue = String(v) }
        refresh()
    }
    private func updateSpaceControls() {
        let vals = spaceFields.map { Int($0.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0 }
        for (f, v) in zip(spaceFields, vals) { spaceSteppers[ObjectIdentifier(f)]?.integerValue = v }
        // 既定と違うときだけ「戻す」ボタンを出す
        resetSpaceButton.isHidden = vals == Self.defaultSpace
    }
    private func updateFontLabel() {
        fontField.stringValue = "\(s.font.displayName ?? s.fontName), \(Int(s.fontSize))pt"
        // 既定と違うフォントのときだけ「戻す」ボタンを出す
        let d = Self.defaultFont
        resetFontButton.isHidden = s.fontName == d.name && s.fontSize == d.size
        // ボタンの文字は短く (同じ行の「選択...」を押しつぶさないように)。どのフォントに戻るかはツールチップで
        resetFontButton.title = Lang.m("SETUP_RESET_FONT", "デフォルトのフォントに戻す")
        resetFontButton.toolTip = Lang.m("SETUP_RESET_FONT_TO", "デフォルトのフォント (%s, %dpt) に戻す",
                                         NSFont(name: d.name, size: d.size)?.displayName ?? d.name, Int(d.size))
    }
    /// 既定のフォント (初めて起動したときの設定 = 同梱の TERATERM.INI を重ねた初期値)
    private static let defaultFont: (name: String, size: CGFloat) = {
        let t = TermSettings.initial()
        return (t.fontName, t.fontSize)
    }()
    private lazy var resetFontButton = SetupUI.button(Lang.m("SETUP_RESET_FONT", "デフォルトのフォントに戻す"), target: self, action: #selector(resetFont))
    @objc private func resetFont() {
        s.fontName = Self.defaultFont.name
        s.fontSize = Self.defaultFont.size
        refresh()
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
    private let fastSizeMoveCheck = SetupUI.check(Lang.t("Tera Term", "DLG_TAB_VISUAL_FAST_SIZE_MOVE", "ウィンドウ移動/リサイズ時テーマを一時的にdisableする"))
    private let themeStartupPopup = SetupUI.popup([Lang.t("Tera Term", "DLG_TAB_VISUAL_THEME_STARTUP_NO_USE", "使用しない"), Lang.t("Tera Term", "DLG_TAB_VISUAL_THEME_STARTUP_FIXED_THEME", "固定テーマ(テーマファイル指定)"), Lang.t("Tera Term", "DLG_TAB_VISUAL_THEME_STARTUP_RANDOM_THEME", "ランダムテーマ")])
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
        themeEditorButton.toolTip = Lang.m("SETUP_NOT_SUPPORTED_ON_MAC", "Mac 版では未対応です")
        bundledThemePopup.addItem(withTitle: Lang.m("SETUP_BUNDLED_THEMES", "同梱のテーマ"))
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
        schemePopup.addItem(withTitle: Lang.t("Tera Term", "DLG_TAB_VISUAL_THEME_STARTUP_NO_USE", "使用しない"))
        for (i, sc) in schemes.enumerated() {
            if i == ColorScheme.presets.count { schemePopup.menu?.addItem(.separator()) }
            let item = NSMenuItem(title: sc.title, action: nil, keyEquivalent: "")
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
        let note = NSTextField(wrappingLabelWithString: Lang.m("SETUP_SCHEME_NOTE", "配色を選ぶと、文字色・背景色・カーソルの色・ANSIカラーをその配色にします (OK で確定)。"))
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
            SetupUI.box(Lang.m("SETUP_SCHEME_BOX", "配色 (Mac)"), SetupUI.column([
                SetupUI.row([SetupUI.label(Lang.m("SETUP_SCHEME", "配色")), schemePopup, SetupUI.label(Lang.m("SETUP_CURSOR_COLOR", "カーソルの色")), cursorWell]),
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

    // UI (ui_pp.cpp)。UI言語は本家の言語ファイル (lang_utf8/*.lng) から選ぶ。先頭は「自動」(macOS の言語設定に従う)。
    // ダイアログフォントは Mac では変えられないので無い
    private let uiLangPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 開いたときに選んでいた番号 (OK で変わったときだけ Lang.chosen を変える)
    private var uiLangInitial = 0
    private func uiPage() -> NSView {
        uiLangPopup.removeAllItems()
        uiLangPopup.addItem(withTitle: Lang.m("SETUP_UI_LANG_AUTO", "自動 (macOS の設定に従う)"))
        for l in Lang.available {
            let item = NSMenuItem(title: l.name, action: nil, keyEquivalent: "")
            item.representedObject = l.file
            item.toolTip = l.file
            uiLangPopup.menu?.addItem(item)
        }
        uiLangInitial = Lang.chosen.flatMap { c in Lang.available.firstIndex { $0.file == c }.map { $0 + 1 } } ?? 0
        uiLangPopup.selectItem(at: uiLangInitial)
        let fontsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Fonts")
        let link = NSButton(title: Lang.t("Tera Term", "DLG_TAB_FONT_FOLDER", "フォント設定/フォントフォルダ(%s)を開く", fontsDir),
                            target: self, action: #selector(openFontFolder))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.attributedTitle = NSAttributedString(string: link.title, attributes: [
            .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .font: NSFont.systemFont(ofSize: 13)])
        return SetupUI.column([
            SetupUI.label(Lang.t("Tera Term", "DLG_GEN_LANG_UI", "UI言語(&L):")),
            SetupUI.indent(uiLangPopup),
            SetupUI.indent(link),
        ], spacing: 8)
    }
    /// OK: UI言語が変わっていれば切り替える (nil = 自動)
    private func applyUILanguage() {
        let i = uiLangPopup.indexOfSelectedItem
        guard i >= 0, i != uiLangInitial else { return }
        Lang.chosen = uiLangPopup.item(at: i)?.representedObject as? String
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
        shellEnv1Field.placeholderString = Lang.m("SETUP_ENV_PLACEHOLDER", "名前=値")
        shellEnv2Field.placeholderString = Lang.m("SETUP_ENV_PLACEHOLDER", "名前=値")
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
            if !self.previewing { l.save() }
        })
        let shellButton = SetupUI.button("...", target: self, action: #selector(chooseShell))
        let note = NSTextField(wrappingLabelWithString: Lang.m("SETUP_LOCAL_SHELL_NOTE", "ファイル > ローカルシェル で開くシェルの設定です (新しく開くときから)。"))
        note.preferredMaxLayoutWidth = 420
        note.textColor = .secondaryLabelColor
        return SetupUI.column([
            SetupUI.box(Lang.m("SETUP_TAB_LOCAL_SHELL", "ローカルシェル"), SetupUI.column([
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
            SetupUI.box(Lang.t("Tera Term", "DLG_KEYB_TRANSMIT", "DELを送信するキー:"), SetupUI.column([
                cb(Lang.t("Tera Term", "DLG_KEYB_BS", "&Backspace キー"), \.bsSendsDel), cb(Lang.t("Tera Term", "DLG_KEYB_DEL", "&Delete キー"), \.deleteKeySendsDel),
            ])),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_KEYB_META", "&Meta キー:")), pop(["off", "on", "left", "right"], ["off", "on", "left", "right"], \.metaKey),
                         SetupUI.label(Lang.m("SETUP_META_OPTION_KEY", "(Option キー)"))]),
            SetupUI.box(Lang.t("Tera Term", "DLG_KEYB_DISABLE", "無効化するモード"), SetupUI.column([
                cb(Lang.t("Tera Term", "DLG_KEYB_APPKEY", "アプリケーションキーパッド(&A)"), \.disableAppKeypad), cb(Lang.t("Tera Term", "DLG_KEYB_APPCUR", "アプリケーションカーソル(&C)"), \.disableAppCursor),
            ])),
        ], spacing: 10)
    }

    // マウス (mouse_pp.cpp)
    private func mousePage() -> NSView {
        SetupUI.column([
            cb(Lang.t("Tera Term", "DLG_TAB_GENERAL_CLICKURL", "クリッカブルURLを有効にする(&E)"), \.enableClickableUrl),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TAB_GENERAL_MOUSEWHEEL_SCROLL_LINE", "ホイールのスクロール行数(&W)")), num(\.mouseWheelScrollLine, width: 50, range: 1...100)]),
        ], spacing: 10)
    }

    // TCP/IP (tcpip_pp.cpp)
    private func tcpipPage() -> NSView {
        let edit = SetupUI.button(Lang.t("Tera Term", "DLG_TCPIP_EDITHISTORY", "ホストリストの編集"), target: self, action: #selector(editHosts))
        return SetupUI.column([
            SetupUI.row([cb(Lang.t("Tera Term", "DLG_TCPIP_HISTORY", "新規接続時にホストリストに追加(&I)"), \.historyList), edit]),
            SetupUI.row([cb(Lang.t("Tera Term", "DLG_TCPIP_TELNET", "T&elnet"), \.telnet), SetupUI.label(Lang.t("Tera Term", "DLG_TCPIP_PORT", "ポート#(&P):")), num(\.tcpPort, width: 70, range: 1...65535)]),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TCPIP_KEEPALIVE", "Telnet &Keep-alive")), num(\.telKeepAliveInterval, width: 60), SetupUI.label(Lang.t("Tera Term", "DLG_TCPIP_KEEPALIVE_SEC", "秒(0指定で無効)"))]),
            cb(Lang.t("Tera Term", "DLG_TCPIP_AUTOCLOSE", "自動的にウィンドウを閉じる(&W)"), \.autoWinClose),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_TCPIP_TERMTYPE", "端末タイプ(&T):")), text(\.termType, width: 160)]),
        ], spacing: 10)
    }
    @objc private func editHosts() { HostListEditDialog().begin(on: panel) }

    // 端末 (term_pp.cpp)
    private let termIsWinCheck = SetupUI.check(Lang.t("Tera Term", "DLG_TERM_ISWIN", "= ウィンドウサイズ(&S):"))
    private let termResizeCheck = SetupUI.check(Lang.t("Tera Term", "DLG_TERM_RESIZE", "自動的に調整(&W):"))
    private let colsField = SetupUI.field(width: 50), rowsField = SetupUI.field(width: 50)
    private func terminalPage() -> NSView {
        bind(termIsWinCheck, \.termIsWin)
        bind(termResizeCheck, \.autoWinResize)
        for f in [colsField, rowsField] { f.delegate = self }
        custom(load: { [unowned self] in
            self.colsField.stringValue = String(self.s.cols); self.rowsField.stringValue = String(self.s.rows)
        }, store: { [unowned self] in
            // 0 以下は変えない。大きすぎるときは最大に
            if let c = Int(self.colsField.stringValue), c > 0 { self.s.cols = max(10, min(TermLimits.widthMax, c)) }   // term_pp.cpp: TermWidthMax
            if let r = Int(self.rowsField.stringValue), r > 0 { self.s.rows = max(2, min(TermLimits.heightMax, r)) }
        })
        let recv = pop(["CR", "CR+LF", "LF", "AUTO"], ["AUTO", "CR", "LF", "AUTODETECT"], \.recvNewline)
        let send = pop(["CR", "CR+LF", "LF"], ["CR", "CRLF", "LF"], \.sendNewline)
        let ids = ["VT100", "VT100J", "VT101", "VT102", "VT102J", "VT220", "VT220J", "VT282", "VT320", "VT382", "VT420", "VT520", "VT525", "dumb"]
        return SetupUI.column([
            SetupUI.box(Lang.t("Tera Term", "DLG_TERM_WIDTHLABEL", "端末サイズ(&T):"), SetupUI.column([
                SetupUI.row([colsField, SetupUI.label("X"), rowsField]),
                termIsWinCheck, termResizeCheck,
            ])),
            SetupUI.box(Lang.t("Tera Term", "DLG_TERM_NEWLINE", "改行コード"), SetupUI.grid([[SetupUI.label(Lang.t("Tera Term", "DLG_TERM_CRRCV", "受信(&R):")), recv], [SetupUI.label(Lang.t("Tera Term", "DLG_TERM_CRSEND", "送信(&M):")), send]])),
            SetupUI.grid([
                [SetupUI.label(Lang.t("Tera Term", "DLG_TERM_ID", "端末ID(&I):")), pop(ids, ids, \.terminalID)],
                [SetupUI.label(Lang.t("Tera Term", "DLG_TERM_ANSBACK", "応答(&A):")), text(\.answerback, width: 200)],
            ]),
            cb(Lang.t("Tera Term", "DLG_TERM_LOCALECHO", "ローカルエコー(&L):"), \.localEcho),
            cb(Lang.t("Tera Term", "DLG_TERM_AUTOSWITCH", "自動切り替え(VT<->TEK)(&U):"), \.autoWinSwitch),
        ], spacing: 10)
    }

    // シリアルポート (serial_pp.cpp)
    private let portPopup = NSPopUpButton()
    private let baudCombo = NSComboBox().ascii()
    private let dataPopup = SetupUI.popup(["7 bit", "8 bit"])
    private let parityPopup = SetupUI.popup(["none", "odd", "even", "mark", "space"])
    private let stopPopup = SetupUI.popup(["1 bit", "2 bit"])
    private let flowPopup = SetupUI.popup(["Xon/Xoff", "RTS/CTS", "DSR/DTR", "none"])
    private let statusChecks = ["CTS", "DSR", "RING", "RLSD"].map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
    private let rtsCheck = NSButton(checkboxWithTitle: "RTS", target: nil, action: nil)
    private let dtrCheck = NSButton(checkboxWithTitle: "DTR", target: nil, action: nil)
    /// serial_pp.cpp RtsList / DtrList (#934): FlowCtrlRTS / FlowCtrlDTR
    private let rtsPopup = SetupUI.popup(["Disable", "Enable", "Handshake", "Toggle"])
    private let dtrPopup = SetupUI.popup(["Disable", "Enable", "Handshake"])
    /// 開いたときの RTS / DTR / フロー制御 (キャンセルで戻す。PSN_RESET)
    private var serialOriginal: (rts: Int, dtr: Int, flow: String)?
    private let serialInfo = NSTextField(wrappingLabelWithString: "")
    private var statusTimer: Timer?
    private static let flowValues = ["xon", "rts", "dsr", "none"]
    private func serialPage() -> NSView {
        let open = session?.conn as? SerialConnection
        let ports = SerialPort.list()
        portPopup.addItems(withTitles: ports.isEmpty ? [Lang.m("SETUP_NO_SERIAL_PORT", "(シリアルポートが見つかりません)")] : ports)
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
        for c in [rtsCheck, dtrCheck] { c.target = self; c.action = #selector(modemLineChanged(_:)) }
        rtsPopup.selectItem(at: max(0, min(3, serial.rts)))
        dtrPopup.selectItem(at: max(0, min(2, serial.dtr)))
        for p in [rtsPopup, dtrPopup] { p.target = self; p.action = #selector(rtsDtrChanged(_:)) }
        flowPopup.target = self; flowPopup.action = #selector(serialFlowChanged(_:))
        if let o = open { serialOriginal = (o.params.rts, o.params.dtr, o.flow) }
        setComStatus()
        serialInfo.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        serialInfo.preferredMaxLayoutWidth = 260
        if let o = open {
            serialInfo.stringValue = Lang.m("SETUP_SERIAL_OPEN", "%s\n開いています\n%d bps %s", o.params.path, serial.baud,
                                            "\(serial.dataBits)\(serial.parity.prefix(1).uppercased())\(serial.stopBits)")
            statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollModem() }
        } else {
            serialInfo.stringValue = ports.isEmpty ? "" : Lang.m("SETUP_SERIAL_NOT_OPEN", "ポートは開いていません。\n設定は次にシリアルポートを開くときに使います。")
        }
        let grid = SetupUI.grid([
            [SetupUI.label(Lang.t("Tera Term", "DLG_SERIAL_PORT", "ポート(&P):")), portPopup],
            [SetupUI.label(Lang.t("Tera Term", "DLG_SERIAL_BAUD", "スピード(&E):")), baudCombo],
            [SetupUI.label(Lang.t("Tera Term", "DLG_SERIAL_DATA", "データ(&D):")), dataPopup],
            [SetupUI.label(Lang.t("Tera Term", "DLG_SERIAL_PARITY", "パリティ(&A):")), parityPopup],
            [SetupUI.label(Lang.t("Tera Term", "DLG_SERIAL_STOP", "ストップビット(&S):")), stopPopup],
            [SetupUI.label(Lang.t("Tera Term", "DLG_SERIAL_FLOW", "フロー制御(&F):")), flowPopup],
            // e4ddcf535 / 47c5acf21 (#934): CTS RTS [RTS] / DSR DTR [DTR] / RING RLSD
            [SetupUI.row([statusChecks[0], rtsCheck]), rtsPopup],
            [SetupUI.row([statusChecks[1], dtrCheck]), dtrPopup],
            [SetupUI.row([statusChecks[2], statusChecks[3]]), NSGridCell.emptyContentView],
        ])
        let delay = SetupUI.box(Lang.t("Tera Term", "DLG_SERIAL_DELAY", "送信遅延"), SetupUI.row([
            num(\.charDelayMs, width: 50, range: 0...9999), SetupUI.label(Lang.t("Tera Term", "DLG_SERIAL_DELAYCHAR", "ミリ秒/字(&C)")),
            num(\.lineDelayMs, width: 50, range: 0...9999), SetupUI.label(Lang.t("Tera Term", "DLG_SERIAL_DELAYLINE", "ミリ秒/行(&L)")),
        ]))
        return SetupUI.row([SetupUI.column([grid, delay], spacing: 12), SetupUI.column([serialInfo], spacing: 12)],
                           spacing: 24, align: .top)
    }
    private func pollModem() {
        guard let o = session?.conn as? SerialConnection, let st = o.modemStatus() else { return }
        for (i, c) in statusChecks.enumerated() { c.state = st & (1 << i) != 0 ? .on : .off }
    }
    /// IDC_CHECK_RTS / IDC_CHECK_DTR: すぐに上げ下げする (EscapeCommFunction)
    @objc private func modemLineChanged(_ sender: NSButton) {
        guard let o = session?.conn as? SerialConnection else { return }
        o.setLine(sender === rtsCheck ? TIOCM_RTS : TIOCM_DTR, sender.state == .on)
    }
    /// IDC_SERIALRTS / IDC_SERIALDTR を変えた: ポートにすぐかける (SetComStatus)
    @objc private func rtsDtrChanged(_ sender: Any?) { setComStatus() }
    /// IDC_SERIALFLOW を変えた: RTS / DTR を既定に戻す (RTS/CTS なら RTS は Handshake、DSR/DTR なら DTR は Handshake)
    @objc private func serialFlowChanged(_ sender: Any?) {
        let f = Self.flowValues[max(0, flowPopup.indexOfSelectedItem)]
        rtsPopup.selectItem(at: SerialParams.defaultRTS(flow: f))
        dtrPopup.selectItem(at: SerialParams.defaultDTR(flow: f))
        setComStatus()
    }
    /// serial_pp.cpp SetComStatus: 開いているポートに RTS / DTR / フロー制御をかけ、チェックを合わせる。
    /// チェックは Disable / Enable のときだけ押せる (Toggle の RTS はふだん下がっている)
    private func setComStatus() {
        let rts = max(0, rtsPopup.indexOfSelectedItem), dtr = max(0, dtrPopup.indexOfSelectedItem)
        let open = session?.conn as? SerialConnection
        open?.setRTSDTR(rts: rts, dtr: dtr, flow: Self.flowValues[max(0, flowPopup.indexOfSelectedItem)])
        rtsCheck.state = rts == SerialParams.disable || rts == SerialParams.toggle ? .off : .on
        dtrCheck.state = dtr == SerialParams.disable ? .off : .on
        rtsCheck.isEnabled = open != nil && rts <= SerialParams.enable
        dtrCheck.isEnabled = open != nil && dtr <= SerialParams.enable
    }

    // ウィンドウ (win_pp.cpp)
    private let cursorRadios = [SetupUI.radio(Lang.t("Tera Term", "DLG_WIN_BLOCK", "四角(&L):")), SetupUI.radio(Lang.t("Tera Term", "DLG_WIN_VERT", "垂直線(&V):")), SetupUI.radio(Lang.t("Tera Term", "DLG_WIN_HORZ", "下線(&O):"))]
    private let scrollCheck = SetupUI.check(Lang.t("Tera Term", "DLG_WIN_SCROLL1", "スクロールバッファ(&S):"))
    private lazy var scrollField = num(\.scrollback, width: 80, range: 0...1_000_000)
    private let boldCheckWindow = SetupUI.check(Lang.t("Tera Term", "DLG_WIN_BOLDFONT", "太字を有効(&D)"))
    private let textRadio = SetupUI.radio(Lang.t("Tera Term", "DLG_WIN_TEXT", "文字(&X)"))
    private let backRadio = SetupUI.radio(Lang.t("Tera Term", "DLG_WIN_BG", "背景(&K)"))
    private let attrPopup = SetupUI.popup([Lang.t("Tera Term", "DLG_WIN_NORMAL", "標準"), Lang.t("Tera Term", "DLG_WIN_BOLD", "太字"), Lang.t("Tera Term", "DLG_WIN_BLINK", "点滅"), Lang.t("Tera Term", "DLG_WIN_REVERSEATTR", "反転"), "URL", Lang.t("Tera Term", "DLG_WIN_UNDERLINE", "下線")])
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
        let swap = SetupUI.button(Lang.t("Tera Term", "DLG_WIN_SWAP_COLORS", "色入れ替え(&W)"), target: self, action: #selector(swapColors))
        let left = SetupUI.column([
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_WIN_TITLELABEL", "タイトル(&T):")), text(\.title, width: 200)]),
            SetupUI.box(Lang.t("Tera Term", "DLG_WIN_CURSOR", "カーソルの形"), SetupUI.column(cursorRadios + [cb(Lang.m("SETUP_CURSOR_BLINK", "カーソルを点滅"), \.cursorBlink)])),
            cb(Lang.t("Tera Term", "DLG_WIN_PCBOLD16", "&16色モード(PC形式):"), \.pcBoldColor),
            cb(Lang.t("Tera Term", "DLG_WIN_AIXTERM16", "1&6色モード(aixterm形式):"), \.aixterm16Color),
            cb(Lang.t("Tera Term", "DLG_WIN_XTERM256", "&256色モード(xterm形式):"), \.xterm256Color),
            SetupUI.row([scrollCheck, scrollField, SetupUI.label(Lang.t("Tera Term", "DLG_WIN_SCROLL3", "行(&N)"))]),
            boldCheckWindow,
        ], spacing: 8)
        let colorBox = SetupUI.box(Lang.t("Tera Term", "DLG_WIN_COLOR", "カラー"), SetupUI.column([
            SetupUI.row([textRadio, backRadio, SetupUI.label(Lang.t("Tera Term", "DLG_WIN_ATTRIB", "属性(&A)")), attrPopup]),
            swap,
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_WIN_R", "赤(&R):")), rgbSliders[0], rgbLabels[0]]),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_WIN_G", "緑(&G):")), rgbSliders[1], rgbLabels[1]]),
            SetupUI.row([SetupUI.label(Lang.t("Tera Term", "DLG_WIN_B", "青(&B):")), rgbSliders[2], rgbLabels[2]]),
            cb(Lang.t("Tera Term", "DLG_WIN_ALWAYSBG", "常に標準の背景色を使う(&U)"), \.useNormalBGColor),
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
        if n.isEmpty || n.contains("/") || n.contains(":") { return Lang.m("SETUP_LOGNAME_INVALID_CHARS", "ログファイル名に使えない文字が含まれています。") }
        if n.utf8.count > 255 { return Lang.m("SETUP_LOGNAME_TOO_LONG", "ログファイル名が長すぎます。") }
        return nil
    }

    override func ok() {
        if let e = validate() {
            selectPage(at: Page.allCases.firstIndex(of: .log)!)
            let a = NSAlert()
            a.messageText = Lang.t("Tera Term", "MSG_TT_ERROR", "Tera Term: エラー")
            a.informativeText = e
            a.beginSheetModal(for: panel)
            return
        }
        for b in binders { b.store() }
        applyThemeTab()
        // TTMado (タブ・窓割り) の入/切 (すぐに効く)
        TTMado.setEnabled(ttMadoCheck.state == .on)
        s.optionAsMeta = s.metaKey.lowercased() != "off"
        // シリアルポート
        if portPopup.isEnabled, let p = portPopup.titleOfSelectedItem { serial.path = p }
        if let b = Int(baudCombo.stringValue.trimmingCharacters(in: .whitespaces)), b > 0 { serial.baud = b }
        serial.dataBits = dataPopup.indexOfSelectedItem == 0 ? 7 : 8
        serial.parity = parityPopup.titleOfSelectedItem ?? "none"
        serial.stopBits = stopPopup.indexOfSelectedItem == 1 ? 2 : 1
        serial.flow = Self.flowValues[max(0, flowPopup.indexOfSelectedItem)]
        serial.rts = max(0, rtsPopup.indexOfSelectedItem)
        serial.dtr = max(0, dtrPopup.indexOfSelectedItem)
        serialOriginal = nil
        fileDir = fileDirField.stringValue
        s.fileDir = fileDir
        finish()
        completion?(s)
        applyUILanguage()
    }

    override func cancel() {
        revertPreview()
        // PSN_RESET: 開いているポートの RTS / DTR / フロー制御を元に戻す
        if let o = serialOriginal, let sc = session?.conn as? SerialConnection { sc.setRTSDTR(rts: o.rts, dtr: o.dtr, flow: o.flow) }
        serialOriginal = nil
        finish()
        completion?(nil)
    }

    // MARK: その場で反映 (見ながら設定できるように)

    /// 変えた設定を、開いた端末のウィンドウにその場で当てる。保存はしない。キャンセルで元に戻す
    private var previewReady = false
    private var previewing = false
    private var previewOriginal: (settings: TermSettings, theme: ThemeData?, themeEnabled: Bool)?
    /// 開いたときの端末のウィンドウの位置と大きさ (キャンセルでそのまま戻す)
    private var previewFrame: NSRect?

    private func livePreview() {
        guard previewReady, !previewing, let sess = session else { return }
        previewing = true
        defer { previewing = false }
        if previewOriginal == nil {
            // キャンセルで戻すのは、開いたときの設定と、そのときの桁数・行数
            var o = sess.settings
            o.cols = sess.term.cols; o.rows = sess.term.rows
            previewOriginal = (o, ThemeRuntime.shared.current, ThemeRuntime.shared.enabled)
            previewFrame = sess.window?.frame
        }
        // 画面の値を写しの設定に読み取る (self.s は変えない)
        let keep = s
        for b in binders { b.store() }
        var p = s
        s = keep
        // 桁数・行数はそのまま (フォントを変えたときはウィンドウの大きさを合わせる)
        p.cols = sess.term.cols; p.rows = sess.term.rows
        // テーマ: 固定テーマなら色と背景を見せる。テーマを使わないなら、テーマの前の色に戻す
        let themeOn = themeEnableCheck.state == .on && themeStartupPopup.indexOfSelectedItem != 0
        if themeOn, let th = previewTheme {
            th.colors.apply(to: &p)
            ThemeRuntime.shared.enabled = true
            ThemeRuntime.shared.set(th)
        } else if !themeOn {
            if let b = ThemeSettings.colorBackup { ThemeSettings.restore(b, to: &p) }
            if ThemeRuntime.shared.current != nil { ThemeRuntime.shared.set(nil) }
        }
        sess.applySettings(p)
        sess.updateWindowAlpha()   // 不透明度 (applyRuntimeSettings はスクロールバッファも変えるので呼ばない)
    }

    /// 自己テスト用: フォントを大きくしてその場の反映を起こす
    func debugPreviewBiggerFont() { s.fontSize += 8; refresh() }

    private func revertPreview() {
        guard let o = previewOriginal, let sess = session else { return }
        previewOriginal = nil
        ThemeRuntime.shared.enabled = o.themeEnabled
        ThemeRuntime.shared.set(o.theme)
        sess.applySettings(o.settings)
        if let f = previewFrame, let w = sess.window, w.frame != f { w.setFrame(f, display: true) }
        previewFrame = nil
        sess.updateWindowAlpha()
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
    private let column = NSTableColumn(identifier: .init("h"))
    /// OK で保存したあと (新しい接続ダイアログがホストの一覧を作り直す。ttxssh.c OpenEditHistory)
    var onSaved: (() -> Void)?

    func begin(on w: NSWindow) {
        panel.title = "Tera Term: " + Lang.t("Tera Term", "DLG_TCPIP_EDITHISTORY", "ホストリストの編集")
        column.width = 460
        column.resizingMask = []
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selected)
        // 5.2: ホストリストを広くし、横にスクロールできるようにした。ダイアログは大きさを変えられる (WS_THICKFRAME)
        let sc = NSScrollView()
        sc.documentView = table
        sc.hasVerticalScroller = true
        sc.hasHorizontalScroller = true
        sc.autohidesScrollers = true
        sc.borderType = .bezelBorder
        sc.translatesAutoresizingMaskIntoConstraints = false
        sc.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        sc.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        entry.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fitColumn()
        let buttons = SetupUI.column([
            SetupUI.button(Lang.t("Tera Term", "DLG_TCPIP_ADD", "追加(&A)"), target: self, action: #selector(add)),
            SetupUI.button(Lang.m("SETUP_HOSTLIST_REPLACE", "置換(&R)"), target: self, action: #selector(replace)),
            SetupUI.button(Lang.t("Tera Term", "DLG_TCPIP_REMOVE", "削除(&D)"), target: self, action: #selector(remove)),
            SetupUI.button(Lang.t("Tera Term", "DLG_TCPIP_UP", "上へ(&U)"), target: self, action: #selector(up)),
            SetupUI.button(Lang.t("Tera Term", "DLG_TCPIP_DOWN", "下へ(&N)"), target: self, action: #selector(down)),
        ])
        let body = SetupUI.column([entry, SetupUI.row([sc, buttons], align: .top)], spacing: 8)
        layout(body)
        panel.styleMask.insert(.resizable)
        panel.contentMinSize = panel.contentRect(forFrameRect: panel.frame).size
        present(on: w)
    }
    /// 一番長いホストに合わせて列を広げる (横スクロール。LB_SETHORIZONTALEXTENT)
    private func fitColumn() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = hosts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        column.width = max(460, ceil(widest) + 16)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { hosts.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let l = NSTextField(labelWithString: hosts[row])
        l.lineBreakMode = .byClipping
        return l
    }
    private func reload() { fitColumn(); table.reloadData() }
    @objc private func selected() { if table.selectedRow >= 0 { entry.stringValue = hosts[table.selectedRow] } }
    @objc private func add() {
        let v = entry.stringValue.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        hosts.insert(v, at: max(0, table.selectedRow)); reload()
    }
    @objc private func replace() {
        let r = table.selectedRow, v = entry.stringValue.trimmingCharacters(in: .whitespaces)
        guard r >= 0, !v.isEmpty else { return }
        hosts[r] = v; reload()
    }
    @objc private func remove() {
        let r = table.selectedRow
        guard r >= 0 else { return }
        hosts.remove(at: r); reload()
    }
    @objc private func up() { move(-1) }
    @objc private func down() { move(1) }
    private func move(_ d: Int) {
        let r = table.selectedRow
        guard r >= 0, r + d >= 0, r + d < hosts.count else { return }
        hosts.swapAt(r, r + d); table.reloadData()
        table.selectRowIndexes([r + d], byExtendingSelection: false)
    }
    override func ok() { ConnHistory.hosts = hosts; close(); onSaved?() }
    override func cancel() { close() }
}
