// 端末ウインドウへのファイルのドラッグ&ドロップ (Tera Term の vtwin.cpp OnDropFiles / OnDropNotify と dnddlg.cpp を移したもの)
// 元のコード: Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project (BSD 3-Clause)
//
// ドロップしたファイルを次のどれかで扱う:
//   SCP で送る (SSH 接続のとき) / ファイル送信 (中身を送る) / ファイル名を貼り付け
// Control (または Option) を押しながらドロップすると、必ずダイアログを出す。

import AppKit
import TeraCore
import TeraCore

enum DropType { case cancel, scp, sendFile, pasteFilename }

/// ファイル名の貼り付け方 (DROP_TYPE_PASTE_*)
struct DropPaste: OptionSet {
    let rawValue: Int
    static let escape = DropPaste(rawValue: 1)
    static let newline = DropPaste(rawValue: 2)
}

/// このウインドウでのドロップの状態 (DropData_t。INI には保存しない)
final class DropState {
    var defaultDropType: DropType = .cancel
    var defaultDropTypePaste: DropPaste = .escape
    var defaultShowDialog: Bool
    var transBin = false
    var doSameProcess = false
    var dropType: DropType = .cancel
    var dropTypePaste: DropPaste = .escape
    var files: [String] = []
    var fileCount = 0
    var directoryCount = 0
    var sendIndex = 0
    init(confirm: Bool) { defaultShowDialog = confirm }
}

/// TERATERM.INI のドロップの設定
struct DropSettings {
    var confirmFileDragAndDrop = true
    var transBin = false
    var scpSendDir = ""

    static func load() -> DropSettings {
        var s = DropSettings()
        if let p = FileTransferOptions.loadTeraTermIni().path, let d = FileManager.default.contents(atPath: p), let ini = IniFile(data: d) {
            s.confirmFileDragAndDrop = ini.onOff("Tera Term", "ConfirmFileDragAndDrop") ?? true
            s.transBin = ini.onOff("Tera Term", "TransBin") ?? false
            s.scpSendDir = ini.string("Tera Term", "ScpSendDir") ?? ""
        }
        return s
    }
}

extension SessionWindowController {

    /// ドロップを受け付けられるか (cv.Ready && IsSendVarNULL())
    var canAcceptDrop: Bool { isConnected && transfer == nil && sendFileJob == nil }

    /// ファイルがドロップされた (OnDropFiles → OnDropNotify(lparam=0))
    func filesDropped(_ paths: [String], forceDialog: Bool) {
        guard canAcceptDrop, !paths.isEmpty else { NSSound.beep(); return }
        window?.makeKeyAndOrderFront(nil)
        let d = dropState
        d.files = paths
        d.fileCount = 0
        d.directoryCount = 0
        for p in paths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { d.directoryCount += 1 } else { d.fileCount += 1 }
        }
        d.doSameProcess = false
        let isSSH = isSSHConnection
        d.dropTypePaste = .escape
        if d.defaultDropType == .cancel {
            d.transBin = dropSettings.transBin
            if !forceDialog {
                if d.fileCount == 1 && d.directoryCount == 0 {
                    if dropSettings.confirmFileDragAndDrop {
                        d.dropType = isSSH ? .scp : .sendFile
                        d.doSameProcess = false
                    } else {
                        d.dropType = .sendFile
                        d.doSameProcess = !d.defaultShowDialog
                    }
                } else if d.fileCount == 0 && d.directoryCount == 1 {
                    d.dropType = .pasteFilename
                    d.doSameProcess = !d.defaultShowDialog
                } else if d.fileCount > 0 && d.directoryCount > 0 {
                    d.dropType = .pasteFilename
                    d.doSameProcess = false
                } else if d.fileCount > 0 && d.directoryCount == 0 {
                    d.dropType = isSSH ? .scp : .sendFile
                    d.doSameProcess = false
                } else {
                    d.dropType = .pasteFilename
                    d.doSameProcess = !dropSettings.confirmFileDragAndDrop
                }
            } else {
                d.dropType = d.directoryCount > 0 ? .pasteFilename : (isSSH ? .scp : .sendFile)
                d.doSameProcess = false
            }
        } else {
            if d.directoryCount > 0 && (d.defaultDropType == .sendFile || d.defaultDropType == .scp) {
                d.dropType = .pasteFilename
                d.dropTypePaste = d.defaultDropTypePaste
                d.doSameProcess = false
            } else {
                d.dropType = d.defaultDropType
                d.dropTypePaste = d.defaultDropTypePaste
                d.doSameProcess = !(forceDialog || d.defaultShowDialog)
            }
        }
        d.sendIndex = 0
        dropNextFile()
    }

    private var isSSHConnection: Bool {
        if case .ssh? = spec { return isConnected }
        return false
    }

    /// 次のファイルを処理する (OnDropNotify の next_file)
    private func dropNextFile() {
        let d = dropState
        guard d.sendIndex < d.files.count else { return }
        let i = d.sendIndex
        d.sendIndex += 1
        let file = d.files[i]

        if !d.doSameProcess {
            guard let r = showDropDialog(file: file, remaining: d.files.count - i,
                                         scpEnable: d.directoryCount == 0 && isSSHConnection,
                                         sendfileEnable: d.directoryCount == 0) else { return }
            if r.sameNextDrop { d.defaultDropType = d.dropType }
            if !dropSettings.confirmFileDragAndDrop { d.defaultShowDialog = !r.dontShow }
        }

        switch d.dropType {
        case .cancel:
            return
        case .sendFile:
            if !macroSendFile(file, binary: d.transBin, done: { [weak self] in self?.dropNextFile() }) {
                dropNextFile()
            }
        case .pasteFilename:
            d.defaultDropTypePaste = d.dropTypePaste
            var s = d.dropTypePaste.contains(.escape) ? SessionWindowController.escapeFilename(file) : file
            if d.files.count > 1 && i < d.files.count - 1 {
                s += d.dropTypePaste.contains(.newline) ? "\r" : " "
            }
            pasteForDrop(s)
            dropNextFile()
        case .scp:
            guard let args = scpArguments(send: true, from: file, to: dropSettings.scpSendDir) else {
                showDropError("scp send error")
                return
            }
            let ok = runScp(args, label: Lang.m("MENU_DROP_SCP_SEND", "SCP 送信"), file: file) { [weak self] ok in
                guard let self = self else { return }
                if !ok { self.showDropError("scp send error"); return }
                self.dropNextFile()
            }
            if !ok { showDropError("scp send error") }
        }
    }

    private func showDropError(_ msg: String) {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Tera Term: error"
        a.informativeText = msg
        if let w = presentingWindow { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// TermSendStartBracket / TermPasteStringNoBracket / TermSendEndBracket
    private func pasteForDrop(_ s: String) {
        if term.bracketedPaste {
            sendBytes(Array("\u{1B}[200~".utf8), echo: false)
            sendText(s)
            sendBytes(Array("\u{1B}[201~".utf8), echo: false)
        } else {
            sendText(s)
        }
    }

    /// vtwin.cpp EscapeFilename: \ は / に、シェルの特別な文字の前に \ を付ける
    static func escapeFilename(_ s: String) -> String {
        let special = Set(" ;&()$!`'[]{}#^~")
        var out = ""
        for c in s {
            if c == "\\" { out.append("/") }
            else if special.contains(c) { out.append("\\"); out.append(c) }
            else { out.append(c) }
        }
        return out
    }

    // MARK: - ダイアログ (dnddlg.cpp)

    private struct DropDialogResult { var sameNextDrop: Bool; var dontShow: Bool }

    private func showDropDialog(file: String, remaining: Int, scpEnable: Bool, sendfileEnable: Bool) -> DropDialogResult? {
        let d = dropState
        let a = NSAlert()
        func tt(_ key: String, _ def: String) -> String { Lang.t("Tera Term", key, def) }
        a.messageText = tt("DLG_DANDD_TITLE", "Tera Term: ファイル ドラッグ&ドロップ")
        a.informativeText = tt("DLG_DANDD_TEXT", "ファイル転送を行いますか？") + "\n" + file

        let scp = NSButton(radioButtonWithTitle: tt("DLG_DANDD_SCP_RADIO", "SCP"), target: nil, action: nil)
        let destLabel = NSTextField(labelWithString: tt("DLG_DANDD_SCP_DEST_LABEL", "送信先:"))
        let dest = NSTextField(string: dropSettings.scpSendDir)
        dest.placeholderString = tt("DLG_DANDD_SCP_DEST_NOTE", "空のときはホームディレクトリに送信されます")
        dest.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let send = NSButton(radioButtonWithTitle: tt("DLG_DANDD_SENDFILE_RADIO", "ファイル送信（ファイルの内容を貼り付け）"), target: nil, action: nil)
        let binary = NSButton(checkboxWithTitle: tt("DLG_DANDD_SEND_BINARY_CHECK", "バイナリ"), target: nil, action: nil)
        let paste = NSButton(radioButtonWithTitle: tt("DLG_DANDD_PASTE_RADIO", "ファイル名を貼り付け"), target: nil, action: nil)
        let escape = NSButton(checkboxWithTitle: tt("DLG_DANDD_PASTE_ESCAPE_CHECK", "エスケープ"), target: nil, action: nil)
        let space = NSButton(radioButtonWithTitle: tt("DLG_DANDD_PASTE_SPACE_RADIO", "スペースで区切る"), target: nil, action: nil)
        let newline = NSButton(radioButtonWithTitle: tt("DLG_DANDD_PASTE_NEWLINE_RADIO", "改行で区切る"), target: nil, action: nil)
        let same = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_DANDD_NEXTFILES", "同じ処理を次の %d 個のファイルに適用", remaining - 1), target: nil, action: nil)
        let nextDrop = NSButton(checkboxWithTitle: tt("DLG_DANDD_SAME_NEEXTDROP", "次のドロップ時、同じ処理を行う"), target: nil, action: nil)
        let dontShow = NSButton(checkboxWithTitle: tt("DLG_DANDD_DONTSHOW_NEEXTDROP", "次のドロップ時、ダイアログを表示しない"), target: nil, action: nil)
        let note = NSTextField(labelWithString: tt("DLG_DANDD_NOTE", "このダイアログは、Control を押しながらドロップすると必ず表示されます"))
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        // ラジオボタンの組 (同じ action でまとめる)
        let group = DropRadioGroup(buttons: [scp, send, paste])
        let sep = DropRadioGroup(buttons: [space, newline])
        group.select(d.dropType == .sendFile ? send : d.dropType == .pasteFilename ? paste : scp)
        sep.select(d.dropTypePaste.contains(.newline) ? newline : space)
        binary.state = d.transBin ? .on : .off
        escape.state = d.dropTypePaste.contains(.escape) ? .on : .off
        // 下の項目を触ったら、その処理のラジオボタンを選ぶ
        group.link(binary, to: send)
        group.link(escape, to: paste)
        group.link(space, to: paste)
        group.link(newline, to: paste)
        dest.delegate = group
        group.destField = dest
        group.scpButton = scp

        scp.isEnabled = scpEnable; destLabel.isEnabled = scpEnable; dest.isEnabled = scpEnable
        send.isEnabled = sendfileEnable; binary.isEnabled = sendfileEnable
        if remaining < 2 { space.isEnabled = false; newline.isEnabled = false; same.isEnabled = false }
        dontShow.state = !d.defaultShowDialog ? .on : .off
        let dontShowEnable = !dropSettings.confirmFileDragAndDrop
        dontShow.isEnabled = dontShowEnable; note.isEnabled = dontShowEnable
        if !dontShowEnable { note.textColor = .tertiaryLabelColor }

        func indent(_ v: NSView...) -> NSStackView {
            let s = NSStackView(views: v)
            s.orientation = .horizontal
            s.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            return s
        }
        let stack = NSStackView(views: [
            scp, indent(destLabel, dest),
            send, indent(binary),
            paste, indent(escape), indent(space, newline),
            NSBox.separator(), same, nextDrop, dontShow, note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: stack.fittingSize.height)
        a.accessoryView = stack
        a.addButton(withTitle: tt("BTN_OK", "OK"))
        a.addButton(withTitle: tt("BTN_CANCEL", "キャンセル"))
        a.window.initialFirstResponder = d.dropType == .scp ? dest : nil

        guard a.runModal() == .alertFirstButtonReturn else { d.dropType = .cancel; return nil }
        if scp.state == .on {
            d.dropType = .scp
            dropSettings.scpSendDir = dest.stringValue
        } else if send.state == .on {
            d.dropType = .sendFile
            d.transBin = binary.state == .on
        } else {
            d.dropType = .pasteFilename
            var p: DropPaste = []
            if escape.state == .on { p.insert(.escape) }
            if newline.state == .on { p.insert(.newline) }
            d.dropTypePaste = p
        }
        d.doSameProcess = same.state == .on
        _ = group; _ = sep
        return DropDialogResult(sameNextDrop: nextDrop.state == .on, dontShow: dontShow.state == .on)
    }
}

/// ラジオボタンの組と、触ったら選ばれるボタンのつながり
private final class DropRadioGroup: NSObject, NSTextFieldDelegate {
    let buttons: [NSButton]
    var links: [ObjectIdentifier: NSButton] = [:]
    weak var destField: NSTextField?
    weak var scpButton: NSButton?
    init(buttons: [NSButton]) {
        self.buttons = buttons
        super.init()
        for b in buttons { b.target = self; b.action = #selector(clicked(_:)) }
    }
    func select(_ b: NSButton) { for x in buttons { x.state = x === b ? .on : .off } }
    func link(_ control: NSButton, to radio: NSButton) {
        links[ObjectIdentifier(control)] = radio
        if control.action == nil || control.target == nil {
            control.target = self
            control.action = #selector(linkClicked(_:))
        } else if let other = control.target as? DropRadioGroup, other !== self {
            // 区切りのラジオボタン: 元の組の動きのあとにこちらも選ぶ
            other.chain[ObjectIdentifier(control)] = (self, radio)
        }
    }
    var chain: [ObjectIdentifier: (DropRadioGroup, NSButton)] = [:]
    @objc func clicked(_ sender: NSButton) {
        select(sender)
        if let (g, r) = chain[ObjectIdentifier(sender)] { g.select(r) }
    }
    @objc func linkClicked(_ sender: NSButton) {
        if let r = links[ObjectIdentifier(sender)] { select(r) }
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        if let s = scpButton { select(s) }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return b
    }
}
