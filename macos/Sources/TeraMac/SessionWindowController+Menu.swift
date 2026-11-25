import AppKit
import TeraCore

/// メニューの「ファイル」(接続まわり)・「編集」・「コントロール」の動作 (vtwin.cpp の On* ハンドラ)
extension SessionWindowController {

    // MARK: - 状態

    /// ファイル送信・貼り付けの送信・プロトコル転送のどれかが動いている (!IsSendVarNULL() || !IsFileVarNULL())
    var isBusy: Bool { transfer != nil || sendFileJob != nil || pasteJob != nil }

    /// 貼り付け・送信系が使えるか (cv.Ready、転送中でない、ログの再生でない)
    var canPaste: Bool { connected && !isBusy && !isReplay }

    var isTCPIP: Bool {
        switch spec {
        case .ssh?, .telnet?, .rawTCP?, .shell?: return true
        default: return false
        }
    }

    // MARK: - 貼り付け (clipboar.c CBSendStart → SendMem)

    /// 1 行ごとに PasteDelayPerLine ミリ秒待って送る。送っている間はキーボードを止める (TalkStatus = IdTalkSendMem)
    func sendPasteText(_ s: String, echo: Bool) {
        guard connected, pasteJob == nil else { return }
        let plan = SendFilePlan.paste(s, delayPerLine: settings.pasteDelayPerLine)
        let job = SendFileJob(plan: plan) { [weak self] chunk in
            guard let self = self, self.conn != nil, case .text(let t) = chunk else { return }
            self.macroSend(Array(t.utf8), mode: .text, echo: echo)
        }
        pasteJob = job
        setTalkQuiet(true)
        job.onFinish = { [weak self, weak job] in
            guard let self = self, self.pasteJob === job else { return }
            self.pasteJob = nil
            self.setTalkQuiet(false)
        }
        job.start()
    }

    // MARK: - ファイル: 接続

    /// 新しい接続 (OnFileNewConnection): つながっていなければこのウインドウで、つながっていれば新しいウインドウで
    @objc func newConnectionMenu(_ sender: Any?) {
        if isConnecting { return }
        if connected || isReplay {
            let c = SessionWindowController(settings: settings)
            c.showWindow(nil)
            c.showConnectDialog()
        } else {
            showConnectDialog()
        }
    }

    /// セッションの複製 (OnDuplicateSession): Telnet / SSH だけ。生の TCP は何もしない。ローカルシェルは「ローカルシェル接続」
    @objc func duplicateSessionMenu(_ sender: Any?) {
        guard let s = spec else { return }
        switch s {
        case .ssh, .telnet:
            let c = SessionWindowController(settings: settings)
            c.transferOptions = transferOptions
            c.showWindow(nil)
            c.connect(s)
        case .shell:
            localShellConnection(nil)
        case .rawTCP, .serial:
            break
        }
    }

    /// Cygwin 接続 (OnCygwinConnection) の Mac 版: 新しいウインドウでこの Mac のシェル
    @objc func localShellConnection(_ sender: Any?) {
        SessionWindowController.openLocalShell(settings: settings)
    }

    /// 接続断 (Disconnect(TRUE)): TCP/IP は「切断しますか？」(ConfirmDisconnect)。シリアルは聞かない
    @objc func disconnectMenu(_ sender: Any?) {
        guard connected || isConnecting else { return }
        if isTCPIP && connected && confirmDisconnectSetting {
            guard SessionWindowController.confirmDisconnect(window) else { return }
        }
        closedByMenu = true
        disconnect()
        afterConnectionClosed()
    }

    static func confirmDisconnect(_ w: NSWindow?) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = Lang.t("Tera Term", "MSG_DISCONNECT_CONF", "切断しますか？")
        a.addButton(withTitle: Lang.t("Tera Term", "BTN_OK", "OK"))
        a.addButton(withTitle: Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"))
        // キャンセルが既定のボタン
        a.buttons[0].keyEquivalent = ""
        a.buttons[1].keyEquivalent = "\r"
        return a.runModal() == .alertFirstButtonReturn
    }

    /// 接続が閉じたあと (CommClose 後): TCP/IP で AutoWinClose ならウインドウを閉じる
    func afterConnectionClosed() {
        if isTCPIP && autoWinCloseSetting && !isReplay {
            closeWithoutConfirm()
        }
    }

    /// 終了 (OnFileExit → OnClose): 接続中の TCP/IP は「切断しますか？」
    @objc func exitMenu(_ sender: Any?) { window?.performClose(sender) }

    /// 確認なしで閉じる (全終了・自動で閉じる)
    func closeWithoutConfirm() {
        skipCloseConfirm = true
        window?.performClose(nil)
        if window?.isVisible == true { window?.close() }
    }

    /// Tera Term の全終了 (OnAllClose): 確かめてから、すべてのウインドウを確認なしで閉じる
    @objc func exitAllMenu(_ sender: Any?) {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = Lang.t("Tera Term", "MSG_ALL_TERMINATE_CONF", "全Tera Termを強制終了しますか？")
        a.addButton(withTitle: Lang.t("Tera Term", "BTN_OK", "OK"))
        a.addButton(withTitle: Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"))
        a.buttons[0].keyEquivalent = ""
        a.buttons[1].keyEquivalent = "\r"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let all = SessionWindowController.all
        for c in all where c !== self { c.closeWithoutConfirm() }
        closeWithoutConfirm()
    }

    // MARK: - ファイル: ログを再生

    /// ログを再生 (OnReplayLog): 新しいウインドウでファイルを受信したデータとして端末に流す。送信は捨てる
    @objc func replayLog(_ sender: Any?) {
        let p = NSOpenPanel()
        p.message = Lang.t("Tera Term", "FILEDLG_OPEN_LOGFILE_TITLE", "バイナリモードで記録された再生するログファイルを選択してください")
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            let a = NSAlert(); a.messageText = Lang.t("Tera Term", "MSG_TT_ERROR", "Tera Term: エラー")
            a.informativeText = Lang.t("Tera Term", "MSG_CANTOPEN_FILE_ERROR", "ファイルが開けません"); a.runModal()
            return
        }
        let c = SessionWindowController(settings: settings)
        c.showWindow(nil)
        c.startReplay(data: [UInt8](data), name: url.lastPathComponent)
    }

    func startReplay(data: [UInt8], name: String) {
        isReplay = true
        replayTitle = name
        updateTitle()
        var pos = 0
        replayTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let end = min(data.count, pos + 4096)
            if pos < end { self.feedReplay(Array(data[pos..<end])) }
            pos = end
            if pos >= data.count {
                t.invalidate()
                self.replayTimer = nil
                self.replayFinished = true
                self.updateTitle()
            }
        }
    }

    // MARK: - ファイル: 印刷

    /// 印刷 (OnFilePrint): 選択があれば「選択した部分」を選べる。選択がなければ見えている画面。白黒で端末のフォント
    @objc func printMenu(_ sender: Any?) {
        let screen = termView.visibleText
        let selection = termView.hasSelection ? termView.selectedText : nil
        printText(selection ?? screen, selectionOnly: selection != nil)
    }

    /// 文字を印刷する (メニューの印刷・端末の印刷の制御シーケンス)
    func printText(_ text: String, selectionOnly: Bool) {
        let selection: String? = selectionOnly ? text : nil
        let screen = text
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        let margin: CGFloat = 36   // PrnMargin 50 (1/100 インチ) = 0.5 インチ
        info.leftMargin = margin; info.rightMargin = margin; info.topMargin = margin; info.bottomMargin = margin
        info.isVerticallyCentered = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: info.paperSize.width - margin * 2, height: 100))
        view.font = settings.font
        view.textColor = .black
        view.backgroundColor = .white
        view.string = selection ?? screen
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = window?.title ?? "Tera Term"
        op.printPanel.options.insert(.showsPrintSelection)
        if selection != nil { info.isSelectionOnly = true }
        op.run()
    }

    // MARK: - コントロール

    /// 端末リセット (OnControlResetTerminal): 画面の文字は残してモードなどを戻し、止めていた相手に送信を再開させる
    @objc func resetTerminalMenu(_ sender: Any?) {
        term.menuReset(lfMode: settings.sendNewline == "CRLF")
        termView.scrollToBottom()
        termView.clearSelection()
        termView.needsDisplay = true
        conn?.unlock()
        termView.keyboardEnabled = true
    }

    /// リモートタイトルリセット: OSC で付けられたタイトルを捨てる
    @objc func resetRemoteTitle(_ sender: Any?) {
        remoteTitle = nil
        updateTitle()
    }

    /// AYT 送信: Telnet で接続しているときだけ IAC AYT
    @objc func areYouThere(_ sender: Any?) {
        guard connected, let t = conn as? TCPConnection, t.isTelnet else { return }
        t.sendAreYouThere()
    }

    /// ブレーク送信: TCP は IAC BREAK、シリアルは SendBreakTime ミリ秒。SSH (OpenSSH) には送る手段がない
    @objc func sendBreakMenu(_ sender: Any?) {
        guard connected, let c = conn else { return }
        if case .ssh? = spec {
            notice(Lang.m("MENU_SSH_NO_BREAK", "SSH 接続ではブレーク信号を送れません (OpenSSH の ssh コマンドに送る方法がないため)"))
            return
        }
        if let sc = c as? SerialConnection { sc.breakMs = sendBreakTimeSetting }
        c.sendBreak()
    }

    /// ポートのリセット: シリアルのバッファを捨てて設定をかけ直す
    @objc func resetPort(_ sender: Any?) {
        (conn as? SerialConnection)?.resetPort()
    }

    /// TEK ウインドウ (Tektronix 4010/4014。SessionWindowController+TEK.swift): OnControlOpenTEK / OnControlCloseTEK
    @objc func openTEK(_ sender: Any?) { openTEKWindow() }
    @objc func closeTEK(_ sender: Any?) { closeTEKWindow() }

    /// マクロ (RunMacroW): マクロが動いていればマクロウインドウを出す。なければファイルを選んで実行
    @objc func macroMenu(_ sender: Any?) {
        if let m = macro { m.showWindow(); return }
        let panel = NSOpenPanel()
        panel.title = Lang.t("Tera Term", "FILEDLG_OPEN_MACRO_TITLE", "MACRO: マクロを開く")
        panel.allowedFileTypes = ["ttl"]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.runMacro(url: url)
        }
    }

    /// 常に最前面に表示 (TTXAlwaysOnTop): このウインドウだけ。保存はしない
    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        guard let w = window else { return }
        w.level = w.level == .floating ? .normal : .floating
    }

    @objc func showMacroWindow(_ sender: Any?) {
        if let m = macro { m.showWindow() } else { MacroRunner.unlinked.last?.showWindow() }
    }

    // MARK: - メニューの使える・使えない (InitMenuPopup)

    func validateMainMenuItem(_ item: NSMenuItem) -> Bool? {
        let ready = connected
        switch item.action {
        case #selector(newConnectionMenu(_:)):
            return !connecting
        case #selector(duplicateSessionMenu(_:)):
            if !ready || isBusy || isReplay { return false }
            if case .serial? = spec { return false }
            return true
        case #selector(disconnectMenu(_:)):
            return ready && !isBusy && !isReplay
        case #selector(sendBreakMenu(_:)):
            return ready && !isBusy
        case #selector(resetPort(_:)):
            if case .serial? = spec { return ready && !isBusy }
            return false
        case #selector(areYouThere(_:)):
            return ready && (conn as? TCPConnection)?.isTelnet == true && transfer == nil
        case #selector(toggleAlwaysOnTop(_:)):
            item.state = window?.level == .floating ? .on : .off
            return true
        case #selector(openTEK(_:)):
            return true
        case #selector(closeTEK(_:)):
            return tekWindow != nil
        case #selector(macroMenu(_:)):
            return macro == nil && transfer == nil
        case #selector(showMacroWindow(_:)):
            return macro != nil || transfer != nil || !MacroRunner.unlinked.isEmpty
        default:
            return nil
        }
    }
}

// 設定の値 (その他の設定の各タブで変えられる)
extension SessionWindowController {
    var confirmDisconnectSetting: Bool { settings.confirmDisconnect }
    var autoWinCloseSetting: Bool { settings.autoWinClose }
    var sendBreakTimeSetting: Int { settings.sendBreakTime }
}
