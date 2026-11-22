import AppKit
import TeraCore

/// メニューバー (ttermpro.rc IDR_MENU + TTSSH・TTProxy・TTXKanjiMenu が足す項目)。
/// 並びと名前は日本語版 Tera Term (ja_JP.lng) に合わせる。Alt+○ のショートカットは ⌘+○ にする
enum MenuBar {
    static func build(app: AppDelegate) -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m
            main.addItem(top)
            return m
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        func sub(_ t: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            let m = NSMenu(title: t)
            items.forEach { m.addItem($0) }
            i.submenu = m
            return i
        }
        let S = SessionWindowController.self

        // アプリのメニュー (Mac の決まり)
        let appMenu = add("Tera Term Mac", [
            item("Tera Term Mac について", #selector(AppDelegate.showAbout(_:))),
            item("謝辞とライセンス…", #selector(AppDelegate.showCredits(_:))),
            item("ホームページ (GitHub)…", #selector(AppDelegate.openHomepage(_:))),
            .separator(),
        ] + AppUpdater.shared.menuItems() + [
            .separator(),
            item("TeraTerm Menu のリスト編集…", #selector(AppDelegate.showMenuEditor(_:))),
            .separator(),
            item("Tera Term Mac を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            app.uninstallMenuItem(),
            item("Tera Term Mac を終了", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = appMenu

        // ファイル
        _ = add("ファイル", [
            item("新しい接続...", #selector(S.newConnectionMenu(_:)), "n"),
            item("セッションの複製", #selector(S.duplicateSessionMenu(_:)), "d"),
            item("ローカルシェル接続", #selector(S.localShellConnection(_:)), "g"),
            .separator(),
            item("ログ...", #selector(S.openLogDialog(_:))),
            item("ログを中断", #selector(S.togglePauseLog(_:))),
            item("ログにコメントを付加...", #selector(S.commentToLog(_:))),
            item("ログを表示", #selector(S.viewLog(_:))),
            item("ログ記録中ダイアログを表示...", #selector(S.showLogDialog(_:))),
            item("ログを終了", #selector(S.stopLogMenu(_:))),
            item("ファイル送信...", #selector(S.sendFileMenu(_:))),
            item("ファイル受信...", #selector(S.receiveFileMenu(_:))),
            sub("転送", [
                sub("Kermit", [
                    item("受信", #selector(S.kermitReceive(_:))),
                    item("取得...", #selector(S.kermitGet(_:))),
                    item("送信...", #selector(S.kermitSend(_:))),
                    item("終了", #selector(S.kermitFinish(_:))),
                ]),
                sub("XMODEM", [item("受信...", #selector(S.xmodemReceive(_:))), item("送信...", #selector(S.xmodemSend(_:)))]),
                sub("YMODEM", [item("受信...", #selector(S.ymodemReceive(_:))), item("送信...", #selector(S.ymodemSend(_:)))]),
                sub("ZMODEM", [item("受信", #selector(S.zmodemReceive(_:))), item("送信...", #selector(S.zmodemSend(_:)))]),
                sub("B-Plus", [item("受信", #selector(S.bplusReceive(_:))), item("送信...", #selector(S.bplusSend(_:)))]),
                sub("Quick-VAN", [item("受信", #selector(S.quickvanReceive(_:))), item("送信...", #selector(S.quickvanSend(_:)))]),
            ]),
            item("SSH SCP...", #selector(S.sshScp(_:))),
            item("ディレクトリを変更...", #selector(S.changeDirectory(_:))),
            item("ログを再生...", #selector(S.replayLog(_:))),
            .separator(),
            item("印刷...", #selector(S.printMenu(_:)), "p"),
            .separator(),
            item("接続断", #selector(S.disconnectMenu(_:)), "i"),
            item("終了", #selector(S.exitMenu(_:)), "w"),
            item("Tera Termの全終了", #selector(S.exitAllMenu(_:))),
        ])

        // 編集
        let T = TerminalView.self
        _ = add("編集", [
            item("コピー", #selector(T.copy(_:)), "c"),
            item("テーブルをコピー", #selector(T.copyTable(_:))),
            .separator(),
            item("貼り付け", #selector(T.paste(_:)), "v"),
            item("貼り付け<CR>", #selector(T.pasteCR(_:)), "r"),
            .separator(),
            item("画面クリア", #selector(S.clearScreen(_:))),
            item("バッファのクリア", #selector(S.clearBuffer(_:))),
            .separator(),
            item("選択を解除", #selector(T.cancelSelection(_:))),
            .separator(),
            item("表示画面を選択", #selector(T.selectScreen(_:))),
            item("全て選択", #selector(T.selectAll(_:)), "a"),
        ])

        // 設定 (プロキシと SSH の項目は TTProxy・TTSSH が T&CP/IP の前に入れる)
        _ = add("設定", [
            item("端末...", #selector(S.setupTerminal(_:)), ","),
            item("ウィンドウ...", #selector(S.setupWindow(_:))),
            item("フォント...", #selector(S.setupFont(_:))),
            item("キーボード...", #selector(S.setupKeyboard(_:))),
            item("シリアルポート...", #selector(S.setupSerialPort(_:))),
            item("プロキシ...", #selector(S.proxySetup(_:))),
            item("SSH...", #selector(S.sshSetup(_:))),
            item("SSH認証...", #selector(S.sshAuthSetup(_:))),
            item("SSH転送...", #selector(S.sshForwardSetup(_:))),
            item("SSH鍵生成...", #selector(S.sshKeyGenerate(_:))),
            item("TCP/IP...", #selector(S.setupTCPIP(_:))),
            item("全般...", #selector(S.setupGeneral(_:))),
            item("その他の設定...", #selector(S.setupAdditional(_:))),
            .separator(),
            item("設定の保存...", #selector(S.saveSetup(_:))),
            item("設定の読み込み...", #selector(S.restoreSetup(_:))),
            item("設定フォルダ..", #selector(S.openSetupDirectory(_:))),
            .separator(),
            item("キーマップ読み込み...", #selector(S.loadKeyMap(_:))),
        ])

        // コントロール
        _ = add("コントロール", [
            item("端末リセット", #selector(S.resetTerminalMenu(_:))),
            item("リモートタイトルリセット", #selector(S.resetRemoteTitle(_:))),
            .separator(),
            item("AYT送信", #selector(S.areYouThere(_:)), "t"),
            item("ブレーク送信", #selector(S.sendBreakMenu(_:)), "b"),
            item("ポートのリセット", #selector(S.resetPort(_:))),
            item("ブロードキャストコマンド", #selector(S.broadcastCommand(_:))),
            .separator(),
            item("TEKウィンドウを開く", #selector(S.openTEK(_:))),
            item("TEKウィンドウを閉じる", #selector(S.closeTEK(_:))),
            .separator(),
            item("マクロ", #selector(S.macroMenu(_:))),
            item("マクロウィンドウの表示", #selector(S.showMacroWindow(_:))),
        ])

        // ウィンドウ (開くたびに作り直す)
        let win = add("ウィンドウ", [])
        win.delegate = WindowMenuController.shared

        // 漢字コード (TTXKanjiMenu。開くたびに作り直す)
        let kanji = add("漢字コード", [])
        kanji.delegate = KanjiMenuController.shared

        // ヘルプ (TTSSH・TTProxy の「について」は Mac 版では「謝辞とライセンス」にまとめる)
        let help = add("ヘルプ", [
            item("目次", #selector(AppDelegate.openHelpIndex(_:))),
            .separator(),
            item("Tera Termについて...", #selector(AppDelegate.showAbout(_:))),
        ])
        NSApp.helpMenu = help
        return main
    }
}

// MARK: - ウィンドウ メニュー (ttcmn.c SetWinMenuW)

final class WindowMenuController: NSObject, NSMenuDelegate {
    static let shared = WindowMenuController()

    enum Arrange { case cascade, stacked, sideBySide }
    /// 元に戻す (WinUndoFlag / WinUndoStyle / WinPrevRect)
    private var undoStyle: Arrange?
    private var undoFlag = false
    private var saved: [(SessionWindowController, NSRect, Bool)] = []

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // 最初の 9 個のウインドウ: 番号 状態 タイトル (# 隠れている - 最小化 @ 最大化 + 通常)
        for (i, c) in SessionWindowController.all.prefix(9).enumerated() {
            guard let w = c.window else { continue }
            let state = !w.isVisible && !w.isMiniaturized ? "#" : (w.isMiniaturized ? "-" : (w.isZoomed ? "@" : "+"))
            let it = NSMenuItem(title: "\(i + 1) \(state) \(w.title)", action: #selector(selectWindow(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            menu.addItem(it)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        func add(_ t: String, _ a: Selector, _ k: String = "") {
            let it = NSMenuItem(title: t, action: a, keyEquivalent: k)
            it.target = self
            menu.addItem(it)
        }
        add("ウィンドウ", #selector(showWindowList(_:)))
        add("すべて最小化", #selector(minimizeAll(_:)))
        add("すべて復元", #selector(restoreAll(_:)))
        add("重ねて表示", #selector(cascade(_:)))
        add("上下に並べて表示", #selector(stacked(_:)))
        add("左右に並べて表示", #selector(sideBySide(_:)))
        if undoFlag, let s = undoStyle {
            let name = s == .cascade ? "重ねて表示" : (s == .stacked ? "上下に並べて表示" : "左右に並べて表示")
            add("元に戻す - " + name, #selector(undo(_:)))
        }
        // Mac のウインドウの操作
        menu.addItem(.separator())
        let mini = NSMenuItem(title: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(mini)
        menu.addItem(NSMenuItem(title: "拡大/縮小", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "前のタブ", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{"))
        menu.addItem(NSMenuItem(title: "次のタブ", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}"))
    }

    /// SelectWin → ForegroundWin: 最小化なら戻して前へ
    static func bringToFront(_ c: SessionWindowController) {
        guard let w = c.window else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func selectWindow(_ sender: NSMenuItem) {
        let all = SessionWindowController.all
        guard sender.tag < all.count else { return }
        WindowMenuController.bringToFront(all[sender.tag])
    }

    @objc func showWindowList(_ sender: Any?) {
        WindowListDialog.run(current: NSApp.keyWindow?.windowController as? SessionWindowController)
    }

    @objc private func minimizeAll(_ sender: Any?) {
        SessionWindowController.all.forEach { $0.window?.miniaturize(nil) }
    }

    @objc private func restoreAll(_ sender: Any?) {
        for c in SessionWindowController.all {
            guard let w = c.window else { continue }
            if w.isMiniaturized { w.deminiaturize(nil) }
            if w.isZoomed { w.zoom(nil) }
            w.orderFront(nil)
        }
    }

    /// 並べる窓: 呼んだウインドウを先頭に、ほかは一覧の順
    private func targets() -> [SessionWindowController] {
        var list = SessionWindowController.all.filter { $0.window?.isVisible == true || $0.window?.isMiniaturized == true }
        if let cur = NSApp.keyWindow?.windowController as? SessionWindowController, let i = list.firstIndex(where: { $0 === cur }) {
            list.remove(at: i); list.insert(cur, at: 0)
        }
        return list
    }

    /// get_valid_window_and_memorize_rect: 同じ並べ方を続けて選ぶと「元に戻す」は消える
    private func memorize(_ style: Arrange, _ list: [SessionWindowController]) {
        if !undoFlag { undoFlag = true } else if undoStyle == style { undoFlag = false }
        undoStyle = style
        saved = list.compactMap { c in c.window.map { (c, $0.frame, $0.isMiniaturized) } }
    }

    private func arrange(_ style: Arrange) {
        let list = targets()
        guard !list.isEmpty, let screen = (list[0].window?.screen ?? NSScreen.main)?.visibleFrame else { return }
        memorize(style, list)
        for c in list { if c.window?.isMiniaturized == true { c.window?.deminiaturize(nil) } }
        let n = CGFloat(list.count)
        for (i, c) in list.enumerated() {
            guard let w = c.window else { continue }
            var f = w.frame
            switch style {
            case .cascade:
                let step: CGFloat = 26
                f.origin = NSPoint(x: screen.minX + step * CGFloat(i), y: screen.maxY - f.height - step * CGFloat(i))
            case .stacked:
                let h = (screen.height / n).rounded(.down)
                f = NSRect(x: screen.minX, y: screen.maxY - h * CGFloat(i + 1), width: screen.width, height: h)
            case .sideBySide:
                let wdt = (screen.width / n).rounded(.down)
                f = NSRect(x: screen.minX + wdt * CGFloat(i), y: screen.minY, width: wdt, height: screen.height)
            }
            w.setFrame(f, display: true, animate: false)
            w.orderFront(nil)
        }
        list.first?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func cascade(_ sender: Any?) { arrange(.cascade) }
    @objc private func stacked(_ sender: Any?) { arrange(.stacked) }
    @objc private func sideBySide(_ sender: Any?) { arrange(.sideBySide) }

    /// UndoAllWin: 覚えておいた位置に戻す
    @objc private func undo(_ sender: Any?) {
        undoFlag = false
        for (c, f, mini) in saved {
            guard let w = c.window else { continue }
            w.setFrame(f, display: true)
            if mini { w.miniaturize(nil) }
        }
        saved = []
    }
}

/// 「ウィンドウ」のダイアログ (windowdlg.cpp: ウィンドウのリスト)
final class WindowListDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var items: [SessionWindowController] = []
    private let current: SessionWindowController?
    private var panel: NSPanel!

    private init(current: SessionWindowController?) { self.current = current }

    static func run(current: SessionWindowController?) {
        let d = WindowListDialog(current: current)
        d.show()
    }

    private func label(_ c: SessionWindowController) -> String {
        guard let w = c.window else { return "" }
        let state = !w.isVisible && !w.isMiniaturized ? "#" : (w.isMiniaturized ? "-" : (w.isZoomed ? "@" : "+"))
        return "\(state) \(w.title)"
    }

    private func show() {
        items = SessionWindowController.all
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Tera Term: ウィンドウのリスト"
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("w"))
        col.width = 380
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(open(_:))
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let openB = NSButton(title: "開く", target: self, action: #selector(open(_:)))
        openB.keyEquivalent = "\r"
        let cancelB = NSButton(title: "キャンセル", target: self, action: #selector(cancel(_:)))
        cancelB.keyEquivalent = "\u{1B}"
        let closeB = NSButton(title: "閉じる", target: self, action: #selector(closeWin(_:)))
        let buttons = NSStackView(views: [openB, cancelB, closeB])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        let left = NSStackView(views: [NSTextField(labelWithString: "ウィンドウ:"), scroll])
        left.orientation = .vertical
        left.alignment = .leading
        let root = NSStackView(views: [left, buttons])
        root.alignment = .top
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        panel.contentView = root
        panel.setContentSize(root.fittingSize)
        table.reloadData()
        if let cur = current, let i = items.firstIndex(where: { $0 === cur }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: label(items[row]))
    }

    @objc private func open(_ sender: Any?) {
        let r = table.selectedRow
        NSApp.stopModal()
        if r >= 0 && r < items.count { WindowMenuController.bringToFront(items[r]) }
    }

    @objc private func cancel(_ sender: Any?) { NSApp.stopModal() }

    /// 閉じる: ほかのウインドウなら一覧から消してそのウインドウを閉じる (ダイアログは開いたまま)。自分なら閉じて自分を閉じる
    @objc private func closeWin(_ sender: Any?) {
        let r = table.selectedRow
        guard r >= 0 && r < items.count else { return }
        let c = items[r]
        if c === current {
            NSApp.stopModal()
            DispatchQueue.main.async { c.window?.performClose(nil) }
            return
        }
        items.remove(at: r)
        table.reloadData()
        DispatchQueue.main.async { c.window?.performClose(nil) }
    }
}

// MARK: - 漢字コード メニュー (TTXKanjiMenu)

/// [TTXKanjiMenu] の設定
struct KanjiMenuSettings {
    var charCodeMenu = true
    var useOneSetting = true
    var useOneSettingMenu = true
    var ambiguousMenu = false
    /// Auto / Japanese (Mac 版は日本語の文字コードだけ)
    var language = "Auto"

    private static let d = UserDefaults.standard
    static func load() -> KanjiMenuSettings {
        var s = KanjiMenuSettings()
        if d.object(forKey: "kanjiCharCodeMenu") != nil { s.charCodeMenu = d.bool(forKey: "kanjiCharCodeMenu") }
        if d.object(forKey: "kanjiUseOneSetting") != nil { s.useOneSetting = d.bool(forKey: "kanjiUseOneSetting") }
        if d.object(forKey: "kanjiUseOneSettingMenu") != nil { s.useOneSettingMenu = d.bool(forKey: "kanjiUseOneSettingMenu") }
        if d.object(forKey: "kanjiAmbiguousMenu") != nil { s.ambiguousMenu = d.bool(forKey: "kanjiAmbiguousMenu") }
        if let v = d.string(forKey: "kanjiLanguage") { s.language = v }
        return s
    }
    func save() {
        let d = KanjiMenuSettings.d
        d.set(charCodeMenu, forKey: "kanjiCharCodeMenu")
        d.set(useOneSetting, forKey: "kanjiUseOneSetting")
        d.set(useOneSettingMenu, forKey: "kanjiUseOneSettingMenu")
        d.set(ambiguousMenu, forKey: "kanjiAmbiguousMenu")
        d.set(language, forKey: "kanjiLanguage")
    }
}

final class KanjiMenuController: NSObject, NSMenuDelegate {
    static let shared = KanjiMenuController()
    var settings = KanjiMenuSettings.load()

    private let codes: [(String, String, TermEncoding)] = [
        ("Shift_JIS", "Shift_JIS", .sjis), ("EUC-JP", "EUC-JP", .eucjp), ("JIS", "JIS", .jis), ("UTF-8", "UTF-8", .utf8),
    ]

    private var session: SessionWindowController? { NSApp.keyWindow?.windowController as? SessionWindowController ?? NSApp.mainWindow?.windowController as? SessionWindowController }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = session
        let recv = s?.settings.encoding
        let send = s?.settings.encodingSend
        func add(_ title: String, _ action: Selector, tag: Int, on: Bool, enabled: Bool = true) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
            it.target = self
            it.tag = tag
            it.state = on ? .on : .off
            it.isEnabled = enabled && s != nil
            menu.addItem(it)
        }
        menu.autoenablesItems = false
        if settings.charCodeMenu {
            if settings.useOneSetting {
                for (i, c) in codes.enumerated() { add("送受信: \(c.0)", #selector(pickRecv(_:)), tag: i, on: recv == c.2) }
            } else {
                for (i, c) in codes.enumerated() { add("受信: \(c.0)", #selector(pickRecv(_:)), tag: i, on: recv == c.2) }
                menu.addItem(.separator())
                for (i, c) in codes.enumerated() { add("送信: \(c.1)", #selector(pickSend(_:)), tag: i, on: send == c.2) }
            }
            if settings.useOneSettingMenu {
                menu.addItem(.separator())
                add("送受信両方を変更", #selector(toggleOne(_:)), tag: 0, on: settings.useOneSetting)
            }
        }
        if settings.ambiguousMenu {
            if settings.charCodeMenu { menu.addItem(.separator()) }
            let utf8 = recv == .utf8 || send == .utf8
            let wide = s?.settings.ambiguousWide ?? false
            add("Ambiguous Character Width 1", #selector(pickAmbiguous(_:)), tag: 1, on: !wide, enabled: utf8)
            add("Ambiguous Character Width 2", #selector(pickAmbiguous(_:)), tag: 2, on: wide, enabled: utf8)
        }
        menu.addItem(.separator())
        let set = NSMenuItem(title: "設定", action: #selector(showSettings(_:)), keyEquivalent: "")
        set.target = self
        menu.addItem(set)
    }

    /// 選んだ文字コードをすぐ使う (CallResetCharSet)
    private func apply(_ f: (inout TermSettings) -> Void) {
        guard let c = session else { return }
        var s = c.settings
        f(&s)
        c.applySettings(s)
    }

    @objc private func pickRecv(_ sender: NSMenuItem) {
        let e = codes[sender.tag].2
        let one = settings.useOneSetting
        apply { s in s.encoding = e; if one { s.encodingSend = e } }
    }

    @objc private func pickSend(_ sender: NSMenuItem) {
        let e = codes[sender.tag].2
        apply { s in s.encodingSend = e }
    }

    /// 送受信両方を変更: オンにするとき送信を受信に合わせる
    @objc private func toggleOne(_ sender: Any?) {
        settings.useOneSetting.toggle()
        settings.save()
        if settings.useOneSetting { apply { s in s.encodingSend = s.encoding } }
    }

    @objc private func pickAmbiguous(_ sender: NSMenuItem) {
        let wide = sender.tag == 2
        apply { s in s.ambiguousWide = wide }
    }

    /// 設定 (KanjiMenu設定)
    @objc private func showSettings(_ sender: Any?) {
        let charCode = NSButton(checkboxWithTitle: "文字コードメニューを表示", target: nil, action: nil)
        let contentsLabel = NSTextField(labelWithString: "メニュー内容:")
        let lang = NSPopUpButton()
        lang.addItems(withTitles: ["自動選択", "日本語"])
        lang.selectItem(at: settings.language == "Japanese" ? 1 : 0)
        let oneMenu = NSButton(checkboxWithTitle: "送受信両方を変更メニューを表示", target: nil, action: nil)
        let one = NSButton(checkboxWithTitle: "送受信両方を変更", target: nil, action: nil)
        let amb = NSButton(checkboxWithTitle: "Ambiguous(曖昧)文字幅メニューを表示", target: nil, action: nil)
        charCode.state = settings.charCodeMenu ? .on : .off
        oneMenu.state = settings.useOneSettingMenu ? .on : .off
        one.state = settings.useOneSetting ? .on : .off
        amb.state = settings.ambiguousMenu ? .on : .off
        let dependents: [NSControl] = [lang, oneMenu, one]
        let toggler = Toggler { dependents.forEach { $0.isEnabled = charCode.state == .on } }
        charCode.target = toggler
        charCode.action = #selector(Toggler.fire)
        toggler.fire()
        let version = NSTextField(labelWithString: "KanjiMenu (Tera Term Mac)")
        version.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [charCode, contentsLabel, lang, oneMenu, one, amb, version])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: stack.fittingSize.height)
        let a = NSAlert()
        a.messageText = "KanjiMenu設定"
        a.accessoryView = stack
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        settings.charCodeMenu = charCode.state == .on
        settings.language = lang.indexOfSelectedItem == 1 ? "Japanese" : "Auto"
        settings.useOneSettingMenu = oneMenu.state == .on
        settings.useOneSetting = one.state == .on
        settings.ambiguousMenu = amb.state == .on
        settings.save()
        _ = toggler
    }

    private final class Toggler: NSObject {
        let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        @objc func fire() { f() }
    }
}
