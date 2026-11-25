// ファイル送信・ファイル受信・転送 (Kermit / XMODEM / YMODEM / ZMODEM / B-Plus / Quick-VAN)・SSH SCP のダイアログ
// 元のコード: teraterm/teraterm/sendfiledlg.cpp, recvfiledlg.cpp, filesys_proto.cpp (_GetXFname / _GetMultiFname /
// _GetTransFname / GetFnDlg), ttssh2/ttxssh/ttxssh.c (TTXScpDialog)
// Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project (BSD 3-Clause)
//
// Windows のコモンダイアログ (GetOpenFileName / GetSaveFileName) は NSOpenPanel / NSSavePanel にして、
// 埋め込みのオプション (IDD_XOPT / IDD_FOPT) はパネルの accessoryView にしている。

import AppKit
import ObjectiveC
import TeraCore

// MARK: - ts のうち FileTransferOptions / DropSettings にないもの

/// TERATERM.INI の [Tera Term] から読む送受信の設定 (ts.SendfileSequential など)。
/// Tera Term の ts と同じくウインドウ (プロセス) ごとに持ち、ダイアログの結果で書き換わる
final class TransferExtraSettings {
    /// SendfileSequential=off
    var sendfileSequential = false
    /// SendfileSkipOptionDialog=off
    var sendfileSkipOptionDialog = false
    /// ReceivefileSkipOptionDialog=off
    var receivefileSkipOptionDialog = false
    /// FileSendFilter= (ワイルドカードでないファイル名なら送信ダイアログに最初から入れる)
    var fileSendFilter = ""
    /// FileReceiveFilter=
    var fileReceiveFilter = ""
    /// FTHideDialog=off: ファイル送信の進み具合のダイアログを出さない
    var ftHideDialog = false
    /// FileSendHighSpeedMode=on: シリアル 115200bps 以上のシーケンシャルのバイナリ送信を大きなまとまりで送る
    var fileSendHighSpeedMode = true

    static func load() -> TransferExtraSettings {
        let s = TransferExtraSettings()
        if let p = FileTransferOptions.loadTeraTermIni().path, let d = FileManager.default.contents(atPath: p),
           let ini = IniFile(data: d) {
            let sec = "Tera Term"
            s.sendfileSequential = ini.onOff(sec, "SendfileSequential") ?? false
            s.sendfileSkipOptionDialog = ini.onOff(sec, "SendfileSkipOptionDialog") ?? false
            s.receivefileSkipOptionDialog = ini.onOff(sec, "ReceivefileSkipOptionDialog") ?? false
            s.fileSendFilter = ini.string(sec, "FileSendFilter") ?? ""
            s.fileReceiveFilter = ini.string(sec, "FileReceiveFilter") ?? ""
            s.ftHideDialog = ini.onOff(sec, "FTHideDialog") ?? false
            s.fileSendHighSpeedMode = ini.onOff(sec, "FileSendHighSpeedMode") ?? true
        }
        // 設定画面で保存したもの (UserDefaults のキーは INI と同じ) があればそちら
        let d = UserDefaults.standard
        if let v = d.string(forKey: "FileSendFilter") { s.fileSendFilter = v }
        if let v = d.string(forKey: "FileReceiveFilter") { s.fileReceiveFilter = v }
        if d.object(forKey: "FTHideDialog") != nil { s.ftHideDialog = d.bool(forKey: "FTHideDialog") }
        if d.object(forKey: "FileSendHighSpeedMode") != nil { s.fileSendHighSpeedMode = d.bool(forKey: "FileSendHighSpeedMode") }
        return s
    }
}

// MARK: - 共通の部品

private var filePanelFilterKey: UInt8 = 0

/// ファイルのパネルのフィルタ (GetCommonDialogFilterWW): 「ユーザ定義(*.txt;*.log)」と「すべてのファイル(*.*)」を選べる。
/// 合わないファイルは選べない (灰色)。パネルが持つ (objc の関連付け) ので、呼んだ側で持っておかなくてよい
final class FilePanelFilter: NSObject, NSOpenSavePanelDelegate {
    let filter: FileDialogFilter
    private var all = false
    private weak var panel: NSSavePanel?

    private init(filter: FileDialogFilter, panel: NSSavePanel) {
        self.filter = filter
        self.panel = panel
    }

    /// mask が空なら何もしない。いまの accessoryView (転送のオプション) はフィルタの下に残す
    @discardableResult
    static func attach(to p: NSSavePanel, mask: String) -> FilePanelFilter? {
        let f = FileDialogFilter(mask)
        guard !f.isEmpty else { return nil }
        let k = FilePanelFilter(filter: f, panel: p)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: [f.userFilterName, FileDialogFilter.allFilterName])
        popup.target = k
        popup.action = #selector(changed(_:))
        let row = NSStackView(views: [NSTextField(labelWithString: Lang.m("XFER_FILE_TYPE", "ファイルの種類:")), popup])
        row.spacing = 6
        var views: [NSView] = [row]
        if let old = p.accessoryView {
            old.translatesAutoresizingMaskIntoConstraints = false
            old.widthAnchor.constraint(equalToConstant: old.frame.width).isActive = true
            old.heightAnchor.constraint(equalToConstant: old.frame.height).isActive = true
            views.append(old)
        }
        let st = NSStackView(views: views)
        st.orientation = .vertical
        st.alignment = .centerX
        st.spacing = 6
        st.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        st.frame = NSRect(origin: .zero, size: st.fittingSize)
        p.accessoryView = st
        if let op = p as? NSOpenPanel { op.isAccessoryViewDisclosed = true }
        p.delegate = k
        objc_setAssociatedObject(p, &filePanelFilterKey, k, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return k
    }

    @objc private func changed(_ sender: NSPopUpButton) {
        all = sender.indexOfSelectedItem == 1
        panel?.validateVisibleColumns()
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if all { return true }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return true }
        return filter.matches(url.lastPathComponent)
    }
}

private var pendingFilterMaskKey: UInt8 = 0

/// ファイルをドロップできるダイアログの中身 (WM_DROPFILES: 最初の 1 つだけ)
final class FileDropContentView: NSView {
    var onDrop: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func firstPath(_ info: NSDraggingInfo) -> String? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first?.path
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop != nil && firstPath(sender) != nil ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let p = firstPath(sender) else { return false }
        onDrop?(p)
        return true
    }
}

/// フォーカスを受けたら知らせる入力欄 (SCP ダイアログの既定ボタンの切り替え: EN_SETFOCUS → DM_SETDEFID)
final class FocusReportingTextField: NSTextField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { onFocus?() }
        return r
    }
}

/// 数字だけの入力欄 (ES_NUMBER / EM_LIMITTEXT)
final class DigitsFormatter: Formatter {
    var maxLength = 10
    override func string(for obj: Any?) -> String? { obj.map { "\($0)" } }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return true
    }
    override func isPartialStringValid(_ partial: String, newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        partial.count <= maxLength && partial.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// GetDlgItemInt(..., FALSE): 先頭の数字を読む。読めなければ 0
func transferDialogInt(_ s: String) -> Int {
    let digits = s.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isNumber }
    return Int(digits.prefix(10)) ?? 0
}

/// 「Tera Term: エラー」「ファイルが開けません」 (MSG_TT_ERROR / MSG_CANTOPEN_FILE_ERROR)
func showCantOpenFileError(over w: NSWindow?) {
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = Lang.t("Tera Term", "MSG_TT_ERROR", "Tera Term: エラー")
    a.informativeText = Lang.t("Tera Term", "MSG_CANTOPEN_FILE_ERROR", "ファイルが開けません")
    a.addButton(withTitle: Lang.t("Tera Term", "BTN_OK", "OK"))
    a.runModal()
}

/// モーダルのダイアログの土台 (DialogBoxParam)。run() は OK で true
class TransferModalDialog: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let content = FileDropContentView(frame: .zero)
    private var accepted = false

    init(title: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    /// root を中身にしてパネルの大きさを合わせる
    func setBody(_ root: NSView) {
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    func run(over parent: NSWindow?) -> Bool {
        if let w = parent {
            let f = w.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.midY - panel.frame.height / 2 + 40))
        } else {
            panel.center()
        }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return accepted
    }

    func endDialog(_ ok: Bool) {
        accepted = ok
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === panel { NSApp.stopModal() }
    }

    func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    /// OK / キャンセル の行 (右寄せ)
    func okCancelRow(ok: NSButton, cancel: NSButton) -> NSStackView {
        ok.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1B}"
        let s = NSStackView(views: [NSView(), cancel, ok])
        s.orientation = .horizontal
        return s
    }

    static func indent(_ v: NSView, by left: CGFloat = 18) -> NSStackView {
        let s = NSStackView(views: [v])
        s.edgeInsets = NSEdgeInsets(top: 0, left: left, bottom: 0, right: 0)
        return s
    }
}

/// 20 個までの履歴 (HistoryStore: 先頭に追加し、同じものは前のを消す)。プロセス (アプリ) 全体で 1 つ
struct TransferHistory {
    private(set) var items: [String] = []
    mutating func addTop(_ s: String) {
        guard !s.isEmpty else { return }
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
        if items.count > 20 { items.removeLast(items.count - 20) }
    }
}

// MARK: - ファイル送信 (IDD_SENDFILEDLG)

final class SendFileDialog: TransferModalDialog {
    struct Values {
        var filename = ""
        var binary = false
        /// 0=no delay 1=per character 2=per line 3=per sendsize
        var delayType = 0
        var delayTick = 0
        var sendSize = 4096
        var sequential = false
    }

    static var history = TransferHistory()

    private var values: Values
    private let initialDir: String
    private let resolveDir: String
    private let filenameCombo = NSComboBox()
    private let bulkRadio = NSButton(radioButtonWithTitle: Lang.t("Tera Term", "DLG_SENDFILE_READING_METHOD_BULK", "バルク(一括)読み込み"), target: nil, action: nil)
    private let seqRadio = NSButton(radioButtonWithTitle: Lang.t("Tera Term", "DLG_SENDFILE_READING_METHOD_SEQUENTIAL", "シーケンシャル(逐次)読み込み"), target: nil, action: nil)
    private let binaryCheck = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_SENDFILE_BINARY", "バイナリ"), target: nil, action: nil)
    private let delayTypeLabel = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_SENDFILE_DELAYTYPE_TITLE", "Delay type"))
    private let delayTypePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sendSizeLabel = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_SENDFILE_SEND_SIZE_TITLE", "Send size(bytes)"))
    private let sendSizeCombo = NSComboBox()
    private let delayTimeLabel = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_SENDFILE_DELAYTIME_TITLE", "Delay time(ms)"))
    private let delayTimeField = NSTextField(string: "")

    /// - Parameters:
    ///   - initialDir: 「...」の最初のフォルダ (GetFileDir)
    init(values: Values, initialDir: String) {
        self.values = values
        self.initialDir = initialDir
        self.resolveDir = initialDir
        super.init(title: Lang.t("Tera Term", "DLG_FILETRANS_TITLE", "ファイル送信"))
        build()
    }

    /// sendfiledlg(): Control キー (Windows の Ctrl) を押していたら skip の扱いを逆にする
    /// ts.FileSendFilter (「...」の Open ダイアログのフィルタ)
    static var filter = ""

    static func run(values: Values, initialDir: String, skipDialog: Bool, filter: String,
                    over parent: NSWindow?) -> Values? {
        SendFileDialog.filter = filter
        var skip = skipDialog
        if NSEvent.modifierFlags.contains(.control) { skip.toggle() }
        if !skip {
            let d = SendFileDialog(values: values, initialDir: initialDir)
            guard d.run(over: parent) else { return nil }
            return d.values
        }
        guard let f = selectFile(initial: values.filename, initialDir: initialDir) else { return nil }
        var v = values
        v.filename = f
        return v
    }

    /// SelectFile(): 「Tera Term: ファイル送信」の Open ダイアログ (ファイルが存在すること)
    static func selectFile(initial: String, initialDir: String) -> String? {
        let p = NSOpenPanel()
        let title = "Tera Term: " + Lang.t("Tera Term", "DLG_FILETRANS_TITLE", "ファイル送信")
        p.title = title
        p.message = title
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.directoryURL = TransferFilePanels.defaultFile(filter: filter, fileDir: initialDir)
            ?? URL(fileURLWithPath: initialDir, isDirectory: true)
        FilePanelFilter.attach(to: p, mask: filter)
        if !initial.isEmpty {
            let full = FileTransferPaths.resolve(initial, fileDir: initialDir)
            if FileManager.default.fileExists(atPath: full) { p.directoryURL = URL(fileURLWithPath: full) }
        }
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return u.path
    }

    private func build() {
        let fileLabel = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_SENDFILE_FILENAME_TITLE", "Filename (drop file in this dialog)"))
        filenameCombo.completes = false
        filenameCombo.numberOfVisibleItems = 10
        filenameCombo.addItems(withObjectValues: SendFileDialog.history.items)
        filenameCombo.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let browse = makeButton("...", #selector(browse(_:)))
        let fileRow = NSStackView(views: [filenameCombo, browse])

        let methodLabel = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_SENDFILE_READING_METHOD_TITLE", "ファイルの読み込み方法"))
        let tip = Lang.t("Tera Term", "DLG_SENDFILE_READING_METOHD_TOOLTIP",
                         "Bulk read:\n・ファイルをメモリに読み込んでから送信する\n・テキストファイルのエンコードは自動判定される\n"
                         + "Sequential read:\n・ファイルから読み込みながら送信する\n・テキストファイルはACPとして読み込み,エンコードは自動判定されない")
        for r in [bulkRadio, seqRadio] {
            r.target = self
            r.action = #selector(methodChanged(_:))
            r.toolTip = tip
        }
        bulkRadio.state = values.sequential ? .off : .on
        seqRadio.state = values.sequential ? .on : .off
        binaryCheck.state = values.binary ? .on : .off

        delayTypePopup.addItems(withTitles: [
            Lang.t("Tera Term", "DLG_SENDFILE_DELAYTYPE_NO_DELAY", "no delay"),
            Lang.t("Tera Term", "DLG_SENDFILE_DELAYTYPE_PER_CHAR", "per character"),
            Lang.t("Tera Term", "DLG_SENDFILE_DELAYTYPE_PER_LINE", "per line"),
            Lang.t("Tera Term", "DLG_SENDFILE_DELAYTYPE_PER_SENDSIZE", "per sendsize"),
        ])
        delayTypePopup.selectItem(at: max(0, min(3, values.delayType)))
        delayTypePopup.target = self
        delayTypePopup.action = #selector(delayTypeChanged(_:))
        sendSizeCombo.addItems(withObjectValues: ["16", "256", "4096"])
        sendSizeCombo.stringValue = "\(values.sendSize)"
        sendSizeCombo.completes = false
        let ssf = DigitsFormatter()
        sendSizeCombo.formatter = ssf
        sendSizeCombo.widthAnchor.constraint(equalToConstant: 110).isActive = true
        delayTimeField.stringValue = "\(values.delayTick)"
        delayTimeField.formatter = DigitsFormatter()
        delayTimeField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let ok = makeButton(Lang.t("Tera Term", "BTN_OK", "OK"), #selector(okPressed(_:)))
        let cancel = makeButton(Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"), #selector(cancelPressed(_:)))
        let stack = NSStackView(views: [
            fileLabel, TransferModalDialog.indent(fileRow),
            methodLabel, TransferModalDialog.indent(bulkRadio), TransferModalDialog.indent(seqRadio),
            binaryCheck,
            delayTypeLabel, TransferModalDialog.indent(delayTypePopup),
            sendSizeLabel, TransferModalDialog.indent(sendSizeCombo),
            delayTimeLabel, TransferModalDialog.indent(delayTimeField),
            okCancelRow(ok: ok, cancel: cancel),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: binaryCheck)
        stack.setCustomSpacing(16, after: stack.views[stack.views.count - 2])
        stack.views.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        content.onDrop = { [weak self] p in
            self?.filenameCombo.stringValue = p
            self?.panel.makeFirstResponder(nil)
        }
        setBody(stack)
        arrangeControls()
        panel.initialFirstResponder = filenameCombo
    }

    /// ArrangeControls()
    private func arrangeControls() {
        let sel = delayTypePopup.indexOfSelectedItem
        if seqRadio.state == .on {
            setEnabled(false, delayTypeLabel, delayTypePopup)
            setEnabled(false, sendSizeLabel, sendSizeCombo)
            setEnabled(false, delayTimeLabel, delayTimeField)
        } else {
            setEnabled(true, delayTypeLabel, delayTypePopup)
            setEnabled(sel == 3, sendSizeLabel, sendSizeCombo)
            setEnabled(sel != 0, delayTimeLabel, delayTimeField)
        }
    }

    private func setEnabled(_ on: Bool, _ label: NSTextField, _ control: NSControl) {
        control.isEnabled = on
        label.textColor = on ? .labelColor : .disabledControlTextColor
    }

    @objc private func methodChanged(_ sender: NSButton) {
        bulkRadio.state = sender === bulkRadio ? .on : .off
        seqRadio.state = sender === seqRadio ? .on : .off
        arrangeControls()
    }

    @objc private func delayTypeChanged(_ sender: Any?) { arrangeControls() }

    @objc private func browse(_ sender: Any?) {
        if let f = SendFileDialog.selectFile(initial: filenameCombo.stringValue, initialDir: initialDir) {
            filenameCombo.stringValue = f
        }
    }

    @objc private func okPressed(_ sender: Any?) {
        panel.makeFirstResponder(nil)
        let name = filenameCombo.stringValue
        // GetFileAttributesW: ないかフォルダならエラーでダイアログに戻る。
        // (Windows はカレントフォルダからの相対。Mac はそれが / なので、送るときと同じく FileDir からの相対で調べる)
        let full = FileTransferPaths.resolve(name, fileDir: resolveDir)
        var isDir: ObjCBool = false
        if name.isEmpty || !FileManager.default.fileExists(atPath: full, isDirectory: &isDir) || isDir.boolValue {
            showCantOpenFileError(over: panel)
            panel.makeFirstResponder(filenameCombo)
            return
        }
        SendFileDialog.history.addTop(name)
        values.filename = name
        values.binary = binaryCheck.state == .on
        values.delayType = delayTypePopup.indexOfSelectedItem
        values.delayTick = transferDialogInt(delayTimeField.stringValue)
        values.sendSize = transferDialogInt(sendSizeCombo.stringValue)
        values.sequential = seqRadio.state == .on
        endDialog(true)
    }

    @objc private func cancelPressed(_ sender: Any?) { endDialog(false) }
}

// MARK: - ファイル受信 (IDD_RECVFILEDLG)

final class ReceiveFileDialog: TransferModalDialog {
    struct Values {
        var filename = ""
        var autoStopSec = 5
    }

    static var history = TransferHistory()

    private var values: Values
    private let initialDir: String
    private let filenameCombo = NSComboBox()
    private let binaryCheck = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_RECVFILE_BINARY", "バイナリ"), target: nil, action: nil)
    private let autoStopField = NSTextField(string: "")

    init(values: Values, initialDir: String) {
        self.values = values
        self.initialDir = initialDir
        super.init(title: Lang.t("Tera Term", "FILEDLG_TRANS_TITLE_RECVFILE", "ファイル受信"))
        build()
    }

    /// ts.FileReceiveFilter (「...」の保存ダイアログのフィルタ)
    static var filter = ""

    /// recvfiledlg(): Control キーで skip の扱いを逆にする。skip のときは保存ダイアログだけ
    static func run(values: Values, initialDir: String, skipDialog: Bool, filter: String = "",
                    over parent: NSWindow?) -> Values? {
        ReceiveFileDialog.filter = filter
        var skip = skipDialog
        if NSEvent.modifierFlags.contains(.control) { skip.toggle() }
        if !skip {
            let d = ReceiveFileDialog(values: values, initialDir: initialDir)
            guard d.run(over: parent) else { return nil }
            return d.values
        }
        guard let f = selectFile(initial: values.filename, initialDir: initialDir) else { return nil }
        var v = values
        v.filename = f
        return v
    }

    /// SelectFile(): 「Tera Term: ファイル受信」の保存ダイアログ (上書きの確認は NSSavePanel がする)
    static func selectFile(initial: String, initialDir: String) -> String? {
        let p = NSSavePanel()
        let title = "Tera Term: " + Lang.t("Tera Term", "FILEDLG_TRANS_TITLE_RECVFILE", "ファイル受信")
        p.title = title
        p.message = title
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: initialDir, isDirectory: true)
        FilePanelFilter.attach(to: p, mask: filter)
        if !initial.isEmpty {
            let full = FileTransferPaths.resolve(initial, fileDir: initialDir)
            p.directoryURL = URL(fileURLWithPath: (full as NSString).deletingLastPathComponent, isDirectory: true)
            p.nameFieldStringValue = (full as NSString).lastPathComponent
        }
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return u.path
    }

    private func build() {
        let fileLabel = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_RECVFILE_FILENAME_TITLE", "受信ファイル名(dialogにファイルをドロップ)"))
        filenameCombo.completes = false
        filenameCombo.numberOfVisibleItems = 10
        filenameCombo.addItems(withObjectValues: ReceiveFileDialog.history.items)
        filenameCombo.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let browse = makeButton("...", #selector(browse(_:)))
        let fileRow = NSStackView(views: [filenameCombo, browse])
        // バイナリは常にチェックして無効 (テキストモードは未実装)
        binaryCheck.state = .on
        binaryCheck.isEnabled = false
        let autoLabel = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_RECVFILE_AUTOSTOP_LABEL", "ファイル受信自動停止待ち時間(秒)"))
        let f = DigitsFormatter()
        f.maxLength = 8
        autoStopField.formatter = f
        autoStopField.stringValue = "\(values.autoStopSec)"
        autoStopField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let ok = makeButton(Lang.t("Tera Term", "BTN_OK", "OK"), #selector(okPressed(_:)))
        let cancel = makeButton(Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"), #selector(cancelPressed(_:)))
        let row = okCancelRow(ok: ok, cancel: cancel)
        let stack = NSStackView(views: [
            fileLabel, TransferModalDialog.indent(fileRow),
            binaryCheck, autoLabel, TransferModalDialog.indent(autoStopField),
            row,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(16, after: stack.views[stack.views.count - 2])
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        content.onDrop = { [weak self] p in
            self?.filenameCombo.stringValue = p
            self?.panel.makeFirstResponder(nil)
        }
        setBody(stack)
        panel.initialFirstResponder = filenameCombo
    }

    @objc private func browse(_ sender: Any?) {
        if let f = ReceiveFileDialog.selectFile(initial: filenameCombo.stringValue, initialDir: initialDir) {
            filenameCombo.stringValue = f
        }
    }

    @objc private func okPressed(_ sender: Any?) {
        panel.makeFirstResponder(nil)
        let name = filenameCombo.stringValue
        // CreateFileW(CREATE_ALWAYS): すぐに作る (あれば空にする)。だめならエラーでダイアログに戻る
        let full = FileTransferPaths.resolve(name, fileDir: initialDir)
        if name.isEmpty || !ReceiveFileDialog.createAlways(full) {
            showCantOpenFileError(over: panel)
            panel.makeFirstResponder(filenameCombo)
            return
        }
        ReceiveFileDialog.history.addTop(name)
        values.filename = name
        values.autoStopSec = transferDialogInt(autoStopField.stringValue)
        endDialog(true)
    }

    @objc private func cancelPressed(_ sender: Any?) { endDialog(false) }

    /// CREATE_ALWAYS
    static func createAlways(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return false }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}

// MARK: - Kermit 取得 (IDD_GETFNDLG)

final class KermitGetDialog: TransferModalDialog {
    private let field = NSTextField(string: "")
    private(set) var filename = ""

    init() {
        super.init(title: Lang.t("Tera Term", "DLG_GETFN_TITLE", "Tera Term: Kermit 取得"))
        let label = NSTextField(labelWithString: Lang.t("Tera Term", "DLG_GETFN_FILENAME", "ファイル名:"))
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let ok = makeButton(Lang.t("Tera Term", "BTN_OK", "OK"), #selector(okPressed(_:)))
        let cancel = makeButton(Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"), #selector(cancelPressed(_:)))
        let row = okCancelRow(ok: ok, cancel: cancel)
        let stack = NSStackView(views: [label, field, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: field)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        setBody(stack)
        panel.initialFirstResponder = field
    }

    @objc private func okPressed(_ sender: Any?) {
        // 空のときは何もしない (ダイアログはそのまま)
        guard !field.stringValue.isEmpty else { return }
        filename = field.stringValue
        endDialog(true)
    }

    @objc private func cancelPressed(_ sender: Any?) { endDialog(false) }
}

// MARK: - 転送のファイル選択 (コモンダイアログ + IDD_XOPT / IDD_FOPT)

/// 転送のファイル選択ダイアログ
enum TransferFilePanels {
    /// ラジオボタンを組にする (accessoryView の中)
    final class RadioGroup: NSObject {
        let buttons: [NSButton]
        init(_ b: [NSButton]) {
            buttons = b
            super.init()
            for x in b { x.target = self; x.action = #selector(clicked(_:)) }
        }
        @objc func clicked(_ sender: NSButton) { for x in buttons { x.state = x === sender ? .on : .off } }
    }

    /// GetCommonDialogDefaultFilenameW: FileSendFilter がワイルドカードでないファイル名で、FileDir にあればそれを選んでおく
    static func defaultFile(filter: String, fileDir: String) -> URL? {
        guard !filter.isEmpty, !filter.contains("*"), !filter.contains("?") else { return nil }
        let p = (fileDir as NSString).appendingPathComponent(filter)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return URL(fileURLWithPath: p)
    }

    private static func optionBox(_ title: String, _ views: [NSView]) -> NSView {
        let box = NSBox()
        box.title = title
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        s.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        box.contentView = s
        box.sizeToFit()
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: max(240, box.frame.width + 20), height: box.frame.height + 12))
        box.setFrameOrigin(NSPoint(x: 10, y: 6))
        wrap.addSubview(box)
        return wrap
    }

    private static func openPanel(title: String, multi: Bool, filter: String, fileDir: String) -> NSOpenPanel {
        let p = NSOpenPanel()
        p.title = title
        p.message = title
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = multi
        p.directoryURL = defaultFile(filter: filter, fileDir: fileDir) ?? URL(fileURLWithPath: fileDir, isDirectory: true)
        // フィルタ (ts.FileSendFilter) は begin で付ける (オプションの accessoryView を付けたあと)
        objc_setAssociatedObject(p, &pendingFilterMaskKey, filter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return p
    }

    private static func begin(_ p: NSSavePanel, over w: NSWindow?, _ done: @escaping (Bool) -> Void) {
        if let mask = objc_getAssociatedObject(p, &pendingFilterMaskKey) as? String { FilePanelFilter.attach(to: p, mask: mask) }
        if let w = w {
            p.beginSheetModal(for: w) { done($0 == .OK) }
        } else {
            done(p.runModal() == .OK)
        }
    }

    /// _GetMultiFname / _GetTransFname: 送るファイル (オプションなし)
    static func chooseSendFiles(title: String, multi: Bool, filter: String, fileDir: String, over w: NSWindow?,
                                done: @escaping ([String]?) -> Void) {
        let p = openPanel(title: title, multi: multi, filter: filter, fileDir: fileDir)
        begin(p, over: w) { ok in done(ok && !p.urls.isEmpty ? p.urls.map { $0.path } : nil) }
    }

    /// XMODEM 受信: 保存ダイアログ + オプション (チェックサム / CRC、バイナリ)
    static func xmodemReceive(fileDir: String, crc: Bool, binary: Bool, over w: NSWindow?,
                              done: @escaping ((file: String, crc: Bool, binary: Bool)?) -> Void) {
        let p = NSSavePanel()
        let title = "Tera Term: " + Lang.t("Tera Term", "FILEDLG_TRANS_TITLE_XRCV", "XMODEM受信")
        p.title = title
        p.message = title
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: fileDir, isDirectory: true)
        let check = NSButton(radioButtonWithTitle: Lang.t("Tera Term", "DLG_XOPT_CHECKSUM", "チェックサム"), target: nil, action: nil)
        let crcB = NSButton(radioButtonWithTitle: Lang.t("Tera Term", "DLG_XOPT_CRC", "CRC"), target: nil, action: nil)
        let bin = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_XOPT_BINARY", "バイナリ"), target: nil, action: nil)
        let group = RadioGroup([check, crcB])
        check.state = crc ? .off : .on
        crcB.state = crc ? .on : .off
        bin.state = binary ? .on : .off
        p.accessoryView = optionBox(Lang.t("Tera Term", "DLG_XOPT", "オプション"), [check, crcB, bin])
        begin(p, over: w) { ok in
            _ = group
            guard ok, let u = p.url else { done(nil); return }
            done((u.path, crcB.state == .on, bin.state == .on))
        }
    }

    /// XMODEM 送信: 開くダイアログ + オプション (1K)
    static func xmodemSend(fileDir: String, filter: String, oneK: Bool, over w: NSWindow?,
                           done: @escaping ((file: String, oneK: Bool)?) -> Void) {
        let p = openPanel(title: "Tera Term: " + Lang.t("Tera Term", "FILEDLG_TRANS_TITLE_XSEND", "XMODEM送信"), multi: false, filter: filter, fileDir: fileDir)
        let k = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_XOPT_1K", "1K"), target: nil, action: nil)
        k.state = oneK ? .on : .off
        p.accessoryView = optionBox(Lang.t("Tera Term", "DLG_XOPT", "オプション"), [k])
        p.isAccessoryViewDisclosed = true
        begin(p, over: w) { ok in
            guard ok, let u = p.url else { done(nil); return }
            done((u.path, k.state == .on))
        }
    }

    /// ZMODEM 送信: 開くダイアログ (複数選択) + Option (バイナリ)
    static func zmodemSend(fileDir: String, filter: String, binary: Bool, over w: NSWindow?,
                           done: @escaping ((files: [String], binary: Bool)?) -> Void) {
        let p = openPanel(title: "Tera Term: " + Lang.t("Tera Term", "FILEDLG_TRANS_TITLE_ZSEND", "ZMODEM送信"), multi: true, filter: filter, fileDir: fileDir)
        let bin = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_XOPT_BINARY", "バイナリ"), target: nil, action: nil)
        bin.state = binary ? .on : .off
        p.accessoryView = optionBox("Option", [bin])
        p.isAccessoryViewDisclosed = true
        begin(p, over: w) { ok in
            guard ok, !p.urls.isEmpty else { done(nil); return }
            done((p.urls.map { $0.path }, bin.state == .on))
        }
    }
}

// MARK: - SSH SCP (IDD_SSHSCP)

final class ScpDialog: TransferModalDialog {
    enum Action {
        case send(file: String, toDir: String)
        case receive(remote: String, localDir: String)
    }

    private let sendFrom = FocusReportingTextField(string: "")
    private let sendTo = FocusReportingTextField(string: "")
    private let recvFrom = FocusReportingTextField(string: "")
    private let recvTo = FocusReportingTextField(string: "")
    private var sendButton: NSButton!
    private var recvButton: NSButton!
    private(set) var action: Action?
    /// SavePaths(): 閉じるときの To: (ts.ScpSendDir に書き戻す)
    private(set) var savedSendDir = ""

    init(scpSendDir: String, recvDir: String) {
        super.init(title: Lang.t("TTSSH", "DLG_SCP_TITLE", "TTSSH: Secure Copy Protocol (SCP)"))
        sendTo.stringValue = scpSendDir
        recvTo.stringValue = recvDir
        build()
    }

    private func build() {
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 50).isActive = true
            return l
        }
        for f in [sendFrom, sendTo, recvFrom, recvTo] {
            f.widthAnchor.constraint(equalToConstant: 280).isActive = true
            f.cell?.isScrollable = true
            f.cell?.wraps = false
        }
        sendButton = makeButton(Lang.t("TTSSH", "DLG_SCP_SENDFILE_SEND", "送信"), #selector(sendPressed(_:)))
        let cancel = makeButton(Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"), #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1B}"
        recvButton = makeButton(Lang.t("TTSSH", "DLG_SCP_RECEIVEFILE_RECEIVE", "受信"), #selector(receivePressed(_:)))
        let selFile = makeButton("...", #selector(selectSendFile(_:)))
        let selDir = makeButton("...", #selector(selectRecvDir(_:)))
        for b in [sendButton!, cancel, recvButton!] { b.widthAnchor.constraint(equalToConstant: 100).isActive = true }
        let spacer1 = NSView(), spacer2 = NSView()
        spacer1.widthAnchor.constraint(equalToConstant: selFile.fittingSize.width).isActive = true
        spacer2.widthAnchor.constraint(equalToConstant: selDir.fittingSize.width).isActive = true

        let note = NSTextField(labelWithString: Lang.t("TTSSH", "DLG_SCP_SENDFILE_DRAG", "このウィンドウにファイルをドラッグできます"))
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let noteRow = NSStackView(views: [label(""), note])

        let grid = NSGridView(views: [
            [label(Lang.t("TTSSH", "DLG_SCP_SENDFILE_FROM", "From:")), sendFrom, selFile, sendButton],
            [label(Lang.t("TTSSH", "DLG_SCP_SENDFILE_TO", "To:")), sendTo, spacer1, cancel],
            [noteRow, NSGridCell.emptyContentView, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [NSBox.transferSeparator(), NSGridCell.emptyContentView, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label(Lang.t("TTSSH", "DLG_SCP_RECEIVEFILE_FROM", "From:")), recvFrom, spacer2, recvButton],
            [label(Lang.t("TTSSH", "DLG_SCP_RECEIVEFILE_TO", "To:")), recvTo, selDir, NSGridCell.emptyContentView],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 4), verticalRange: NSRange(location: 2, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 4), verticalRange: NSRange(location: 3, length: 1))
        grid.rowAlignment = .firstBaseline

        sendFrom.onFocus = { [weak self] in self?.setDefault(send: true) }
        sendTo.onFocus = { [weak self] in self?.setDefault(send: true) }
        recvFrom.onFocus = { [weak self] in self?.setDefault(send: false) }
        recvTo.onFocus = { [weak self] in self?.setDefault(send: false) }
        content.onDrop = { [weak self] p in self?.sendFrom.stringValue = p }
        setBody(grid)
        setDefault(send: true)
        panel.initialFirstResponder = sendFrom
    }

    /// DM_SETDEFID: Enter で押されるボタン
    private func setDefault(send: Bool) {
        sendButton.keyEquivalent = send ? "\r" : ""
        recvButton.keyEquivalent = send ? "" : "\r"
    }

    @objc private func selectSendFile(_ sender: Any?) {
        let p = NSOpenPanel()
        p.title = Lang.t("TTSSH", "DLG_SCP_SELECT_FILE_TITLE", "送信ファイル選択")
        p.message = p.title
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.showsHiddenFiles = true   // OFN_FORCESHOWHIDDEN
        if p.runModal() == .OK, let u = p.url { sendFrom.stringValue = u.path }
        panel.makeFirstResponder(sendFrom)
        setDefault(send: true)
    }

    @objc private func selectRecvDir(_ sender: Any?) {
        let p = NSOpenPanel()
        p.title = Lang.t("TTSSH", "DLG_SCP_SELECT_DEST_TITLE", "受信フォルダ選択")
        p.message = p.title

        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        let cur = FileTransferPaths.expandEnvironment(recvTo.stringValue)
        if FileTransferPaths.folderExists(cur) { p.directoryURL = URL(fileURLWithPath: cur, isDirectory: true) }
        if p.runModal() == .OK, let u = p.url { recvTo.stringValue = u.path }
        panel.makeFirstResponder(recvTo)
        setDefault(send: false)
    }

    private func savePaths() { savedSendDir = sendTo.stringValue }

    @objc private func sendPressed(_ sender: Any?) {
        panel.makeFirstResponder(nil)
        action = .send(file: sendFrom.stringValue, toDir: sendTo.stringValue)
        savePaths()
        endDialog(true)
    }

    @objc private func cancelPressed(_ sender: Any?) {
        savePaths()
        endDialog(false)
    }

    @objc private func receivePressed(_ sender: Any?) {
        panel.makeFirstResponder(nil)
        let remote = recvFrom.stringValue
        // 最後の / の後ろがファイル名。/ で終わるときは何もしない (ダイアログはそのまま)
        if remote.isEmpty || remote.hasSuffix("/") { return }
        action = .receive(remote: remote, localDir: FileTransferPaths.expandEnvironment(recvTo.stringValue))
        savePaths()
        endDialog(true)
    }

    override func windowWillClose(_ notification: Notification) {
        if action == nil { savePaths() }
        super.windowWillClose(notification)
    }
}

private extension NSBox {
    static func transferSeparator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
}

// MARK: - シーケンシャル送信 (filesys.cpp FileSendStart / FileSend: Tera Term 4 の送り方)

enum SequentialSendPlan {
    /// CP932 の 2 バイト文字の 1 バイト目 (IsDBCSLeadByte。日本語版 Windows の ACP = 932)
    static func isLeadByte(_ c: UInt8) -> Bool { (0x81...0x9F).contains(c) || (0xE0...0xFC).contains(c) }

    private static let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

    /// - Parameters:
    ///   - binary: ts.TransBin。バイナリはそのまま (CommBinaryOut)
    ///   - bracketed: BracketedPasteMode(): ESC[200~ と ESC[201~ (バイナリとして) で囲む
    /// テキストは 1 バイトずつ読み、CR の直後の LF は飛ばし (CR LF → CR)、2 バイト文字は CP932 で 1 文字にし、
    /// TAB / LF / CR 以外の制御文字は送らない。それ以外の 1 バイトはそのまま U+00xx として送る (CommTextOutW)
    /// FILE_SEND_BUF_SIZE (FileSendBinayBoost で 1 度に読む大きさ)
    static let boostPiece = 8192

    /// highSpeed: FileSendBinayBoost の条件 (シリアル・FileSendHighSpeedMode・バイナリ・ブラケットなし・Telnet でない・
    /// ローカルエコーなし・115200bps 以上) を満たす: 8192 バイトずつまとめて送る
    static func make(data: Data, binary: Bool, bracketed: Bool, highSpeed: Bool = false) -> SendFilePlan {
        let b = [UInt8](data)
        let piece = highSpeed && binary && !bracketed ? boostPiece : 1024
        var chunks: [SendFilePlan.Chunk] = []
        if bracketed { chunks.append(.binary(Array("\u{1B}[200~".utf8))) }
        if binary {
            var i = 0
            while i < b.count {
                chunks.append(.binary(Array(b[i..<min(b.count, i + piece)])))
                i += piece
            }
        } else {
            var cur = String.UnicodeScalarView()
            var start = 0
            var crSend = false
            var i = 0
            while i < b.count {
                var c = b[i]
                i += 1
                if c == 0x0A && crSend {
                    // CR を送った直後の LF → もう 1 バイト読む
                    guard i < b.count else { break }
                    c = b[i]
                    i += 1
                }
                var u: Unicode.Scalar?
                if isLeadByte(c) {
                    guard i < b.count else { break }   // 2 バイト目が読めない → 終わり
                    let pair = Data([c, b[i]])
                    i += 1
                    u = String(data: pair, encoding: cp932)?.unicodeScalars.first
                } else {
                    u = Unicode.Scalar(c)
                }
                if let u = u, u.value >= 0x20 || u.value == 0x09 || u.value == 0x0A || u.value == 0x0D {
                    cur.append(u)
                }
                crSend = u?.value == 0x0D
                if i - start >= piece {
                    if !cur.isEmpty { chunks.append(.text(String(cur))) }
                    cur = String.UnicodeScalarView()
                    start = i
                }
            }
            if !cur.isEmpty { chunks.append(.text(String(cur))) }
        }
        if bracketed { chunks.append(.binary(Array("\u{1B}[201~".utf8))) }
        return SendFilePlan(chunks: chunks, delayMs: 0)
    }
}

// MARK: - 確認用 (TERAMAC_GUIDESNAP: かんたんマニュアルの画面写真)

extension SendFileDialog {
    /// ファイル名の欄を例の名前にする
    func debugGuideFill(_ path: String) { filenameCombo.stringValue = path }
}
