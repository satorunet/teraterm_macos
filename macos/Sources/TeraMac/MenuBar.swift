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

        // 本家の文言 ([Tera Term] などの節)。Mac 版だけのものは Lang.m
        func tt(_ key: String, _ def: String) -> String { Lang.t("Tera Term", key, def) }
        func ssh(_ key: String, _ def: String) -> String { Lang.t("TTSSH", key, def) }
        func proxy(_ key: String, _ def: String) -> String { Lang.t("TTProxy", key, def) }

        // アプリのメニュー (Mac の決まり)
        let appMenu = add("Tera Term Mac", [
            item(Lang.m("MENU_APP_ABOUT", "Tera Term Mac について"), #selector(AppDelegate.showAbout(_:))),
            item(Lang.m("MENU_APP_CREDITS", "謝辞とライセンス…"), #selector(AppDelegate.showCredits(_:))),
            item(Lang.m("MENU_APP_HOMEPAGE", "ホームページ (GitHub)…"), #selector(AppDelegate.openHomepage(_:))),
            .separator(),
        ] + AppUpdater.shared.menuItems() + [
            .separator(),
            item(Lang.m("MENU_APP_TTMENU_EDIT", "TeraTerm Menu のリスト編集…"), #selector(AppDelegate.showMenuEditor(_:))),
            .separator(),
            item(Lang.m("MENU_APP_HIDE", "Tera Term Mac を隠す"), #selector(NSApplication.hide(_:)), "h"),
            item(Lang.m("MENU_APP_HIDE_OTHERS", "ほかを隠す"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(Lang.m("MENU_APP_SHOW_ALL", "すべてを表示"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            app.uninstallMenuItem(),
            item(Lang.m("MENU_APP_QUIT", "Tera Term Mac を終了"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = appMenu

        // ファイル
        _ = add(tt("MENU_FILE", "ファイル"), [
            item(tt("MENU_FILE_NEW", "新しい接続..."), #selector(S.newConnectionMenu(_:)), "n"),
            item(tt("MENU_FILE_DUPLICATE", "セッションの複製"), #selector(S.duplicateSessionMenu(_:)), "d"),
            item(Lang.m("MENU_FILE_LOCALSHELL", "ローカルシェル接続"), #selector(S.localShellConnection(_:)), "g"),
            .separator(),
            item(tt("MENU_FILE_LOG", "ログ..."), #selector(S.openLogDialog(_:))),
            item(tt("MENU_FILE_PAUSELOG", "ログを中断"), #selector(S.togglePauseLog(_:))),
            item(tt("MENU_FILE_COMMENTLOG", "ログにコメントを付加..."), #selector(S.commentToLog(_:))),
            item(tt("MENU_FILE_VIEWLOG", "ログを表示"), #selector(S.viewLog(_:))),
            item(tt("MENU_FILE_SHOWLOGDIALOG", "ログ記録中ダイアログを表示..."), #selector(S.showLogDialog(_:))),
            item(tt("MENU_FILE_STOPLOG", "ログを終了"), #selector(S.stopLogMenu(_:))),
            item(tt("MENU_FILE_SENDFILE", "ファイル送信..."), #selector(S.sendFileMenu(_:))),
            item(tt("MENU_FILE_RECVFILE", "ファイル受信..."), #selector(S.receiveFileMenu(_:))),
            sub(tt("MENU_TRANS", "転送"), [
                sub("Kermit", [
                    item(tt("MENU_TRANS_KERMIT_RCV", "受信"), #selector(S.kermitReceive(_:))),
                    item(tt("MENU_TRANS_KERMIT_GET", "取得..."), #selector(S.kermitGet(_:))),
                    item(tt("MENU_TRANS_KERMIT_SEND", "送信..."), #selector(S.kermitSend(_:))),
                    item(tt("MENU_TRANS_KERMIT_FINISH", "終了"), #selector(S.kermitFinish(_:))),
                ]),
                sub("XMODEM", [item(tt("MENU_TRANS_X_RCV", "受信..."), #selector(S.xmodemReceive(_:))), item(tt("MENU_TRANS_X_SEND", "送信..."), #selector(S.xmodemSend(_:)))]),
                sub("YMODEM", [item(tt("MENU_TRANS_Y_RCV", "受信..."), #selector(S.ymodemReceive(_:))), item(tt("MENU_TRANS_Y_SEND", "送信..."), #selector(S.ymodemSend(_:)))]),
                sub("ZMODEM", [item(tt("MENU_TRANS_Z_RCV", "受信"), #selector(S.zmodemReceive(_:))), item(tt("MENU_TRANS_Z_SEND", "送信..."), #selector(S.zmodemSend(_:)))]),
                sub("B-Plus", [item(tt("MENU_TRANS_BP_RCV", "受信"), #selector(S.bplusReceive(_:))), item(tt("MENU_TRANS_BP_SEND", "送信..."), #selector(S.bplusSend(_:)))]),
                sub("Quick-VAN", [item(tt("MENU_TRANS_QV_RCV", "受信"), #selector(S.quickvanReceive(_:))), item(tt("MENU_TRANS_QV_SEND", "送信..."), #selector(S.quickvanSend(_:)))]),
            ]),
            item("SSH SCP...", #selector(S.sshScp(_:))),
            item(tt("MENU_FILE_CHANGEDIR", "ディレクトリを変更..."), #selector(S.changeDirectory(_:))),
            item(tt("MENU_FILE_REPLAYLOG", "ログを再生..."), #selector(S.replayLog(_:))),
            .separator(),
            item(tt("MENU_FILE_PRINT", "印刷..."), #selector(S.printMenu(_:)), "p"),
            .separator(),
            item(tt("MENU_FILE_DISCONNECT", "接続断"), #selector(S.disconnectMenu(_:)), "i"),
            item(tt("MENU_FILE_EXIT", "終了"), #selector(S.exitMenu(_:)), "w"),
            item(tt("MENU_FILE_EXITALL", "Tera Termの全終了"), #selector(S.exitAllMenu(_:))),
        ])

        // 編集
        let T = TerminalView.self
        _ = add(tt("MENU_EDIT", "編集"), [
            item(tt("MENU_EDIT_COPY", "コピー"), #selector(T.copy(_:)), "c"),
            item(tt("MENU_EDIT_COPYTABLE", "テーブルをコピー"), #selector(T.copyTable(_:))),
            .separator(),
            item(tt("MENU_EDIT_PASTE", "貼り付け"), #selector(T.paste(_:)), "v"),
            item(tt("MENU_EDIT_PASTECR", "貼り付け<CR>"), #selector(T.pasteCR(_:)), "r"),
            .separator(),
            item(tt("MENU_EDIT_CLSCREEN", "画面クリア"), #selector(S.clearScreen(_:))),
            item(tt("MENU_EDIT_CLBUFFER", "バッファのクリア"), #selector(S.clearBuffer(_:))),
            .separator(),
            item(tt("MENU_EDIT_CANCELSELECT", "選択を解除"), #selector(T.cancelSelection(_:))),
            .separator(),
            item(tt("MENU_EDIT_SELECTSCREEN", "表示画面を選択"), #selector(T.selectScreen(_:))),
            item(tt("MENU_EDIT_SELECTALL", "全て選択"), #selector(T.selectAll(_:)), "a"),
        ])

        // 設定 (プロキシと SSH の項目は TTProxy・TTSSH が T&CP/IP の前に入れる)
        _ = add(tt("MENU_SETUP", "設定"), [
            item(tt("MENU_SETUP_TERMINAL", "端末..."), #selector(S.setupTerminal(_:)), ","),
            item(tt("MENU_SETUP_WINDOW", "ウィンドウ..."), #selector(S.setupWindow(_:))),
            item(tt("MENU_SETUP_FONT", "フォント..."), #selector(S.setupFont(_:))),
            item(Lang.m("MENU_SETUP_THEME", "テーマ..."), #selector(S.setupTheme(_:))),
            item(tt("MENU_SETUP_KEYBOARD", "キーボード..."), #selector(S.setupKeyboard(_:))),
            item(tt("MENU_SETUP_SERIALPORT", "シリアルポート..."), #selector(S.setupSerialPort(_:))),
            item(proxy("MENU_SETUP", "プロキシ..."), #selector(S.proxySetup(_:))),
            item(ssh("MENU_SSH", "SSH..."), #selector(S.sshSetup(_:))),
            item(ssh("MENU_SSH_AUTH", "SSH認証..."), #selector(S.sshAuthSetup(_:))),
            item(ssh("MENU_SSH_FORWARD", "SSH転送..."), #selector(S.sshForwardSetup(_:))),
            item(ssh("MENU_SSH_KEYGEN", "SSH鍵生成..."), #selector(S.sshKeyGenerate(_:))),
            item(tt("MENU_SETUP_TCPIP", "TCP/IP..."), #selector(S.setupTCPIP(_:))),
            item(tt("MENU_SETUP_GENERAL", "全般..."), #selector(S.setupGeneral(_:))),
            item(tt("MENU_SETUP_ADDITION", "その他の設定..."), #selector(S.setupAdditional(_:))),
            .separator(),
            item(tt("MENU_SETUP_SAVE", "設定の保存..."), #selector(S.saveSetup(_:))),
            item(tt("MENU_SETUP_RESTORE", "設定の読み込み..."), #selector(S.restoreSetup(_:))),
            item(tt("MENU_SETUP_OPENSETUP", "設定フォルダ.."), #selector(S.openSetupDirectory(_:))),
            .separator(),
            item(tt("MENU_SETUP_LOADKEYMAP", "キーマップ読み込み..."), #selector(S.loadKeyMap(_:))),
        ])

        // コントロール
        _ = add(tt("MENU_CONTROL", "コントロール"), [
            item(tt("MENU_CONTROL_RESET", "端末リセット"), #selector(S.resetTerminalMenu(_:))),
            item(tt("MENU_CONTROL_RESETTITLE", "リモートタイトルリセット"), #selector(S.resetRemoteTitle(_:))),
            .separator(),
            item(tt("MENU_CONTROL_AREYOUTHERE", "AYT送信"), #selector(S.areYouThere(_:)), "t"),
            item(tt("MENU_CONTROL_SENDBREAK", "ブレーク送信"), #selector(S.sendBreakMenu(_:)), "b"),
            item(tt("MENU_CONTROL_RESETPORT", "ポートのリセット"), #selector(S.resetPort(_:))),
            item(tt("MENU_CONTROL_BROADCAST", "ブロードキャストコマンド"), #selector(S.broadcastCommand(_:))),
            .separator(),
            item(tt("MENU_CONTROL_OPENTEK", "TEKウィンドウを開く"), #selector(S.openTEK(_:))),
            item(tt("MENU_CONTROL_CLOSETEK", "TEKウィンドウを閉じる"), #selector(S.closeTEK(_:))),
            .separator(),
            // TTXAlwaysOnTop (追加プラグイン) が「マクロ」の前に入れる項目
            item(Lang.t("TTXAlwaysOnTop", "MENU_ALWAYSONTOP", "常に最前面に表示"), #selector(S.toggleAlwaysOnTop(_:))),
            .separator(),
            item(tt("MENU_CONTROL_MACRO", "マクロ"), #selector(S.macroMenu(_:))),
            item(tt("MENU_CONTROL_SHOW_MACRO", "マクロウィンドウの表示"), #selector(S.showMacroWindow(_:))),
        ])

        // ウィンドウ (開くたびに作り直す)
        let win = add(tt("MENU_WINDOW", "ウィンドウ"), [])
        win.delegate = WindowMenuController.shared


        // 漢字コード (TTXKanjiMenu。開くたびに作り直す)
        let kanji = add(Lang.t("TTXKanjiMenu", "MENU_KANJI", "漢字コード"), [])
        kanji.delegate = KanjiMenuController.shared

        // ヘルプ
        let help = add(tt("MENU_HELP", "ヘルプ"), [
            item(tt("MENU_HELP_INDEX", "目次"), #selector(AppDelegate.openHelpIndex(_:))),
            // Mac 版だけ: 匿名の要望・お知らせボックス (FeedbackPanel)
            item(Lang.m("FEEDBACK_MENU", "要望・お知らせを送る…"), #selector(AppDelegate.openFeedback(_:))),
            item(Lang.m("FEEDBACK_ISSUES_MENU", "GitHub の Issues で報告する…"), #selector(AppDelegate.openIssues(_:))),
            .separator(),
            // TTProxy・TTSSH が「Tera Termについて」の前に入れる項目
            item(proxy("MENU_ABOUT", "TTProxyについて..."), #selector(AppDelegate.showAboutTTProxy(_:))),
            item(ssh("MENU_ABOUT", "TTSSHについて..."), #selector(AppDelegate.showAboutTTSSH(_:))),
            item(tt("MENU_HELP_ABOUT", "Tera Termについて..."), #selector(AppDelegate.showAbout(_:))),
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
    /// 並べる前にタブでまとまっていた窓 (元に戻すときにタブに戻す)。各組の先頭が選ばれていたタブ
    private var savedTabs: [[SessionWindowController]] = []

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // 最初の 9 個のウインドウ: 番号 状態 タイトル (# 隠れている - 最小化 @ 最大化 + 通常)
        // (分割中のペインは、分割しているウインドウの状態と、そのセッションのタイトル)
        for (i, c) in SessionWindowController.all.prefix(9).enumerated() {
            guard let w = c.presentingWindow else { continue }
            let state = !w.isVisible && !w.isMiniaturized ? "#" : (w.isMiniaturized ? "-" : (w.isZoomed ? "@" : "+"))
            let it = NSMenuItem(title: "\(i + 1) \(state) \(c.displayTitle)", action: #selector(selectWindow(_:)), keyEquivalent: "")
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
        func tt(_ key: String, _ def: String) -> String { Lang.t("Tera Term", key, def) }
        add(tt("MENU_WINDOW_WINDOW", "ウィンドウ"), #selector(showWindowList(_:)))
        add(tt("MENU_WINDOW_MINIMIZEALL", "すべて最小化"), #selector(minimizeAll(_:)))
        add(tt("MENU_WINDOW_RESTOREALL", "すべて復元"), #selector(restoreAll(_:)))
        add(tt("MENU_WINDOW_CASCADE", "重ねて表示"), #selector(cascade(_:)))
        add(tt("MENU_WINDOW_STACKED", "上下に並べて表示"), #selector(stacked(_:)))
        add(tt("MENU_WINDOW_SIDEBYSIDE", "左右に並べて表示"), #selector(sideBySide(_:)))
        if undoFlag, let s = undoStyle {
            let title: String
            switch s {
            case .cascade: title = tt("MENU_WINDOW_CASCADE_UNDO", "元に戻す - 重ねて表示")
            case .stacked: title = tt("MENU_WINDOW_STACKED_UNDO", "元に戻す - 上下に並べて表示")
            case .sideBySide: title = tt("MENU_WINDOW_SIDEBYSIDE_UNDO", "元に戻す - 左右に並べて表示")
            }
            add(title, #selector(undo(_:)))
        }
        // Mac のウインドウの操作
        menu.addItem(.separator())
        let mini = NSMenuItem(title: Lang.m("MENU_WINDOW_MINIATURIZE", "しまう"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(mini)
        menu.addItem(NSMenuItem(title: Lang.m("MENU_WINDOW_ZOOM", "拡大/縮小"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: Lang.m("MENU_WINDOW_PREV_TAB", "前のタブ"), action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{"))
        menu.addItem(NSMenuItem(title: Lang.m("MENU_WINDOW_NEXT_TAB", "次のタブ"), action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}"))
        // ウィンドウ内のメニューバー (本家の「メニューバーを表示」/ PopupMenu)
        menu.addItem(.separator())
        let bar = NSMenuItem(title: InWindowMenuBar.isShown ? Lang.m("MENU_CLOSE_MENUBAR", "メニューバーを閉じる") : Lang.m("MENU_OPEN_MENUBAR", "メニューバーを開く"),
                             action: #selector(toggleMenuBar(_:)), keyEquivalent: "")
        bar.target = self
        menu.addItem(bar)
    }

    @objc private func toggleMenuBar(_ sender: Any?) { InWindowMenuBar.isShown.toggle() }

    // MARK: タブ (TabSplit.swift)

    @objc func splitTabsSideBySide(_ sender: Any?) {
        if let w = TabSplit.currentWindow { TabSplit.splitTabs(of: w, sideBySide: true) }
    }
    @objc func splitTabsStacked(_ sender: Any?) {
        if let w = TabSplit.currentWindow { TabSplit.splitTabs(of: w, sideBySide: false) }
    }
    @objc func splitPaneSideBySide(_ sender: Any?) {
        if let w = TabSplit.currentWindow { TabSplit.splitFocused(of: w, sideBySide: true) }
    }
    @objc func splitPaneStacked(_ sender: Any?) {
        if let w = TabSplit.currentWindow { TabSplit.splitFocused(of: w, sideBySide: false) }
    }
    @objc func unsplitTabs(_ sender: Any?) { TabSplit.unsplitCurrent() }
    @objc func toggleTabMark(_ sender: Any?) {
        // 分割のペインなら「この画面を選ぶ」(ペインの ≡ メニューと同じ)
        if let c = SessionWindowController.current, let sp = c.tabSplit { sp.togglePaneMark(c); return }
        guard let c = SessionWindowController.current, TabMarks.canMark(c) else { return }
        TabMarks.toggle(c)
    }
    @objc func clearTabMarks(_ sender: Any?) {
        TabMarks.clearAll()
        TabSplit.all.forEach { $0.clearPaneMarks() }
    }
    @objc func mergeAllWindows(_ sender: Any?) { TabSplit.mergeAllWindows() }
    @objc func moveTabToNewWindow(_ sender: Any?) { TabSplit.moveCurrentTabToNewWindow() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // TTMado を切っているときは、タブ・窓割りの項目は使えない
        let tabItems: [Selector] = [#selector(splitTabsSideBySide(_:)), #selector(splitTabsStacked(_:)), #selector(splitPaneSideBySide(_:)),
                                    #selector(splitPaneStacked(_:)), #selector(unsplitTabs(_:)), #selector(toggleTabMark(_:)), #selector(clearTabMarks(_:))]
        if !TTMado.isEnabled, let a = item.action, tabItems.contains(a) { return false }
        let w = TabSplit.currentWindow
        let sp = TabSplit.split(of: w)
        switch item.action {
        case #selector(splitTabsSideBySide(_:)):
            item.state = sp?.isSideBySide == true ? .on : .off
            return TabSplit.canSplit(w)
        case #selector(splitTabsStacked(_:)):
            item.state = sp != nil && sp?.isSideBySide == false ? .on : .off
            return TabSplit.canSplit(w)
        case #selector(splitPaneSideBySide(_:)), #selector(splitPaneStacked(_:)): return TabSplit.canSplitFocused(w)
        case #selector(unsplitTabs(_:)): return sp != nil
        case #selector(toggleTabMark(_:)):
            let c = SessionWindowController.current
            if let s = c, let ps = s.tabSplit {
                item.title = s.paneMarked ? Lang.m("MENU_PANE_UNMARK", "この画面の選択を外す") : Lang.m("MENU_PANE_MARK", "この画面を選ぶ")
                return ps.panes.count > 1
            }
            let on = c?.tabMarked == true
            item.title = on ? Lang.m("MENU_TABS_UNMARK", "このタブの選択を外す") : Lang.m("MENU_TABS_MARK", "このタブを選ぶ")
            guard let s = c, TabMarks.canMark(s) else { return false }
            return (s.window?.tabGroup?.windows.count ?? 1) > 1 || on
        case #selector(clearTabMarks(_:)): return TabMarks.any || TabSplit.all.contains { $0.sessions.contains { $0.paneMarked } }
        case #selector(mergeAllWindows(_:)): return TabSplit.canMerge(w)
        case #selector(moveTabToNewWindow(_:)): return TabSplit.canMoveToNewWindow(w)
        default: return true
        }
    }

    /// SelectWin → ForegroundWin: 最小化なら戻して前へ。分割中のペインなら、そのペインにフォーカスを移す
    static func bringToFront(_ c: SessionWindowController) {
        guard let w = c.presentingWindow else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        if c.tabSplit != nil { w.makeFirstResponder(c.termView) }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func selectWindow(_ sender: NSMenuItem) {
        let all = SessionWindowController.all
        guard sender.tag < all.count else { return }
        WindowMenuController.bringToFront(all[sender.tag])
    }

    @objc func showWindowList(_ sender: Any?) {
        WindowListDialog.run(current: SessionWindowController.current)
    }

    @objc private func minimizeAll(_ sender: Any?) {
        SessionWindowController.presentedWindows.forEach { $0.miniaturize(nil) }
    }

    @objc private func restoreAll(_ sender: Any?) {
        for w in SessionWindowController.presentedWindows {
            if w.isMiniaturized { w.deminiaturize(nil) }
            if w.isZoomed { w.zoom(nil) }
            w.orderFront(nil)
        }
    }

    /// 並べる窓: 呼んだウインドウを先頭に、ほかは一覧の順
    private func targets() -> [SessionWindowController] {
        var list = SessionWindowController.all.filter { $0.window?.isVisible == true || $0.window?.isMiniaturized == true }
        if let cur = SessionWindowController.current, let i = list.firstIndex(where: { $0 === cur }) {
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

    /// タブでまとまっている窓を、ばらばらの窓にする。上下・左右に並べるときは、タブも 1 枚ずつ窓割りで見せる
    private func untabAll() -> [[SessionWindowController]] {
        var groups: [[SessionWindowController]] = [], done = Set<ObjectIdentifier>()
        for c in SessionWindowController.all {
            guard let w = c.window, !done.contains(ObjectIdentifier(w)), let g = w.tabGroup, g.windows.count > 1 else { continue }
            let wins = g.windows
            wins.forEach { done.insert(ObjectIdentifier($0)) }
            let sel = g.selectedWindow
            let members = (wins.filter { $0 === sel } + wins.filter { $0 !== sel }).compactMap { $0.windowController as? SessionWindowController }
            groups.append(members)
            let frame = (sel ?? w).frame
            for x in wins.dropFirst() {
                g.removeWindow(x)
                x.setFrame(frame, display: false)
                x.orderFront(nil)
            }
        }
        return groups
    }

    private func arrange(_ style: Arrange) {
        // タブの分割表示はやめてから並べる (ペインはタブに戻る)。
        // TTMado を切っているときは、TTMado の前と同じく見えているウインドウだけを並べる (タブはばらさない)
        TabSplit.unsplitAll()
        let tabs = style == .cascade || !TTMado.isEnabled ? [] : untabAll()
        let list = targets()
        guard !list.isEmpty, let screen = (list[0].window?.screen ?? NSScreen.main)?.visibleFrame else { return }
        memorize(style, list)
        if !tabs.isEmpty || !undoFlag { savedTabs = undoFlag ? tabs : [] }
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
        // タブだった窓はタブに戻す (先頭が選ばれていたタブ)
        for g in savedTabs {
            guard let first = g.first?.window else { continue }
            for c in g.dropFirst() { if let w = c.window { first.addTabbedWindow(w, ordered: .above) } }
            first.tabGroup?.selectedWindow = first
            first.makeKeyAndOrderFront(nil)
        }
        saved = []
        savedTabs = []
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
        guard let w = c.presentingWindow else { return "" }
        let state = !w.isVisible && !w.isMiniaturized ? "#" : (w.isMiniaturized ? "-" : (w.isZoomed ? "@" : "+"))
        return "\(state) \(c.displayTitle)"
    }

    private func show() {
        items = SessionWindowController.all
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = Lang.t("Tera Term", "DLG_WINLIST_TITLE", "Tera Term: ウィンドウのリスト")
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
        let openB = NSButton(title: Lang.t("Tera Term", "DLG_WINLIST_OPEN", "開く"), target: self, action: #selector(open(_:)))
        openB.keyEquivalent = "\r"
        let cancelB = NSButton(title: Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"), target: self, action: #selector(cancel(_:)))
        cancelB.keyEquivalent = "\u{1B}"
        let closeB = NSButton(title: Lang.t("Tera Term", "DLG_WINLIST_CLOSEWIN", "閉じる"), target: self, action: #selector(closeWin(_:)))
        let buttons = NSStackView(views: [openB, cancelB, closeB])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        let left = NSStackView(views: [NSTextField(labelWithString: Lang.t("Tera Term", "DLG_WINLIST_LABEL", "ウィンドウ:")), scroll])
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
            DispatchQueue.main.async { c.performCloseSession() }
            return
        }
        items.remove(at: r)
        table.reloadData()
        DispatchQueue.main.async { c.performCloseSession() }
    }
}

// MARK: - 漢字コード メニュー (TTXKanjiMenu)

/// [TTXKanjiMenu] の設定
struct KanjiMenuSettings {
    var charCodeMenu = true
    var useOneSetting = true
    var useOneSettingMenu = true
    var ambiguousMenu = false
    /// Auto / Japanese / Korean (メニュー内容)
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

    /// (表示名, [TTXKanjiMenu] のキーの後ろ, 文字コード)。ttxkanjimenu.c MenuNameRecvJ / MenuNameRecvK。
    /// 本家の KanjiMenu には 1 バイトの文字コード (ISO8859-x / CPxxx) は並ばない (設定画面の「エンコーディング」で選ぶ)
    private static let codesJ: [(String, String, TermEncoding)] = [
        ("Shift_JIS", "SJIS", .sjis), ("EUC-JP", "EUCJP", .eucjp), ("JIS", "JIS", .jis), ("UTF-8", "UTF8", .utf8),
    ]
    private static let codesK: [(String, String, TermEncoding)] = [
        ("KS5601", "KS5601", .ks5601), ("UTF-8", "UTF8", .utf8),
    ]
    /// TTXModifyMenu: Auto は GetACP (932 → 日本語, 949 → 韓国語, ほかは日本語)。Mac は優先する言語で決める
    private var codes: [(String, String, TermEncoding)] {
        switch settings.language {
        case "Japanese": return Self.codesJ
        case "Korean": return Self.codesK
        default: return (Locale.preferredLanguages.first ?? "").hasPrefix("ko") ? Self.codesK : Self.codesJ
        }
    }
    private func k(_ key: String, _ def: String) -> String { Lang.t("TTXKanjiMenu", key, def) }

    private var session: SessionWindowController? { SessionWindowController.current }

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
                for (i, c) in codes.enumerated() { add(k("MENU_" + c.1, "送受信: \(c.0)"), #selector(pickRecv(_:)), tag: i, on: recv == c.2) }
            } else {
                for (i, c) in codes.enumerated() { add(k("MENU_RECV_" + c.1, "受信: \(c.0)"), #selector(pickRecv(_:)), tag: i, on: recv == c.2) }
                menu.addItem(.separator())
                for (i, c) in codes.enumerated() { add(k("MENU_SEND_" + c.1, "送信: \(c.0)"), #selector(pickSend(_:)), tag: i, on: send == c.2) }
            }
            if settings.useOneSettingMenu {
                menu.addItem(.separator())
                add(k("MENU_USE_ONE_SETTING", "送受信両方を変更"), #selector(toggleOne(_:)), tag: 0, on: settings.useOneSetting)
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
        let set = NSMenuItem(title: k("MENU_SETTING", "設定"), action: #selector(showSettings(_:)), keyEquivalent: "")
        set.target = self
        menu.addItem(set)
    }

    /// 選んだ文字コードをすぐ使う (CallResetCharSet: 端末設定ダイアログの後処理 → ResetCharSet)。
    /// 途中まで受けた文字・JIS の状態と G0〜G3 を初めに戻す (TTXKanjiMenu 0.1.7)
    private func apply(_ f: (inout TermSettings) -> Void) {
        guard let c = session else { return }
        var s = c.settings
        f(&s)
        c.applySettings(s)
        c.resetCharSet()
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
        let charCode = NSButton(checkboxWithTitle: k("MENU_CHARCODE", "文字コードメニューを表示"), target: nil, action: nil)
        let contentsLabel = NSTextField(labelWithString: k("MENU_CONTENTS", "メニュー内容") + ":")
        let lang = NSPopUpButton()
        lang.addItems(withTitles: [k("MENU_CONTENTS_AUTO", "自動選択"), k("MENU_CONTENTS_JAPANESE", "日本語"), k("MENU_CONTENTS_KOREAN", "韓国語")])
        lang.selectItem(at: settings.language == "Japanese" ? 1 : settings.language == "Korean" ? 2 : 0)
        let oneMenu = NSButton(checkboxWithTitle: k("MENU_USE_ONE_SETTING_MENU", "送受信両方を変更メニューを表示"), target: nil, action: nil)
        let one = NSButton(checkboxWithTitle: k("MENU_USE_ONE_SETTING", "送受信両方を変更"), target: nil, action: nil)
        let amb = NSButton(checkboxWithTitle: k("MENU_AMB_MENU", "Ambiguous(曖昧)文字幅メニューを表示"), target: nil, action: nil)
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
        a.messageText = k("MENU_SETTING_TITLE", "KanjiMenu設定")
        a.accessoryView = stack
        a.addButton(withTitle: k("BTN_OK", "OK"))
        a.addButton(withTitle: k("BTN_CANCEL", "キャンセル"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        settings.charCodeMenu = charCode.state == .on
        settings.language = lang.indexOfSelectedItem == 1 ? "Japanese" : lang.indexOfSelectedItem == 2 ? "Korean" : "Auto"
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
