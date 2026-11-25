// ログのダイアログ (logdlg.cpp IDD_LOGDLG / ftdlg.cpp IDD_FILETRANSDLG (ログ記録中) / commentdlg.cpp)
// (Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project, BSD 3-Clause)

import AppKit
import TeraCore

// MARK: - ログの設定 (ts.LogBinary など)。TermSettings (設定画面のログのタブ) と同じ値を使う

struct LogDefaults {
    var binary = false              // LogBinary
    var append = false              // LogAppend
    var plainText = false           // LogTypePlainText
    var timestamp = false           // LogTimestamp
    var timestampType = 0           // LogTimestampType 0 ローカル 1 UTC 2 経過(Logging) 3 経過(Connection)
    /// "Logging" ダイアログ 0 非表示 1 最小化 2 表示 (LogHideDialog / LogDialogShowState, 23aa80682 #1576)
    var dialogShowState = 1
    var includeScreenBuffer = false // LogIncludeScreenBuffer (LogAllBuffIncludedInFirst)
    var defaultName = "teraterm.log" // LogDefaultName

    /// LogTimestampType の INI の値 (Local / UTC / LoggingElapsed / ConnectionElapsed。空はローカル)
    static let timestampTypeNames = ["Local", "UTC", "LoggingElapsed", "ConnectionElapsed"]
    static func timestampIndex(_ s: String) -> Int {
        timestampTypeNames.firstIndex { $0.caseInsensitiveCompare(s) == .orderedSame } ?? 0
    }

    static func load(_ s: TermSettings) -> LogDefaults {
        var v = LogDefaults()
        v.binary = s.logBinary
        v.append = s.logAppend
        v.plainText = s.logTypePlainText
        v.timestamp = s.logTimestamp
        v.timestampType = timestampIndex(s.logTimestampType)
        v.dialogShowState = s.logShowState
        v.includeScreenBuffer = s.logIncludeScreenBuffer
        if !s.logDefaultName.isEmpty { v.defaultName = s.logDefaultName }
        return v
    }

    /// ts に書き戻す (SetLogFlags)。次に開くウインドウも同じになるよう、そのキーだけ保存する
    func store(into s: inout TermSettings) {
        s.logBinary = binary
        s.logAppend = append
        s.logTypePlainText = plainText
        s.logTimestamp = timestamp
        s.logTimestampType = LogDefaults.timestampTypeNames[max(0, min(3, timestampType))]
        s.logShowState = dialogShowState
        s.logIncludeScreenBuffer = includeScreenBuffer
        let d = UserDefaults.standard
        d.set(binary, forKey: "LogBinary")
        d.set(append, forKey: "LogAppend")
        d.set(plainText, forKey: "LogTypePlainText")
        d.set(timestamp, forKey: "logTimestamp")
        d.set(s.logTimestampType, forKey: "LogTimestampType")
        d.set(s.logHideDialog, forKey: "LogHideDialog")
        d.set(s.logDialogShowState, forKey: "LogDialogShowState")
        d.set(includeScreenBuffer, forKey: "LogIncludeScreenBuffer")
    }

    /// FLogOpen に渡すオプション
    var options: TTLLogOptions {
        var o = TTLLogOptions()
        o.binary = binary
        o.append = append
        o.plainText = plainText
        o.timestamp = timestamp
        o.timestampType = timestampType
        o.dialogShowState = dialogShowState
        o.includeScreenBuffer = includeScreenBuffer
        return o
    }
}

/// ダイアログを閉じたときの結果 (FLogDlgInfo_t)
struct LogDialogResult {
    var path: String
    var append: Bool
    var bom: Bool
    var code: TeraLog.Code
    var options: TTLLogOptions
}

// MARK: - ログ (IDD_LOGDLG)

/// ファイルをドロップできる土台 (WM_DROPFILES)
private final class LogDropView: NSView {
    var onDrop: ((String) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // 複数ドロップされても最初の1つだけを扱う
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first else { return false }
        onDrop?(u.path)
        return true
    }
}

final class LogDialog: SheetDialog, NSComboBoxDelegate {
    /// DLG_FOPT_LOGGINGDIALOG_HIDDEN / _MINIMIZED / _NORMAL (log_pp.cpp / logdlg.cpp loggingdialog_list)
    static var showStateTitles: [String] {
        [Lang.m("MISC_LOGGINGDIALOG_HIDDEN", "非表示"),
         Lang.m("MISC_LOGGINGDIALOG_MINIMIZED", "最小化"),
         Lang.m("MISC_LOGGINGDIALOG_NORMAL", "表示")]
    }
    /// ファイル名の履歴 (HistoryStoreCreate(20))。保存はしない
    private static var history: [String] = []

    private weak var session: SessionWindowController?
    private var defaults = LogDefaults()
    private var completion: ((LogDialogResult?) -> Void)?

    private let nameCombo = NSComboBox()
    private let browseButton = NSButton(title: "...", target: nil, action: nil)
    private let newRadio = NSButton(radioButtonWithTitle: Lang.t("Tera Term", "DLG_FOPT_NEW_OVERWRITE", "新規/上書き"), target: nil, action: nil)
    private let appendRadio = NSButton(radioButtonWithTitle: Lang.t("Tera Term", "DLG_FOPT_APPEND", "追記"), target: nil, action: nil)
    private let textRadio = NSButton(radioButtonWithTitle: Lang.t("Tera Term", "DLG_FOPT_TEXT", "テキスト"), target: nil, action: nil)
    private let binRadio = NSButton(radioButtonWithTitle: Lang.t("Tera Term", "DLG_FOPT_BINARY", "バイナリ"), target: nil, action: nil)
    private let bomCheck = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_FOPT_BOM", "BOM"), target: nil, action: nil)
    private let codePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let plainCheck = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_FOPT_PLAIN", "プレーンテキスト"), target: nil, action: nil)
    private let timestampCheck = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_FOPT_TIMESTAMP", "タイムスタンプ"), target: nil, action: nil)
    private let timestampPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// IDC_LOGGINGDIALOG_DROPDOWN (Hide dialog のチェックボックスから変わった。23aa80682 #1576)
    private let showStatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let includeCheck = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_FOPT_ALLBUFFINFIRST", "現在バッファを含む"), target: nil, action: nil)

    // work
    private var fileExist = false
    private var currentBOM = 0        // 0 なし 1 UTF-8 2 UTF-16LE 3 UTF-16BE
    private var timer: Timer?         // 1 秒ごとに既定の名前を入れ直す
    private var onInitDialog = false
    private var eventMonitor: Any?

    init(session: SessionWindowController) {
        self.session = session
        super.init()
        defaults = LogDefaults.load(session.settings)
        build()
    }

    func begin(on w: NSWindow, completion: @escaping (LogDialogResult?) -> Void) {
        self.completion = completion
        present(on: w)
        panel.makeFirstResponder(nameCombo)
        nameCombo.currentEditor()?.selectAll(nil)
        // 1 秒ごとに既定の名前 (strftime などを展開したもの) を入れ直す。名前に触ったら止める
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.timerFired() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // FNameEditProc: キーを押す・クリックする・フォーカスが移るとタイマーを止める
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self = self, e.window === self.panel { self.stopTimer() }
            return e
        }
    }

    // MARK: 作る

    private func build() {
        panel.title = Lang.t("Tera Term", "DLG_FOPT_TITLE", "ログ")

        let nameLabel = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_FOPT_FILENAME_TITLE", "ログファイル名(dialogにファイルをドロップ)"))
        nameCombo.translatesAutoresizingMaskIntoConstraints = false
        nameCombo.widthAnchor.constraint(equalToConstant: 380).isActive = true
        nameCombo.completes = false
        nameCombo.numberOfVisibleItems = 20
        nameCombo.addItems(withObjectValues: LogDialog.history)
        nameCombo.delegate = self
        browseButton.target = self; browseButton.action = #selector(browse)
        let nameRow = NSStackView(views: [nameCombo, browseButton])
        nameRow.spacing = 6

        for b in [newRadio, appendRadio, textRadio, binRadio, timestampCheck] {
            b.target = self; b.action = #selector(arrange(_:))
        }
        codePopup.addItems(withTitles: ["UTF-8", "UTF-16LE", "UTF-16BE"])
        timestampPopup.addItems(withTitles: [
            Lang.t("Tera Term", "DLG_FOPT_TIMESTAMP_LOCAL", "ローカルタイム"),
            Lang.t("Tera Term", "DLG_FOPT_TIMESTAMP_UTC", "UTC"),
            Lang.t("Tera Term", "DLG_FOPT_TIMESTAMP_ELAPSED_LOGGING", "経過時間(Logging)"),
            Lang.t("Tera Term", "DLG_FOPT_TIMESTAMP_ELAPSED_CONNECTION", "経過時間(Connection)"),
        ])

        func box(_ title: String, _ views: [NSView]) -> NSBox {
            let b = NSBox()
            b.title = title
            let st = NSStackView(views: views)
            st.orientation = .vertical
            st.alignment = .leading
            st.spacing = 6
            // contentView は自動レイアウトで大きさが決まらず、中身が潰れて見えなくなる。箱そのものに載せて四辺を留める
            b.translatesAutoresizingMaskIntoConstraints = false
            st.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(st)
            NSLayoutConstraint.activate([
                st.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 12),
                st.trailingAnchor.constraint(lessThanOrEqualTo: b.trailingAnchor, constant: -12),
                st.topAnchor.constraint(equalTo: b.topAnchor, constant: 22),
                st.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -10),
            ])
            return b
        }
        func indent(_ views: [NSView]) -> NSView {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let st = NSStackView(views: [spacer] + views)
            st.spacing = 8
            return st
        }

        let modeBox = box(Lang.t("Tera Term", "DLG_FOPT_APPEND_LABEL", "書き込みモード"), [newRadio, appendRadio])
        let typeBox = box(Lang.t("Tera Term", "DLG_FOPT_BINARY_LABEL", "テキスト/バイナリモード"), [
            textRadio,
            indent([bomCheck, codePopup]),
            indent([plainCheck]),
            indent([timestampCheck, timestampPopup]),
            binRadio,
        ])
        let boxes = NSStackView(views: [modeBox, typeBox])
        boxes.alignment = .top
        boxes.spacing = 12

        // LTEXT "Logging &dialog state" の下に字下げしたドロップダウン (filesys_log.rc)
        showStatePopup.addItems(withTitles: LogDialog.showStateTitles)
        let showStateLabel = NSTextField(labelWithString: Lang.m("MISC_LOGGINGDIALOG", "ログ記録中ダイアログ"))
        let body = NSStackView(views: [nameLabel, nameRow, boxes, showStateLabel, indent([showStatePopup]), includeCheck])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        layout(body)

        // ファイルのドロップを受ける
        if let old = panel.contentView {
            let drop = LogDropView(frame: NSRect(origin: .zero, size: old.frame.size))
            old.frame = drop.bounds
            old.autoresizingMask = [.width, .height]
            panel.contentView = drop
            drop.addSubview(old)
            drop.onDrop = { [weak self] p in self?.dropped(p) }
        }

        // WM_INITDIALOG
        onInitDialog = true
        codePopup.selectItem(at: 0)
        setMode(append: defaults.append)
        timestampCheck.state = defaults.timestamp ? .on : .off
        timestampPopup.selectItem(at: defaults.timestampType)
        plainCheck.state = defaults.plainText ? .on : .off
        showStatePopup.selectItem(at: max(0, min(2, defaults.dialogShowState)))
        includeCheck.state = defaults.includeScreenBuffer ? .on : .off
        bomCheck.state = .off   // BOM は毎回 off
        setBinary(defaults.binary)
        let fname = defaultFileName()
        nameCombo.stringValue = fname
        arrangeFilename(fname)
        onInitDialog = false
    }

    /// FLogGetLogFilename(NULL)
    private func defaultFileName() -> String {
        guard let s = session else { return defaults.defaultName }
        let (h, p) = s.logHostAndPort
        return TeraLog.logFileName(defaults.defaultName, logDir: s.logDirectory, host: h, port: p)
    }

    /// 入力された名前 (そのまま使う。相対パスはログのフォルダから)
    private func resolve(_ name: String) -> String {
        let n = (name as NSString).expandingTildeInPath
        if n.isEmpty || n.hasPrefix("/") { return n }
        return ((session?.logDirectory ?? NSHomeDirectory()) as NSString).appendingPathComponent(n)
    }

    private func setMode(append: Bool) {
        newRadio.state = append ? .off : .on
        appendRadio.state = append ? .on : .off
    }

    private func setBinary(_ bin: Bool) {
        textRadio.state = bin ? .off : .on
        binRadio.state = bin ? .on : .off
    }

    // MARK: CheckLogFile / ArrangeControls

    private func checkLogFile(_ path: String) {
        var isDir: ObjCBool = false
        fileExist = !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        currentBOM = 0
        guard fileExist, let h = FileHandle(forReadingAtPath: path) else { return }
        let b = [UInt8](h.readData(ofLength: 4))
        h.closeFile()
        if b.count < 2 { currentBOM = 0 }
        else if b[0] == 0xFF && b[1] == 0xFE { currentBOM = 2 }
        else if b[0] == 0xFE && b[1] == 0xFF { currentBOM = 3 }
        else if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { currentBOM = 1 }
    }

    @objc private func arrange(_ sender: NSButton?) {
        // ラジオボタンは別の箱にあるので自分で切り替える
        if sender === newRadio { setMode(append: false) }
        if sender === appendRadio { setMode(append: true) }
        if sender === textRadio { setBinary(false) }
        if sender === binRadio { setBinary(true) }
        arrangeControls()
    }

    private func arrangeControls() {
        appendRadio.isEnabled = fileExist
        let binary = binRadio.state == .on
        let newOverwrite = newRadio.state == .on
        // BOM, Encoding: Text かつ New/Overwrite の場合に Enable
        bomCheck.isEnabled = !binary && newOverwrite
        codePopup.isEnabled = !binary && newOverwrite
        // Plain Text, Timestamp, Timestamp 種別
        plainCheck.isEnabled = !binary
        timestampCheck.isEnabled = !binary
        timestampPopup.isEnabled = !binary && timestampCheck.state == .on
        if fileExist && !newOverwrite {
            // 既存ファイルのエンコーディングを反映する
            codePopup.selectItem(at: currentBOM == 2 ? 1 : currentBOM == 3 ? 2 : 0)
        }
    }

    private func arrangeFilename(_ name: String) {
        let prev = fileExist
        checkLogFile(resolve(name))
        if onInitDialog || prev != fileExist {
            // ファイルが存在する: 設定に合わせて新規(上書き)/追記。存在しない: 新規
            setMode(append: fileExist && defaults.append)
            arrangeControls()
        }
    }

    // MARK: 名前の欄

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func timerFired() {
        guard timer != nil else { return }
        let fname = defaultFileName()
        if nameCombo.stringValue != fname {
            nameCombo.stringValue = fname
        }
        nameCombo.currentEditor()?.selectAll(nil)
        arrangeFilename(fname)
    }

    func controlTextDidChange(_ obj: Notification) {
        arrangeFilename(nameCombo.stringValue)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        let i = nameCombo.indexOfSelectedItem
        guard i >= 0, let s = nameCombo.itemObjectValue(at: i) as? String else { return }
        arrangeFilename(s)
    }

    func comboBoxWillPopUp(_ notification: Notification) { stopTimer() }   // CBN_DROPDOWN

    private func dropped(_ path: String) {
        stopTimer()
        setMode(append: true)
        nameCombo.stringValue = path
        panel.makeFirstResponder(nameCombo)
        nameCombo.currentEditor()?.selectAll(nil)
        arrangeFilename(path)
    }

    /// 「...」: 保存ダイアログ
    @objc private func browse() {
        stopTimer()
        let sp = NSSavePanel()
        sp.title = "Tera Term: " + Lang.t("Tera Term", "DLG_FOPT_TITLE", "ログ")
        sp.canCreateDirectories = true
        sp.allowsOtherFileTypes = true
        let filterKeeper = FilePanelFilter.attach(to: sp, mask: "*.txt;*.log")
        let cur = resolve(nameCombo.stringValue)
        sp.directoryURL = URL(fileURLWithPath: session?.logDirectory ?? NSHomeDirectory(), isDirectory: true)
        sp.nameFieldStringValue = (cur as NSString).lastPathComponent
        sp.beginSheetModal(for: panel) { [weak self] r in
            _ = filterKeeper
            guard let self = self, r == .OK, let u = sp.url else { return }
            self.nameCombo.stringValue = u.path
            self.arrangeFilename(u.path)
        }
    }

    // MARK: OK / キャンセル

    private func finish(_ r: LogDialogResult?) {
        stopTimer()
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        close()
        let c = completion
        completion = nil
        c?(r)
    }

    override func ok() {
        let name = nameCombo.stringValue
        let path = resolve(name)
        // SetLogFlags: ダイアログの内容を ts に書き戻し
        let binary = binRadio.state == .on
        defaults.binary = binary
        defaults.append = appendRadio.state == .on
        if !binary {
            defaults.plainText = plainCheck.state == .on
            defaults.timestamp = timestampCheck.state == .on
        }
        defaults.dialogShowState = max(0, showStatePopup.indexOfSelectedItem)
        defaults.includeScreenBuffer = includeCheck.state == .on
        defaults.timestampType = max(0, timestampPopup.indexOfSelectedItem)
        if let ss = session { defaults.store(into: &ss.settings) }
        let o = defaults.options

        // HistoryStoreAddTop
        LogDialog.history.removeAll { $0 == name }
        LogDialog.history.insert(name, at: 0)
        if LogDialog.history.count > 20 { LogDialog.history.removeLast(LogDialog.history.count - 20) }

        finish(LogDialogResult(path: path, append: defaults.append, bom: bomCheck.state == .on,
                               code: TeraLog.Code(rawValue: max(0, codePopup.indexOfSelectedItem)) ?? .utf8,
                               options: o))
    }

    override func cancel() { finish(nil) }
}

// MARK: - ログ記録中 (IDD_FILETRANSDLG, OpLog)

final class LogProgressWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private weak var session: SessionWindowController?
    private let fileNameField = NSTextField(labelWithString: "")
    private let fullPathField = NSTextField(labelWithString: "")
    private let bytesField = NSTextField(labelWithString: "0")
    private let pauseButton = NSButton(title: Lang.t("Tera Term", "DLG_FILETRANS_PAUSE", "一時停止"), target: nil, action: nil)
    private var timer: Timer?

    init(session: SessionWindowController, path: String) {
        self.session = session
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Tera Term: " + Lang.t("Tera Term", "FILEDLG_TRANS_TITLE_LOG", "ログ記録中")
        window.isReleasedWhenClosed = false
        window.delegate = self

        fileNameField.stringValue = (path as NSString).lastPathComponent
        fullPathField.stringValue = path
        fullPathField.isSelectable = true
        fullPathField.lineBreakMode = .byTruncatingMiddle
        fullPathField.translatesAutoresizingMaskIntoConstraints = false
        fullPathField.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: Lang.t("Tera Term", "DLG_FILETRANS_FILENAME", "ファイル名:")), fileNameField],
            [NSTextField(labelWithString: Lang.t("Tera Term", "DLG_FILETRANS_FULLPATH", "フルパス:")), fullPathField],
            [NSTextField(labelWithString: Lang.t("Tera Term", "DLG_FILETRANS_TRNAS", "転送済容量:")), bytesField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6

        let hide = NSButton(title: Lang.t("Tera Term", "DLG_FOPT_HIDEDIALOG", "ダイアログを非表示"), target: self, action: #selector(hideDialog))
        let closeB = NSButton(title: Lang.t("Tera Term", "DLG_FILETRANS_CLOSE", "閉じる"), target: self, action: #selector(closeLog))
        pauseButton.target = self; pauseButton.action = #selector(togglePause)
        let buttons = NSStackView(views: [hide, NSView(), closeB, pauseButton])
        buttons.spacing = 8

        let root = NSStackView(views: [grid, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
        ])
        window.contentView = container
        window.setContentSize(container.fittingSize)
        window.center()

        refresh()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 転送済容量と 一時停止/再開 を今の状態にする (RefreshNum / ChangeButton)
    func refresh() {
        guard let l = session?.teraLog else { return }
        bytesField.stringValue = "\(l.byteCount)"
        pauseButton.title = l.paused ? Lang.t("Tera Term", "DLG_FILETRANS_START", "再開") : Lang.t("Tera Term", "DLG_FILETRANS_PAUSE", "一時停止")
    }

    /// CFileTransDlg::Create: 非表示なら作るだけ。最小化なら表示してすぐ最小化、通常なら通常サイズで表示 (23aa80682 #1576)
    func start(showState: Int) {
        guard showState != 0 else { return }
        window.orderFront(nil)
        if showState == 1 { window.miniaturize(nil) }
    }

    /// FLogShowDlg: 通常の大きさで前に出す (非表示にしていても)
    func showNormal() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window.delegate = nil
        window.close()
    }

    @objc private func hideDialog() { window.orderOut(nil) }

    /// 閉じる (IDCANCEL): ログを止める
    @objc private func closeLog() { session?.stopLog() }

    @objc private func togglePause() {
        guard let s = session, s.teraLog != nil else { return }
        s.logPaused.toggle()
        refresh()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeLog()   // タイトルバーの閉じるボタンも IDCANCEL
        return false
    }
}

// MARK: - ログにコメントを付加 (IDD_COMMENT_DIALOG)

private final class CommentPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class CommentDialog: NSObject, NSWindowDelegate {
    private let panel: CommentPanel
    private let field = NSTextField(string: "")
    private weak var parentWindow: NSWindow?
    private var completion: ((String?) -> Void)?
    private var retainSelf: CommentDialog?

    override init() {
        panel = CommentPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 90),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = Lang.t("Tera Term", "DLG_COMMENT_TITLE", "ログにコメントを付加")
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(nil) }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        field.target = self; field.action = #selector(ok)
        let okB = NSButton(title: Lang.t("Tera Term", "BTN_OK", "OK"), target: self, action: #selector(ok))

        okB.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), okB])
        let root = NSStackView(views: [field, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
        ])
        panel.contentView = container
        panel.setContentSize(container.fittingSize)
    }

    /// OK なら入力した文字列、閉じたら nil
    func begin(on w: NSWindow, completion: @escaping (String?) -> Void) {
        self.completion = completion
        parentWindow = w
        retainSelf = self
        w.beginSheet(panel, completionHandler: nil)
        panel.makeFirstResponder(field)
    }

    private func finish(_ s: String?) {
        guard let c = completion else { return }
        completion = nil
        parentWindow?.endSheet(panel)
        panel.orderOut(nil)
        retainSelf = nil
        c(s)
    }

    @objc private func ok() { finish(field.stringValue) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(nil)
        return false
    }
}

// MARK: - 確認用 (TERAMAC_GUIDESNAP: かんたんマニュアルの画面写真)

extension LogDialog {
    /// ファイル名の欄を例の名前にする (1 秒ごとの入れ直しも止める)
    func debugGuideFill(_ path: String) {
        stopTimer()
        nameCombo.stringValue = path
        arrangeFilename(path)
    }
}
