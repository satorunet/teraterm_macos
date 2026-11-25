import Foundation

/// send / sendtext / sendbinary の送り方
public enum TTLSendMode {
    /// send: 文字として読めれば文字列、読めなければバイナリ (Tera Term の SendData)
    case compat
    /// sendtext: UTF-8 の文字列として送る (送信時に端末の文字コードへ変換)
    case text
    /// sendbinary: バイト列をそのまま送る
    case binary
}

/// ファイル転送の種類
public enum TTLTransfer {
    case xmodemSend, xmodemRecv, ymodemSend, ymodemRecv, zmodemSend, zmodemRecv
    case kermitSend, kermitRecv, kermitGet, kermitFinish
    case bplusSend, bplusRecv, quickvanSend, quickvanRecv
}

/// logopen のオプション
public struct TTLLogOptions {
    public var binary = false
    public var append = false
    public var plainText = false
    public var timestamp = false
    /// "Logging" ダイアログの表示状態 (tttypes.h enum LogDialogShowState, 23aa80682 #1576)
    /// 0: SHOWSTATE_HIDDEN 1: SHOWSTATE_MINIMIZED (既定) 2: SHOWSTATE_NORMAL
    public var dialogShowState = 1
    /// ダイアログを出さない (以前の LogHideDialog。dialogShowState == 0)
    public var hideDialog: Bool {
        get { dialogShowState == 0 }
        set { if newValue { dialogShowState = 0 } else if dialogShowState == 0 { dialogShowState = 1 } }
    }
    public var includeScreenBuffer = false
    /// 0: ローカル時刻 1: UTC 2: 経過時間 (ログ開始から) 3: 経過時間 (接続から)
    public var timestampType = 0
    public init() {}
}

/// listbox の拡張オプション
public struct TTLListBoxOptions {
    public var doubleClick = false
    public var minMaxButton = false
    public var minimize = false
    public var maximize = false
    public var size: (Int, Int)?
    public init() {}
}

/// マクロが端末ウインドウに頼む操作。マクロのスレッドから呼ばれる (メインスレッドではない)
public protocol TTLHost: AnyObject {
    func ttlMacroStarted(_ macro: TTLInterpreter)
    /// エラーを見せる。true を返すとマクロを止める (false は「続行」)
    func ttlError(message: String, line: Int, lineText: String, file: String, range: Range<Int>) -> Bool

    // 送受信
    func ttlSend(_ bytes: [UInt8], mode: TTLSendMode)
    func ttlSendBreak()
    func ttlSendKCode(_ keyCode: Int, count: Int)
    /// sendbroadcast / sendmulticast。name が nil なら全ウインドウ
    func ttlSendBroadcast(_ bytes: [UInt8], multicastName: String?)
    func ttlSetMulticastName(_ name: String)
    func ttlSendFile(_ path: String, binary: Bool) -> Bool
    func ttlRecvFile(_ path: String, binary: Bool, autoStopSec: Int) -> Bool

    // 接続
    /// connect / cygconnect。接続を始めたら true。結果は setComReady で知らせる
    func ttlConnect(_ param: String, cygwin: Bool) -> Bool
    func ttlDisconnect(confirm: Bool)
    /// unlink / closett のあとの connect: 新しい端末ウインドウを開いて、マクロをそちらにつなぎ直す
    func ttlLinkNewWindow() -> Bool
    func ttlCloseTT()
    func ttlIsConnected() -> Bool
    /// connect のあと、まだ接続を試している途中なら true
    func ttlIsConnecting() -> Bool
    /// unlink / closett: マクロが端末から離れた (Tera Term の DDE 切断。logautoclose はここで閉じる)
    func ttlUnlink()
    /// beep の種類 (0: 既定 1: 情報 2: 警告 3: エラー 4: 問い合わせ 5: 標準)
    func ttlBeep(_ type: Int)

    // 画面・ウインドウ
    func ttlShowTT(_ mode: Int)
    func ttlSetTitle(_ s: String)
    func ttlGetTitle() -> String
    func ttlClearScreen(_ mode: Int)
    func ttlDispStr(_ bytes: [UInt8])
    func ttlEnableKeyboard(_ on: Bool)
    /// (ウインドウの x, y, 幅, 高さ, 内側の x, y, 幅, 高さ)
    func ttlGetTTPos() -> [Int]?
    func ttlCallMenu(_ id: Int)
    func ttlChangeDir(_ path: String)
    func ttlLoadKeyMap(_ path: String)
    func ttlRestoreSetup(_ path: String)
    func ttlSetEcho(_ on: Bool)
    func ttlSetDebug(_ mode: Int)

    // ログ
    /// logopen。name はマクロに書いたままのファイル名 (strftime・&h などの展開と、相対パスの扱いはホストが行う)。
    /// すでにログを取っていたら false (前のログはそのまま)
    func ttlLogOpen(_ name: String, options: TTLLogOptions) -> Bool
    func ttlLogClose()
    func ttlLogPause()
    func ttlLogStart()
    func ttlLogWrite(_ s: [UInt8])
    /// (オプションの和 1 binary 2 append 4 plain 8 timestamp 16 hide dialog, ファイルのパス)。ログを取っていなければ nil
    func ttlLogInfo() -> (flags: Int, path: String)?
    func ttlLogRotate(_ command: String)
    func ttlLogAutoClose(_ on: Bool)

    // ファイル転送
    /// 結果は result に入る値 (1: 成功 0: 失敗)。始められなかったら nil (result は変えない)
    func ttlTransfer(_ kind: TTLTransfer, files: [String], option: Int) -> Int?
    func ttlScp(send: Bool, from: String, to: String) -> Bool

    // シリアル
    func ttlSetBaud(_ baud: Int) -> Bool
    func ttlSetDTR(_ on: Bool)
    func ttlSetRTS(_ on: Bool)
    func ttlSetFlowCtrl(_ mode: Int) -> Bool
    /// シリアル接続なら true (result=1)。シリアルでなければ nil (result は変えない)
    func ttlSetSerialDelay(char: Int?, line: Int?) -> Bool?
    /// モデムの状態 (ビット: 1=CTS 2=DSR 4=RI 8=DCD)。取れなければ nil (マクロには 0)
    func ttlGetModemStatus() -> Int?
    /// 接続先のホスト名 (TCP/SSH)
    func ttlGetHostname() -> String?

    // ダイアログ
    /// false = 閉じた (キャンセル) のでマクロを止める
    func ttlMessageBox(_ text: String, title: String) -> Bool
    /// 入力された文字列。nil = 閉じた (マクロを止める)
    func ttlInputBox(_ text: String, title: String, defaultValue: String, secret: Bool) -> String?
    /// 1: はい 0: いいえ -1: 閉じた (マクロを止める)
    func ttlYesNoBox(_ text: String, title: String) -> Int
    func ttlStatusBox(_ text: String, title: String)
    func ttlCloseStatus()
    func ttlBringupBox()
    /// setdlgpos。x が Int.min なら既定の位置 (中央) に戻す。position (1〜10) があれば x, y は使わず offset を足す
    func ttlSetDialogPos(x: Int, y: Int, position: Int, offsetX: Int, offsetY: Int)
    func ttlShowMacroWindow(_ mode: Int)
    /// 選んだ番号 (0〜)、-1: キャンセル、-2: 閉じた (マクロを止める)
    func ttlListBox(_ text: String, title: String, items: [String], selected: Int, options: TTLListBoxOptions) -> Int
    func ttlFileNameBox(_ title: String, save: Bool, initialDir: String?) -> String?
    func ttlDirNameBox(_ title: String, initialDir: String?) -> String?

    // クリップボード
    func ttlGetClipboard() -> String?
    func ttlSetClipboard(_ s: String) -> Bool

    /// Tera Term (このアプリ) の場所 (getttdir)
    func ttlAppDirectory() -> String

    /// recvfile (raw.c)。result に入る値 (1: 自動停止で成功 0: キャンセル・切断)。始められなかったら nil (result は変えない)。
    /// path はマクロが書いたままの文字列 (相対パスは FileDir から)
    func ttlRecvFileResult(_ path: String, autoStopSec: Int) -> Int?
}

/// 何もしない既定の動き (テスト用・未実装の機能用)
public extension TTLHost {
    func ttlMacroStarted(_ macro: TTLInterpreter) {}
    func ttlError(message: String, line: Int, lineText: String, file: String, range: Range<Int>) -> Bool { true }
    func ttlSendBreak() {}
    func ttlSendKCode(_ keyCode: Int, count: Int) {}
    func ttlSendBroadcast(_ bytes: [UInt8], multicastName: String?) { ttlSend(bytes, mode: .compat) }
    func ttlSetMulticastName(_ name: String) {}
    func ttlSendFile(_ path: String, binary: Bool) -> Bool { false }
    func ttlRecvFile(_ path: String, binary: Bool, autoStopSec: Int) -> Bool { false }
    func ttlConnect(_ param: String, cygwin: Bool) -> Bool { false }
    func ttlDisconnect(confirm: Bool) {}
    func ttlLinkNewWindow() -> Bool { true }
    func ttlCloseTT() { ttlDisconnect(confirm: false) }
    func ttlIsConnected() -> Bool { true }
    func ttlIsConnecting() -> Bool { false }
    func ttlUnlink() {}
    func ttlBeep(_ type: Int) {}
    func ttlShowTT(_ mode: Int) {}
    func ttlSetTitle(_ s: String) {}
    func ttlGetTitle() -> String { "" }
    func ttlClearScreen(_ mode: Int) {}
    func ttlDispStr(_ bytes: [UInt8]) {}
    func ttlEnableKeyboard(_ on: Bool) {}
    func ttlGetTTPos() -> [Int]? { nil }
    func ttlCallMenu(_ id: Int) {}
    func ttlChangeDir(_ path: String) {}
    func ttlLoadKeyMap(_ path: String) {}
    func ttlRestoreSetup(_ path: String) {}
    func ttlSetEcho(_ on: Bool) {}
    func ttlSetDebug(_ mode: Int) {}
    func ttlLogOpen(_ path: String, options: TTLLogOptions) -> Bool { false }
    func ttlLogClose() {}
    func ttlLogPause() {}
    func ttlLogStart() {}
    func ttlLogWrite(_ s: [UInt8]) {}
    func ttlLogInfo() -> (flags: Int, path: String)? { nil }
    func ttlLogRotate(_ command: String) {}
    func ttlLogAutoClose(_ on: Bool) {}
    func ttlTransfer(_ kind: TTLTransfer, files: [String], option: Int) -> Int? { 0 }
    func ttlScp(send: Bool, from: String, to: String) -> Bool { false }
    func ttlSetBaud(_ baud: Int) -> Bool { false }
    func ttlSetDTR(_ on: Bool) {}
    func ttlSetRTS(_ on: Bool) {}
    func ttlSetFlowCtrl(_ mode: Int) -> Bool { false }
    func ttlSetSerialDelay(char: Int?, line: Int?) -> Bool? { nil }
    func ttlGetModemStatus() -> Int? { nil }
    func ttlGetHostname() -> String? { nil }
    func ttlMessageBox(_ text: String, title: String) -> Bool { true }
    func ttlInputBox(_ text: String, title: String, defaultValue: String, secret: Bool) -> String? { "" }
    func ttlYesNoBox(_ text: String, title: String) -> Int { 1 }
    func ttlStatusBox(_ text: String, title: String) {}
    func ttlCloseStatus() {}
    func ttlBringupBox() {}
    func ttlSetDialogPos(x: Int, y: Int, position: Int, offsetX: Int, offsetY: Int) {}
    func ttlShowMacroWindow(_ mode: Int) {}
    func ttlListBox(_ text: String, title: String, items: [String], selected: Int, options: TTLListBoxOptions) -> Int { selected }
    func ttlFileNameBox(_ title: String, save: Bool, initialDir: String?) -> String? { nil }
    func ttlDirNameBox(_ title: String, initialDir: String?) -> String? { nil }
    func ttlGetClipboard() -> String? { nil }
    func ttlSetClipboard(_ s: String) -> Bool { false }
    func ttlAppDirectory() -> String { Bundle.main.bundlePath }
    func ttlRecvFileResult(_ path: String, autoStopSec: Int) -> Int? {
        ttlRecvFile(path, binary: true, autoStopSec: autoStopSec) ? 1 : 0
    }
}

public extension TTLInterpreter {
    /// testlink と同じ (0: リンクなし 1: リンクのみ 2: 接続中)
    var linkState: Int {
        recv.lock(); defer { recv.unlock() }
        return !linked ? 0 : (comReady ? 2 : 1)
    }
}

/// ttmdde.c の送信バッファの大きさ (send / sendln は 511 バイトまで)
let OutBufSize = 512

extension TTLInterpreter {
    /// listbox の "listboxsize=WxH" (swscanf "%[^=]=%d%[xX]%d" と同じ読み方)
    static func scanListBoxSize(_ s: String) -> (Int, Int)? {
        guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { return nil }
        let rest = s[s.index(after: eq)...]
        // %d
        let digitsEnd: (Substring) -> Substring.Index = { sub in
            var i = sub.startIndex
            while i < sub.endIndex, sub[i] == " " || sub[i] == "\t" { i = sub.index(after: i) }
            if i < sub.endIndex, sub[i] == "+" || sub[i] == "-" { i = sub.index(after: i) }
            while i < sub.endIndex, sub[i].isASCII, sub[i].isNumber { i = sub.index(after: i) }
            return i
        }
        let e1 = digitsEnd(rest)
        guard let w = TTCommandLine.scanInt(String(rest[rest.startIndex..<e1])) else { return nil }
        var i = e1
        var nx = 0
        while i < rest.endIndex, rest[i] == "x" || rest[i] == "X" { i = rest.index(after: i); nx += 1 }
        guard nx > 0 else { return nil }
        let tail = rest[i...]
        guard let h = TTCommandLine.scanInt(String(tail)) else { return nil }
        return (w, h)
    }
}
