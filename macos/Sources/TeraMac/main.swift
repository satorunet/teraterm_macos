import AppKit
import TeraCore
import TeraUninstall

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedByFile = false

    func applicationDidFinishLaunching(_ n: Notification) {
        AppUpdater.shared.start()
        buildMenu()
        // TTMado (タブ・窓割り): 入のときだけ、タブの Shift+クリック・タブやウインドウのドラッグを見張る (TTMado/)
        if TTMado.isEnabled { TTMado.install() }
        // 言語を変えたら メニューを作り直し、ウインドウの題 ([未接続] など) も付け直す
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange(_:)), name: Lang.didChange, object: nil)
        // TERAMAC_INI_DRYRUN=<ini>: 読み込み結果を書き出して終わる (設定は変えない。確認用)
        if TeraTermIniImport.dryRunIfRequested() { exit(0) }
        // TERAMAC_TTMENU_TEST=<ttpmenu.ini>: 読んで書き出し、もう一度読んだ結果を <ini>.out.txt に (確認用・保存はしない)
        if let path = ProcessInfo.processInfo.environment["TERAMAC_TTMENU_TEST"] {
            var out: [String] = []
            if let d = FileManager.default.contents(atPath: path), let ini = IniFile(data: d) {
                let r = TTMenuIni.read(ini)
                for e in r.entries {
                    out.append("\(e.name) | host=\(e.host) mode=\(e.mode.rawValue) ssh=\(e.useSSH) user=\(e.useUser):\(e.user) pw=\(r.passwords[e.id] ?? "-") startup=\(e.startup) opt=\(e.option) macro=\(e.macroFile)")
                }
                out += r.notes
                let written = TTMenuIni.write(r.entries, includePasswords: false)
                try? written.write(to: URL(fileURLWithPath: path + ".written.ini"))
                if let again = IniFile(data: written) {
                    out.append("ROUNDTRIP " + TTMenuIni.read(again).entries.map { $0.name + "=" + $0.host }.joined(separator: ", "))
                }
                out.append("ENC " + TTMenuIni.encodePassword("pass") + "-> " + (TTMenuIni.decodePassword(TTMenuIni.encodePassword("pass")) ?? "nil"))
            }
            try? out.joined(separator: "\n").write(toFile: path + ".out.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        if let dir = ProcessInfo.processInfo.environment["TERAMAC_SNAPSHOT"] {
            SelfTest.run(dir: dir)
            return
        }
        offerMoveToApplications()
        // TeraTerm Menu: メニューバーに常駐
        TeraMenuController.shared.install()
        DispatchQueue.main.async {
            guard !self.openedByFile else { return }
            // コマンドライン: TeraMac host:22 /ssh /user=root など (Tera Term と似た書き方)
            let all = CommandLine.arguments.dropFirst()
            let menuOnly = all.contains("--menu")
            let args = all.filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") && $0 != "--menu" }
            // 「起動時に実行」の項目を開く
            let startedAny = args.isEmpty ? TeraMenuLauncher.runStartupEntries() : false
            // ログイン時の起動 (--menu) ではメニューバーだけ。起動時の項目を開いたら空のウインドウは出さない
            if args.isEmpty && (menuOnly || startedAny) { return }
            // ふつうに起動したときは TeraTerm Menu の接続先一覧を出す (単体の接続ウインドウは出さない)
            if args.isEmpty {
                TeraMenuController.shared.showEditor(nil)
                return
            }
            let c = SessionWindowController()
            c.showWindow(nil)
            // /M=マクロ.ttl でマクロを実行 (Tera Term と同じ)
            if let m = args.first(where: { $0.lowercased().hasPrefix("/m=") }) {
                let path = (String(m.dropFirst(3)) as NSString).expandingTildeInPath
                let rest = args.filter { $0 != m }
                if !rest.isEmpty, let spec = ConnectionSpec.parse(rest.joined(separator: " ")) { c.connect(spec) }
                c.runMacro(url: URL(fileURLWithPath: path))
                return
            }
            if let spec = ConnectionSpec.parse(args.joined(separator: " ")) {
                c.connect(spec)
            } else {
                c.showConnectDialog()
            }
        }
        if !CommandLine.arguments.contains("--menu") { NSApp.activate(ignoringOtherApps: true) }
        if let out = ProcessInfo.processInfo.environment["TERAMAC_DEBUG_WINDOWS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                var t = NSApp.windows.filter { $0.isVisible }.map { "\($0.className) '\($0.title)' \(Int($0.frame.width))x\(Int($0.frame.height))" }
                for i in NSApp.mainMenu?.items.first?.submenu?.items ?? [] where !i.isSeparatorItem {
                    t.append("MENU \(i.title)\(i.isHidden ? " (非表示)" : "")")
                }
                try? t.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // .ttl マクロを開いたら、新しいウインドウで実行する
        // (AppKit は "/ssh" "/M=..." のようなコマンドライン引数もここに渡してくるので、実在するファイルだけ扱う)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDir), !isDir.boolValue else { return false }
        let url = URL(fileURLWithPath: filename)
        openedByFile = true
        let c = SessionWindowController()
        c.showWindow(nil)
        c.runMacro(url: url)
        return true
    }

    /// TeraTerm Menu と同じく、ウインドウを閉じても常駐し続ける
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock のアイコンを押したとき、ウインドウがなければ接続先一覧を出す
        if !flag { TeraMenuController.shared.showEditor(nil) }
        return true
    }

    /// Dock アイコンの右クリックにも登録一覧を出す
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        TeraMenuController.shared.listMenu
    }

    /// アプリケーションフォルダにインストールされて動いているか
    var isInstalled: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// アンインストールのメニューは、インストールされているときだけ出す
    private func uninstallItem(_ i: NSMenuItem) -> NSMenuItem {
        i.isHidden = !isInstalled
        return i
    }

    @objc func uninstall(_ sender: Any?) {
        let before = TeraUninstall.appLocations()
        TeraUninstall.confirmAndRun(inApp: true)
        // 何か消したら終了する (設定を書き戻さないように、終了確認はとばす)
        let removedApp = before.contains { !FileManager.default.fileExists(atPath: $0.path) }
        let removedPrefs = UserDefaults.standard.persistentDomain(forName: TeraUninstall.bundleID)?.isEmpty ?? true
        if removedApp || removedPrefs {
            SessionWindowController.all.forEach { $0.disconnect(silent: true) }
            exit(0)
        }
    }

    /// DMG やダウンロードフォルダから起動されたら、アプリケーションフォルダへの移動をすすめる
    private func offerMoveToApplications() {
        let path = Bundle.main.bundlePath
        let env = ProcessInfo.processInfo.environment
        guard env["TERAMAC_SNAPSHOT"] == nil, env["TERAMAC_DEBUG_WINDOWS"] == nil,
              path.hasSuffix(".app"),
              !path.hasPrefix("/Applications/"), !path.hasPrefix(NSHomeDirectory() + "/Applications/"),
              path.hasPrefix("/Volumes/") || path.contains("/Downloads/") || path.contains("/AppTranslocation/") else { return }
        let a = NSAlert()
        a.messageText = Lang.m("MENU_MOVE_TO_APPS", "アプリケーションフォルダに移動しますか?")
        let from = path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
            ? Lang.m("MENU_MOVE_FROM_DMG", "ディスクイメージ") : Lang.m("MENU_MOVE_FROM_DOWNLOADS", "ダウンロードフォルダ")
        a.informativeText = Lang.m("MENU_MOVE_TO_APPS_INFO", "いまは %s から動いています。アプリケーションフォルダに入れると、次からは Launchpad などから起動できます。", from)
        a.addButton(withTitle: Lang.m("MENU_MOVE_BUTTON", "移動する"))
        a.addButton(withTitle: Lang.m("MENU_MOVE_KEEP", "このまま使う"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications/" + (path as NSString).lastPathComponent)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
        } catch {
            let e = NSAlert()
            e.messageText = Lang.m("MENU_MOVE_FAILED", "移動できませんでした")
            e.informativeText = Lang.m("MENU_MOVE_FAILED_INFO", "%s\n\nFinder で「アプリケーション」フォルダへドラッグしてください。", error.localizedDescription)
            e.runModal()
            return
        }
        // ダウンロードフォルダのものは元を消す (ディスクイメージはそのまま)
        if path.contains("/Downloads/") { try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", dest.path]
        try? p.run()
        exit(0)
    }

    @objc func showMenuEditor(_ sender: Any?) { TeraMenuController.shared.showEditor(sender) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let live = SessionWindowController.all.filter { $0.isConnected }
        guard !live.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = Lang.m("MENU_QUIT_CONFIRM", "%d 個の接続を切断して終了しますか?", live.count)
        a.addButton(withTitle: Lang.m("MENU_QUIT_BUTTON", "終了"))
        a.addButton(withTitle: Lang.m("MENU_QUIT_CANCEL", "やめる"))
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    @objc func newWindow(_ sender: Any?) {
        let c = SessionWindowController()
        c.showWindow(nil)
        c.showConnectDialog()
    }

    @objc func newShellWindow(_ sender: Any?) {
        let c = SessionWindowController()
        c.showWindow(nil)
        c.connect(.shell)
    }

    static let homepage = URL(string: "https://github.com/satorunet/teraterm_macos")!

    @objc func showAbout(_ sender: Any?) { AboutWindowController.shared.show() }

    @objc func showCredits(_ sender: Any?) { CreditsWindowController.shared.show() }

    @objc func openHomepage(_ sender: Any?) { NSWorkspace.shared.open(AppDelegate.homepage) }

    private func buildMenu() {
        NSApp.mainMenu = MenuBar.build(app: self)
    }

    /// 言語の切り替え (Lang.didChange): メニューを作り直す。ウインドウ内のメニューバーは自分で描き直す
    @objc private func languageDidChange(_ n: Notification) {
        buildMenu()
        SessionWindowController.all.forEach { $0.updateTitle() }
    }

    func uninstallMenuItem() -> NSMenuItem {
        uninstallItem(NSMenuItem(title: Lang.m("MENU_APP_UNINSTALL", "Tera Term Mac をアンインストール…"), action: #selector(uninstall(_:)), keyEquivalent: ""))
    }

    /// ヘルプの目次 (Tera Term のヘルプ: マクロのコマンドなどの説明)
    @objc func openHelpIndex(_ sender: Any?) {
        HelpViewer.openIndex()
    }

    @objc func openFeedback(_ sender: Any?) { FeedbackPanel.show() }

    // 端末のウインドウがないときのメニュー
    @objc func newConnectionMenu(_ sender: Any?) { newWindow(sender) }
    @objc func localShellConnection(_ sender: Any?) { newShellWindow(sender) }
    @objc func replayLog(_ sender: Any?) {
        let c = SessionWindowController()
        c.replayLog(sender)
    }
}

/// TERAMAC_SNAPSHOT=<dir> で起動すると、画面を PNG に書き出して終わる (見た目の確認用)
enum SelfTest {
    static func snap(_ v: NSView, _ path: String) {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// ウィンドウ全体 (タイトルバー・タブ・ウィンドウ内メニューバーを含む) を写す。自分のウィンドウなので許可はいらない
    static func snapWindow(_ w: NSWindow, _ path: String) {
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                                [.boundsIgnoreFraming, .bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// TERAMAC_SPLITSNAP: タブの分割表示 (TabSplit) の確認。3 つのタブを左右に分割して写し、
    /// メニューの動作の届き先・タイトル・シートを出すウインドウを split.txt に書いて、上下・取り出し・閉じるを試す
    static func splitTest(_ c: SessionWindowController, dir: String) {
        var log: [String] = []
        func note(_ s: String) { log.append(s) }
        let c2 = SessionWindowController(), c3 = SessionWindowController()
        c.window?.addTabbedWindow(c2.window!, ordered: .above)
        c2.window?.addTabbedWindow(c3.window!, ordered: .above)
        for (i, x) in [c, c2, c3].enumerated() {
            x.macroTitle = "pane\(i + 1)"
            x.term.feed("\u{1B}[1mpane \(i + 1)\u{1B}[0m split test\r\n")
            x.termView.dataArrived()
        }
        c2.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        /// 端末から応答者をたどって、アクションを受けるもの
        func target(_ w: NSWindow, _ sel: Selector) -> String {
            var r: NSResponder? = w.firstResponder
            while let x = r {
                if x.responds(to: sel) { return (x as? SessionWindowController)?.displayTitle ?? String(describing: type(of: x)) }
                r = x.nextResponder
            }
            return "nil"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let host = c2.window else { exit(1) }
            note("tabs=\(host.tabGroup?.windows.count ?? 0) canSplit=\(TabSplit.canSplit(host))")
            TabSplit.splitTabs(of: host, sideBySide: true)
            let sp = TabSplit.split(of: host)
            note("split panes=\(sp?.panes.count ?? 0) visibleWindows=\(NSApp.windows.filter { $0.isVisible && $0.windowController is SessionWindowController }.count) title=\(host.title)")
            host.makeFirstResponder(c3.termView)
            note("focus pane3: title=\(host.title) current=\(SessionWindowController.current?.displayTitle ?? "nil") clearScreen->\(target(host, #selector(SessionWindowController.clearScreen(_:)))) presenting3=\(c3.presentingWindow === host)")
            host.makeFirstResponder(c.termView)
            note("focus pane1: title=\(host.title) exitMenu->\(target(host, #selector(SessionWindowController.exitMenu(_:)))) cols=\(c.term.cols)/\(c2.term.cols)/\(c3.term.cols)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                snapWindow(host, dir + "/split_side.png")
                TabSplit.splitTabs(of: host, sideBySide: false)
                note("stacked: vertical=\(sp?.isSideBySide ?? true) rows=\(c.term.rows)/\(c2.term.rows)/\(c3.term.rows)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    snapWindow(host, dir + "/split_stacked.png")
                    // ホストのセッション (pane2) を閉じる → 分割は残りのウインドウへ移る
                    c2.performCloseSession()
                    let w2 = c.presentingWindow
                    note("closed pane2: panes=\(TabSplit.split(of: w2)?.panes.count ?? 0) all=\(SessionWindowController.all.count) hostIsPane=\(w2 === c.window || w2 === c3.window) title=\(w2?.title ?? "")")
                    // フォーカスのあるペインを新しいウインドウへ → 残り 1 つで分割をやめる
                    w2?.makeFirstResponder(c3.termView)
                    TabSplit.moveCurrentTabToNewWindow()
                    note("moved pane3: splits=\(TabSplit.all.count) c.tabSplit=\(c.tabSplit == nil ? "nil" : "set") c3visible=\(c3.window?.isVisible ?? false) c.content=\(type(of: c.window?.contentView)) c3.content=\(type(of: c3.window?.contentView)) separate=\(c3.window?.tabGroup?.windows.contains(c.window!) == false)")
                    TabSplit.mergeAllWindows()
                    note("merged: tabs=\(c.window?.tabGroup?.windows.count ?? 0)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        if let w = c.window { snapWindow(w, dir + "/split_after.png") }
                        // 選んだタブだけの分割と、入れ子の分割
                        splitTestMarks(dir: dir, note: note) {
                            splitMergeTests(dir: dir, note: note) {
                                splitRemoveTests(dir: dir, note: note) {
                                    try? log.joined(separator: "\n").write(toFile: dir + "/split.txt", atomically: true, encoding: .utf8)
                                    exit(0)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// TERAMAC_SPLITSNAP の続き: タブ A,B,C,D で、B だけ選んで (Shift+クリックと同じ処理) 左右に分割 → C・D はタブのまま (split_marked.png)。
    /// B にフォーカスして C を選び「この画面を上下に分割」→ A | (B / C) (split_nested.png)。B を閉じて木が縮むか、
    /// 選ばずに「この画面を左右に分割」で次のタブ D が入るか、分割をやめてタブに戻るかを見る
    static func splitTestMarks(dir: String, note: @escaping (String) -> Void, done: @escaping () -> Void) {
        guard let first = SessionWindowController.current?.window, let g = first.tabGroup,
              g.windows.count >= 2,
              let a = g.windows[0].windowController as? SessionWindowController,
              let b = g.windows[1].windowController as? SessionWindowController else { done(); return }
        let cc = SessionWindowController(), dd = SessionWindowController()
        g.windows[1].addTabbedWindow(cc.window!, ordered: .above)
        cc.window!.addTabbedWindow(dd.window!, ordered: .above)
        for (x, n) in [(a, "A"), (b, "B"), (cc, "C"), (dd, "D")] {
            x.macroTitle = n
            x.term.feed("\u{1B}[2J\u{1B}[H\u{1B}[1mtab \(n)\u{1B}[0m nested split test\r\n")
            x.termView.dataArrived()
        }
        func name(_ x: SessionWindowController) -> String { x.macroTitle ?? "?" }
        func tabs(_ w: NSWindow?) -> String { (w?.tabGroup?.windows ?? []).map { $0.tab.title }.joined(separator: "|") }
        a.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let aw = a.window, let bw = b.window, let cw = cc.window else { done(); return }
            // タブ B の Shift+クリック: B のタブが選ばれ、印を付けて A に戻る
            bw.makeKeyAndOrderFront(nil)
            let ok = TabMarks.tabClicked(bw, previous: aw)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                note("shift-click B: handled=\(ok) marked=\(TabMarks.marked(in: aw).map(name)) selected=\(aw.tabGroup?.selectedWindow === aw) key=\(NSApp.keyWindow === aw) tabs=\(tabs(aw))")
                // メニューの「このタブを選ぶ」と同じ: D を付けて外す
                TabMarks.toggle(dd); let on = dd.tabMarked; TabMarks.toggle(dd)
                note("toggle D: on=\(on) off=\(!dd.tabMarked) canSplitFocused=\(TabSplit.canSplitFocused(aw)) partners=\(TabSplit.partners(for: aw).map(name))")
                snapWindow(aw, dir + "/split_marks.png")
                // (a) 選んだタブ (B) だけを左右に分割。C・D はタブのまま
                TabSplit.splitTabs(of: aw, sideBySide: true)
                let sp = TabSplit.split(of: aw)
                note("split marked: layout=\(sp?.layoutDescription(name) ?? "nil") tabs=\(tabs(aw)) bHidden=\(!bw.isVisible) bInGroup=\(aw.tabGroup?.windows.contains(bw) == true) marks=\(TabMarks.any) cols=\(a.term.cols)/\(b.term.cols)/\(cc.term.cols)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    snapWindow(aw, dir + "/split_marked.png")
                    // ほかのタブ (C) に切り替えて、分割のタブに戻る
                    cw.makeKeyAndOrderFront(nil)
                    note("switch to C: current=\(SessionWindowController.current.map(name) ?? "nil") selected=\(cw.tabGroup?.selectedWindow === cw) cContent=\(cw.contentView.map { "\(type(of: $0))" } ?? "nil")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        aw.makeKeyAndOrderFront(nil)
                        aw.makeFirstResponder(b.termView)
                        note("back to split, focus B: current=\(SessionWindowController.current.map(name) ?? "nil") title=\(aw.title)")
                        // タブ C の Shift+クリック (分割のタブにいるとき) → 「この画面を上下に分割」
                        cw.makeKeyAndOrderFront(nil)
                        let ok2 = TabMarks.tabClicked(cw, previous: aw)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            note("shift-click C: handled=\(ok2) marked=\(TabMarks.marked(in: aw).map(name)) back=\(NSApp.keyWindow === aw) current=\(SessionWindowController.current.map(name) ?? "nil")")
                            TabSplit.splitFocused(of: aw, sideBySide: false)
                            note("nested: layout=\(sp?.layoutDescription(name) ?? "nil") tabs=\(tabs(aw)) focused=\(SessionWindowController.current.map(name) ?? "nil") size A=\(a.term.cols)x\(a.term.rows) B=\(b.term.cols)x\(b.term.rows) C=\(cc.term.cols)x\(cc.term.rows)")
                            let clear = target(aw, #selector(SessionWindowController.clearScreen(_:)))
                            aw.makeFirstResponder(cc.termView)
                            note("focus C: current=\(SessionWindowController.current.map(name) ?? "nil") clearScreen(B)->\(clear) clearScreen->\(target(aw, #selector(SessionWindowController.clearScreen(_:)))) presentingC=\(cc.presentingWindow === aw)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                snapWindow(aw, dir + "/split_nested.png")
                                // B を閉じる → 節 (B / C) は C だけになって消え、A | C
                                b.performCloseSession()
                                note("closed B: layout=\(sp?.layoutDescription(name) ?? "nil") current=\(SessionWindowController.current.map(name) ?? "nil") C=\(cc.term.cols)x\(cc.term.rows)")
                                // 選ばずに「この画面を左右に分割」→ 次のタブ D
                                aw.makeFirstResponder(cc.termView)
                                TabSplit.splitFocused(of: aw, sideBySide: true)
                                note("split C with next tab: layout=\(sp?.layoutDescription(name) ?? "nil") tabs=\(tabs(aw)) canSplitFocused=\(TabSplit.canSplitFocused(aw))")
                                // 外側の向きだけ変える
                                TabSplit.splitTabs(of: aw, sideBySide: false)
                                note("root stacked: layout=\(sp?.layoutDescription(name) ?? "nil")")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    snapWindow(aw, dir + "/split_nested2.png")
                                    sp?.unsplit()
                                    let w = a.window
                                    note("unsplit: splits=\(TabSplit.all.count) tabs=\(tabs(w)) contents=\((w?.tabGroup?.windows ?? []).map { "\(type(of: $0.contentView!))" }.joined(separator: ","))")
                                    done()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// TERAMAC_SPLITSNAP の続き: 分割しているウインドウ W (A | B) に、ほかのセッション C を入れる (タブのドラッグ・ウインドウのドラッグ)。
    /// C は W のタブ (選んでいる / いない) か、別のウインドウ。入れたあとの各ウインドウの状態を書き、見えなくなったものを探す
    /// TERAMAC_SPLITSNAP の続き: TB(LR(P1..P5), Q) から、下の Q を新しいウインドウに分ける (Q がホスト / ホストでない / タブのドラッグの経路で入れた)。
    /// 残ったウインドウの根・節・ペイン・端末の大きさと、ウインドウの見え方を書いて写す
    static func splitRemoveTests(dir: String, note: @escaping (String) -> Void, done: @escaping () -> Void) {
        // (名前, Q をホストにするか, Q をタブのドラッグの経路 (HiddenHandoff) で入れるか)
        let cases: [(String, Bool, Bool)] = [("q-not-host", false, false), ("q-host", true, false), ("q-handoff", false, true)]
        func showAlone(_ x: SessionWindowController) {
            guard let xw = x.window else { return }
            let mode = xw.tabbingMode
            xw.tabbingMode = .disallowed
            x.showWindow(nil)
            xw.tabbingMode = mode
        }
        func frames(_ v: NSView, _ depth: Int = 0) -> String {
            let f = v.frame
            let fs = "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
            if let p = v as? TabPaneView {
                let tv = p.container.termView
                return "\(p.session?.macroTitle ?? "?")[\(fs) hidden=\(p.isHidden ? 1 : 0) term=\(Int(tv.frame.width))x\(Int(tv.frame.height)) cont=\(Int(p.container.frame.width))x\(Int(p.container.frame.height))]"
            }
            if let n = v as? TabSplitNodeView {
                return (n.isVertical ? "LR" : "TB") + "[\(fs)](" + n.arrangedSubviews.map { frames($0, depth + 1) }.joined(separator: ", ") + ")"
            }
            return "?"
        }
        func run(_ i: Int) {
            guard i < cases.count else { done(); return }
            let (label, qHost, handoff) = cases[i]
            let ps = (1...5).map { _ in SessionWindowController() }
            let q = SessionWindowController()
            for (k, x) in ps.enumerated() { x.macroTitle = "P\(k + 1)" }
            q.macroTitle = "Q"
            for x in ps + [q] {
                x.term.feed("\u{1B}[1m\(x.macroTitle ?? "")\u{1B}[0m remove test\r\n")
                x.termView.dataArrived()
            }
            showAlone(ps[0])
            guard let w1 = ps[0].window else { done(); return }
            for x in ps.dropFirst() + [q] { (w1.tabGroup?.windows.last ?? w1).addTabbedWindow(x.window!, ordered: .above) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if handoff {
                    // P1 だけのウインドウに、Q をタブのドラッグと同じ経路で下に入れる
                    w1.makeKeyAndOrderFront(nil)
                    TabBarDrag.dropForTest(q, into: w1, pane: nil, side: .below, partner: nil, tearOff: false)
                } else {
                    TabMarks.set(qHost ? ps[0] : q, true)
                    let hw = qHost ? q.window! : w1
                    hw.makeKeyAndOrderFront(nil)
                    TabSplit.splitTabs(of: hw, sideBySide: false)   // TB(P1, Q)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    guard let sp = q.tabSplit else { note("remove \(label): no split"); run(i + 1); return }
                    var prev = sp.panes.first { $0.session === ps[0] }
                    for x in ps.dropFirst() {
                        if let t = prev { sp.insert(x, at: t, side: .right) }
                        prev = sp.panes.first { $0.session === x }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let hw0 = sp.hostWindow
                        note("remove \(label): before layout=\(sp.layoutDescription { $0.macroTitle ?? "?" }) host=\(sp.host.macroTitle ?? "?") \(frames(sp.root))")
                        TabSplit.moveToNewWindow(q)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            let sp2 = ps[0].tabSplit
                            let hw = sp2?.hostWindow
                            note("remove \(label): after layout=\(sp2?.layoutDescription { $0.macroTitle ?? "?" } ?? "nil") host=\(sp2?.host.macroTitle ?? "nil") hostChanged=\(hw !== hw0) win vis=\(hw?.isVisible == true ? 1 : 0) a=\(hw?.alphaValue ?? -1) key=\(hw?.isKeyWindow == true ? 1 : 0) content=\(hw?.contentView.map { "\(type(of: $0))" } ?? "nil") frame=\(hw.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "") \(sp2.map { frames($0.root) } ?? "") qWin vis=\(q.window?.isVisible == true ? 1 : 0) a=\(q.window?.alphaValue ?? -1) rootWin=\(sp2?.root.window === hw ? 1 : 0) hiddenAnc=\(sp2?.root.isHiddenOrHasHiddenAncestor == true ? 1 : 0) rootAlpha=\(sp2?.root.alphaValue ?? -1) layer=\(sp2?.root.layer != nil ? 1 : 0) wantsLayer=\(sp2?.root.wantsLayer == true ? 1 : 0) superview=\(sp2?.root.superview.map { "\(type(of: $0))" } ?? "nil") paneAlpha=\(sp2?.panes.map { "\($0.alphaValue)/\($0.container.alphaValue)/\($0.container.isHidden ? 1 : 0)" }.joined(separator: ",") ?? "") winOcc=\(hw?.occlusionState.contains(.visible) == true ? 1 : 0) winNum=\(hw?.windowNumber ?? 0) onScreen=\(hw?.isOnActiveSpace == true ? 1 : 0)")
                            if let h = hw { snapWindow(h, dir + "/remove_\(label).png") }
                            for x in [q] + ps { x.closeWithoutConfirm() }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { run(i + 1) }
                        }
                    }
                }
            }
        }
        run(0)
    }

    static func splitMergeTests(dir: String, note: @escaping (String) -> Void, done: @escaping () -> Void) {
        // (名前, タブのドラッグか, C は W のタブか, C を選ぶか, AppKit の引き出しをまねるか, AppKit がタブを組に戻すのをまねるか)
        // snapBack: タブを中身の上に落としても AppKit が受け付けないと、タブは元の組に戻って選ばれる (分割に入れたあとに起きることがある)
        let cases: [(String, Bool, Bool, Bool, Bool, Bool)] = [
            ("tabbar-tab", true, true, false, false, false),
            ("tabbar-tab-selected", true, true, true, false, false),
            ("tabbar-tab-selected-tearoff", true, true, true, true, false),
            ("tabbar-tab-tearoff", true, true, false, true, false),
            ("tabbar-tab-selected-snapback", true, true, true, false, true),
            ("window-own", false, false, false, false, false),
            ("window-tab", false, true, false, false, false),
            ("window-tab-selected", false, true, true, false, false),
        ]
        /// ほかのウインドウのタブに自動で入らないように出す
        func showAlone(_ x: SessionWindowController) {
            guard let xw = x.window else { return }
            let mode = xw.tabbingMode
            xw.tabbingMode = .disallowed
            x.showWindow(nil)
            xw.tabbingMode = mode
        }
        func run(_ i: Int) {
            guard i < cases.count else { done(); return }
            let (label, tabBar, cAsTab, cSel, tear, snapBack) = cases[i]
            let a = SessionWindowController(), b = SessionWindowController()
            a.macroTitle = "A"; b.macroTitle = "B"
            showAlone(a)
            a.window?.addTabbedWindow(b.window!, ordered: .above)
            a.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let w = a.window else { done(); return }
                TabSplit.splitTabs(of: w, sideBySide: true)
                let c = SessionWindowController()
                c.macroTitle = "C"
                if cAsTab { w.addTabbedWindow(c.window!, ordered: .above) } else { showAlone(c) }
                if cSel { c.window?.makeKeyAndOrderFront(nil) } else { w.makeKeyAndOrderFront(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let sp = TabSplit.split(of: w)
                    let before = state([a, b, c], w)
                    guard let pane = sp?.panes.last, let cw = c.window else { note("merge \(label): no split"); run(i + 1); return }
                    if tabBar {
                        TabBarDrag.dropForTest(c, into: w, pane: pane, side: .right, partner: nil, tearOff: tear)
                        if snapBack {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                w.addTabbedWindow(cw, ordered: .above)
                                cw.makeKeyAndOrderFront(nil)
                            }
                        }
                    } else {
                        TabTearOff.finishRelease(c, cw, near: nil, zoneWindow: w, pane: pane, side: .right)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        let host = a.presentingWindow
                        note("merge \(label): before[\(before)] after[\(state([a, b, c], host))] layout=\(TabSplit.split(of: host)?.layoutDescription { $0.macroTitle ?? "?" } ?? "nil")")
                        if let h = host { snapWindow(h, dir + "/merge_\(label).png") }
                        for x in [c, b, a] { x.closeWithoutConfirm() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { run(i + 1) }
                    }
                }
            }
        }
        /// 各セッションのウインドウの状態
        func state(_ list: [SessionWindowController], _ host: NSWindow?) -> String {
            let ws = list.map { x -> String in
                guard let xw = x.window else { return "\(x.macroTitle ?? "?"):nowin" }
                let g = xw.tabGroup?.windows ?? [xw]
                return "\(x.macroTitle ?? "?"):vis=\(xw.isVisible ? 1 : 0) a=\(xw.alphaValue) cv=\(xw.contentView.map { "\(type(of: $0))" } ?? "nil") grp=\(g.count) sel=\(xw.tabGroup?.selectedWindow === xw ? 1 : 0) split=\(x.tabSplit == nil ? "-" : (x.tabSplit?.hostWindow === host ? "W" : "other"))"
            }
            return ws.joined(separator: " ") + " hostVis=\(host?.isVisible == true ? 1 : 0) hostA=\(host?.alphaValue ?? -1) key=\(NSApp.keyWindow.flatMap { ($0.windowController as? SessionWindowController)?.macroTitle } ?? "nil")"
        }
        run(0)
    }

    /// 端末から応答者をたどって、アクションを受けるもの
    static func target(_ w: NSWindow, _ sel: Selector) -> String {
        var r: NSResponder? = w.firstResponder
        while let x = r {
            if x.responds(to: sel) { return (x as? SessionWindowController)?.macroTitle ?? String(describing: type(of: x)) }
            r = x.nextResponder
        }
        return "nil"
    }

    static func run(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // TERAMAC_GUIDESNAP: かんたんマニュアルの画面写真 (SelfTestGuide.swift)
        if ProcessInfo.processInfo.environment["TERAMAC_GUIDESNAP"] != nil { guide(dir: dir); return }
        // TERAMAC_MADOSNAP: かんたんマニュアルの窓割り (TTMado) の写真 (SelfTestMado.swift)
        if ProcessInfo.processInfo.environment["TERAMAC_MADOSNAP"] != nil { madoGuide(dir: dir); return }
        let c = SessionWindowController()
        c.showWindow(nil)
        if ProcessInfo.processInfo.environment["TERAMAC_SPLITSNAP"] == "remove" {
            // 分けるところだけ (時間を短くする)
            var log: [String] = []
            c.window?.orderOut(nil)
            splitRemoveTests(dir: dir, note: { log.append($0) }) {
                try? log.joined(separator: "\n").write(toFile: dir + "/split.txt", atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["TERAMAC_SPLITSNAP"] != nil { splitTest(c, dir: dir); return }
        if ProcessInfo.processInfo.environment["TERAMAC_TABSNAP"] != nil {
            // タブを 2 つにして、ウィンドウ全体を写す (メニューバーとタブの並びの確認用)
            let c2 = SessionWindowController()
            c.window?.addTabbedWindow(c2.window!, ordered: .above)
            c2.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                snapWindow(c2.window!, dir + "/tabs.png")
                // 設定 > ウィンドウ のシート (メニューバーの出し入れは保存した設定を書き換えるので、ここではしない)
                c2.openSetupSheet(.window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let sh = SetupSheet.current?.panel { snapWindow(sh, dir + "/setup_window.png") }
                    // その場の反映: フォントを大きくして端末を写し、キャンセルで戻るか写す
                    c2.term.feed("preview test ABC 日本語\r\n")
                    SetupSheet.current?.debugPreviewBiggerFont()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        snapWindow(c2.window!, dir + "/preview_font.png")
                        SetupSheet.current?.bringToFront(page: .font)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if let sh = SetupSheet.current?.panel { snapWindow(sh, dir + "/setup_font.png") }
                            SetupSheet.current?.cancel()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                snapWindow(c2.window!, dir + "/preview_cancel.png")
                                exit(0)
                            }
                        }
                    }
                }
            }
            return
        }
        let demo = """
        \u{1B}[1mTeraMac\u{1B}[0m 表示テスト  \u{1B}[31m赤\u{1B}[32m緑\u{1B}[33m黄\u{1B}[34m青\u{1B}[35m紫\u{1B}[36m水\u{1B}[0m\r
        \u{1B}[7m反転\u{1B}[0m \u{1B}[4m下線\u{1B}[0m \u{1B}[38;5;208m256色\u{1B}[0m \u{1B}[38;2;255;105;180mTrueColor\u{1B}[0m \u{1B}[44;97m 背景 \u{1B}[0m\r
        ┌────────┬────────┐\r
        │ 日本語 │ ｶﾅ ABC │\r
        └────────┴────────┘\r
        \u{1B}(0lqqqqwqqqqk\u{1B}(B DEC 罫線\r
        $ ls -la\r

        """
        c.term.feed(demo)
        c.termView.dataArrived()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            snap(c.window?.contentView ?? c.termView, dir + "/term.png")  // ウィンドウ内のメニューバーも写す
            if let v = CreditsWindowController.shared.window?.contentView { snap(v, dir + "/credits.png") }
            if let about = AboutWindowController.shared.window, let v = about.contentView { snap(v, dir + "/about.png") }
            // マクロでローカルシェルと TCP 接続を実際に動かす
            c.term.feed("\u{1B}[2J\u{1B}[H")
            let ttl = """
            timeout = 10
            connect '/shell'
            wait '$' '%'
            sendln 'echo "cols=$(tput cols) lines=$(tput lines) term=$TERM"; printf "\\033[42m OK \\033[0m\\n"'
            wait ' OK '
            port = '47123'
            getenv 'TERAMAC_TCPPORT' port
            strlen port
            if result > 0 then
              s = '127.0.0.1:'
              strconcat s port
              strconcat s ' /t=0'
              disconnect 0
              connect s
              sendln 'hello-from-macro'
              wait 'hello-from-macro'
              if result = 1 sendln 'tcp-ok'
              mpause 500
            endif
            dev = ''
            getenv 'TERAMAC_SERIAL' dev
            strlen dev
            if result > 0 then
              s = '/C='
              strconcat s dev
              strconcat s ' /BAUD=115200'
              disconnect 0
              connect s
              send 'serial-ping'#13
              wait 'serial-pong'
              if result = 1 sendln 'serial-ok'
              mpause 500
            endif
            """
            let ttlPath = dir + "/test.ttl"
            try? ttl.write(toFile: ttlPath, atomically: true, encoding: .utf8)
            c.runMacro(url: URL(fileURLWithPath: ttlPath))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    snap(c.termView, dir + "/shell.png")
                    try? c.term.screenText.write(toFile: dir + "/shell.txt", atomically: true, encoding: .utf8)
                    c.disconnect(silent: true)
                    let dlg = ConnectDialog()
                    dlg.begin(on: c.window!) { _, _ in }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        snap(dlg.panel.contentView!, dir + "/connect.png")
                        dlg.cancel()
                        let sd = SetupDialog(settings: c.settings)
                        sd.begin(on: c.window!) { _ in }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            snap(sd.panel.contentView!, dir + "/setup.png")
                            schemeSheet(dir + "/schemes.png")
                            sd.cancel()
                            menuTest(dir: dir)
                        }
                    }
                }
        }
    }
}

extension SelfTest {
    /// 配色の候補を一覧の絵にする (見本 + プレビュー)
    static func schemeSheet(_ path: String) {
        let list = ColorScheme.presets + ColorScheme.terminalProfiles()
        let cols = 3, cellW: CGFloat = 330, cellH: CGFloat = 150
        let rows = (list.count + cols - 1) / cols
        let host = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH))
        for (i, s) in list.enumerated() {
            let x = CGFloat(i % cols) * cellW, y = CGFloat(rows - 1 - i / cols) * cellH
            let label = NSTextField(labelWithString: s.name)
            label.frame = NSRect(x: x + 110, y: y + cellH - 22, width: 220, height: 18)
            let sw = NSImageView(image: s.swatch())
            sw.frame = NSRect(x: x + 6, y: y + cellH - 24, width: 96, height: 20)
            let pv = SchemePreview(frame: NSRect(x: x + 6, y: y + 4, width: cellW - 12, height: cellH - 32))
            pv.fg = s.fg; pv.bg = s.bg; pv.cursor = s.cursor
            pv.ansi = s.ansi16 ?? Array(Palette.colors.prefix(16))
            pv.font = NSFont(name: "Menlo-Regular", size: 10)!
            [label, sw, pv].forEach { host.addSubview($0) }
        }
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        snap(host, path)
    }

    /// TeraTerm Menu の画面と自動ログインを確かめる (利用者の登録内容は最後に元に戻す)
    static func menuTest(dir: String) {
        let d = UserDefaults.standard
        let saved = d.data(forKey: "menuEntries")
        let savedTree = d.data(forKey: "menuTree")
        var e1 = MenuEntry(); e1.name = "本番サーバ (SSH)"; e1.host = "prod.example.com"; e1.user = "admin"; e1.useSSH = true; e1.startup = true
        var e2 = MenuEntry(); e2.name = "ルータ (Telnet)"; e2.host = "192.168.1.1"; e2.useSSH = false; e2.user = "cisco"
        var e3 = MenuEntry(); e3.name = "定期バックアップ"; e3.mode = .macro; e3.macroFile = "~/backup.ttl"
        var e4 = MenuEntry(); e4.name = "検証用 自動ログイン"; e4.useSSH = false; e4.user = "tester"
        e4.host = "127.0.0.1:" + (ProcessInfo.processInfo.environment["TERAMAC_LOGINPORT"] ?? "47124")
        e4.option = "/T=0 /passwd=s3cret"
        MenuStore.shared.entries = [e1, e2, e3, e4]
        // フォルダ分けも見る: 「ネットワーク機器」に e2、その下の「夜間」に e3
        let net = MenuNode(folder: "ネットワーク機器")
        let night = MenuNode(folder: "夜間")
        night.children = [MenuNode(entryID: e3.id)]
        net.children = [MenuNode(entryID: e2.id), night]
        MenuStore.shared.tree = [MenuNode(entryID: e1.id), net, MenuNode(entryID: e4.id)]
        let ed = MenuEditorWindowController()
        ed.showWindow(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            snap(ed.window!.contentView!, dir + "/menu_editor.png")
            let dd = MenuDetailsDialog(entry: e4)
            dd.begin(on: ed.window!) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                snap(dd.panel.contentView!, dir + "/menu_details.png")
                dd.cancel()
                let m = TeraMenuController.shared.listMenu
                func titles(_ menu: NSMenu, _ depth: Int) -> [String] {
                    menu.items.flatMap { [String(repeating: "  ", count: depth) + $0.title] + ($0.submenu.map { titles($0, depth + 1) } ?? []) }
                }
                try? titles(m, 0).joined(separator: "\n").write(toFile: dir + "/menu_list.txt", atomically: true, encoding: .utf8)
                if ProcessInfo.processInfo.environment["TERAMAC_LOGINPORT"] != nil {
                    TeraMenuLauncher.launch(e4)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if let c = SessionWindowController.all.last {
                        try? c.term.screenText.write(toFile: dir + "/menu_login.txt", atomically: true, encoding: .utf8)
                    }
                    if let s = saved { d.set(s, forKey: "menuEntries") } else { d.removeObject(forKey: "menuEntries") }
                    if let s = savedTree { d.set(s, forKey: "menuTree") } else { d.removeObject(forKey: "menuTree") }
                    exit(0)
                }
            }
        }
    }
}

// アンインストーラーから呼ばれる: 保存したパスワードを消して終わる (画面は出さない)
if CommandLine.arguments.contains("--purge-keychain") {
    exit(TeraUninstall.deleteKeychain() ? 0 : 1)
}

// ssh の ProxyCommand として動くとき (ProxyRelay.swift)。ここで終わる
ProxyRelay.runIfRequested()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
