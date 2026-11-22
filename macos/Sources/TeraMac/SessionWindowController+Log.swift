// ファイル メニューのログの項目 (vtwin.cpp OnFileLog / OnPauseLog / OnCommentToLog / OnViewLog / OnShowLogDialog / OnStopLog)
// (Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project, BSD 3-Clause)

import AppKit
import ObjectiveC
import TeraCore

private var logProgressKey: UInt8 = 0

extension SessionWindowController {

    // MARK: - ログ記録中ダイアログ

    /// このウインドウの「ログ記録中」(FileTransDlg)
    var logProgressWindow: LogProgressWindow? {
        get { objc_getAssociatedObject(self, &logProgressKey) as? LogProgressWindow }
        set { objc_setAssociatedObject(self, &logProgressKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// FLogOpen から: 「ログ記録中」を作る。HideDialog なら表示しない
    func showLogProgressWindow(hidden: Bool) {
        closeLogProgressWindow()
        guard let l = teraLog else { return }
        let w = LogProgressWindow(session: self, path: l.path)
        logProgressWindow = w
        w.start(hidden: hidden)
    }

    /// FLogClose から
    func closeLogProgressWindow() {
        logProgressWindow?.close()
        logProgressWindow = nil
    }

    // MARK: - メニュー

    /// ログ(L)... (OnFileLog)
    @objc func openLogDialog(_ sender: Any?) {
        guard teraLog == nil, let w = window else { return }
        let dlg = LogDialog(session: self)
        dlg.begin(on: w) { [weak self] r in
            guard let self = self, let r = r else { return }
            if !r.append {
                try? FileManager.default.removeItem(atPath: r.path)   // DeleteFileW
            }
            if self.startLog(path: r.path, options: r.options, code: r.code, bom: r.bom) {
                // 現在バッファにあるデータをすべて書き出してから、ログ採取を開始する (テキストのときだけ)
                if let l = self.teraLog, !l.isBinary, r.options.includeScreenBuffer {
                    self.outputAllBufferToLog()
                }
            } else {
                // ログできない
                let a = NSAlert()
                a.alertStyle = .critical
                a.messageText = "Tera Term: ファイル オープン エラー"
                a.informativeText = "ログファイルに書き込めません。\n\(r.path)"
                a.beginSheetModal(for: w, completionHandler: nil)
            }
        }
    }

    /// FLogOutputAllBuffer: スクロールバックと画面のすべての行を文字で書く (行ごとに CR+LF)
    func outputAllBufferToLog() {
        guard let l = teraLog else { return }
        var s = ""
        for i in 0..<term.totalLines {
            s += term.line(at: i).text
            s += "\r\n"
        }
        l.writeString(Array(s.utf8))
    }

    /// ログを中断 (OnPauseLog)
    @objc func togglePauseLog(_ sender: Any?) {
        guard teraLog != nil else { return }
        logPaused.toggle()
        logProgressWindow?.refresh()
    }

    /// ログにコメントを付加... (OnCommentToLog)
    @objc func commentToLog(_ sender: Any?) {
        guard let w = window else { return }
        guard teraLog != nil else {
            // 選択できないので呼ばれないはず
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "エラー"
            a.informativeText = "ログファイルを開けません"
            a.beginSheetModal(for: w, completionHandler: nil)
            return
        }
        CommentDialog().begin(on: w) { [weak self] s in
            guard let self = self, let s = s, !s.isEmpty else { return }
            self.writeLogString(Array(s.utf8))
            self.writeLogString(Array("\n".utf8))   // TODO 改行コード (Tera Term と同じく LF)
        }
    }

    /// ログを表示 (OnViewLog): ViewlogEditor (Windows の既定は notepad.exe) で開く。
    /// Mac は UserDefaults の logViewlogEditor (アプリのパス) があればそれ、なければテキストエディット
    @objc func viewLog(_ sender: Any?) {
        guard let p = logPath else { return }
        let file = URL(fileURLWithPath: p)
        let ws = NSWorkspace.shared
        var app: URL?
        if let e = UserDefaults.standard.string(forKey: "logViewlogEditor"), !e.isEmpty {
            app = URL(fileURLWithPath: (e as NSString).expandingTildeInPath)
        } else {
            app = ws.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        }
        let fail: (Error?) -> Void = { [weak self] err in
            DispatchQueue.main.async {
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "エラー"
                a.informativeText = "ログファイルを表示できません (\((err as NSError?)?.code ?? 0))"
                if let w = self?.window { a.beginSheetModal(for: w, completionHandler: nil) } else { a.runModal() }
            }
        }
        guard let appURL = app else {
            if !ws.open(file) { fail(nil) }
            return
        }
        ws.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err = err { fail(err) }
        }
    }

    /// ログ記録中ダイアログを表示 (OnShowLogDialog / FLogShowDlg)
    @objc func showLogDialog(_ sender: Any?) {
        logProgressWindow?.showNormal()
    }

    /// ログを終了 (OnStopLog / FLogClose)。確認しない
    @objc func stopLogMenu(_ sender: Any?) {
        stopLog()
    }

    /// ログの項目を使えるか (InitMenuPopup)。ログの項目でなければ nil
    func validateLogMenuItem(_ item: NSMenuItem) -> Bool? {
        let logging = teraLog != nil
        switch item.action {
        case #selector(openLogDialog(_:)):
            return !logging
        case #selector(togglePauseLog(_:)):
            item.state = logging && logPaused ? .on : .off
            return logging
        case #selector(commentToLog(_:)), #selector(viewLog(_:)), #selector(showLogDialog(_:)), #selector(stopLogMenu(_:)):
            return logging
        default:
            return nil
        }
    }
}
