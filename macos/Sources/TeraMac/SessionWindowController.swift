import AppKit
import TeraCore

/// 1 つのウインドウ = 1 つの接続
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    let term: Terminal
    let termView: TerminalView
    var settings: TermSettings
    private(set) var spec: ConnectionSpec?
    var conn: Connection?
    var connection: Connection? { conn }
    /// ファイルのドラッグ&ドロップ (FileDrop.swift)
    lazy var dropSettings = DropSettings.load()
    lazy var dropState = DropState(confirm: dropSettings.confirmFileDragAndDrop)
    private var decoder: StreamDecoder
    private(set) var connected = false
    /// connect したが、まだつながっていない (TCP の接続中・ssh がまだ何も出していない)
    private(set) var connecting = false
    /// cv.TitleRemoteW (端末が持つ。nil を入れるとリモートのタイトルを消す)
    var remoteTitle: String? {
        get { term.remoteTitle }
        set { if newValue == nil { term.clearRemoteTitle() } }
    }
    /// JIS の送信 (漢字アウトを次の英数の前に付けるので、ウインドウごとに状態を持つ)
    private var jisEncoder = JISEncoder()
    /// TTProxy のコマンドライン (-proxy=URL / -noproxy) で置き換えたプロキシ。本家はプロセスごと (defaultProxy) なので、
    /// Mac ではウインドウごとに持つ (起動時の引数は最初のウインドウ、connect マクロはそのウインドウ)
    var proxyOverride: ProxyURL?
    /// シリアルポートの自動再接続 (AutoComPortReconnect)
    private(set) lazy var serialReconnect = SerialReconnect(session: self)
    /// ログ (filesys_log.cpp の LogVar)
    private(set) var teraLog: TeraLog?
    var logPath: String? { teraLog?.path }
    private var connectedAt = Date()
    var logPaused: Bool {
        get { teraLog?.paused ?? false }
        set { teraLog?.paused = newValue }
    }
    /// logautoclose (ttdde.c AutoLogClose): マクロが終わったら (DDE が切れたら) ログを閉じる
    var logAutoClose = false
    // マクロ用
    var multicastName = ""
    /// settitle / /W= のタイトル (Tera Term の ts.TitleW。nil なら設定の Title)。
    /// CmdSetTitle: AcceptTitleChangeRequest=overwrite ならリモートのタイトルを消す
    var macroTitle: String? {
        didSet {
            if settings.acceptTitleChangeRequest.lowercased() == "overwrite" { remoteTitle = nil }
            term.localTitle = localTitle   // タイトル報告 (CSI 21 t) にも使う
            updateTitle()
        }
    }
    /// ts.TitleW
    var localTitle: String { macroTitle ?? settings.title }
    /// SerialNo (RegWin: 前のウインドウの番号 + 1)
    let serialNo: Int
    /// connect の /timeout= など、ssh に渡す追加の引数
    private var sshExtraArgs: [String] = []
    /// ファイル転送のフォルダ (GetFileDir: FileDir を展開し、無ければダウンロード)。設定すると FileDir をそのまま書き換える
    var transferDir: String? {
        get { FileTransferPaths.fileDirectory(transferOptions.fileDir) }
        set { transferOptions.fileDir = newValue ?? "" }
    }
    /// ファイル転送 (XMODEM / ZMODEM / recvfile など)。動いている間は受信したデータをこちらに渡す
    private(set) var transfer: FileTransfer?
    /// Tera Term の ts にあたる転送の設定。TERATERM.INI があれば読む (マクロの指定がつぎの転送にも残る)
    var transferOptions = TermSettings.initialTransferOptions()
    /// ZMODEM / B-Plus の自動起動 (ZmodemAuto / BPAuto)
    private var autoStartScanner = TransferAutoStartScanner()
    private var autoStartBypass = false
    /// ZMODEM 自動送信でファイルを選んでいる間に受けたデータ
    private var autoSendBuffer: [UInt8]?
    /// sendfile の送信中 (SendMem)
    var sendFileJob: SendFileJob?
    /// TalkStatus != IdTalkKeyb の間、キーボード・貼り付けを止めるために退避したハンドラ
    private var savedKeyHandlers: (text: ((String) -> Void)?, bytes: (([UInt8]) -> Void)?)?
    /// cv.DelayFlag = FALSE の間退避したシリアルの送信遅延
    private var savedSerialDelay: (char: Int, line: Int)?
    var transferPanel: TransferProgressPanel?
    private var scpPanels: [TransferProgressPanel] = []
    private var scpJobs: [ScpJob] = []
    /// 自動ログイン: プロンプトが出たら順に答える (TeraTerm Menu の自動ログイン)
    struct LoginStep {
        var prompt: String
        var response: String
        /// prompt を (大文字小文字を区別しない) 正規表現として、受信の末尾に合わせる
        var regex = false
    }
    private var loginSteps: [LoginStep] = []
    private var recentOutput = ""
    var macro: MacroRunner?
    private var statusLabel: NSTextField?
    /// ログの再生のウインドウ (cv.PortType == IdFile): 送信・転送・切断・複製はできない
    var isReplay = false
    var replayTimer: Timer?
    /// 貼り付け・ブロードキャストの送信中 (SendMem)
    var pasteJob: SendFileJob?
    /// メニューの「接続断」で切った (onClose で AutoWinClose を二重に行わない)
    var closedByMenu = false
    /// 全終了・自動で閉じるときは「切断しますか？」を出さない
    var skipCloseConfirm = false
    var replayTitle: String?
    var replayFinished = false
    /// ドラッグ中に変わった端末の大きさ (終わったときに相手へ知らせる)
    var pendingResize: (Int, Int)?

    static var all: [SessionWindowController] = []

    // MARK: - タブの分割表示 (TabSplit.swift)

    /// タブを分割して 1 つのウインドウに並べているとき、その分割 (ペインになっている間だけ)
    weak var tabSplit: TabSplit?
    /// ペインのときの、このセッションの次の応答者 (ペインのビュー → 分割のウインドウ)。
    /// ペインの端末 → TerminalContainerView → このコントローラ → ペイン … の順にして、メニューの動作をこのセッションで受ける
    weak var paneNextResponder: NSResponder?
    override var nextResponder: NSResponder? {
        get { paneNextResponder ?? super.nextResponder }
        set { super.nextResponder = newValue }
    }
    /// 分割に使うタブとして選んだ印 (TabMarks)。タブの題の前に「✓ 」を付ける
    var tabMarked = false
    /// 印を付けたときのタブの組 (ほかの組に移ったら印を消す)
    weak var tabMarkGroup: NSWindowTabGroup?
    /// タブの右のチェックボックス (TabCheckAccessory)
    var tabCheck: TabCheckAccessory?
    /// 分割のペインで「この画面を選ぶ」の印 (次の「この画面を左右/上下に分割」で、その画面の隣に移す)
    var paneMarked = false
    /// タブの組から分けたときの元のウィンドウのセッション (TabTearOff。元のウィンドウのタブに戻す)
    weak var tearOffOrigin: SessionWindowController?
    /// 前に見たときの、同じタブの組のほかのウインドウ (タブを引き出したかを見分ける)
    var tabSiblings: [WeakWindow] = []
    /// 前に見たときのウインドウの位置 (2 つのタブの組が分かれたとき、動いた方を見分ける)
    var tabFrame: NSRect = .zero
    /// シート・アラート・パネルを出すウインドウ。分割中は (このセッションのウインドウは隠れているので) 分割しているウインドウ
    var presentingWindow: NSWindow? { tabSplit?.hostWindow ?? window }
    /// このセッションのタイトル (分割中は、ホストのウインドウのタイトルはフォーカスのあるペインのもの)
    private(set) var displayTitle = ""

    /// 今のセッション: キーウインドウ (なければメインウインドウ) のセッション。分割中はフォーカスのあるペイン
    static var current: SessionWindowController? { session(for: NSApp.keyWindow) ?? session(for: NSApp.mainWindow) }

    /// ウインドウに出ているセッション (分割中のウインドウならフォーカスのあるペイン)
    static func session(for w: NSWindow?) -> SessionWindowController? {
        guard let w = w else { return nil }
        if let r = w.contentView as? TabSplitRootView { return r.split?.focused }
        return w.windowController as? SessionWindowController
    }

    /// 画面に出ているセッションのウインドウ (分割で隠しているペインのウインドウは除き、分割中のウインドウは 1 回だけ)
    static var presentedWindows: [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        return all.compactMap { $0.presentingWindow }.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    init(settings initial: TermSettings = TermSettings.load()) {
        var settings = CommandLineSession.applyOnce(to: initial)   // 起動時の /B /KR /KT (最初のウインドウだけ)
        // 起動時のテーマ (BGLoadThemeFile): テーマの色を設定に写してから画面を作る
        if let t = ThemeFile.startupTheme(base: settings) {
            t.colors.apply(to: &settings)
            ThemeRuntime.shared.set(t)
        }
        self.settings = settings
        serialNo = (SessionWindowController.all.last?.serialNo ?? 0) + 1
        term = Terminal(cols: settings.cols, rows: settings.rows)
        termView = TerminalView(term: term, settings: settings)
        decoder = StreamDecoder(encoding: settings.encoding)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.tabbingMode = .preferred
        super.init(window: win)
        win.delegate = self
        win.contentView = TerminalContainerView(termView: termView)  // ウィンドウ内のメニューバー + 端末
        win.backgroundColor = settings.bg
        applyNewlineSettings()
        fitWindow(cols: settings.cols, rows: settings.rows)
        win.center()
        if let last = SessionWindowController.all.last?.window {
            win.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        win.makeFirstResponder(termView)
        termView.owner = self
        // 分割中: クリックなどで端末がファーストレスポンダになったら、そのペインにフォーカスを移す
        termView.onFocus = { [weak self] in
            guard let self = self else { return }
            self.tabSplit?.paneFocused(self)
        }

        // 応答はバイト列のまま送る (Answerback・タイトル報告は UTF-8 とは限らない)
        term.onResponseBytes = { [weak self] b in self?.sendBytes(b, echo: false, reconnect: false) }
        // OSC 0 / 1 / 2: 端末がリモートのタイトルを覚えている (AcceptTitleChangeRequest=off なら受けない)。タイトルを組み立て直す
        term.onTitle = { [weak self] _ in self?.updateTitle() }
        term.onBell = { NSSound.beep() }
        term.onBellKind = { [weak self] k in
            switch k {
            case .sound: NSSound.beep()
            case .visual: self?.flashTerminal()
            case .off: break
            }
        }
        term.onWindowOp = { [weak self] op in self?.windowOperation(op) }
        term.windowInfo = { [weak self] in self?.currentWindowInfo() ?? WindowInfo() }
        term.onClipboardWrite = { s in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
        term.onClipboardRead = { NSPasteboard.general.string(forType: .string) }
        term.onClipboardNotice = { [weak self] n in self?.showClipboardNotice(n) }
        term.onPrint = { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .screen: self.printText(self.termView.visibleText, selectionOnly: false)
            case .text(let t): self.printText(t, selectionOnly: false)
            }
        }
        term.onMacroText = { [weak self] b in self?.macroText(b) }
        termView.onSendText = { [weak self] s in self?.sendText(s) }
        termView.onSendBytes = { [weak self] b in self?.sendBytes(b, echo: true) }
        termView.onFilesDropped = { [weak self] paths, force in self?.filesDropped(paths, forceDialog: force) }
        termView.onPaste = { [weak self] s in self?.sendPasteText(s, echo: true) }
        termView.canPaste = { [weak self] in self?.canPaste ?? false }
        termView.onResize = { [weak self] c, r in
            guard let self = self else { return }
            // ウインドウの大きさをドラッグで変えている間は相手に知らせず、終わったときに 1 回だけ知らせる
            // (知らせるたびにシェルがプロンプトを描き直し、古い行が何度も残るため)
            if let sp = self.tabSplit {
                // 分割中: 区切りのドラッグ・ウインドウの大きさの変更が落ち着いてから知らせる
                self.pendingResize = (c, r)
                if self.presentingWindow?.inLiveResize != true { sp.scheduleResizeFlush() }
            } else if self.window?.inLiveResize == true {
                self.pendingResize = (c, r)
            } else {
                self.conn?.resize(cols: c, rows: r)
            }
            self.updateTitle()
        }
        SessionWindowController.all.append(self)
        proxyOverride = CommandLineSession.takeStartupProxy()   // 起動時の -proxy= / -noproxy
        // 端末の設定 (端末 ID・タイトル・制御シーケンスなど) をすぐにかける
        applySettings(settings)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 端末からの依頼 (ベル・ウィンドウ操作・OSC 52)

    /// ビジュアルベル (vtterm.c VisualBell。8e22ce326 #333): 文字色と背景色を入れ替え (CSQExchangeColor)、
    /// BeepVBellWait ミリ秒 (1 未満は 1) たったら戻す。本家は Sleep で止めるが、Mac 版は止めずにあとで戻す
    func flashTerminal() {
        guard !termView.bellInverted else { return }
        termView.bellInverted = true
        termView.displayIfNeeded()
        let v = termView
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(1, settings.beepVBellWait))) { v.bellInverted = false }
    }

    /// スクリーンの左上を原点にした座標 (Windows と同じ向き) と Mac の座標を変える
    private var screenTop: CGFloat { (presentingWindow?.screen ?? NSScreen.main)?.frame.maxY ?? 0 }

    /// CSI Ps t (vtwin.cpp / vtdisp.c DispWindowOp)
    private func windowOperation(_ op: WindowOp) {
        guard let w = presentingWindow else { return }
        switch op {
        case .deiconify: w.deminiaturize(nil)
        case .iconify: w.miniaturize(nil)
        case .move(let x, let y): w.setFrameTopLeftPoint(NSPoint(x: CGFloat(x), y: screenTop - CGFloat(y)))
        case .resizePixels(let width, let height):
            let cur = termView.bounds.size
            let wd = width > 0 ? CGFloat(width) : cur.width, ht = height > 0 ? CGFloat(height) : cur.height
            let cols = max(1, Int(wd / termView.cellW)), rows = max(1, Int(ht / termView.cellH))
            resizeTerminal(cols: cols, rows: rows)
        case .raise: w.orderFront(nil)
        case .lower: w.orderBack(nil)
        case .refresh: termView.needsDisplay = true
        case .resizeTerminal(let c, let r):
            resizeTerminal(cols: c > 0 ? c : term.cols, rows: r > 0 ? r : term.rows)
        case .maximize: if !w.isZoomed { w.zoom(nil) }
        case .restore: if w.isZoomed { w.zoom(nil) }
        case .toggleMaximize: w.zoom(nil)
        }
    }

    /// ChangeTerminalSize: 端末の桁数・行数を変えてウインドウを合わせ、相手に知らせる
    private func resizeTerminal(cols: Int, rows: Int) {
        // TermWidthMax / TermHeightMax (4.106: 1000 桁 / 500 行)
        let cols = min(TermLimits.widthMax, cols), rows = min(TermLimits.heightMax, rows)
        fitWindow(cols: cols, rows: rows)
        conn?.resize(cols: term.cols, rows: term.rows)
        updateTitle()
    }

    private func currentWindowInfo() -> WindowInfo {
        var i = WindowInfo()
        guard let w = presentingWindow else { return i }
        let top = screenTop
        i.iconified = w.isMiniaturized
        i.windowX = Int(w.frame.minX); i.windowY = Int(top - w.frame.maxY)
        i.windowWidth = Int(w.frame.width); i.windowHeight = Int(w.frame.height)
        let client = w.convertToScreen(termView.convert(termView.bounds, to: nil))
        i.clientX = Int(client.minX); i.clientY = Int(top - client.maxY)
        i.clientWidth = Int(client.width); i.clientHeight = Int(client.height)
        let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        i.screenWidth = Int(vis.width); i.screenHeight = Int(vis.height)
        i.cellWidth = Int(termView.cellW); i.cellHeight = Int(termView.cellH)
        i.screenCols = termView.cellW > 0 ? Int(vis.width / termView.cellW) : 0
        i.screenRows = termView.cellH > 0 ? Int(vis.height / termView.cellH) : 0
        return i
    }

    /// OSC 52 の通知 (NotifyClipboardAccess)。止めないようにシートで出す
    private func showClipboardNotice(_ n: ClipboardNotice) {
        guard let w = presentingWindow, w.attachedSheet == nil else { return }
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = n.title
        a.informativeText = n.message
        a.beginSheetModal(for: w, completionHandler: nil)
    }

    /// 漢字コードを変えたとき (KanjiMenu の CallResetCharSet → ResetCharSet): 途中まで受けた文字・JIS の状態、
    /// 送信の JIS の状態と端末の G0〜G3 を初めに戻す
    func resetCharSet() {
        decoder.reset()
        jisEncoder = JISEncoder(options: TermEncoding.jisSendOptions)
        term.resetCharSet()
    }

    /// 送る文字を送信の文字コードにする (JIS は漢字アウトの状態を続ける)
    func encodeForSend(_ s: String) -> [UInt8] {
        guard settings.encodingSend == .jis else { return settings.encodingSend.encode(s) }
        jisEncoder.options = TermEncoding.jisSendOptions
        return jisEncoder.encode(s)
    }

    private func applyNewlineSettings() {
        term.recvCRasCRLF = settings.recvNewline == "CR"
        term.recvLFasCRLF = settings.recvNewline == "LF"
    }

    func fitWindow(cols: Int? = nil, rows: Int? = nil) {
        guard let w = window else { return }
        if tabSplit != nil {
            // 分割中はウインドウ (ほかのペインと共有) の大きさを変えない。フォントが変わったときのために、
            // 今のペインの大きさで桁数・行数を決め直す
            termView.setFrameSize(termView.frame.size)
            return
        }
        let size = termView.contentSize(cols: cols ?? term.cols, rows: rows ?? term.rows)
        // メニューバーはタイトルバーの飾りなので、中身の大きさには入らない
        let top = w.frame.maxY
        w.setContentSize(size)
        w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX, y: top))
        w.contentResizeIncrements = NSSize(width: termView.cellW, height: termView.cellH)
    }

    func applySettings(_ s: TermSettings) {
        term.aixterm16Color = s.aixterm16Color
        term.xterm256Color = s.xterm256Color
        let resize = s.cols != settings.cols || s.rows != settings.rows || s.fontName != settings.fontName || s.fontSize != settings.fontSize
        let menuBarChanged = s.popupMenu != settings.popupMenu
        settings = s
        // 「メニューバーを表示する」(PopupMenu) が変わったら、メニューバーを出し入れする (保存済みの値を各ウィンドウが読む)
        // (設定画面は applySettings のあとで保存するので、保存が済んでから知らせる)
        if menuBarChanged {
            DispatchQueue.main.async { NotificationCenter.default.post(name: InWindowMenuBar.changedNotification, object: nil) }
        }
        termView.settings = s
        decoder.encoding = s.encoding
        decoder.jis7Katakana = s.katakanaReceive7
        TermEncoding.jisSendOptions = JISSendOptions(kanjiIn: s.kanjiIn, kanjiOut: s.kanjiOut, katakana7: s.katakanaSend7)
        term.applyTeraTermSettings(terminalID: s.terminalID, answerback: s.answerbackBytes, title: localTitle, acceptTitleChangeRequest: s.acceptTitleChangeRequest, titleReportSequence: s.titleReportSequence,
            windowCtrlSequence: s.windowCtrlSequence, windowReportSequence: s.windowReportSequence, cursorCtrlSequence: s.cursorCtrlSequence, clipboardAccessFromRemote: s.clipboardAccessFromRemote, notifyClipboardAccess: s.notifyClipboardAccess,
            clearScrollBufferFromRemote: s.clearScrollBufferFromRemote, printerCtrlSequence: s.printerCtrlSequence, beep: s.beep, receive: s.encoding, send: s.encodingSend,
            decSpMappingDir: s.decSpMappingDir, unicodeToDecSpMapping: s.unicodeToDecSpMapping, unicodeEmojiOverride: s.unicodeEmojiOverride, unicodeEmojiWidth: s.unicodeEmojiWidth)
        term.defaultCursorBlink = s.cursorBlink
        // dumb 端末 + LogTimestamp: 行頭のタイムスタンプを画面にも出す (dd65db75a #255)。経過時間はどちらも接続からの時間
        term.dumbTimestamp = { [weak self] in
            // ts.LogTimestamp: 設定か、ログのダイアログで選んだもの (ログを取っていなくても出す)
            guard let self = self, self.term.terminalID == .dumb,
                  self.settings.logTimestamp || self.teraLog?.options.timestamp == true else { return nil }
            let t = LogDefaults.timestampIndex(self.settings.logTimestampType)
            return TeraLog.timestampText(type: t, now: Date(), start: self.connectedAt, connected: self.connectedAt)
        }
        window?.backgroundColor = s.bg
        applyNewlineSettings()
        if let sc = conn as? SerialConnection { sc.charDelayMs = s.charDelayMs; sc.lineDelayMs = s.lineDelayMs }
        if resize {
            fitWindow(cols: s.cols, rows: s.rows)
            conn?.resize(cols: term.cols, rows: term.rows)
        }
        termView.needsDisplay = true
    }

    /// ChangeTitle (ttwinman.c): Title / TitleFormat / AcceptTitleChangeRequest と接続の状態から
    func updateTitle() {
        let t = WindowTitle.make(titleInput)
        displayTitle = t
        guard let w = window else { return }
        if let sp = tabSplit {
            // 分割中: 隠しているウインドウには自分のタイトル、分割しているウインドウはフォーカスのあるペインのタイトル
            if w !== sp.hostWindow { w.title = t; w.tab.title = t }
            sp.titlesChanged()
            return
        }
        w.title = t
        w.tab.title = tabMarked ? TabMarks.prefix + t : t   // 分割に使うタブとして選んだ印 (Shift+クリック / タブメニュー)
        tabCheck?.refresh()
        // Windows と同じくタイトルバーにアプリのアイコン
        if w.representedURL == nil {
            w.representedURL = Bundle.main.bundleURL
            if let icon = NSApp.applicationIconImage?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                w.standardWindowButton(.documentIconButton)?.image = icon
            }
        }
    }

    /// ChangeTitle の材料 (GetConnectHostName は ts.HostName: ホスト名だけ。ポートは ts.TCPPort)
    var titleInput: WindowTitleInput {
        var i = WindowTitleInput(title: localTitle, remoteTitle: remoteTitle,
                                 acceptTitleChangeRequest: settings.acceptTitleChangeRequest,
                                 titleFormat: settings.titleFormat, connecting: connecting,
                                 ready: connected, serialNo: serialNo)
        if isReplay {
            // ログの再生 (IdFile): 再生しているファイル
            i.ready = !replayFinished
            i.port = .tcp(host: replayTitle ?? "", port: 0)
            return i
        }
        switch spec {
        case .ssh(let h, let p, _, _)?, .telnet(let h, let p)?, .rawTCP(let h, let p)?: i.port = .tcp(host: h, port: p)
        case .serial(let sp)?: i.port = .serial(name: (sp.path as NSString).lastPathComponent, baud: (conn as? SerialConnection)?.params.baud ?? sp.baud)
        case .shell?: i.port = .tcp(host: ConnectionSpec.shell.title, port: 0)
        case nil: break
        }
        return i
    }

    // MARK: - 接続

    func showConnectDialog(onEnd: (() -> Void)? = nil) {
        guard let w = presentingWindow else { onEnd?(); return }
        let dlg = ConnectDialog()
        dlg.settings = settings
        dlg.begin(on: w) { [weak self, weak dlg] spec, password in
            defer { onEnd?() }
            guard let self = self, let spec = spec else { return }
            // ダイアログの値を ts に (HistoryList / Telnet / TCPPort)
            switch spec {
            case .ssh: self.settings.historyList = dlg?.historyList ?? self.settings.historyList
            case .telnet(_, let p): self.settings.telnet = true; self.settings.tcpPort = p; self.settings.historyList = dlg?.historyList ?? self.settings.historyList
            case .rawTCP(_, let p): self.settings.telnet = false; self.settings.tcpPort = p; self.settings.historyList = dlg?.historyList ?? self.settings.historyList
            default: break
            }
            if dlg?.telnetBinary == true { self.settings.telBin = true }   // /B
            self.connect(spec, password: password)
        }
    }

    /// 接続する。TCP と ssh は「つながった」ときに macro.connectionChanged() (Tera Term の SetDdeComReady(1))。
    /// sshArgs: ssh に足す引数 (/auth= /timeout= など)。timeout: TCP の接続を待つ秒数 (/timeout=、0 / nil は OS 任せ)
    @discardableResult
    func connect(_ spec: ConnectionSpec, password: String? = nil, loginSteps steps: [LoginStep] = [],
                 sshArgs: [String] = [], timeout: Int? = nil, telnetBinary: Bool = false, quiet: Bool = false) -> Bool {
        disconnect(silent: true)
        // ほかの接続を始めたら、シリアルの自動再接続は待つのをやめる
        if !serialReconnect.opening { serialReconnect.cancel() }
        self.spec = spec
        remoteTitle = nil
        sshExtraArgs = sshArgs
        // TTProxy: コマンドライン・connect マクロの -proxy= / -noproxy があればそちら (このウインドウの defaultProxy)
        let proxySettings = ProxySettings.load().overridden(by: proxyOverride)
        if let o = proxyOverride, o.isSSL, spec.isNetwork {
            let m = Lang.m("CONN2_PROXY_SSL_UNSUPPORTED", "SSL を使うプロキシ (ssl / http+ssl など) には対応していません")
            notice(m)
            if !quiet, let w = presentingWindow {
                let a = NSAlert()
                a.messageText = Lang.m("MENU_CONNECT_FAILED", "接続できませんでした")
                a.informativeText = m
                a.beginSheetModal(for: w)
            }
            updateTitle()
            macro?.connectionChanged()
            return false
        }
        // TTSSH は pty-req の端末の種類に ts.TermType を使う
        var sshEnv = SSHSetupArgs.environment(spec, proxy: proxySettings)
        if !settings.termType.isEmpty { sshEnv["TERM"] = settings.termType }
        let c = makeConnection(spec, cols: term.cols, rows: term.rows, sshArgs: sshArgs + SSHSetupArgs.forConnection(spec, proxy: proxySettings),
                               sshEnv: sshEnv, timeout: timeout, telnetBinary: telnetBinary || settings.telBin, termType: settings.termType,
                               keepAlive: settings.telKeepAliveInterval, proxy: proxySettings.config)
        if let sc = c as? SerialConnection { sc.charDelayMs = settings.charDelayMs; sc.lineDelayMs = settings.lineDelayMs; sc.breakMs = settings.sendBreakTime }
        c.onData = { [weak self] b in self?.received(b) }
        c.onClose = { [weak self, weak c] msg in
            guard let self = self, c === self.conn else { return }
            let wasConnecting = self.connecting
            // ssh 自身が失敗して終わった (認証失敗など): 何か出力があって「接続中」でなくなっていても、接続できなかった扱いで理由を出す
            let sshFailed = (c as? PTYConnection)?.sshFailed == true
            self.connected = false
            self.connecting = false
            self.conn = nil
            self.transferConnectionLost()
            if sshFailed, let pc = c as? PTYConnection { self.notice(pc.sshFailSummary) } else
            { self.notice(msg.map { wasConnecting ? $0 : Lang.m("MENU_DISCONNECTED_REASON", "切断されました: %s", $0) } ?? Lang.m("MENU_DISCONNECTED", "切断されました")) }
            if (wasConnecting || sshFailed) && !quiet, let m = msg, let w = self.presentingWindow {
                // cv.NoMsg (マクロの connect) のときは出さない
                let a = NSAlert()
                a.messageText = Lang.m("MENU_CONNECT_FAILED", "接続できませんでした")
                a.informativeText = m
                a.beginSheetModal(for: w)
            }
            self.updateTitle()
            self.macro?.connectionChanged()
            // AutoComPortReconnect: USB シリアルを抜いた → 戻ったら開き直す (vtwin.cpp SerialReconnect)
            if case .serial(let p) = spec, msg != nil, !wasConnecting, !self.closedByMenu { self.serialReconnect.portClosed(p) }
            // 相手から切られた: TCP/IP で AutoWinClose ならウインドウを閉じる (接続できなかったときは閉じない)
            if !wasConnecting && !sshFailed && !self.closedByMenu { self.afterConnectionClosed() }
            self.closedByMenu = false
        }
        c.onConnected = { [weak self, weak c] in
            guard let self = self, c === self.conn, self.connecting else { return }
            self.connecting = false
            self.connected = true
            self.transfer?.isReady = true
            self.connectedAt = Date()
            self.teraLog?.connectedTime = self.connectedAt
            if c is TCPConnection { self.notice(Lang.m("MENU_CONNECTED_TO", "%s に接続しました", spec.title)) }
            self.updateTitle()
            self.autoStartLog()
            self.macro?.connectionChanged()
        }
        if c is TCPConnection { notice(Lang.m("MENU_CONNECTING_TO", "%s に接続しています…", spec.title)) }
        loginSteps = steps
        if let pw = password, !pw.isEmpty, steps.isEmpty { loginSteps = [LoginStep(prompt: "password:", response: pw)] }
        recentOutput = ""
        do {
            try c.start()
        } catch {
            notice(error.localizedDescription)
            if !quiet {
                let a = NSAlert()
                a.messageText = Lang.m("MENU_CONNECT_FAILED", "接続できませんでした")
                a.informativeText = error.localizedDescription
                if let w = presentingWindow { a.beginSheetModal(for: w) } else { a.runModal() }
            }
            updateTitle()
            macro?.connectionChanged()
            return false
        }
        conn = c
        if c.waitsForConnection {
            connecting = true
            connected = false
            updateTitle()
            return true
        }
        connected = true
        transfer?.isReady = true
        connectedAt = Date()
        teraLog?.connectedTime = connectedAt
        macro?.connectionChanged()
        if case .serial(let p) = spec {
            notice(Lang.m("MENU_SERIAL_OPENED", "%s を開きました (%d bps, %s, フロー制御: %s)",
                          p.path, p.baud, "\(p.dataBits)\(p.parity.prefix(1).uppercased())\(p.stopBits)", p.flow))
        }
        updateTitle()
        autoStartLog()
        return true
    }

    /// 開いているシリアルポートの設定を変えた (setbaud・設定の変更): spec とタイトルを今の値にする
    func serialParamsChanged() {
        guard let sc = conn as? SerialConnection, case .serial? = spec else { return }
        spec = .serial(sc.params)
        updateTitle()
    }

    var isConnected: Bool { connected }
    /// 接続を始めたが、まだつながっていない (TCP の接続中・ssh の接続中・接続ダイアログを出している)
    var isConnecting: Bool { connecting || connectDialogOpen }
    /// マクロの connect '' で出した接続ダイアログ
    var connectDialogOpen = false

    func disconnect(silent: Bool = false) {
        guard let c = conn else { return }
        conn = nil
        connected = false
        connecting = false
        transferConnectionLost()
        c.close()
        if !silent { notice(Lang.m("MENU_DISCONNECTED_BY_USER", "切断しました")) }
        updateTitle()
        macro?.connectionChanged()
    }

    /// 端末に案内を出す (相手には送らない)。Tera Term にはない Mac 版の表示なので、
    /// マクロの受信 (wait など) にもログにも入れない (端末の CR/LF の状態も変えない)
    func notice(_ s: String) {
        let saved = term.onMacroText
        term.onMacroText = nil
        defer { term.onMacroText = saved }
        let prefix = term.cx == 0 ? "" : "\r\n"
        let one = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        term.feed(prefix + "\u{1B}[0;36m[\(one)]\u{1B}[0m\r\n")
        termView.dataArrived()
    }

    // MARK: - 受信

    /// ログの再生: 受信したデータとして端末に流す
    func feedReplay(_ bytes: [UInt8]) { received(bytes) }

    private func received(_ bytes: [UInt8]) {
        var bytes = bytes
        // ファイル転送中はプロトコルへ。終わったときに読まれずに残った分は端末へ (cv.InBuff の残り)
        if autoSendBuffer != nil { autoSendBuffer! += bytes; return }
        if let t = transfer {
            bytes = t.feed(bytes)
            if bytes.isEmpty { return }
        }
        if transfer == nil && !autoStartBypass && (transferOptions.zmodemAuto || transferOptions.bplusAuto) {
            autoStartScanner.zmodemAuto = transferOptions.zmodemAuto
            autoStartScanner.bplusAuto = transferOptions.bplusAuto
            let r = autoStartScanner.scan(bytes)
            if let trig = r.trigger {
                if !r.display.isEmpty {
                    autoStartBypass = true
                    received(r.display)
                    autoStartBypass = false
                }
                startAutoTransfer(trig, rest: r.rest)
                return
            }
            bytes = r.display
            if bytes.isEmpty { return }
        }
        teraLog?.putBinary(bytes)   // バイナリのログは受信したそのまま (FLogPutBinary)
        // TEK ウインドウが前のときは TEK へ (VT ↔ TEK の切り替えもここ)
        bytes = routeTEK(bytes)
        if bytes.isEmpty { return }
        let s = decoder.decode(bytes)
        guard !s.isEmpty else { return }
        term.feed(s)
        termView.dataArrived()
        if let step = loginSteps.first {
            recentOutput = String((recentOutput + s).suffix(300))
            let tail = recentOutput.lowercased().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let prompt = step.prompt.lowercased().trimmingCharacters(in: .whitespaces)
            var hit = step.regex ? tail.range(of: step.prompt, options: [.regularExpression, .caseInsensitive]) != nil
                                 : !prompt.isEmpty && tail.hasSuffix(prompt)
            // パスワードは日本語のプロンプトも受ける
            if !hit && prompt.contains("password") {
                hit = tail.range(of: "パスワード.*[:：]$", options: .regularExpression) != nil
            }
            if hit {
                loginSteps.removeFirst()
                recentOutput = ""
                sendBytes(encodeForSend(step.response) + settings.sendNewlineBytes, echo: false)
            }
        }
    }

    // MARK: - 送信

    func sendText(_ s: String) {
        sendBytes(encodeForSend(s), echo: true)
    }

    /// binary: Telnet の CR を CR NUL にするか (CommBinaryOut は CR LF も CR NUL LF。テキストは改行コードの設定どおり)。
    /// reconnect: 切断中の Enter で再接続する (キーボードだけ。マクロの send では再接続しない)
    func sendBytes(_ b: [UInt8], echo: Bool, binary: Bool = false, reconnect: Bool = true) {
        guard !b.isEmpty else { return }
        guard let c = conn else {
            if reconnect && echo && spec != nil && !connected && !connecting && b == settings.sendNewlineBytes {
                // 切断中に Enter で再接続 (Tera Term の「自動再接続」に近い動き)
                if let sp = spec { connect(sp) }
            }
            return
        }
        c.write(b, binary: binary)
        if echo && settings.localEcho {
            var d = StreamDecoder(encoding: settings.encodingSend)
            var shown = d.decode(b)
            if b == settings.sendNewlineBytes { shown = "\r\n" }
            term.feed(shown)
            termView.dataArrived()
        }
    }

    // MARK: - ログ

    /// メニューの「ログ開始」: バイナリ (受信したそのまま)
    func startLog(path: String, append: Bool = true) -> Bool {
        var o = TTLLogOptions()
        o.append = append
        o.binary = true
        return startLog(path: path, options: o)
    }

    /// FLogOpen。すでにログを取っていたら false (前のログはそのまま)
    func startLog(path: String, options o: TTLLogOptions, code: TeraLog.Code = .utf8, bom: Bool = false) -> Bool {
        guard teraLog == nil else { return false }
        guard let l = TeraLog(path: path, options: o, code: code, bom: bom, connectedTime: connectedAt) else { return false }
        // Log rotate configuration (ts.LogRotate / LogRotateSize / LogRotateStep)
        l.configureRotation(enabled: settings.logRotate != 0, size: settings.logRotateSize, step: settings.logRotateStep)
        teraLog = l
        // CmdSetLogOpt で ts.LogTypePlainText が変わり、FixLogOption でバイナリなら off になる (BS をマクロに渡すかも変わる)
        term.logTypePlainText = l.options.plainText
        showLogProgressWindow(showState: o.dialogShowState)   // FLogOpen が「ログ記録中」を作る
        return true
    }

    func stopLog() {
        closeLogProgressWindow()
        teraLog?.close()
        teraLog = nil
    }

    /// logwrite (FLogWriteStr): 一時停止中でも書く
    func writeLogString(_ utf8: [UInt8]) {
        guard let l = teraLog else { return }
        l.writeString(utf8, encoded: l.isBinary ? settings.encoding.encode(String(decoding: utf8, as: UTF8.self)) : nil)
    }

    /// logrotate size N / rotate N / halt (今のログだけ)
    func setLogRotate(_ command: String) { teraLog?.setRotate(command) }

    /// ログのフォルダ (GetTermLogDir: LogDefaultPath があればそれ、なければ FileDir)。どちらもなければ書類フォルダ
    var logDirectory: String {
        let def = (settings.logDefaultPath as NSString).expandingTildeInPath
        if !def.isEmpty { return FileTransferPaths.expandEnvironment(def) }
        if let d = transferDir, !d.isEmpty, FileManager.default.fileExists(atPath: d) { return d }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    /// &h &p に使う接続先 (ConvertLognameW: 接続しているときだけ)
    var logHostAndPort: (String?, Int?) {
        guard connected, let s = spec else { return (nil, nil) }
        switch s {
        case .ssh(let h, let p, _, _), .telnet(let h, let p), .rawTCP(let h, let p): return (h, p)
        case .serial(let sp): return ((sp.path as NSString).lastPathComponent, nil)
        case .shell: return (nil, nil)
        }
    }

    /// 端末に表示した文字 (エスケープシーケンスなし、改行は CheckEOL でそろえた UTF-8)。マクロとテキストのログへ (OutputLogUTF32)
    private func macroText(_ b: [UInt8]) {
        macro?.received(b)
        // dumb 端末ではタイムスタンプは画面に出したものがログに入るので、ログの側では付けない (dd65db75a #255)
        teraLog?.suppressTimestamp = term.terminalID == .dumb
        teraLog?.putText(b)
    }

    // MARK: - メニューの操作

    @objc func newConnection(_ sender: Any?) { showConnectDialog() }

    @objc func duplicateSession(_ sender: Any?) {
        let c = SessionWindowController(settings: settings)
        c.showWindow(nil)
        if let s = spec {
            if case .serial = s {
                c.showConnectDialog()   // 同じシリアルポートは 2 つ開けない
            } else {
                c.connect(s)
            }
        } else {
            c.showConnectDialog()
        }
    }

    @objc func disconnectSession(_ sender: Any?) { disconnect() }

    @objc func reconnect(_ sender: Any?) {
        if let s = spec { connect(s) }
    }

    /// 古い「ログ開始/停止」(マクロの callmenu からも呼ばれる): ログを取っていなければ ログ... 、取っていれば ログを終了
    @objc func toggleLog(_ sender: Any?) {
        if teraLog != nil { stopLogMenu(sender) } else { openLogDialog(sender) }
    }

    @objc func sendFile(_ sender: Any?) { sendFileMenu(sender) }

    @objc func sendBreak(_ sender: Any?) { conn?.sendBreak() }

    @objc func resetTerminal(_ sender: Any?) {
        term.feed("\u{1B}c")
        termView.dataArrived()
    }

    /// 画面クリア: 画面をバッファへ押し出す (見えている位置は一番下へ)
    @objc func clearScreen(_ sender: Any?) {
        term.clearScreen()
        termView.scrollToBottom()
        termView.needsDisplay = true
    }

    /// バッファのクリア: スクロールバックも画面も捨てる。選択も消す
    @objc func clearBuffer(_ sender: Any?) {
        term.clearBuffer()
        termView.clearSelection()
        termView.scrollToBottom()
        termView.needsDisplay = true
    }

    @objc func showTerminalSetup(_ sender: Any?) { setupTerminal(sender) }

    @objc func serialSetup(_ sender: Any?) { setupSerialPort(sender) }

    @objc func runMacroMenu(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["ttl", "txt"]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: presentingWindow!) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.runMacro(url: url)
        }
    }

    func runMacro(url: URL, params: [String] = []) {
        guard macro == nil else { NSSound.beep(); return }
        do {
            let m = try MacroRunner(path: url.path, params: params, session: self)
            macro = m
            notice(Lang.m("MENU_MACRO_STARTED", "マクロ開始: %s", url.lastPathComponent))
            m.start()
        } catch {
            let a = NSAlert()
            a.messageText = Lang.m("MENU_MACRO_LOAD_FAILED", "マクロを読めませんでした")
            a.informativeText = "\(error)"
            a.beginSheetModal(for: presentingWindow!)
        }
    }


    // MARK: - マクロから使う

    /// send / sendtext / sendbinary (ttdde.c SendData / SendStringU8 / SendBinary)。
    /// echo: ローカルエコー (ts.LocalEcho) するか。sendbroadcast / sendmulticast はしない (broadcast.cpp)。
    /// 切断中は何も送らない (再接続しない)
    func macroSend(_ b: [UInt8], mode: TTLSendMode, echo: Bool = true) {
        var binary = mode == .binary
        if mode == .compat {
            // IsBinaryData: CR/LF 以外の 0x20 未満が 1 バイトでもあればバイナリ。UTF-8 として読めなくてもバイナリ
            if b.contains(where: { $0 < 0x20 && $0 != 0x0D && $0 != 0x0A }) { binary = true }
            if String(bytes: b, encoding: .utf8) == nil { binary = true }
        }
        if binary {
            sendBytes(b, echo: echo, binary: true, reconnect: false)
            return
        }
        let text = String(decoding: b, as: UTF8.self)
        var out: [UInt8] = []
        for (i, part) in text.components(separatedBy: "\r").enumerated() {
            if i > 0 { out += settings.sendNewlineBytes }
            out += encodeForSend(part)
        }
        sendBytes(out, echo: echo, reconnect: false)
    }

    /// sendkcode (keyboard.c KeyCodeSend)。Tera Term のキーコード (IBM PC のスキャンコード。+512 Shift +1024 Ctrl +2048 Alt)。
    /// Mac には KEYBOARD.CNF がないので、既定の割り当て (IBMKEYB.CNF / VT のキー) と主なキーだけを送る。
    /// Enter は送信の改行コード、カーソルキーはアプリケーションカーソルモードに従う
    func macroSendKeyCode(_ code: Int, count: Int) {
        // KeyCodeSend: キーマップ (KEYBOARD.CNF) に割り当てのあるキーはその内容 (GetKeyStr) を送る
        let km = KeyMapStore.current
        let id = km.keyID(forCode: code)
        if id > 0, let a = km.action(for: id, appKeypad: term.appKeypad, appCursor: term.appCursor) {
            for _ in 0..<max(1, count) {
                switch a {
                case .binary(let str):
                    sendBytes(str.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }, echo: false, reconnect: false)
                case .text(let str):
                    macroSend(Array(str.utf8), mode: .text, echo: false)
                case .command(let c):
                    macroCallMenu(c)
                case .macro, .accel:
                    break   // マクロの実行中に別のマクロ・ショートカットは動かさない
                }
            }
            return
        }
        guard let seq = SessionWindowController.keyCodeSequence(code, appCursor: term.appCursor, appKeypad: term.appKeypad,
                                                                newline: settings.sendNewlineBytes) else {
            notice(Lang.m("MENU_SENDKCODE_UNSUPPORTED", "sendkcode %d には対応していません", code))
            return
        }
        for _ in 0..<max(1, count) { sendBytes(seq, echo: false, reconnect: false) }
    }

    static func keyCodeSequence(_ code: Int, appCursor: Bool, appKeypad: Bool, newline: [UInt8]) -> [UInt8]? {
        let esc: UInt8 = 0x1B
        func csi(_ s: String) -> [UInt8] { [esc, 0x5B] + Array(s.utf8) }
        func ss3(_ s: String) -> [UInt8] { [esc, 0x4F] + Array(s.utf8) }
        func cur(_ c: String) -> [UInt8] { appCursor ? ss3(c) : csi(c) }
        // [VT editor keypad] [VT numeric keypad] [VT function keys] [X function keys] (IBMKEYB.CNF)
        switch code {
        case 328: return cur("A")
        case 336: return cur("B")
        case 333: return cur("C")
        case 331: return cur("D")
        case 338: return csi("2~")   // Insert
        case 327: return csi("1~")   // Find (Home)
        case 329: return csi("5~")   // Prev
        case 339: return csi("3~")   // Remove (Delete)
        case 335: return csi("4~")   // Select (End)
        case 337: return csi("6~")   // Next
        case 59: return ss3("P")
        case 60: return ss3("Q")
        case 61: return ss3("R")
        case 62: return ss3("S")
        case 63: return csi("15~")   // XF5
        case 64: return csi("17~")
        case 65: return csi("18~")
        case 66: return csi("19~")
        case 67: return csi("20~")
        case 68: return csi("21~")
        case 87: return csi("23~")
        case 88: return csi("24~")
        case 573: return csi("25~")
        case 574: return csi("26~")
        case 575: return csi("28~")  // Help
        case 576: return csi("29~")  // Do
        case 577: return csi("31~")
        case 578: return csi("32~")
        case 579: return csi("33~")
        case 580: return csi("34~")
        case 527: return csi("Z")    // XBackTab
        case 284: return appKeypad ? ss3("M") : newline   // NumEnter
        default: break
        }
        let numpad: [Int: (String, String)] = [82: ("0", "p"), 79: ("1", "q"), 80: ("2", "r"), 81: ("3", "s"), 75: ("4", "t"),
                                               76: ("5", "u"), 77: ("6", "v"), 71: ("7", "w"), 72: ("8", "x"), 73: ("9", "y"),
                                               78: ("+", "l"), 83: (".", "n"), 309: ("/", "o"), 55: ("*", "j"), 74: ("-", "m")]
        if let (n, a) = numpad[code] { return appKeypad ? ss3(a) : Array(n.utf8) }
        // そのほかのキー (VKey2KeyStr / OemKeyScan): US 配列のスキャンコード
        let shift = code & 512 != 0, ctrl = code & 1024 != 0, alt = code & 2048 != 0
        let scan = code & 0x1FF
        var out: [UInt8]
        switch scan {
        case 1: out = [esc]
        case 14: out = [0x08]
        case 15: out = shift ? csi("Z") : [0x09]
        case 28: out = newline
        case 57: out = [0x20]
        default:
            let rows: [(Int, String, String)] = [
                (2, "1234567890-=", "!@#$%^&*()_+"), (16, "qwertyuiop[]", "QWERTYUIOP{}"),
                (30, "asdfghjkl;'`", "ASDFGHJKL:\"~"), (43, "\\zxcvbnm,./", "|ZXCVBNM<>?"),
            ]
            var ch: Character?
            for (start, lower, upper) in rows {
                let i = scan - start
                if i >= 0 && i < lower.count {
                    ch = Array(shift ? upper : lower)[i]
                    break
                }
            }
            guard let c = ch, let v = c.asciiValue else { return nil }
            if ctrl {
                let u = Character(String(c).uppercased()).asciiValue ?? v
                guard u >= 0x40 && u <= 0x5F else { return nil }
                out = [u & 0x1F]
            } else {
                out = [v]
            }
        }
        if alt && scan != 28 { out = [esc] + out }   // Meta キーは ESC を前に付ける
        return out
    }

    /// sendfile (sendmem.cpp SendMemSendFile2)。相対パスは FileDir から。テキストは LoadFileWW と同じ読み方で
    /// 改行を CR にして端末の改行コード・文字コードで、バイナリはそのまま送る。SendfileDelay* の遅延とローカルエコー付き。
    /// 送り終わったら done。ファイルが読めなければ false (マクロはすぐ次へ)
    func macroSendFile(_ path: String, binary: Bool, done: @escaping () -> Void) -> Bool {
        let full = FileTransferPaths.resolve(path, fileDir: FileTransferPaths.fileDirectory(transferOptions.fileDir))
        guard let d = FileManager.default.contents(atPath: full) else { return false }
        let o = transferOptions
        let plan = SendFilePlan.make(data: d, binary: binary, delayType: o.sendfileDelayType,
                                     delayTick: o.sendfileDelayTick, sendSize: o.sendfileSize)
        let job = SendFileJob(plan: plan) { [weak self] chunk in
            // CommBinaryBuffOut / CommTextOutW は切断中は何もしない
            guard let self = self, self.conn != nil else { return }
            switch chunk {
            case .binary(let b): self.sendBytes(b, echo: true)
            case .text(let t): self.macroSend(Array(t.utf8), mode: .text)
            }
        }
        sendFileJob = job
        setTalkQuiet(true)   // TalkStatus = IdTalkSendMem
        // 進み具合 (Windows 版の「ファイル送信」ダイアログにあたる)
        let panel = transferPanel ?? TransferProgressPanel()
        transferPanel = panel
        let name = (full as NSString).lastPathComponent
        panel.onCancel = { [weak job] in job?.finish() }
        let title = Lang.t("Tera Term", "DLG_FILETRANS_TITLE", "ファイル送信")
        let proto = binary ? title + " (" + Lang.t("Tera Term", "DLG_SENDFILE_BINARY", "バイナリ") + ")" : title
        if !transferExtra.ftHideDialog { panel.show(title: title, over: presentingWindow) }   // FTHideDialog
        panel.set(proto: proto, file: name, detail: Lang.m("MENU_BYTES_PROGRESS", "%d / %d バイト", 0, job.totalBytes), percent: 0)
        job.onProgress = { [weak panel] sent, total in
            panel?.set(proto: proto, file: name,
                       detail: Lang.m("MENU_BYTES_PROGRESS", "%d / %d バイト", sent, total), percent: total > 0 ? Double(sent) * 100 / Double(total) : 100)
        }
        job.onFinish = { [weak self, weak job] in
            guard let self = self else { done(); return }
            if self.sendFileJob === job {
                self.sendFileJob = nil
                self.setTalkQuiet(false)
                self.transferPanel?.close()
            }
            done()
        }
        job.start()
        return true
    }

    /// scp を進み具合のパネル付きで動かす (ドロップの SCP、マクロの scpsend / scprecv)
    @discardableResult
    func runScp(_ args: [String], label: String, file: String, done: @escaping (Bool) -> Void) -> Bool {
        let job = ScpJob(arguments: args)
        let panel = TransferProgressPanel()
        scpPanels.append(panel)
        let name = (file as NSString).lastPathComponent
        panel.onCancel = { [weak job] in job?.cancel() }
        job.onProgress = { [weak panel] f, pc, detail in
            panel?.set(proto: label, file: f.isEmpty ? name : f, detail: detail, percent: pc)
        }
        job.onFinish = { [weak self, weak panel] ok in
            panel?.close()
            self?.scpPanels.removeAll { $0 === panel }
            done(ok)
        }
        guard job.start() else { panel.close(); scpPanels.removeAll { $0 === panel }; return false }
        scpJobs.append(job)
        panel.show(title: label, over: presentingWindow)
        panel.set(proto: label, file: name, detail: Lang.m("MENU_CONNECTING", "接続しています…"), percent: nil)
        let originalDone = job.onFinish
        job.onFinish = { [weak self, weak job] ok in
            originalDone?(ok)
            self?.scpJobs.removeAll { $0 === job }
        }
        return true
    }

    /// dispstr (ttdde.c CmdDispStr: SendMemTextW, echo=TRUE, send=FALSE)。
    /// ローカルエコーと同じく端末を通すので、マクロの受信 (wait) とログにも入る。CR は送信の改行コードでエコーされる (ControlEcho)
    func macroDisplay(_ b: [UInt8]) {
        let text = String(decoding: b, as: UTF8.self)
        let nl: String
        switch settings.sendNewline {
        case "CRLF": nl = "\r\n"
        case "LF": nl = "\n"
        default: nl = "\r"
        }
        term.feed(text.replacingOccurrences(of: "\r", with: nl))
        termView.dataArrived()
    }

    func macroNotice(_ s: String) { notice(s) }

    /// ファイル転送を始める (filesys_proto.cpp の *Start*)。終わったら done(成功したか)。
    /// false: 始められなかった (転送中・sendfile 中・送信ファイルが開けない等。マクロの result は変えない)。
    /// 未接続でも Windows 版と同じく始める (cv.Ready = FALSE: 回線には何も出ず、プロトコルが自分で諦めるかキャンセルで 0)
    func startTransfer(_ kind: FileTransferKind, files: [String], binaryFlag: Int, xmodemOption: Int,
                       autoStopSec: Int? = nil, fromMacro: Bool = true,
                       done: @escaping (Bool) -> Void) -> Bool {
        // ProtoStart(): FileVar != NULL / FileSnedIsSending()
        guard transfer == nil, autoSendBuffer == nil, sendFileJob == nil else { return false }
        transferOptions.applyMacroParameters(kind: kind, binaryFlag: binaryFlag, xmodemOption: xmodemOption, autoStopSec: autoStopSec)
        if case .serial(let p)? = spec { transferOptions.isTCPIP = false; transferOptions.baudRate = p.baud } else { transferOptions.isTCPIP = true }
        let dir = FileTransferPaths.fileDirectory(transferOptions.fileDir)
        // 送信は他の送信と同じ conn.write (Telnet の IAC 二重化などは Connection 側)
        let t = FileTransfer(kind: kind, files: files, receiveDir: dir, options: transferOptions) { [weak self] b in
            // Tera Term の CommBinaryOut と同じく、転送データはバイナリとして書く (Telnet の CR NUL など)
            self?.conn?.write(b, binary: true)
        }
        t.isReady = connected
        t.showsMessages = !fromMacro   // マクロからは fv->NoMsg = TRUE
        t.onMessage = { [weak self] m in
            guard let self = self else { return }
            let a = NSAlert()
            a.messageText = Lang.t("Tera Term", "MSG_TT_ERROR", "Tera Term: Error")
            a.informativeText = m
            if let w = self.presentingWindow { a.beginSheetModal(for: w) } else { a.runModal() }
        }
        t.onProgress = { [weak self] p in self?.transferPanel?.update(p) }
        t.onFinish = { [weak self, weak t] ok in
            guard let self = self else { done(ok); return }
            if self.transfer === t { self.transfer = nil }
            self.endTransferUI()
            done(ok)
        }
        // 終わったあと読まれずに残った受信データは端末へ (feed の中で終わったときは received() が受け取る)
        t.onUnconsumedInput = { [weak self] b in self?.received(b) }
        transfer = t
        beginTransferUI(t)
        if !t.start() {
            // OpenProtoDlg 失敗 → ProtoEnd() (DdeCmnd 前なので result は変わらない)
            if transfer === t { transfer = nil }
            endTransferUI()
            return false
        }
        return true
    }

    /// 転送ダイアログの Cancel (ProtoDlgCancel)。プロトコルの中断手順のあと result 0
    func cancelTransfer() { transfer?.cancel() }
    @objc func cancelTransferMenu(_ sender: Any?) { cancelTransfer() }

    /// cv.DelayFlag = FALSE / TalkStatus = IdTalkQuiet と転送の進み具合のパネル
    private func beginTransferUI(_ t: FileTransfer) {
        setTalkQuiet(true)
        if let sc = conn as? SerialConnection, savedSerialDelay == nil {
            savedSerialDelay = (sc.charDelayMs, sc.lineDelayMs)
            sc.charDelayMs = 0
            sc.lineDelayMs = 0
        }
        let panel = transferPanel ?? TransferProgressPanel()
        transferPanel = panel
        panel.onCancel = { [weak self] in self?.cancelTransfer() }
        panel.show(title: SessionWindowController.transferTitle(t.kind), over: presentingWindow)
    }

    /// 転送ダイアログの題 (本家の FILEDLG_TRANS_TITLE_*)
    static func transferTitle(_ k: FileTransferKind) -> String {
        func tt(_ key: String, _ def: String) -> String { Lang.t("Tera Term", "FILEDLG_TRANS_TITLE_" + key, def) }
        switch k {
        case .kermitRecv: return tt("KMTRCV", "Kermit受信")
        case .kermitGet: return tt("KMTGET", "Kermit取得")
        case .kermitSend: return tt("KMTSEND", "Kermit送信")
        case .kermitFinish: return tt("KMTFIN", "Kermit終了")
        case .xmodemRecv: return tt("XRCV", "XMODEM受信")
        case .xmodemSend: return tt("XSEND", "XMODEM送信")
        case .ymodemRecv: return tt("YRCV", "YMODEM受信")
        case .ymodemSend: return tt("YSEND", "YMODEM送信")
        case .zmodemRecv, .zmodemAutoRecv: return tt("ZRCV", "ZMODEM受信")
        case .zmodemSend, .zmodemAutoSend: return tt("ZSEND", "ZMODEM送信")
        case .bplusRecv, .bplusAutoRecv: return tt("BPRCV", "B-Plus受信")
        case .bplusSend: return tt("BPSEND", "B-Plus送信")
        case .quickvanRecv: return tt("QVRCV", "Quick-VAN受信")
        case .quickvanSend: return tt("QVSEND", "Quick-VAN送信")
        case .rawRecv: return tt("RAWRCV", "ファイル受信中")
        }
    }

    /// ProtoEnd(): cv.DelayFlag = TRUE / TalkStatus = IdTalkKeyb
    private func endTransferUI() {
        if let d = savedSerialDelay {
            if let sc = conn as? SerialConnection { sc.charDelayMs = d.char; sc.lineDelayMs = d.line }
            savedSerialDelay = nil
        }
        transferPanel?.close()
        setTalkQuiet(false)
    }

    /// キーボード・貼り付けを止める / 戻す (TalkStatus)
    func setTalkQuiet(_ quiet: Bool) {
        if quiet {
            guard savedKeyHandlers == nil else { return }
            savedKeyHandlers = (termView.onSendText, termView.onSendBytes)
            termView.onSendText = { _ in }
            termView.onSendBytes = { _ in }
        } else {
            guard transfer == nil, sendFileJob == nil, let k = savedKeyHandlers else { return }
            termView.onSendText = k.text
            termView.onSendBytes = k.bytes
            savedKeyHandlers = nil
        }
    }

    /// 回線が切れた (cv.Ready = FALSE)。転送は Windows 版と同じくそのまま (Parse されなくなり、
    /// タイムアウトでプロトコルが諦めるかキャンセルで終わる)。sendfile の残りは送られずに終わる
    private func transferConnectionLost() {
        transfer?.isReady = false
        sendFileJob?.finish()
    }

    /// ZMODEM / B-Plus の自動起動 (vtterm.c CANSeen / DLESeen)
    private func startAutoTransfer(_ trig: TransferAutoStartScanner.Trigger, rest: [UInt8]) {
        func run(_ kind: FileTransferKind, files: [String], rest: [UInt8]) {
            if startTransfer(kind, files: files, binaryFlag: transferOptions.xmodemBin ? 1 : 0, xmodemOption: 0,
                             fromMacro: false, done: { _ in }), let t = transfer {
                let left = t.feed(rest)
                if !left.isEmpty { received(left) }
            } else if !rest.isEmpty {
                received(rest)
            }
        }
        switch trig {
        case .zmodemReceive: run(.zmodemAutoRecv, files: [], rest: rest)
        case .bplusReceive: run(.bplusAutoRecv, files: [], rest: rest)
        case .zmodemSend:
            // ZMODEMStartSend(NULL, 0, TRUE): 送るファイルを選ぶ。選ばなければ CAN x8 + BS x10 を送って終わり
            guard transfer == nil, sendFileJob == nil else { received(rest); return }
            autoSendBuffer = rest
            let p = NSOpenPanel()
            p.title = "Tera Term: ZMODEM Send"
            p.allowsMultipleSelection = true
            p.canChooseDirectories = false
            p.directoryURL = URL(fileURLWithPath: FileTransferPaths.fileDirectory(transferOptions.fileDir))
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
                guard let self = self else { return }
                let buffered = self.autoSendBuffer ?? []
                self.autoSendBuffer = nil
                if r == .OK, !p.urls.isEmpty {
                    run(.zmodemAutoSend, files: p.urls.map { $0.path }, rest: buffered)
                } else {
                    self.conn?.write([UInt8](repeating: 0x18, count: 8) + [UInt8](repeating: 0x08, count: 10))
                    if !buffered.isEmpty { self.received(buffered) }
                }
            }
            if let w = presentingWindow { p.beginSheetModal(for: w, completionHandler: finish) } else { finish(p.runModal()) }
        }
    }

    /// gettitle: ts.TitleW (settitle・/W= のタイトル。既定は TERATERM.INI の Title=Tera Term)。リモートのタイトルやウインドウの飾りは含まない
    var titleForMacro: String { localTitle }

    var hostnameForMacro: String {
        guard connected, let s = spec else { return "" }
        switch s {
        case .ssh(let h, _, _, _), .telnet(let h, _), .rawTCP(let h, _): return h
        case .serial(let p): return (p.path as NSString).lastPathComponent
        case .shell: return ""
        }
    }

    /// scpsend / scprecv の scp コマンドの引数 (SSH 接続のときだけ)
    func scpArguments(send: Bool, from: String, to: String) -> [String]? {
        guard connected, case .ssh(let uhost, let port, let user, let key)? = spec else { return nil }
        let host = IDN.hostNameToASCII(uhost)   // 接続と同じ ACE 形式 (#1493)
        var a = ["-o", "ControlPath=\(sshControlPath(host: host, port: port, user: user))", "-o", "BatchMode=yes"]
        if port != 22 { a += ["-P", String(port)] }
        if !key.isEmpty { a += ["-i", (key as NSString).expandingTildeInPath] }
        let remote = user.isEmpty ? host : "\(user)@\(host)"
        if send {
            a += [from, "\(remote):\(to)"]
        } else {
            let dest = to.isEmpty ? ((transferDir ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()) as NSString).appendingPathComponent((from as NSString).lastPathComponent) : to
            a += ["\(remote):\(from)", dest]
        }
        return a
    }

    /// callmenu: Tera Term のメニュー番号 (tt_res.h の ID_*)。Mac 版に同じ操作があるものだけ。
    /// TEK・マクロウインドウ・ヘルプなど Mac にないものは何もしない (Tera Term と同じく result は変えない)
    func macroCallMenu(_ id: Int) {
        let actions: [Int: () -> Void] = [
            50110: { self.newConnection(nil) }, 50003: { self.newConnection(nil) },
            50111: { self.duplicateSession(nil) }, 50010: { self.duplicateSession(nil) },
            50112: { SessionWindowController.openLocalShell(settings: self.settings) },   // Cygwin 接続 → ローカルシェル
            50120: { self.toggleLog(nil) }, 50125: { self.stopLog() }, 50124: { self.logPaused.toggle() },
            50122: { if let p = self.logPath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } },
            50123: { if let p = self.logPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } },
            50130: { self.sendFile(nil) },
            50190: { self.macroDisconnect(confirm: true) }, 50009: { self.macroDisconnect(confirm: true) },
            50199: { self.performCloseSession() }, 50005: { self.performCloseSession() },
            50200: { NSApp.terminate(nil) },
            50210: { self.termView.copy(nil) }, 50002: { self.termView.copy(nil) },
            50230: { self.termView.paste(nil) }, 50008: { self.termView.paste(nil) },
            50250: { self.clearScreen(nil) }, 50260: { self.clearBuffer(nil) },
            50280: { self.termView.selectAll(nil) }, 50290: { self.termView.selectAll(nil) },
            50310: { self.showTerminalSetup(nil) }, 50320: { self.showTerminalSetup(nil) }, 50330: { self.showTerminalSetup(nil) },
            50340: { self.showTerminalSetup(nil) }, 50370: { self.showTerminalSetup(nil) }, 50375: { self.showTerminalSetup(nil) },
            50350: { self.serialSetup(nil) }, 50360: { self.newConnection(nil) },
            50380: { self.settings.save() },
            50410: { self.resetTerminal(nil) }, 50411: { self.term.clearRemoteTitle(); self.updateTitle() },
            50420: { (self.conn as? TCPConnection)?.sendAreYouThere() },
            50430: { self.sendBreak(nil) }, 50001: { self.sendBreak(nil) },
            50440: { if case .serial? = self.spec, let s = self.spec { self.connect(s) } },
            50470: { self.runMacroMenu(nil) },
            50990: { NSApp.orderFrontStandardAboutPanel(nil) },
        ]
        if let f = actions[id] { f() } else { notice(Lang.m("MENU_CALLMENU_UNSUPPORTED", "callmenu %d には対応していません", id)) }
    }

    /// 新しいウインドウでローカルシェル
    static func openLocalShell(settings: TermSettings) {
        let c = SessionWindowController(settings: settings)
        c.showWindow(nil)
        c.connect(.shell)
    }

    /// restoresetup: TERATERM.INI を読み込んでこのウインドウに使う
    func macroRestoreSetup(_ path: String) {
        // 相対パスは設定フォルダから (本家 ttdde.c: GetFullPathW(ts.HomeDirW, …))
        let path = path.hasPrefix("/") ? path : ((AppPaths.setupDirectory as NSString).appendingPathComponent(path) as NSString).standardizingPath
        guard let d = FileManager.default.contents(atPath: path), let ini = IniFile(data: d) else { return }
        let r = TeraTermIniImport.read(ini, base: settings)
        applySettings(r.settings)
        // Tera Term と同じく転送の設定 (ts) も読み直す
        transferOptions = FileTransferOptions(ini: ini)
    }

    /// 利用者がマクロを止める。このウインドウにつながったマクロがなければ、ウインドウから離れた (unlink した) マクロを止める
    @objc func stopMacro(_ sender: Any?) {
        if let m = macro { m.cancel() } else { MacroRunner.unlinked.forEach { $0.cancel() } }
    }

    /// マクロがこのウインドウから離れた (終わった・unlink・closett・別のウインドウへ connect)。
    /// ttdde.c XTYP_DISCONNECT: logautoclose ならログを閉じる
    func macroDetached(_ m: MacroRunner) {
        guard macro === m else { return }
        macro = nil
        setStatus(nil)
        termView.keyboardEnabled = true
        if logAutoClose {
            stopLog()
            logAutoClose = false
        }
    }

    /// マクロが終わった
    func macroFinished(_ m: MacroRunner, error: String?) {
        guard macro === m else { return }
        macroDetached(m)
        if let e = error { notice(Lang.m("MENU_MACRO_STOPPED_ERROR", "マクロのエラーで止めました: %s", e)) } else { notice(Lang.m("MENU_MACRO_FINISHED", "マクロ終了")) }
    }

    /// disconnect (vtwin.cpp Disconnect): TCP (SSH を含む) で confirm なら「切断しますか?」(ConfirmDisconnect=on)
    func macroDisconnect(confirm: Bool) {
        guard conn != nil else { return }
        let tcp: Bool
        switch spec {
        case .ssh?, .telnet?, .rawTCP?: tcp = true
        default: tcp = false
        }
        if confirm && tcp && connected {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = Lang.t("Tera Term", "MSG_DISCONNECT_CONF", "切断しますか?")
            a.addButton(withTitle: Lang.t("Tera Term", "BTN_OK", "OK"))
            a.addButton(withTitle: Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"))
            a.buttons[1].keyEquivalent = "\u{1b}"
            a.window.initialFirstResponder = a.buttons[1]
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        disconnect()
    }

    /// マクロの statusbox / dispstr 用の小さな表示
    func setStatus(_ s: String?) {
        if s == nil || s!.isEmpty {
            statusLabel?.removeFromSuperview(); statusLabel = nil; return
        }
        if statusLabel == nil {
            let l = NSTextField(labelWithString: "")
            l.drawsBackground = true
            l.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9)
            l.font = NSFont.systemFont(ofSize: 12)
            termView.addSubview(l)
            statusLabel = l
        }
        statusLabel!.stringValue = " " + s! + " "
        statusLabel!.sizeToFit()
        statusLabel!.setFrameOrigin(NSPoint(x: termView.bounds.width - statusLabel!.frame.width - 8, y: 8))
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(disconnectSession(_:)), #selector(sendBreak(_:)), #selector(sendFile(_:)):
            return connected
        case #selector(reconnect(_:)):
            return spec != nil && !connected
        case #selector(cancelTransferMenu(_:)):
            return transfer != nil
        case #selector(stopMacro(_:)):
            return macro != nil || !MacroRunner.unlinked.isEmpty
        case #selector(runMacroMenu(_:)):
            return macro == nil
        default:
            if let r = validateMainMenuItem(item) { return r }
            if let r = validateLogMenuItem(item) { return r }
            if let r = validateTransferMenuItem(item) { return r }
            if let r = validateSetupMenuItem(item) { return r }
            return true
        }
    }

    // MARK: - ウインドウ

    /// OnClose: 接続中の TCP/IP で ConfirmDisconnect なら「切断しますか？」(キャンセルが既定)。シリアル・未接続は聞かない
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 分割中のウインドウの閉じるボタン: すべてのペインを閉じる (確認は 1 回)
        if let sp = tabSplit, sender === sp.hostWindow { return sp.windowShouldCloseAll() }
        if skipCloseConfirm { return true }
        guard connected, isTCPIP, confirmDisconnectSetting else { return true }
        return SessionWindowController.confirmDisconnect(sender)
    }

    func windowWillClose(_ notification: Notification) {
        // 分割のペインなら外す (残りが 1 つなら分割をやめる)
        tabSplit?.remove(self)
        replayTimer?.invalidate()
        pasteJob?.finish()
        // OnClose(): FileSendEnd(); ProtoEnd() → 転送中のマクロの result は 0
        transfer?.abort()
        sendFileJob?.finish()
        transferPanel?.close()
        // マクロは止めずにリンクだけ外す (Tera Term の DDE 切断。testlink 0・waitevent 2 になる)
        if let m = macro { m.sessionClosed() }
        serialReconnect.cancel()
        disconnect(silent: true)
        stopLog()
        SessionWindowController.all.removeAll { $0 === self }
    }

    func windowDidResize(_ notification: Notification) { updateTitle() }

    /// タイトルバーのドラッグが始まった: 引き出したウインドウなら、元のウインドウに寄せたらタブに戻す (TabTearOff)
    func windowWillMove(_ notification: Notification) { if TTMado.isEnabled { TabTearOff.dragBegan(self) } }

    /// ドラッグで大きさを変え終わった: 最後の大きさだけ相手に知らせる
    func windowDidEndLiveResize(_ notification: Notification) {
        if let sp = tabSplit { sp.flushResizes(); return }
        if let (c, r) = pendingResize {
            pendingResize = nil
            conn?.resize(cols: c, rows: r)
        }
    }
}
