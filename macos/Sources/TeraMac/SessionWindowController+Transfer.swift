// ファイル メニューの ファイル送信 / ファイル受信 / 転送 ▸ ... / SSH SCP (vtwin.cpp OnFileSend / OnFileRecv /
// OnFileKermit* / OnFileX* / OnFileY* / OnFileZ* / OnFileBP* / OnFileQV*, ttxssh.c の SCP メニュー)
// 元のコード: Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project (BSD 3-Clause)

import AppKit
import ObjectiveC
import TeraCore

private var transferExtraKey: UInt8 = 0

extension SessionWindowController {

    /// ts のうち FileTransferOptions / DropSettings にない送受信の設定 (ウインドウごと)
    var transferExtra: TransferExtraSettings {
        if let s = objc_getAssociatedObject(self, &transferExtraKey) as? TransferExtraSettings { return s }
        let s = TransferExtraSettings.load()
        objc_setAssociatedObject(self, &transferExtraKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    /// GetFileDir(&ts)
    private var transferFileDir: String { FileTransferPaths.fileDirectory(transferOptions.fileDir) }

    /// Busy = !IsSendVarNULL() || !IsFileVarNULL()
    private var transferBusy: Bool { transfer != nil || sendFileJob != nil }

    // MARK: - メニューの有効・無効 (vtwin.cpp InitMenuPopup / TransMenu, ttxssh.c)

    /// 転送まわりのメニュー項目なら有効か、それ以外は nil
    func validateTransferMenuItem(_ item: NSMenuItem) -> Bool? {
        guard let a = item.action else { return nil }
        let mine: [Selector] = [#selector(sendFileMenu(_:)), #selector(receiveFileMenu(_:)), #selector(kermitReceive(_:)), #selector(kermitGet(_:)),
                                #selector(kermitSend(_:)), #selector(kermitFinish(_:)), #selector(xmodemReceive(_:)), #selector(xmodemSend(_:)),
                                #selector(ymodemReceive(_:)), #selector(ymodemSend(_:)), #selector(zmodemReceive(_:)), #selector(zmodemSend(_:)),
                                #selector(bplusReceive(_:)), #selector(bplusSend(_:)), #selector(quickvanReceive(_:)), #selector(quickvanSend(_:)),
                                #selector(sshScp(_:))]
        // ログの再生のウインドウ (cv.PortType == IdFile) では送受信できない
        if isReplay && mine.contains(a) { return false }
        if a == #selector(sshScp(_:)) {
            // cv->Ready && pvar->socket != INVALID_SOCKET: SSH でつながっているとき
            if case .ssh? = spec { return connected }
            return false
        }
        let xyq: [Selector] = [#selector(xmodemReceive(_:)), #selector(xmodemSend(_:)),
                               #selector(ymodemReceive(_:)), #selector(ymodemSend(_:)),
                               #selector(quickvanReceive(_:)), #selector(quickvanSend(_:))]
        let zb: [Selector] = [#selector(zmodemReceive(_:)), #selector(zmodemSend(_:)),
                              #selector(bplusReceive(_:)), #selector(bplusSend(_:))]
        let common: [Selector] = [#selector(sendFileMenu(_:)), #selector(sendFile(_:)), #selector(receiveFileMenu(_:)),
                                  #selector(kermitReceive(_:)), #selector(kermitGet(_:)),
                                  #selector(kermitSend(_:)), #selector(kermitFinish(_:))]
        let isXYQ = xyq.contains(a), isZB = zb.contains(a)
        guard isXYQ || isZB || common.contains(a) else { return nil }
        // !Ready || Busy || Replay で灰色 (ログの再生は spec にないので、別の担当が足す)
        if !connected || transferBusy { return false }
        var sevenBit = false, xonxoff = false
        if case .serial(let p)? = spec {
            sevenBit = p.dataBits == 7
            xonxoff = p.flow == "xon"
        }
        if isXYQ { return !(sevenBit || xonxoff) }
        if isZB { return !sevenBit }
        return true
    }

    // MARK: - ファイル送信 (OnFileSend)

    @objc func sendFileMenu(_ sender: Any?) {
        guard !transferBusy else { NSSound.beep(); return }
        let dir = transferFileDir
        let ex = transferExtra
        let o = transferOptions
        let initial = SendFileDialog.Values(filename: "", binary: dropSettings.transBin, delayType: o.sendfileDelayType,
                                            delayTick: o.sendfileDelayTick, sendSize: o.sendfileSize,
                                            sequential: ex.sendfileSequential)
        guard let v = SendFileDialog.run(values: initial, initialDir: dir, skipDialog: ex.sendfileSkipOptionDialog,
                                         filter: ex.fileSendFilter, over: window) else { return }
        // ts に書き戻す
        dropSettings.transBin = v.binary
        transferOptions.sendfileDelayType = v.delayType
        transferOptions.sendfileDelayTick = v.delayTick
        transferOptions.sendfileSize = v.sendSize
        ex.sendfileSequential = v.sequential

        // ダイアログを閉じている間に別の送信が始まっていたら何もしない
        guard !transferBusy, let d = FileManager.default.contents(atPath: FileTransferPaths.resolve(v.filename, fileDir: dir)) else { return }
        let full = FileTransferPaths.resolve(v.filename, fileDir: dir)
        if !v.sequential {
            // SendMemSendFile: 一括で読み、遅延の設定で区切る
            let plan = SendFilePlan.make(data: d, binary: v.binary, delayType: v.delayType,
                                         delayTick: v.delayTick, sendSize: v.sendSize)
            runSendFilePlan(plan, path: full, binary: v.binary)
        } else {
            // FileSendStart: cv.Ready でなければ始めない
            guard connected else { return }
            let bracketed = term.bracketedPaste
            // FileSend(): FileSendBinayBoost の条件
            var boost = false
            if case .serial(let p)? = spec, ex.fileSendHighSpeedMode, v.binary, !bracketed, !settings.localEcho {
                boost = ((conn as? SerialConnection)?.params.baud ?? p.baud) >= 115200
            }
            let plan = SequentialSendPlan.make(data: d, binary: v.binary, bracketed: bracketed, highSpeed: boost)
            runSendFilePlan(plan, path: full, binary: v.binary)
        }
    }

    /// SendFilePlan を進み具合のパネル付きで送る (「Tera Term: ファイル送信中」)。
    /// テキストは端末の改行コード・文字コードで (CommTextOutW)、バイナリはそのまま (CommBinaryOut)。どちらもローカルエコーあり
    private func runSendFilePlan(_ plan: SendFilePlan, path: String, binary: Bool) {
        let job = SendFileJob(plan: plan) { [weak self] chunk in
            guard let self = self, self.conn != nil else { return }
            switch chunk {
            case .binary(let b): self.sendBytes(b, echo: true, binary: true, reconnect: false)
            case .text(let t): self.macroSend(Array(t.utf8), mode: .text)
            }
        }
        sendFileJob = job
        setTalkQuiet(true)
        let panel = transferPanel ?? TransferProgressPanel()
        transferPanel = panel
        let name = (path as NSString).lastPathComponent
        let proto = binary ? "ファイル送信 (バイナリ)" : "ファイル送信"
        panel.onCancel = { [weak job] in job?.finish() }
        // FTHideDialog: 進み具合のダイアログを出さない
        if !transferExtra.ftHideDialog { panel.show(title: "ファイル送信中", over: window) }
        panel.set(proto: proto, file: name, detail: "0 / \(job.totalBytes) バイト", percent: 0)
        job.onProgress = { [weak panel] sent, total in
            panel?.set(proto: proto, file: name, detail: "\(sent) / \(total) バイト",
                       percent: total > 0 ? Double(sent) * 100 / Double(total) : 100)
        }
        job.onFinish = { [weak self, weak job] in
            guard let self = self, self.sendFileJob === job else { return }
            self.sendFileJob = nil
            self.setTalkQuiet(false)
            self.transferPanel?.close()
        }
        job.start()
    }

    // MARK: - ファイル受信 (OnFileRecv)

    @objc func receiveFileMenu(_ sender: Any?) {
        guard !transferBusy else { NSSound.beep(); return }
        let dir = transferFileDir
        let ex = transferExtra
        let initial = ReceiveFileDialog.Values(filename: "", autoStopSec: transferOptions.receiveFileAutoStopWaitTime)
        guard let v = ReceiveFileDialog.run(values: initial, initialDir: dir, skipDialog: ex.receivefileSkipOptionDialog,
                                            filter: ex.fileReceiveFilter, over: window) else { return }
        dropSettings.transBin = true   // ts.TransBin = data.binary (いつも TRUE)
        // RawStartReceive(filename, ts.ReceivefileAutoStopWaitTime)
        _ = startTransfer(.rawRecv, files: [v.filename], binaryFlag: 1, xmodemOption: 0,
                          autoStopSec: v.autoStopSec, fromMacro: false, done: { _ in })
    }

    // MARK: - 転送 ▸ Kermit

    private func startMenuTransfer(_ kind: FileTransferKind, files: [String] = [], binaryFlag: Int? = nil,
                                   xmodemOption: Int = 0, noMessages: Bool = false) {
        let ok = startTransfer(kind, files: files, binaryFlag: binaryFlag ?? (transferOptions.xmodemBin ? 1 : 0),
                               xmodemOption: xmodemOption, fromMacro: noMessages, done: { _ in })
        if !ok { NSSound.beep() }
    }

    @objc func kermitReceive(_ sender: Any?) { startMenuTransfer(.kermitRecv) }

    @objc func kermitGet(_ sender: Any?) {
        guard !transferBusy else { NSSound.beep(); return }
        let d = KermitGetDialog()
        guard d.run(over: window) else { return }
        startMenuTransfer(.kermitGet, files: [d.filename])
    }

    @objc func kermitSend(_ sender: Any?) {
        chooseSend("Tera Term: Kermit送信", multi: true) { [weak self] f in self?.startMenuTransfer(.kermitSend, files: f) }
    }

    @objc func kermitFinish(_ sender: Any?) { startMenuTransfer(.kermitFinish) }

    // MARK: - 転送 ▸ XMODEM

    @objc func xmodemReceive(_ sender: Any?) {
        guard !transferBusy else { NSSound.beep(); return }
        let opt = transferOptions.xmodemOpt
        let crc = opt == XmodemOption.crc || opt == XmodemOption.oneKCRC
        TransferFilePanels.xmodemReceive(fileDir: transferFileDir, crc: crc, binary: transferOptions.xmodemBin,
                                         over: window) { [weak self] r in
            guard let self = self, let r = r else { return }
            // ts.XmodemOpt は 1K のビットを残して チェックサム / CRC を、ts.XmodemBin はダイアログの値に
            self.startMenuTransfer(.xmodemRecv, files: [r.file], binaryFlag: r.binary ? 1 : 0,
                                   xmodemOption: r.crc ? XmodemOption.crc : XmodemOption.check)
        }
    }

    @objc func xmodemSend(_ sender: Any?) {
        guard !transferBusy else { NSSound.beep(); return }
        let opt = transferOptions.xmodemOpt
        let oneK = opt == XmodemOption.oneKCRC || opt == XmodemOption.oneKCksum
        TransferFilePanels.xmodemSend(fileDir: transferFileDir, filter: transferExtra.fileSendFilter, oneK: oneK,
                                      over: window) { [weak self] r in
            guard let self = self, let r = r else { return }
            // 1K なら Xopt1kCRC、でなければ XoptCRC を渡し、CRC / チェックサムは ts.XmodemOpt のまま
            self.startMenuTransfer(.xmodemSend, files: [r.file],
                                   xmodemOption: r.oneK ? XmodemOption.oneKCRC : XmodemOption.crc)
        }
    }

    // MARK: - 転送 ▸ YMODEM

    @objc func ymodemReceive(_ sender: Any?) { startMenuTransfer(.ymodemRecv) }

    @objc func ymodemSend(_ sender: Any?) {
        chooseSend("Tera Term: YMODEM送信", multi: true) { [weak self] f in self?.startMenuTransfer(.ymodemSend, files: f) }
    }

    // MARK: - 転送 ▸ ZMODEM

    @objc func zmodemReceive(_ sender: Any?) { startMenuTransfer(.zmodemRecv) }

    @objc func zmodemSend(_ sender: Any?) {
        guard !transferBusy else { NSSound.beep(); return }
        TransferFilePanels.zmodemSend(fileDir: transferFileDir, filter: transferExtra.fileSendFilter,
                                      binary: transferOptions.xmodemBin, over: window) { [weak self] r in
            guard let self = self, let r = r else { return }
            // ts.XmodemBin = Opt。この転送もダイアログの値で
            self.transferOptions.xmodemBin = r.binary
            self.startMenuTransfer(.zmodemSend, files: r.files, binaryFlag: r.binary ? 1 : 0)
        }
    }

    // MARK: - 転送 ▸ B-Plus

    /// BPStartReceive(TRUE, TRUE): 自動モード (メッセージなし)
    @objc func bplusReceive(_ sender: Any?) { startMenuTransfer(.bplusAutoRecv, noMessages: true) }

    @objc func bplusSend(_ sender: Any?) {
        chooseSend("Tera Term: B-Plus送信", multi: false) { [weak self] f in self?.startMenuTransfer(.bplusSend, files: f) }
    }

    // MARK: - 転送 ▸ Quick-VAN

    @objc func quickvanReceive(_ sender: Any?) { startMenuTransfer(.quickvanRecv) }

    @objc func quickvanSend(_ sender: Any?) {
        chooseSend("Tera Term: Quick-VAN送信", multi: true) { [weak self] f in self?.startMenuTransfer(.quickvanSend, files: f) }
    }

    private func chooseSend(_ title: String, multi: Bool, start: @escaping ([String]) -> Void) {
        guard !transferBusy else { NSSound.beep(); return }
        TransferFilePanels.chooseSendFiles(title: title, multi: multi, filter: transferExtra.fileSendFilter,
                                           fileDir: transferFileDir, over: window) { files in
            if let f = files { start(f) }
        }
    }

    // MARK: - SSH SCP (ttxssh.c TTXScpDialog / ssh.c SSH_scp_transaction)

    @objc func sshScp(_ sender: Any?) {
        guard case .ssh? = spec, connected else { NSSound.beep(); return }
        let d = ScpDialog(scpSendDir: dropSettings.scpSendDir, recvDir: transferFileDir)
        _ = d.run(over: window)
        dropSettings.scpSendDir = d.savedSendDir   // ts.ScpSendDir
        switch d.action {
        case .send(let file, let toDir)?: scpDialogSend(file: file, toDir: toDir)
        case .receive(let remote, let localDir)?: scpDialogReceive(remote: remote, localDir: localDir)
        case nil: break
        }
    }

    private func scpAlert(_ title: String, _ text: String, style: NSAlert.Style = .critical) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func scpDialogSend(file: String, toDir: String) {
        // fopen(filename, "rb") できなければ「TTSSH: ファイルオープンエラー」
        let path = (file as NSString).expandingTildeInPath
        guard let fp = fopen(path, "rb") else {
            let err = String(cString: strerror(errno))
            scpAlert("TTSSH: ファイルオープンエラー", "読み取り用にファイルを開けません: \(err) \(file)")
            return
        }
        fclose(fp)
        // 送信先が空なら "." (リモートのホーム)
        guard let args = scpArguments(send: true, from: path, to: toDir) else { return }
        let ok = runScp(args, label: "SCP ファイル送信中", file: path) { [weak self] ok in
            if !ok { self?.scpAlert("TTSSH: SCP エラー", "scp send error") }
        }
        if !ok { scpAlert("TTSSH: SCP エラー", "scp send error") }
    }

    private func scpDialogReceive(remote: String, localDir: String) {
        let name = remote.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? remote
        guard !name.isEmpty else { return }
        // 受信先: 空なら FileDir/名前、フォルダなら そのフォルダ/名前、それ以外はそのままファイル名
        let local: String
        if localDir.isEmpty {
            local = (transferFileDir as NSString).appendingPathComponent(name)
        } else if FileTransferPaths.folderExists(localDir) {
            local = (localDir as NSString).appendingPathComponent(name)
        } else {
            local = localDir
        }
        if access(local, F_OK) == 0 {
            if access(local, W_OK) != 0 {
                scpAlert("TTSSH: ファイルオープンエラー", "ファイル `\(local)' は読み取り専用です.")
                return
            }
            let a = NSAlert()
            a.alertStyle = .informational
            a.messageText = "TTSSH: 確認"
            a.informativeText = "ファイル `\(local)' が存在します.\n上書きしますか？"
            a.addButton(withTitle: "はい")
            a.addButton(withTitle: "いいえ")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        // fopen(localfilefull, "wb")
        guard let fp = fopen(local, "wb") else {
            let err = String(cString: strerror(errno))
            scpAlert("TTSSH: ファイルオープンエラー", "書き込み用にファイルを開けません: \(err) \(local)")
            return
        }
        fclose(fp)
        guard var args = scpArguments(send: false, from: remote, to: local) else { return }
        args.insert("-p", at: args.count - 2)   // scp -p -f (更新日時などを保つ)
        let ok = runScp(args, label: "SCP ファイル受信中", file: local) { [weak self] ok in
            if !ok { self?.scpAlert("TTSSH: SCP エラー", "scp receive error") }
        }
        if !ok { scpAlert("TTSSH: SCP エラー", "scp receive error") }
    }
}
