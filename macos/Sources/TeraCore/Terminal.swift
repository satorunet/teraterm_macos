import Foundation

public enum TColor: Equatable {
    case def
    case idx(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct CellAttr: Equatable {
    public var fg: TColor = .def
    public var bg: TColor = .def
    /// 太字などはビットで持つ (1 文字分を小さくして、メモリと複製の手間を減らす)
    private var flags: UInt16 = 0
    @inline(__always) private func bit(_ b: UInt16) -> Bool { flags & b != 0 }
    @inline(__always) private mutating func set(_ b: UInt16, _ v: Bool) { if v { flags |= b } else { flags &= ~b } }
    public var bold: Bool { get { bit(1) } set { set(1, newValue) } }
    public var dim: Bool { get { bit(2) } set { set(2, newValue) } }
    public var italic: Bool { get { bit(4) } set { set(4, newValue) } }
    public var underline: Bool { get { bit(8) } set { set(8, newValue) } }
    public var blink: Bool { get { bit(16) } set { set(16, newValue) } }
    public var reverse: Bool { get { bit(32) } set { set(32, newValue) } }
    public var invisible: Bool { get { bit(64) } set { set(64, newValue) } }
    public var strike: Bool { get { bit(128) } set { set(128, newValue) } }
    /// DEC Special Graphics の文字 (Tera Term の AttrSpecial)。ch には同じ形の Unicode 文字が入り、幅はいつも 1
    public var decSpecial: Bool { get { bit(256) } set { set(256, newValue) } }
    public init() {}
}

/// 1 つの Unicode スカラーでない文字 (結合文字つきなど) の置き場。Cell には番号だけ入れる
enum ClusterTable {
    private static var list: [Character] = []
    private static var index: [Character: UInt32] = [:]
    private static let lock = NSLock()
    static func id(_ c: Character) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        if let i = index[c] { return i }
        let i = UInt32(list.count)
        list.append(c); index[c] = i
        return i
    }
    static func char(_ i: UInt32) -> Character {
        lock.lock(); defer { lock.unlock() }
        return Int(i) < list.count ? list[Int(i)] : " "
    }
}

public struct Cell: Equatable {
    /// 文字: ふつうは Unicode スカラーの値そのもの。最上位ビットが立っていたら ClusterTable の番号
    private var code: UInt32 = 0x20
    public var attr = CellAttr()
    /// 1 = 半角, 2 = 全角の左半分, 0 = 全角の右半分
    public var width: UInt8 = 1
    private static let clusterBit: UInt32 = 0x8000_0000

    public var ch: Character {
        get {
            if code & Cell.clusterBit != 0 { return ClusterTable.char(code & ~Cell.clusterBit) }
            return Character(Unicode.Scalar(code) ?? " ")
        }
        set {
            let u = newValue.unicodeScalars
            if u.count == 1, let f = u.first { code = f.value } else { code = Cell.clusterBit | ClusterTable.id(newValue) }
        }
    }
    /// 1 つのスカラーの文字ならその値 (速い判定用)
    public var scalarValue: UInt32? { code & Cell.clusterBit == 0 ? code : nil }

    public init() {}
    public init(ch: Character, attr: CellAttr, width: UInt8) {
        self.attr = attr; self.width = width; self.ch = ch
    }
    public init(scalar: Unicode.Scalar, attr: CellAttr, width: UInt8) {
        self.code = scalar.value; self.attr = attr; self.width = width
    }
}

public struct Line {
    public var cells: [Cell]
    /// 右端で自動折り返しして次の行に続いている
    public var wrapped = false
    public init(cols: Int, attr: CellAttr = CellAttr()) {
        var c = Cell(); c.attr.bg = attr.bg
        cells = Array(repeating: c, count: cols)
    }
    public var text: String {
        var s = ""
        for c in cells where c.width != 0 { s.append(c.ch) }
        return s
    }
}

public enum CursorStyle { case block, underline, bar }

/// OSC で変える色の 24 ビット値 (COLORREF)
public struct RGB: Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// OSC 4 / 5 / 10〜19 で変える色 (vtdisp.h CS_VT_* / CS_TEK_*)
public enum ColorSlot: Hashable {
    /// 256 色表 (vt->ANSIColor) の番号。8 色モードのときは GetIndex256From16 したもの (表示に使う番号)
    case ansi(Int)
    case normalFG, normalBG, boldFG, boldBG, blinkFG, underFG, reverseBG, tekFG, tekBG
}

/// XtColor2TTColor の結果 (CS_ANSICOLOR_ALL / CS_SP_ALL はリセットだけ)
public enum ColorTarget: Equatable {
    case slot(ColorSlot)
    case allANSI
    case allSpecial
}

// MARK: - Tera Term の設定 (ts) に対応する型

/// 端末ID (TerminalID。common/tttypes_termid.cpp)
public enum TerminalID: String, CaseIterable {
    case vt100 = "VT100", vt100j = "VT100J", vt101 = "VT101", vt102 = "VT102", vt102j = "VT102J"
    case vt220 = "VT220", vt220j = "VT220J", vt282 = "VT282", vt320 = "VT320", vt382 = "VT382"
    case vt420 = "VT420", vt520 = "VT520", vt525 = "VT525", dumb = "dumb"

    /// TermIDGetID: 大文字小文字も区別して比べ、知らない名前は VT100
    public init(ini: String) { self = TerminalID(rawValue: ini) ?? .vt100 }

    /// TermIDGetVTLevel
    public var vtLevel: Int {
        switch self {
        case .vt100, .vt100j, .vt101, .dumb: return 1
        case .vt102, .vt102j, .vt220, .vt220j: return 2
        case .vt282, .vt320, .vt382: return 3
        case .vt420: return 4
        case .vt520, .vt525: return 5
        }
    }

    /// DA1 (CSI c / ESC Z) の応答 (vtterm.c AnswerTerminalType)。dumb は応答しない
    public var primaryDA: String? {
        let p: String
        switch self {
        case .vt100: p = "1;2"
        case .vt100j: p = "5;2"
        case .vt101: p = "1;0"
        case .vt102: p = "6"
        case .vt102j: p = "15"
        case .vt220: p = "62;1;2;6;7;8;9"
        case .vt220j: p = "62;1;2;5;6;7;8"
        case .vt282: p = "62;1;2;4;5;6;7;8;10;11"
        case .vt320: p = "63;1;2;6;7;8;9"
        case .vt382: p = "63;1;2;4;5;6;7;8;10;15"
        case .vt420: p = "64;1;2;6;7;8;9;15;18;19;21"
        case .vt520: p = "65;1;2;7;9;12;18;19;21;23;24;42;44;45;46"
        case .vt525: p = "65;1;2;7;9;12;18;19;21;22;23;24;42;44;45;46"
        case .dumb: return nil
        }
        return "\u{1B}[?" + p + "c"
    }

    /// DA2 (CSI > c)。Tera Term は端末IDによらず VT382 + xterm rev 331
    public static let secondaryDA = "\u{1B}[>32;331;0c"
}

/// ウィンドウタイトルの変更要求 (AcceptTitleChangeRequest)
public enum TitleChangeMode: String {
    case off, overwrite, ahead, last
    /// ttset.c: overwrite / on → 上書き、ahead、last、それ以外は無効 (大文字小文字は無視)
    public init(ini: String) {
        switch ini.lowercased() {
        case "overwrite", "on": self = .overwrite
        case "ahead": self = .ahead
        case "last": self = .last
        default: self = .off
        }
    }
}

/// ウィンドウタイトルの報告要求 (TitleReportSequence)
public enum TitleReportMode: String {
    case ignore, accept, empty
    /// ttset.c: accept、ignore / off、それ以外は空白
    public init(ini: String) {
        switch ini.lowercased() {
        case "accept": self = .accept
        case "ignore", "off": self = .ignore
        default: self = .empty
        }
    }
}

/// リモートからのクリップボードアクセス (ClipboardAccessFromRemote)
public struct ClipboardAccess: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let read = ClipboardAccess(rawValue: 1)
    public static let write = ClipboardAccess(rawValue: 2)
    public static let off: ClipboardAccess = []
    public static let readWrite: ClipboardAccess = [.read, .write]
    /// ttset.c: on / readwrite、read、write、それ以外は無効
    public init(ini: String) {
        switch ini.lowercased() {
        case "on", "readwrite": self = .readWrite
        case "read": self = .read
        case "write": self = .write
        default: self = .off
        }
    }
}

/// OSC 52 の通知 (NotifyClipboardAccess がオンのとき。vtterm.c XsProcClipboard の NotifyInfo/WarnMessage)
public enum ClipboardNotice: Equatable {
    case read
    case write(String)
    case readRejected
    case writeRejected
    /// 拒否のときは警告 (NotifyWarnMessage)
    public var isWarning: Bool { self == .readRejected || self == .writeRejected }
    /// ja_JP.lng MSG_CBACCESS_TITLE / MSG_CBACCESS_REJECT_TITLE
    public var title: String {
        isWarning ? Lang.t("Tera Term", "MSG_CBACCESS_REJECT_TITLE", "クリップボードアクセスの拒否")
                  : Lang.t("Tera Term", "MSG_CBACCESS_TITLE", "クリップボードアクセス")
    }
    public var message: String {
        switch self {
        case .read: return Lang.t("Tera Term", "MSG_CBACCESS_READ", "リモートホストがクリップボードの内容を読み取りました。")
        case .write(let t): return Lang.t("Tera Term", "MSG_CBACCESS_WRITE", "リモートホストがクリップボードに書き込みました。") + "\n--\n" + t
        case .readRejected: return Lang.t("Tera Term", "MSG_CBACCESS_READ_REJECT", "リモートホストからのクリップボード読み取りを拒否しました。")
        case .writeRejected: return Lang.t("Tera Term", "MSG_CBACCESS_WRITE_REJECT", "リモートホストからのクリップボード書き込みを拒否しました。")

        }
    }
}

/// ベル (Beep)
public enum BellKind: String {
    case off, sound, visual
    /// ttset.c: off、visual、それ以外はサウンド
    public init(ini: String) {
        switch ini.lowercased() {
        case "off": self = .off
        case "visual": self = .visual
        default: self = .sound
        }
    }
}

/// DEC Special Graphics のマッピング (DecSpMappingDir)
public enum DecSpecialMapping: Int {
    /// 0: Unicode の罫線などを DEC Special Graphics として扱う (UnicodeToDecSpMapping のビットで選ぶ)
    case unicodeToDec = 0
    /// 1: DEC Special Graphics を Unicode の文字にする (幅は Unicode の規則)
    case decToUnicode = 1
    /// 2: マッピングしない (DEC Special Graphics は特殊フォントで 1 桁)
    case doNot = 2
    /// ttset.c: 0/1/2、それ以外は 0
    public init(ini: Int) { self = DecSpecialMapping(rawValue: ini) ?? .unicodeToDec }
}

/// ウィンドウ操作の制御シーケンス (CSI Ps t。WindowCtrlSequence がオンのときだけ)
public enum WindowOp: Equatable {
    case deiconify                       // 1
    case iconify                         // 2
    case move(x: Int, y: Int)            // 3;x;y
    case resizePixels(width: Int, height: Int)   // 4;h;w (DispResizeWin)
    case raise                           // 5
    case lower                           // 6
    case refresh                         // 7
    /// 8;rows;cols (ChangeTerminalSize)。端末とウインドウの大きさを変える
    case resizeTerminal(cols: Int, rows: Int)
    case restore                         // 9;0 / 10;0
    case maximize                        // 9;1 / 10;1
    case toggleMaximize                  // 10;2
}

/// ウィンドウ情報の報告 (CSI 11/13/14/15/16/19 t) に使う値。座標はスクリーンの左上が原点のピクセル
public struct WindowInfo {
    public var iconified = false
    /// ウインドウ全体の左上 (DispGetWindowPos client=FALSE)
    public var windowX = 0, windowY = 0
    /// 描画領域の左上 (client=TRUE)
    public var clientX = 0, clientY = 0
    public var windowWidth = 0, windowHeight = 0
    public var clientWidth = 0, clientHeight = 0
    /// デスクトップ (作業領域) の大きさ (ピクセル)
    public var screenWidth = 0, screenHeight = 0
    /// デスクトップに入る桁数・行数 (DispGetRootWinSize inPixels=FALSE)
    public var screenCols = 0, screenRows = 0
    public var cellWidth = 0, cellHeight = 0
    public init() {}
}

/// 印刷 (PrinterCtrlSequence がオンのとき)
public enum PrintRequest: Equatable {
    /// CSI 0 i: 画面 (DECPEX オン) またはスクロール範囲 (DECPEX オフ) を印刷
    case screen(wholeScreen: Bool)
    /// プリンタコントローラ (CSI 5 i 〜 CSI 4 i)・カーソル行 (CSI ? 1 i)・自動印刷 (CSI ? 5 i) で印刷する文字
    case text(String)
}

/// ウィンドウタイトルの組み立て (ttwinman.c ChangeTitle の TempTitleWithRemote 部分)
public enum TitleFormatter {
    /// local: 設定のタイトル (Title)、remote: リモートから来たタイトル (nil か空なら使わない)
    /// connected: 接続中で接続処理中でない (Connecting || !cv.Ready のときはリモートタイトルを使わない)
    public static func title(local: String, remote: String?, mode: TitleChangeMode, connected: Bool = true) -> String {
        guard connected, let r = remote, !r.isEmpty else { return local }
        switch mode {
        case .off: return local
        case .ahead: return r + " " + local
        case .last: return local + " " + r
        case .overwrite: return r
        }
    }

    /// CSI 20 t / 21 t (TitleReportSequence=accept) で返すタイトル
    public static func report(local: String, remote: String?, mode: TitleChangeMode) -> String {
        let r = remote ?? ""
        switch mode {
        case .off: return local
        case .ahead: return r + " " + local
        case .last: return local + " " + r
        case .overwrite: return remote ?? local
        }
    }
}

/// VT100 / xterm 互換の端末画面
public final class Terminal {
    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var lines: [Line]
    private var savedMainLines: [Line]?
    public private(set) var scrollback = LineBuffer()
    public var scrollbackLimit = 10000
    /// 画面から押し出された行の通算数 (選択範囲の位置合わせに使う)
    public private(set) var scrolledOutTotal = 0

    public private(set) var cx = 0
    public private(set) var cy = 0
    private var wrapPending = false
    public private(set) var attr = CellAttr()
    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabs: [Bool] = []

    public private(set) var usingAlt = false
    public private(set) var appCursor = false
    public private(set) var appKeypad = false
    public private(set) var bracketedPaste = false
    public private(set) var cursorVisible = true
    public private(set) var reverseScreen = false
    public private(set) var cursorStyle: CursorStyle = .block
    /// 既定のカーソル形 (Tera Term の CursorShape)。リセットするとこれに戻る
    public var defaultCursorStyle: CursorStyle = .block { didSet { cursorStyle = defaultCursorStyle } }
    public private(set) var mouseMode = 0     // 0 / 1000 / 1002 / 1003
    public private(set) var mouseSGR = false
    /// SGR-Pixels 形式 (DECSET 1016、vtterm.c IdMouseTrackExtSGRP。f10c93025 #575)。
    /// mouseSGR も true になり、座標は文字の位置ではなくピクセル (ウインドウの点) で送る
    public private(set) var mouseSGRPixels = false
    private var autowrap = true
    private var insertMode = false
    private var originMode = false
    private var lnm = false

    /// 受信した CR を CR+LF として扱う (Tera Term の「改行コード 受信: CR+LF」)
    public var recvCRasCRLF = false
    /// 受信した LF を CR+LF として扱う
    public var recvLFasCRLF = false
    /// AutoWinSwitch (VT<->TEK の自動切り替え): ESC FF・FS/GS/RS/US・CSI ? 38 h・ESC % ! 0 で TEK へ
    public var autoWinSwitch = false
    /// TEK へ切り替える (ChangeEmu = IdTEK)。まだ読んでいない受信 (CommInsert1Byte で戻したものを含む) を渡す
    public var onEnterTEK: (([UInt8]) -> Void)?
    private var tekPrefix: [UInt8]?
    public var ambiguousWide = false

    // MARK: 端末タブ
    /// 端末ID (TerminalID)。DA1 の応答と dumb 端末
    public var terminalID: TerminalID = .vt100
    /// 応答 (Answerback。Hex2Str したバイト列)。ENQ を受けたら送る。空なら何も送らない
    public var answerbackBytes: [UInt8] = []
    /// answerbackBytes を UTF-8 として読み書きする
    public var answerback: String {
        get { String(decoding: answerbackBytes, as: UTF8.self) }
        set { answerbackBytes = Array(newValue.utf8) }
    }

    // MARK: 制御シーケンスタブ
    /// 設定のタイトル (Title)。タイトル報告とタイトルの組み立てに使う
    public var localTitle = "Tera Term"
    /// AcceptTitleChangeRequest。off なら OSC 0/1/2 のタイトルを受け取らない
    public var titleChangeMode: TitleChangeMode = .overwrite
    /// TitleReportSequence (CSI 20 t / 21 t)
    public var titleReportMode: TitleReportMode = .empty
    /// WindowCtrlSequence (CSI 1〜10 t)
    public var windowCtrlEnabled = true
    /// WindowReportSequence (CSI 11〜19 t)
    public var windowReportEnabled = true
    /// CursorCtrlSequence (DECSCUSR、DECSET 12、SM/RM 33・34)
    public var cursorCtrlEnabled = false
    /// ClipboardAccessFromRemote (OSC 52)
    public var clipboardAccess: ClipboardAccess = .off
    /// NotifyClipboardAccess: onClipboardNotice を呼ぶ
    public var notifyClipboardAccess = true
    /// ClearScrollBufferFromRemote (CSI 3 J でバッファを消す)
    public var clearScrollbackFromRemote = true
    /// PrinterCtrlSequence (CSI i / CSI ? i)
    public var printerCtrlEnabled = false
    /// Beep (BEL と ESC g)
    public var bellMode: BellKind = .sound
    /// ベルの鳴りすぎ対策 (BeepOverUsedCount / BeepOverUsedTime 秒 / BeepSuppressTime 秒)
    public var beepOverUsedCount = 5
    public var beepOverUsedTime = 2.0
    public var beepSuppressTime = 5.0
    /// ベルの時刻 (秒。テストで差し替える)
    public var bellClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// OSC の文字列の最大長 (MaxOSCBufferSize)
    public var maxOSCBufferSize = 4096
    /// OSC 4 / 5 / 10 / 11 / 17 / 19 で変えた色 (vt->ANSIColor / vt->BGVT*Color)。ないものは設定の色
    public private(set) var colorOverrides: [ColorSlot: RGB] = [:]
    /// 8 色モード ((ts.ColorFlag & CF_FULLCOLOR) == 0: PcBoldColor・Aixterm16Color・Xterm256Color がどれもオフ)。
    /// OSC 4 の 1〜7 と 9〜15 を入れ替えて覚える (DispSetColor の GetIndex256From16)
    public var eightColorMode = false
    /// 設定の色 (DispGetColor が返す ts.VTColor など。.ansi は表示の 256 色表の初期値)。問い合わせの応答に使う
    public var configuredColor: ((ColorSlot) -> RGB)?
    /// OSC で色が変わった (描き直す)
    public var onColorsChanged: (() -> Void)?
    /// dumb 端末の行頭に出すタイムスタンプ (FLogTimeStampStrW の "[...] ")。nil を返したら出さない (LogTimestamp がオフ)
    public var dumbTimestamp: (() -> String?)?

    // MARK: エンコーディングタブ
    /// 受信の文字コード (KanjiReceive)。OSC 52 で受けた文字の変換と絵文字幅 (UTF-8 のときだけ) に使う
    public var receiveEncoding: TermEncoding = .utf8
    /// 送信の文字コード (KanjiSend)。OSC 52 の読み取り応答とタイトル報告に使う
    public var sendEncoding: TermEncoding = .utf8
    /// DecSpMappingDir
    public var decSpecialMapping: DecSpecialMapping = .doNot
    /// UnicodeToDecSpMapping (bit0 罫線素片、bit1 句読点・ブロック・網掛け、bit2 中点)
    public var unicodeToDecSpMask = 3
    /// UnicodeEmojiOverride がオンなら UnicodeEmojiWidth (1 / 2)。nil ならオーバーライドしない
    public var emojiWidthOverride: Int?

    // MARK: 外への通知
    /// 応答 (DA・DSR など)。onResponseBytes があればそちらを使う
    public var onResponse: ((String) -> Void)?
    /// 応答をバイト列で (Answerback やタイトル報告など UTF-8 でないものも正しく送れる)
    public var onResponseBytes: (([UInt8]) -> Void)?
    /// リモートタイトル (cv.TitleRemoteW) が変わった。引数は新しいリモートタイトル (消えたら "")。
    /// ウインドウのタイトルは TitleFormatter.title(local:remote:mode:) か windowTitle で組み立てる
    public var onTitle: ((String) -> Void)?
    /// ベル (bellMode が off でないとき。onBellKind がなければこちら)
    public var onBell: (() -> Void)?
    /// ベルの種類つき (sound / visual)。鳴りすぎ対策のあとに呼ぶ
    public var onBellKind: ((BellKind) -> Void)?
    /// ウィンドウ操作 (WindowCtrlSequence)
    public var onWindowOp: ((WindowOp) -> Void)?
    /// ウィンドウ情報 (WindowReportSequence)。nil なら CSI 18 t だけ答える
    public var windowInfo: (() -> WindowInfo)?
    /// OSC 52 の書き込み (クリップボードに入れる文字)
    public var onClipboardWrite: ((String) -> Void)?
    /// OSC 52 の読み取り (クリップボードの文字を返す。nil なら応答しない)
    public var onClipboardRead: (() -> String?)?
    /// OSC 52 の通知 (NotifyClipboardAccess)
    public var onClipboardNotice: ((ClipboardNotice) -> Void)?
    /// 印刷 (PrinterCtrlSequence)
    public var onPrint: ((PrintRequest) -> Void)?

    /// リモートから来たタイトル (cv.TitleRemoteW)。OSC 0/1/2 で空にすると nil
    public private(set) var remoteTitle: String?
    private var titleStack: [String?] = []
    /// 今のウインドウタイトル (ChangeTitle の TempTitleWithRemote)
    public var windowTitle: String { TitleFormatter.title(local: localTitle, remote: remoteTitle, mode: titleChangeMode) }
    /// リモートタイトルを消す (メニューのリセットや、タイトルを変えて上書きモードのとき)
    public func clearRemoteTitle() { remoteTitle = nil }
    /// カーソルの点滅 (CursorCtrlSequence で変わる。描画側はこれを見る)
    public private(set) var cursorBlink = true
    /// 既定の点滅 (NonblinkingCursor の逆)。リセットするとこれに戻る
    public var defaultCursorBlink = true { didSet { cursorBlink = defaultCursorBlink } }

    private var printerMode = false
    private var autoPrintMode = false
    private var printExtent = true
    private var printBuf = ""
    private var bellSuppressAt = -Double.infinity
    private var bellStartAt = -Double.infinity
    private var bellOverUsedLeft = 0
    /// マクロ (TTL の wait など) に渡す文字列 (UTF-8)。Tera Term と同じく表示した文字と CR/LF/TAB/BS だけで、
    /// エスケープシーケンスは含まない。改行はログと同じく CR+LF / LF にそろえ、単独の CR は捨てる
    public var onMacroText: (([UInt8]) -> Void)?
    /// Tera Term の LogTypePlainText。on のとき BS をマクロ・ログに出さない (配布の TERATERM.INI は on)
    public var logTypePlainText = true
    /// その他の設定 > 表示: 16色モード(aixterm形式) / 256色モード(xterm形式)
    public var aixterm16Color = true
    public var xterm256Color = true
    private var macroBuf: [UInt8] = []
    private var macroCRHold = false

    private enum Charset { case ascii, dec, uk }
    private var g: [Charset] = [.ascii, .ascii, .ascii, .ascii]
    private var gl = 0
    private var singleShift: Int?

    private struct Saved {
        var cx = 0, cy = 0, attr = CellAttr(), g: [Charset] = [.ascii, .ascii, .ascii, .ascii], gl = 0
        var originMode = false, autowrap = true, wrapPending = false
    }
    private var saved = Saved()
    private var savedAlt = Saved()

    private enum State { case ground, esc, escInter, csi, osc, oscEsc, str, strEsc, charset(Int) }
    private var state: State = .ground
    private var params: [Int] = []
    /// params[k] のあとが ':' (サブパラメータが続く) か。SGR 38:2::r:g:b と 38;2;r;g;b を区別する
    private var subNext: [Bool] = []
    private var curParam: Int?
    private var priv: Character?
    private var inter = ""
    private var escInter: Character = " "
    private var oscBuf = ""
    private var oscLen = 0
    private var lastChar: Unicode.Scalar?
    private var lastWasCR = false

    /// 画面が変わったら true (描画側で false に戻す)
    public var dirty = true

    public init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(2, cols)
        self.rows = max(1, rows)
        lines = (0..<self.rows).map { _ in Line(cols: max(2, cols)) }
        scrollBottom = self.rows - 1
        resetTabs()
    }

    /// 「その他の設定」の値 (INI の文字列のまま) をまとめてかける (externalsetup.cpp の OK のあとの処理)。
    /// title を変えたとき上書きモードならリモートタイトルを消す
    public func applyTeraTermSettings(terminalID: String, answerback: [UInt8], title: String,
                                      acceptTitleChangeRequest: String, titleReportSequence: String,
                                      windowCtrlSequence: Bool, windowReportSequence: Bool, cursorCtrlSequence: Bool,
                                      clipboardAccessFromRemote: String, notifyClipboardAccess: Bool,
                                      clearScrollBufferFromRemote: Bool, printerCtrlSequence: Bool, beep: String,
                                      receive: TermEncoding, send: TermEncoding, decSpMappingDir: Int,
                                      unicodeToDecSpMapping: Int, unicodeEmojiOverride: Bool, unicodeEmojiWidth: Int) {
        self.terminalID = TerminalID(ini: terminalID)
        answerbackBytes = answerback
        titleChangeMode = TitleChangeMode(ini: acceptTitleChangeRequest)
        if title != localTitle && titleChangeMode == .overwrite { remoteTitle = nil }
        localTitle = title
        titleReportMode = TitleReportMode(ini: titleReportSequence)
        windowCtrlEnabled = windowCtrlSequence
        windowReportEnabled = windowReportSequence
        cursorCtrlEnabled = cursorCtrlSequence
        clipboardAccess = ClipboardAccess(ini: clipboardAccessFromRemote)
        self.notifyClipboardAccess = notifyClipboardAccess
        clearScrollbackFromRemote = clearScrollBufferFromRemote
        printerCtrlEnabled = printerCtrlSequence
        bellMode = BellKind(ini: beep)
        receiveEncoding = receive
        sendEncoding = send
        decSpecialMapping = DecSpecialMapping(ini: decSpMappingDir)
        unicodeToDecSpMask = unicodeToDecSpMapping
        emojiWidthOverride = unicodeEmojiOverride ? (unicodeEmojiWidth == 2 ? 2 : 1) : nil
        dirty = true
    }

    // MARK: - 外から見る

    public var totalLines: Int { scrollback.count + rows }

    /// 0 = スクロールバックの一番古い行
    public func line(at index: Int) -> Line {
        if index < scrollback.count {
            // 履歴の行は行末の空白を切り詰めて持っているので、画面の幅まで空白で戻して渡す
            var l = scrollback[index]
            if l.cells.count < cols { l.cells.append(contentsOf: repeatElement(Cell(), count: cols - l.cells.count)) }
            return l
        }
        return lines[index - scrollback.count]
    }

    public var screenText: String {
        lines.map { $0.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    /// スクロールバックの文字 (行末の空白は除く)
    public var scrollbackText: String {
        scrollback.map { $0.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\n" }.joined()
    }

    public func clearScrollback() {
        scrollback.removeAll()
        dirty = true
    }

    /// Tera Term の「画面クリア」(buffer.c BuffClearScreen): 画面全体をスクロールしてバッファへ押し出し
    /// (消さずに履歴に残す)、今の属性の空白で埋めてカーソルを左上へ。モード・マージン・属性はそのまま
    public func clearScreen() {
        for y in 0..<rows {
            if !usingAlt { pushScrollback(lines[y]) }
            lines[y] = Line(cols: cols, attr: attr)
        }
        cx = 0; cy = 0; wrapPending = false
        dirty = true
    }

    /// 「バッファのクリア」(buffer.c ClearBuffer): スクロールバックと画面をすべて捨て、今の属性の空白で埋める。
    /// カーソルは左上、スクロール範囲は画面全体に戻す。モード・タブ・属性は変えない
    public func clearBuffer() {
        scrollback.removeAll()
        for y in 0..<rows { lines[y] = Line(cols: cols, attr: attr) }
        cx = 0; cy = 0; wrapPending = false
        scrollTop = 0; scrollBottom = rows - 1
        dirty = true
    }

    /// メニューの「端末リセット」(vtterm.c ResetTerminal)。画面の文字は消さない (RIS の ESC c とは違う)。
    /// lfMode: 送信改行が CR+LF なら LNM をオン (LFMode = ts.CRSend == IdCRLF)
    /// ResetCharSet (CharSetInit): G0〜G3 と GL・シングルシフトを初めに戻す (漢字コードを変えたとき。TTXKanjiMenu CallResetCharSet)
    public func resetCharSet() {
        g = [.ascii, .ascii, .ascii, .ascii]; gl = 0; singleShift = nil
    }

    public func menuReset(lfMode: Bool) {
        // BuffReset: 代替画面の退避は捨てる (表示中の内容はそのまま)
        if usingAlt { savedMainLines = nil; usingAlt = false }
        cx = 0; cy = 0; wrapPending = false
        scrollTop = 0; scrollBottom = rows - 1
        resetTabs()
        attr = CellAttr()
        insertMode = false; lnm = lfMode; autowrap = true
        appCursor = false; appKeypad = false; originMode = false
        reverseScreen = false
        mouseMode = 0; mouseSGR = false; mouseSGRPixels = false
        bracketedPaste = false
        // OnControlResetTerminal: DispResetColor(CS_ALL) で OSC 4/5/10/11/17/19 で変えた色も戻す (adfcf70eb)
        resetColors()
        cursorVisible = true; cursorStyle = defaultCursorStyle; cursorBlink = defaultCursorBlink
        g = [.ascii, .ascii, .ascii, .ascii]; gl = 0; singleShift = nil
        printerMode = false; autoPrintMode = false; printExtent = true; printBuf = ""
        saved = Saved(); savedAlt = Saved()
        state = .ground; params = []; subNext = []; curParam = nil; priv = nil; inter = ""; oscBuf = ""
        lastChar = nil
        dirty = true
    }

    // MARK: - サイズ変更

    public func resize(cols newCols: Int, rows newRows: Int) {
        // buffer.c ChangeBuffer: TermWidthMax / TermHeightMax まで (4.106)
        let nc = min(TermLimits.widthMax, max(2, newCols)), nr = min(TermLimits.heightMax, max(1, newRows))
        if nc == cols && nr == rows { return }
        func fit(_ l: inout Line) {
            if l.cells.count > nc {
                l.cells.removeLast(l.cells.count - nc)
                if l.cells[nc - 1].width == 2 { l.cells[nc - 1] = Cell() }
            } else if l.cells.count < nc {
                l.cells.append(contentsOf: Array(repeating: Cell(), count: nc - l.cells.count))
            }
        }
        var keepPending = false
        if nc != cols {
            // 幅が変わったら、自動折り返しでつながっている行を新しい幅で折り返し直す
            // (狭めても右側が消えず、広げ直すと元に戻る)。代替画面はアプリが描き直すので切り詰めるだけ
            let before = scrollback.count
            if usingAlt, let m = savedMainLines {
                var all = scrollback.array; scrollback = []; savedMainLines = nil
                all.append(contentsOf: m)
                let r = reflow(&all, screenStart: before, cursorX: saved.cx, cursorY: saved.cy, pending: saved.wrapPending, newCols: nc)
                scrollback = LineBuffer(r.scrollback); savedMainLines = r.screen
                saved.cx = r.cx; saved.cy = r.cy; saved.wrapPending = r.pending
                for i in lines.indices { fit(&lines[i]) }
            } else {
                var all = scrollback.array; scrollback = []
                all.append(contentsOf: lines); lines = []
                let r = reflow(&all, screenStart: before, cursorX: cx, cursorY: cy, pending: wrapPending, newCols: nc)
                scrollback = LineBuffer(r.scrollback); lines = r.screen
                cx = r.cx; cy = r.cy; keepPending = r.pending
            }
            scrolledOutTotal += scrollback.count - before
            if scrollback.count > scrollbackLimit {
                scrollback.removeFirst(scrollback.count - scrollbackLimit)
            }
        }
        if nr < rows {
            // カーソルより下の空行から消し、足りなければ上の行をスクロールバックへ
            var excess = rows - nr
            while excess > 0 && lines.count - 1 > cy && lines.last!.text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast(); excess -= 1
            }
            while excess > 0 {
                let l = lines.removeFirst()
                if !usingAlt { pushScrollback(l) }
                cy -= 1; excess -= 1
            }
            if lines.count > nr { lines.removeLast(lines.count - nr) }
            if var m = savedMainLines {
                while m.count > nr { m.removeFirst() }
                savedMainLines = m
            }
        } else if nr > rows {
            var add = nr - rows
            while add > 0 && !usingAlt && !scrollback.isEmpty {
                var l = scrollback.removeLast()
                fit(&l)
                lines.insert(l, at: 0)
                cy += 1; add -= 1
            }
            while add > 0 { lines.append(Line(cols: nc)); add -= 1 }
            if var m = savedMainLines {
                while m.count < nr { m.append(Line(cols: nc)) }
                savedMainLines = m
            }
        }
        cols = nc; rows = nr
        cy = max(0, min(cy, rows - 1))
        cx = max(0, min(cx, cols - 1))
        wrapPending = keepPending && cx == cols - 1
        scrollTop = 0; scrollBottom = rows - 1
        resetTabs()
        dirty = true
    }

    /// 折り返しのやり直し。scrollback と画面の行を、自動折り返し (wrapped) でつながった論理行にまとめ、
    /// 新しい幅で折り返す。画面の先頭行とカーソルの位置は論理行の中の位置で追いかける。
    /// 返す画面の行数は元の画面と同じ (行数の変更は resize の続きで行う)。
    /// 本家 (buffer.c ChangeBuffer) は新しい幅に入る分だけ写してはみ出しを捨てるが、ここでは捨てずに折り返す
    private func reflow(_ all: inout [Line], screenStart: Int, cursorX: Int, cursorY: Int, pending: Bool,
                        newCols nc: Int) -> (scrollback: [Line], screen: [Line], cx: Int, cy: Int, pending: Bool) {
        let want = all.count - screenStart
        let curRow = screenStart + max(0, min(cursorY, want - 1))
        let curX = cursorX + (pending ? 1 : 0)
        let plain = CellAttr()
        let space: Character = " "
        func isPlainBlank(_ c: Cell) -> Bool { c.width == 1 && c.attr == plain && c.ch == space }
        let blank = Cell()
        var out: [Line] = []
        out.reserveCapacity(all.count + 16)
        var newStart = -1, ncx = 0, ncy = 0, npending = false
        var i = 0
        while i < all.count {
            var j = i
            while j + 1 < all.count && all[j].wrapped { j += 1 }
            let hasStart = screenStart >= i && screenStart <= j
            let hasCur = curRow >= i && curRow <= j
            if i == j {
                // 1 行だけの論理行: 中身が新しい幅に入るなら、行末を切り詰める/足すだけで済ませる
                var l = all[i]; all[i] = Line(cols: 0)
                // 新しい幅より右が空白だけか (右端から nc まで見れば足りる)
                var len = l.cells.count
                while len > nc && isPlainBlank(l.cells[len - 1]) { len -= 1 }
                if hasCur { len = max(len, min(curX, l.cells.count)) }
                if len <= nc {
                    if hasStart { newStart = out.count }
                    if hasCur {
                        ncy = out.count
                        if curX >= nc { ncx = nc - 1; npending = true } else { ncx = curX }
                    }
                    if l.cells.count > nc { l.cells.removeLast(l.cells.count - nc) }
                    else if l.cells.count < nc { l.cells.append(contentsOf: repeatElement(blank, count: nc - l.cells.count)) }
                    l.wrapped = false
                    out.append(l)
                    i = j + 1
                    continue
                }
                all[i] = l
            }
            // 論理行にまとめる (位置は論理行の中のセルの番号)
            var cells: [Cell] = []
            var startOff = -1, curOff = -1
            for k in i...j {
                if k == screenStart { startOff = cells.count }
                if k == curRow { curOff = cells.count + min(curX, all[k].cells.count) }
                var c = all[k].cells; all[k] = Line(cols: 0)
                // 全角文字が右端に入らずに折り返したときの埋め草は捨てる
                if k < j, let last = c.last, isPlainBlank(last), all[k + 1].cells.first?.width == 2 { c.removeLast() }
                cells.append(contentsOf: c)
            }
            // 行末の空白 (色なし) は捨てる。ただしカーソルより前は残す
            var len = cells.count
            while len > max(0, curOff) && isPlainBlank(cells[len - 1]) { len -= 1 }
            if len < cells.count { cells.removeLast(cells.count - len) }
            // 新しい幅で折り返す。切れ目は幅だけを見て決め、セルはまとめて写す
            var rowStart = 0, col = 0, k = 0
            func emit(_ end: Int, wrapped: Bool) {
                var l = Line(cols: 0)
                l.cells.reserveCapacity(nc)
                l.cells.append(contentsOf: cells[rowStart..<end])
                if l.cells.count < nc { l.cells.append(contentsOf: repeatElement(blank, count: nc - l.cells.count)) }
                l.wrapped = wrapped
                out.append(l)
                rowStart = end; col = 0
            }
            while k < cells.count {
                if col >= nc || (cells[k].width == 2 && col == nc - 1) { emit(k, wrapped: true) }
                if k == startOff { newStart = out.count }
                if k == curOff { ncy = out.count; ncx = col }
                col += 1; k += 1
            }
            if startOff >= cells.count { newStart = out.count }
            if curOff >= cells.count {
                ncy = out.count
                if col >= nc { ncx = nc - 1; npending = true } else { ncx = col }
            }
            emit(cells.count, wrapped: false)
            i = j + 1
        }
        all = []
        if out.isEmpty { out.append(Line(cols: nc)) }
        newStart = max(0, min(newStart, out.count - 1))
        var newScreen = Array(out[newStart...])
        out.removeLast(out.count - newStart)
        var newBack = out
        var y = max(0, ncy - newStart)
        // 行数を元の画面にそろえる: 増えたらカーソルより下の空行を消し、まだ多ければ上をスクロールバックへ
        while newScreen.count > want && newScreen.count - 1 > y,
              let last = newScreen.last, !last.wrapped, last.cells.allSatisfy(isPlainBlank) {
            newScreen.removeLast()
        }
        if newScreen.count > want && y > 0 {
            let n = min(newScreen.count - want, y)
            newBack.append(contentsOf: newScreen[..<n]); newScreen.removeFirst(n); y -= n
        }
        if newScreen.count > want { newScreen.removeLast(newScreen.count - want) }
        // 減ったら (広げてつながった行があれば) スクロールバックから戻す。行数を増やすときと同じ
        if newScreen.count < want && !newBack.isEmpty {
            let n = min(want - newScreen.count, newBack.count)
            newScreen.insert(contentsOf: newBack[(newBack.count - n)...], at: 0)
            newBack.removeLast(n); y += n
        }
        while newScreen.count < want { newScreen.append(Line(cols: nc)) }
        return (newBack, newScreen, ncx, y, npending)
    }

    private func resetTabs() {
        tabs = (0..<cols).map { $0 % 8 == 0 && $0 != 0 }
    }

    // MARK: - 入力

    public func feed(_ s: String) {
        var rest: [UInt8]?
        let scalars = s.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            process(scalars[i])
            i = scalars.index(after: i)
            if let p = tekPrefix {
                // 残りはバイトに戻す (TEK の受信は 7 ビット。それ以外の文字は UTF-8)
                tekPrefix = nil
                rest = p + scalars[i...].flatMap { $0.value < 0x80 ? [UInt8($0.value)] : Array(String($0).utf8) }
                break
            }
        }
        dirty = true
        if !macroBuf.isEmpty {
            let b = macroBuf
            macroBuf = []
            onMacroText?(b)
        }
        if let r = rest { onEnterTEK?(r) }
    }

    /// ChangeEmu = IdTEK (prefix は CommInsert1Byte で戻すバイト)
    private func enterTEK(_ prefix: [UInt8]) {
        guard autoWinSwitch, onEnterTEK != nil else { return }
        tekPrefix = prefix
        state = .ground
    }

    private func macroOut(_ v: UInt32) {
        guard onMacroText != nil else { return }
        // 速くするため: ふつうの ASCII はそのまま
        if v < 0x80 && v != 0x0D && v != 0x0A { macroCRHold = false; macroBuf.append(UInt8(v)); return }
        switch v {
        case 0x0D:
            macroCRHold = true
        case 0x0A:
            if macroCRHold { macroCRHold = false; macroBuf += [0x0D, 0x0A] } else { macroBuf.append(0x0A) }
        default:
            macroCRHold = false
            if let u = Unicode.Scalar(v) { macroBuf += Array(String(Character(u)).utf8) }
        }
    }

    private func process(_ sc: Unicode.Scalar) {
        let v = sc.value
        if terminalID == .dumb {
            // VTParse (dd65db75a #255): dumb 端末でログのタイムスタンプ (LogTimestamp) がオンなら、
            // 行頭 (CursorX == 0) に CR / LF でない文字が来たとき、その前に時刻を画面にも出す (ログにも入る)
            if cx == 0 && !wrapPending && v != 0x0A && v != 0x0D, let stamp = dumbTimestamp?() {
                for u in stamp.unicodeScalars { put(u) }
            }
            // dumb 端末 (ParseControlDumb): エスケープシーケンスは解釈せず、LF / CR / BEL のほかの制御文字は U+2400〜 で見せる
            if v < 0x20 {
                switch v {
                case 0x0A, 0x0D: control(v)
                case 0x07: ringBell()
                default: put(Unicode.Scalar(0x2400 + v)!)
                }
            } else if v != 0x7F {
                put(sc)
            }
            return
        }
        switch state {
        case .ground:
            if v < 0x20 || v == 0x7F {
                if printerMode { printerControl(v) } else { control(v) }
            } else if printerMode {
                printBuf.unicodeScalars.append(sc)
            } else {
                put(sc)
            }

        case .esc:
            if v < 0x20 { control(v); return }
            escape(sc)

        case .escInter:
            if v < 0x20 { control(v); return }
            if escInter == "#" && sc == "8" { decAlign() }
            if escInter == "%" && sc == "!" { escInter = "!"; return }   // ESC % !
            if escInter == "!" && sc == "0" { enterTEK([]) }            // ESC % ! 0 (ESCSelectCode)
            state = .ground

        case .charset(let which):
            let cs: Charset
            switch sc {
            case "0": cs = .dec
            case "A": cs = .uk
            default: cs = .ascii
            }
            g[which] = cs
            state = .ground

        case .csi:
            if v == 0x1B { state = .esc; return }
            if v == 0x18 || v == 0x1A { state = .ground; return }
            if v < 0x20 { control(v); return }
            switch v {
            case 0x30...0x39:
                curParam = (curParam ?? 0) &* 10 &+ Int(v - 0x30)
                if curParam! > 99999 { curParam = 99999 }
            case 0x3B, 0x3A:
                params.append(curParam ?? -1); curParam = nil
                subNext.append(v == 0x3A)
            case 0x3C...0x3F:
                priv = Character(sc)
            case 0x20...0x2F:
                inter.append(Character(sc))
            case 0x40...0x7E:
                if let p = curParam { params.append(p) } else if !params.isEmpty { params.append(-1) }
                while subNext.count < params.count { subNext.append(false) }
                csiDispatch(Character(sc))
                state = .ground
            default:
                state = .ground
            }

        case .osc:
            if v == 0x07 { oscDispatch(bel: true); state = .ground; return }
            if v == 0x1B { state = .oscEsc; return }
            if v == 0x18 || v == 0x1A { state = .ground; return }
            if oscLen < maxOSCBufferSize - 1 { oscBuf.unicodeScalars.append(sc); oscLen += 1 }

        case .oscEsc:
            if sc == "\\" { oscDispatch(bel: false); state = .ground } else { state = .ground; process(sc) }

        case .str:
            if v == 0x1B { state = .strEsc } else if v == 0x07 || v == 0x18 || v == 0x1A { state = .ground }

        case .strEsc:
            state = sc == "\\" ? .ground : .str
        }
    }

    private func control(_ v: UInt32) {
        let wasCR = lastWasCR
        lastWasCR = false
        switch v {
        case 0x05: sendBytes(answerbackBytes)    // ENQ
        case 0x07: ringBell()
        case 0x08:
            // vtterm.c BackSpace: カーソルが動いたときだけ (LogTypePlainText なら出さない)
            if wrapPending || cx > 0, !logTypePlainText { macroOut(0x08) }
            if wrapPending { wrapPending = false } else if cx > 0 { cx -= 1 }
        case 0x09:
            macroOut(0x09)
            var x = cx + 1
            while x < cols - 1 && !tabs[x] { x += 1 }
            cx = min(x, cols - 1); wrapPending = false
        case 0x0C where autoWinSwitch && onEnterTEK != nil && { if case .esc = state { return true }; return false }():
            enterTEK([0x1B, 0x0C])   // ESC FF (JustAfterESC)
        case 0x1C...0x1F where autoWinSwitch && onEnterTEK != nil:
            enterTEK([UInt8(v)])     // FS GS RS US
        case 0x0A, 0x0B, 0x0C:
            // ProcessLF / LineFeed: 受信の改行が LF なら CR+LF。CR+LF モードで CR のあとに来た LF もそのまま改行する
            _ = wasCR
            if recvLFasCRLF && v == 0x0A { macroOut(0x0D); cx = 0; wrapPending = false }
            // 自動印刷 (LineFeed): 改行する前にカーソル行を印刷する
            if autoPrintMode { onPrint?(.text(currentLineForPrint() + "\r" + String(Unicode.Scalar(UInt8(v))))) }
            indexLF()
        case 0x0D:
            // ProcessCR: 受信の改行が CR+LF なら CR のあとに LF を足す (CommInsert1Byte)
            macroOut(0x0D)
            cx = 0; wrapPending = false
            if recvCRasCRLF { indexLF(); lastWasCR = true }
        case 0x0E: gl = 1
        case 0x0F: gl = 0
        case 0x18, 0x1A: state = .ground
        case 0x1B:
            state = .esc
            params = []; subNext = []; curParam = nil; priv = nil; inter = ""
        default: break
        }
    }

    /// vtterm.c LineFeed(logFlag=TRUE): マクロ・ログに LF を出して 1 行下へ。LNM なら続けて CR
    private func indexLF() {
        macroOut(0x0A)
        lineFeed()
        if lnm { macroOut(0x0D); cx = 0; wrapPending = false }
    }

    private func escape(_ sc: Unicode.Scalar) {
        state = .ground
        if printerMode && !"[()*+".unicodeScalars.contains(sc) {
            // プリンタコントローラ中 (PrnParseEscape): 解釈しないシーケンスはそのままプリンタへ
            printBuf.unicodeScalars.append("\u{1B}")
            printBuf.unicodeScalars.append(sc)
            return
        }
        switch sc {
        case "[":
            state = .csi; params = []; subNext = []; curParam = nil; priv = nil; inter = ""
        case "]":
            state = .osc; oscBuf = ""; oscLen = 0
        case "P", "_", "^", "X":
            state = .str
        case "(": state = .charset(0)
        case ")": state = .charset(1)
        case "*": state = .charset(2)
        case "+": state = .charset(3)
        case "#", "%", " ":
            escInter = Character(sc); state = .escInter
        case "7": saveCursor()
        case "8": restoreCursor()
        case "D": indexLF()                    // IND: LineFeed(0, TRUE)
        case "E": cx = 0; wrapPending = false; indexLF()   // NEL
        case "M": reverseIndex()
        case "H": if cx < cols { tabs[cx] = true }
        case "c": fullReset()
        case "Z": if let da = terminalID.primaryDA { respond(da) }   // DECID
        case "g": ringBell()                   // Visual Bell (RingBell は ts.Beep で鳴らす)
        case "=": appKeypad = true
        case ">": appKeypad = false
        case "N": singleShift = 2
        case "O": singleShift = 3
        case "n": gl = 2
        case "o": gl = 3
        default: break
        }
    }

    // MARK: - 文字を置く

    /// DEC Special Graphics 0x5F–0x7E の Unicode (vtterm.c PutU32NoLog の dec2unicode)
    private static let decGraphics: [UInt32: Unicode.Scalar] = [
        0x5F: "\u{A0}", 0x60: "◆", 0x61: "▒", 0x62: "␉", 0x63: "␌", 0x64: "␍", 0x65: "␊", 0x66: "°", 0x67: "±",
        0x68: "␤", 0x69: "␋", 0x6A: "┘", 0x6B: "┐", 0x6C: "┌", 0x6D: "└", 0x6E: "┼", 0x6F: "⎺",
        0x70: "⎻", 0x71: "─", 0x72: "⎼", 0x73: "⎽", 0x74: "├", 0x75: "┤", 0x76: "┴", 0x77: "┬",
        0x78: "│", 0x79: "≤", 0x7A: "≥", 0x7B: "π", 0x7C: "≠", 0x7D: "£", 0x7E: "·",
    ]

    /// Unicode の記号 → DEC Special Graphics (unisym2decsp.map)。上位 8 ビットが UnicodeToDecSpMapping のビット、下位が文字
    static let unicodeToDecSp: [UInt32: UInt16] = {
        var m: [UInt32: UInt16] = [
            0x00B7: 0x047E, 0x2022: 0x027E, 0x2024: 0x047E, 0x2027: 0x027E, 0x2219: 0x047E,
            0x23BA: 0x016F, 0x23BB: 0x0170, 0x23BC: 0x0172, 0x23BD: 0x0173,
            0x2591: 0x0261, 0x2592: 0x0261, 0x2593: 0x0261, 0x25AA: 0x027E, 0x25AE: 0x0260, 0x2B1D: 0x027E,
        ]
        // 罫線素片 U+2500–U+257F (2571–257B は対応なし)
        let box: [(ClosedRange<UInt32>, UInt16)] = [
            (0x2500...0x2501, 0x71), (0x2502...0x2503, 0x78), (0x2504...0x2505, 0x71), (0x2506...0x2507, 0x78),
            (0x2508...0x2509, 0x71), (0x250A...0x250B, 0x78), (0x250C...0x250F, 0x6C), (0x2510...0x2513, 0x6B),
            (0x2514...0x2517, 0x6D), (0x2518...0x251B, 0x6A), (0x251C...0x2523, 0x74), (0x2524...0x252B, 0x75),
            (0x252C...0x2533, 0x77), (0x2534...0x253B, 0x76), (0x253C...0x254B, 0x6E), (0x254C...0x254D, 0x71),
            (0x254E...0x254F, 0x78), (0x2550...0x2550, 0x71), (0x2551...0x2551, 0x78), (0x2552...0x2554, 0x6C),
            (0x2555...0x2557, 0x6B), (0x2558...0x255A, 0x6D), (0x255B...0x255D, 0x6A), (0x255E...0x2560, 0x74),
            (0x2561...0x2563, 0x75), (0x2564...0x2566, 0x77), (0x2567...0x2569, 0x76), (0x256A...0x256C, 0x6E),
            (0x256D...0x256D, 0x6C), (0x256E...0x256E, 0x6B), (0x256F...0x256F, 0x6A), (0x2570...0x2570, 0x6D),
            (0x257C...0x257C, 0x71), (0x257D...0x257D, 0x78), (0x257E...0x257E, 0x71), (0x257F...0x257F, 0x78),
        ]
        for (r, c) in box { for u in r { m[u] = 0x0100 | c } }
        return m
    }()

    private func blankCell() -> Cell {
        var c = Cell(); c.attr.bg = attr.bg; return c
    }

    private func put(_ input: Unicode.Scalar) {
        var sc = input
        let cs = g[singleShift ?? gl]
        singleShift = nil
        // PutU32NoLog: DEC Special Graphics の扱い (DecSpMappingDir)
        var special = cs == .dec && (0x5F...0x7E).contains(sc.value)
        switch decSpecialMapping {
        case .unicodeToDec:
            if !special, sc.value >= 0x80, unicodeToDecSpMask != 0, let cset = Terminal.unicodeToDecSp[sc.value],
               Int(cset >> 8) & unicodeToDecSpMask != 0 {
                special = true
                sc = Unicode.Scalar(UInt8(cset & 0xFF))
            }
        case .decToUnicode:
            if special, let m = Terminal.decGraphics[sc.value] { sc = m; special = false }
        case .doNot:
            break
        }
        if special, let m = Terminal.decGraphics[sc.value] { sc = m }
        if cs == .uk && sc == "#" { sc = "£" }
        // U+FEFF (BOM / ZWNBSP) は幅 0 で何も描かないので捨てる (DEL と同じ)
        if sc.value == 0xFEFF { return }
        macroOut(sc.value)

        // 特殊フォントの文字はいつも半角
        // UnicodeAmbiguousWidth / 絵文字幅の設定は受信が UTF-8 のときだけ使う (#1127, termCharWidth 内で判断)
        let w = special ? 1 : sc.value < 0x7F ? 1 : termCharWidth(sc, ambiguousWide: ambiguousWide,
                                            emojiWidth: emojiWidthOverride, kanjiCode: receiveEncoding)
        if w == 0 {
            // 直前の文字にくっつける
            var x = wrapPending ? cx : cx - 1
            if x >= 0 && x < cols {
                if lines[cy].cells[x].width == 0 && x > 0 { x -= 1 }
                var s = String(lines[cy].cells[x].ch)
                s.unicodeScalars.append(sc)
                if s.count == 1 { lines[cy].cells[x].ch = Character(s) }
            }
            return
        }
        if wrapPending {
            if autowrap {
                lines[cy].wrapped = true
                cx = 0
                lineFeed()
            }
            wrapPending = false
        }
        if w == 2 && cx >= cols - 1 {
            if autowrap {
                lines[cy].cells[cx] = blankCell()
                lines[cy].wrapped = true
                cx = 0
                lineFeed()
            } else {
                cx = cols - 2
            }
        }
        if insertMode { insertChars(w) }
        clearWide(cy, cx)
        if w == 2 { clearWide(cy, cx + 1) }
        var a = attr
        a.decSpecial = special
        lines[cy].cells[cx] = Cell(scalar: sc, attr: a, width: UInt8(w))
        if w == 2 { lines[cy].cells[cx + 1] = Cell(ch: " ", attr: attr, width: 0) }
        lastChar = sc
        cx += w
        if cx >= cols {
            cx = cols - 1
            wrapPending = true
        }
    }

    /// 全角文字の片側だけ上書きされるとき、もう片側を消す
    private func clearWide(_ y: Int, _ x: Int) {
        guard x >= 0 && x < cols else { return }
        let c = lines[y].cells[x]
        if c.width == 0 && x > 0 { lines[y].cells[x - 1] = blankCell() }
        if c.width == 2 && x + 1 < cols { lines[y].cells[x + 1] = blankCell() }
    }

    /// 画面の上から流れた行をスクロールバックへ。追い出された (または残さない) 行を返す: 空行の入れ物に使い回す
    @discardableResult private func pushScrollback(_ l: Line) -> Line? {
        scrolledOutTotal += 1
        if scrollbackLimit <= 0 {
            if !scrollback.isEmpty { scrollback.removeAll() }
            return l
        }
        if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
        // 行末の色なしの空白は持たない (メモリを減らす)。折り返して続く行は空白も中身なのでそのまま。
        // 切り詰めた写しを履歴に入れ、元の行 (画面の幅) は空行の入れ物として使い回す
        var len = l.cells.count
        if !l.wrapped {
            l.cells.withUnsafeBufferPointer { b in
                let blank = Cell()
                while len > 0 && b[len - 1] == blank { len -= 1 }
            }
        }
        let trim = l.cells.count - len >= 8
        if !trim {
            if scrollback.count == scrollbackLimit { return scrollback.appendEvicting(l) }
            scrollback.append(l)
            return nil
        }
        if scrollback.count == scrollbackLimit {
            // 追い出す古い行の入れ物に写す (大きさが合えば確保し直さない)
            scrollback.reuseOldest { old in
                let cap = old.cells.capacity
                if cap >= len && cap <= len * 2 + 16 {
                    old.cells.removeAll(keepingCapacity: true)
                } else {
                    old.cells = []
                    old.cells.reserveCapacity(len)
                }
                old.cells.append(contentsOf: l.cells[0..<len])
                old.wrapped = false
            }
            return l
        }
        var t = Line(cols: 0)
        t.cells.reserveCapacity(len)
        t.cells.append(contentsOf: l.cells[0..<len])
        scrollback.append(t)
        return l
    }

    /// 使い終わった行を空行にして返す (幅が違えば新しく作る)
    private func blankLine(reusing old: inout Line?) -> Line {
        // old を空にしてから書き換える (参照が 1 つだけになり、複製せずにその場で書ける)
        guard var l = old, l.cells.count == cols else { old = nil; return Line(cols: cols, attr: attr) }
        old = nil
        var c = Cell(); c.attr.bg = attr.bg
        l.cells.withUnsafeMutableBufferPointer { b in for i in b.indices { b[i] = c } }
        l.wrapped = false
        return l
    }

    private func lineFeed() {
        wrapPending = false
        if cy == scrollBottom {
            scrollUp(1)
        } else if cy < rows - 1 {
            cy += 1
        }
    }

    private func reverseIndex() {
        wrapPending = false
        if cy == scrollTop {
            scrollDown(1)
        } else if cy > 0 {
            cy -= 1
        }
    }

    private func scrollUp(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        for _ in 0..<n {
            let l = lines.remove(at: scrollTop)
            var spare = scrollTop == 0 && !usingAlt ? pushScrollback(l) : l
            lines.insert(blankLine(reusing: &spare), at: scrollBottom)
        }
    }

    private func scrollDown(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        for _ in 0..<n {
            lines.remove(at: scrollBottom)
            lines.insert(Line(cols: cols, attr: attr), at: scrollTop)
        }
    }

    private func insertChars(_ n: Int) {
        let n = min(n, cols - cx)
        clearWide(cy, cx)
        var cells = lines[cy].cells
        cells.removeLast(n)
        cells.insert(contentsOf: Array(repeating: blankCell(), count: n), at: cx)
        if cells[cols - 1].width == 2 { cells[cols - 1] = blankCell() }
        lines[cy].cells = cells
    }

    private func deleteChars(_ n: Int) {
        let n = min(n, cols - cx)
        clearWide(cy, cx)
        clearWide(cy, cx + n - 1)
        lines[cy].cells.removeSubrange(cx..<(cx + n))
        lines[cy].cells.append(contentsOf: Array(repeating: blankCell(), count: n))
        if lines[cy].cells[cx].width == 0 { lines[cy].cells[cx] = blankCell() }
    }

    private func erase(_ y: Int, _ from: Int, _ to: Int) {
        guard from < to else { return }
        clearWide(y, from)
        clearWide(y, to - 1)
        for x in from..<to { lines[y].cells[x] = blankCell() }
        if to == cols { lines[y].wrapped = false }
    }

    private func decAlign() {
        for y in 0..<rows {
            for x in 0..<cols { lines[y].cells[x] = Cell(ch: "E", attr: CellAttr(), width: 1) }
        }
        cx = 0; cy = 0
    }

    private func saveCursor() {
        let s = Saved(cx: cx, cy: cy, attr: attr, g: g, gl: gl, originMode: originMode, autowrap: autowrap, wrapPending: wrapPending)
        if usingAlt { savedAlt = s } else { saved = s }
    }

    private func restoreCursor() {
        let s = usingAlt ? savedAlt : saved
        cx = min(s.cx, cols - 1); cy = min(s.cy, rows - 1)
        attr = s.attr; g = s.g; gl = s.gl
        originMode = s.originMode; autowrap = s.autowrap; wrapPending = s.wrapPending
    }

    private func fullReset() {
        if usingAlt { leaveAlt() }
        attr = CellAttr()
        for y in 0..<rows { lines[y] = Line(cols: cols) }
        cx = 0; cy = 0; wrapPending = false
        scrollTop = 0; scrollBottom = rows - 1
        appCursor = false; appKeypad = false; bracketedPaste = false
        cursorVisible = true; reverseScreen = false; autowrap = true
        insertMode = false; originMode = false; lnm = false
        mouseMode = 0; mouseSGR = false; mouseSGRPixels = false; cursorStyle = defaultCursorStyle; cursorBlink = defaultCursorBlink
        g = [.ascii, .ascii, .ascii, .ascii]; gl = 0
        printerMode = false; autoPrintMode = false; printExtent = true; printBuf = ""
        saved = Saved(); savedAlt = Saved()
        resetTabs()
    }

    private func enterAlt() {
        guard !usingAlt else { return }
        savedMainLines = lines
        lines = (0..<rows).map { _ in Line(cols: cols) }
        usingAlt = true
    }

    private func leaveAlt() {
        guard usingAlt, let m = savedMainLines else { return }
        lines = m
        savedMainLines = nil
        usingAlt = false
    }

    // MARK: - CSI

    private func p(_ i: Int, _ def: Int) -> Int {
        guard i < params.count, params[i] > 0 else { return def }
        return params[i]
    }

    private func p0(_ i: Int) -> Int {
        guard i < params.count, params[i] >= 0 else { return 0 }
        return params[i]
    }

    private func moveTo(_ x: Int, _ y: Int) {
        let top = originMode ? scrollTop : 0
        let bottom = originMode ? scrollBottom : rows - 1
        cx = max(0, min(x, cols - 1))
        cy = max(top, min(y + top, bottom))
        wrapPending = false
    }

    private func csiDispatch(_ f: Character) {
        if priv == "?" { decPrivate(f); return }
        if printerMode {
            // PrnParseCS: CSI 4 i でプリンタコントローラを終える。ほかは終わりの文字だけプリンタへ
            if priv == nil && inter.isEmpty && f == "i" && p0(0) == 4 {
                printerMode = false
                let t = printBuf
                printBuf = ""
                onPrint?(.text(t))
            } else {
                printBuf.append(f)
            }
            return
        }
        if priv == ">" {
            // CSGT: Secondary DA
            if f == "c" && p0(0) == 0 { respond(TerminalID.secondaryDA) }
            return
        }
        if priv != nil { return }
        if inter == " " && f == "q" {
            // DECSCUSR (CursorCtrlSequence がオンのときだけ)
            guard cursorCtrlEnabled else { return }
            switch p0(0) {
            case 0, 1: cursorStyle = .block; cursorBlink = true
            case 2: cursorStyle = .block; cursorBlink = false
            case 3: cursorStyle = .underline; cursorBlink = true
            case 4: cursorStyle = .underline; cursorBlink = false
            case 5: cursorStyle = .bar; cursorBlink = true
            case 6: cursorStyle = .bar; cursorBlink = false
            default: break
            }
            return
        }
        if inter == "!" && f == "p" {
            // DECSTR (ソフトリセット)
            attr = CellAttr(); insertMode = false; originMode = false; autowrap = true
            cursorVisible = true; appCursor = false; appKeypad = false
            scrollTop = 0; scrollBottom = rows - 1
            return
        }
        if !inter.isEmpty { return }

        switch f {
        case "@": insertChars(p(0, 1))
        case "A":
            let top = cy >= scrollTop ? scrollTop : 0
            cy = max(top, cy - p(0, 1)); wrapPending = false
        case "B", "e":
            let bottom = cy <= scrollBottom ? scrollBottom : rows - 1
            cy = min(bottom, cy + p(0, 1)); wrapPending = false
        case "C", "a": cx = min(cols - 1, cx + p(0, 1)); wrapPending = false
        case "D": cx = max(0, cx - p(0, 1)); wrapPending = false
        case "E": cy = min(scrollBottom, cy + p(0, 1)); cx = 0; wrapPending = false
        case "F": cy = max(scrollTop, cy - p(0, 1)); cx = 0; wrapPending = false
        case "G", "`": cx = max(0, min(cols - 1, p(0, 1) - 1)); wrapPending = false
        case "H", "f": moveTo(p(1, 1) - 1, p(0, 1) - 1)
        case "I":
            for _ in 0..<p(0, 1) { control(0x09) }
        case "Z":
            for _ in 0..<p(0, 1) {
                var x = cx - 1
                while x > 0 && !tabs[x] { x -= 1 }
                cx = max(0, x)
            }
        case "J":
            switch p0(0) {
            case 0:
                erase(cy, cx, cols)
                for y in (cy + 1)..<max(cy + 1, rows) { erase(y, 0, cols) }
            case 1:
                for y in 0..<cy { erase(y, 0, cols) }
                erase(cy, 0, min(cx + 1, cols))
            case 2:
                for y in 0..<rows { erase(y, 0, cols) }
            case 3:
                // CSI 3 J: ClearScrollBufferFromRemote なら ClearBuffer (バッファ全体を消してカーソルを左上へ)
                if clearScrollbackFromRemote { clearBuffer() }
            default: break
            }
        case "K":
            switch p0(0) {
            case 0: erase(cy, cx, cols)
            case 1: erase(cy, 0, min(cx + 1, cols))
            case 2: erase(cy, 0, cols)
            default: break
            }
        case "L":
            if cy >= scrollTop && cy <= scrollBottom {
                let n = min(p(0, 1), scrollBottom - cy + 1)
                for _ in 0..<n {
                    lines.remove(at: scrollBottom)
                    lines.insert(Line(cols: cols, attr: attr), at: cy)
                }
                cx = 0; wrapPending = false
            }
        case "M":
            if cy >= scrollTop && cy <= scrollBottom {
                let n = min(p(0, 1), scrollBottom - cy + 1)
                for _ in 0..<n {
                    lines.remove(at: cy)
                    lines.insert(Line(cols: cols, attr: attr), at: scrollBottom)
                }
                cx = 0; wrapPending = false
            }
        case "P": deleteChars(p(0, 1))
        case "S": scrollUp(p(0, 1))
        case "T": scrollDown(p(0, 1))
        case "X":
            let n = min(p(0, 1), cols - cx)
            erase(cy, cx, cx + n)
        case "b":
            if let c = lastChar {
                for _ in 0..<min(p(0, 1), 65535) { put(c) }
            }
        case "c": if let da = terminalID.primaryDA { respond(da) }   // DA (AnswerTerminalType)
        case "d": cy = max(0, min(rows - 1, p(0, 1) - 1 + (originMode ? scrollTop : 0))); wrapPending = false
        case "g":
            switch p0(0) {
            case 0: if cx < cols { tabs[cx] = false }
            case 3: tabs = Array(repeating: false, count: cols)
            default: break
            }
        case "h", "l":
            let on = f == "h"
            for m in params {
                if m == 4 { insertMode = on }
                if m == 20 { lnm = on }
                if cursorCtrlEnabled {
                    if m == 33 { cursorBlink = !on }                       // WYSTCURM
                    if m == 34 { cursorStyle = on ? .underline : .block }  // WYULCURM
                }
            }
        case "i": mediaCopy(p0(0))
        case "m": sgr()
        case "n":
            switch p0(0) {
            case 5: onResponse?("\u{1B}[0n")
            case 6:
                let y = originMode ? cy - scrollTop : cy
                onResponse?("\u{1B}[\(y + 1);\(cx + 1)R")
            default: break
            }
        case "r":
            let top = p(0, 1) - 1
            let bottom = p(1, rows) - 1
            if top < bottom && bottom < rows {
                scrollTop = top; scrollBottom = bottom
                moveTo(0, 0)
            }
        case "s": saveCursor()
        case "u": restoreCursor()
        case "t": windowSequence()
        default: break
        }
    }

    // MARK: - 応答・ベル・ウィンドウ・印刷

    private func sendBytes(_ b: [UInt8]) {
        guard !b.isEmpty else { return }
        if let f = onResponseBytes { f(b) } else { onResponse?(String(decoding: b, as: UTF8.self)) }
    }

    /// ASCII の応答
    private func respond(_ s: String) {
        if let f = onResponseBytes { f(Array(s.utf8)) } else { onResponse?(s) }
    }

    /// vtterm.c RingBell: BeepSuppressTime 秒のあいだは鳴らさない。BeepOverUsedTime 秒に BeepOverUsedCount 回鳴ったら止める
    private func ringBell() {
        let now = bellClock()
        if now - bellSuppressAt < beepSuppressTime {
            bellSuppressAt = now
            return
        }
        if now - bellStartAt < beepOverUsedTime {
            if bellOverUsedLeft <= 1 { bellSuppressAt = now } else { bellOverUsedLeft -= 1 }
        } else {
            bellStartAt = now
            bellOverUsedLeft = beepOverUsedCount
        }
        guard bellMode != .off else { return }
        if let f = onBellKind { f(bellMode) } else { onBell?() }
    }

    /// CSSunSequence (CSI Ps t)
    private func windowSequence() {
        func q(_ i: Int) -> Int { p0(i) }
        let op = q(0)
        switch op {
        case 1...10:
            guard windowCtrlEnabled else { return }
            switch op {
            case 1: onWindowOp?(.deiconify)
            case 2: onWindowOp?(.iconify)
            case 3: onWindowOp?(.move(x: q(1), y: q(2)))
            case 4: onWindowOp?(.resizePixels(width: q(2), height: q(1)))
            case 5: onWindowOp?(.raise)
            case 6: onWindowOp?(.lower)
            case 7: onWindowOp?(.refresh)
            case 8:
                let r = q(1) <= 1 ? 24 : q(1)
                let c = q(2) <= 1 ? 80 : q(2)
                onWindowOp?(.resizeTerminal(cols: c, rows: r))
            case 9:
                if q(1) == 0 { onWindowOp?(.restore) } else if q(1) == 1 { onWindowOp?(.maximize) }
            case 10:
                switch q(1) {
                case 0: onWindowOp?(.restore)
                case 1: onWindowOp?(.maximize)
                case 2: onWindowOp?(.toggleMaximize)
                default: break
                }
            default: break
            }
        case 11...19:
            guard windowReportEnabled else { return }
            if op == 18 { respond("\u{1B}[8;\(rows);\(cols)t"); return }
            guard let info = windowInfo?() else { return }
            switch op {
            case 11: respond("\u{1B}[\(info.iconified ? 2 : 1)t")
            case 13:
                switch q(1) {
                case 0, 1: respond("\u{1B}[3;\(max(0, info.windowX));\(max(0, info.windowY))t")
                case 2: respond("\u{1B}[3;\(max(0, info.clientX));\(max(0, info.clientY))t")
                default: break
                }
            case 14:
                switch q(1) {
                case 0, 1: respond("\u{1B}[4;\(info.clientHeight);\(info.clientWidth)t")
                case 2: respond("\u{1B}[4;\(info.windowHeight);\(info.windowWidth)t")
                default: break
                }
            case 15: respond("\u{1B}[5;\(info.screenHeight);\(info.screenWidth)t")
            case 16: respond("\u{1B}[6;\(info.cellHeight);\(info.cellWidth)t")
            case 19: respond("\u{1B}[9;\(info.screenRows);\(info.screenCols)t")
            default: break
            }
        case 20, 21:
            // タイトルの報告 (OSC L… / OSC l… を ST で)
            let kind = op == 20 ? "L" : "l"
            switch titleReportMode {
            case .ignore: break
            case .empty: respond("\u{1B}]" + kind + "\u{1B}\\")
            case .accept:
                let t = TitleFormatter.report(local: localTitle, remote: remoteTitle, mode: titleChangeMode)
                sendBytes(Array("\u{1B}]".utf8) + sendEncoding.encode(kind + t) + Array("\u{1B}\\".utf8))
            }
        case 22:
            // Push Title
            if (0...2).contains(q(1)) && titleChangeMode != .off { titleStack.append(remoteTitle) }
        case 23:
            // Pop Title
            if (0...2).contains(q(1)) && titleChangeMode != .off, let t = titleStack.popLast() {
                remoteTitle = t
                onTitle?(t ?? "")
            }
        default: break
        }
    }

    /// カーソル行の文字 (BuffDumpCurrentLine。行末の空白を除く)
    private func currentLineForPrint() -> String {
        lines[cy].text.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }

    /// CS_i_Mode (MC)
    private func mediaCopy(_ m: Int) {
        guard printerCtrlEnabled else { return }
        switch m {
        case 0: onPrint?(.screen(wholeScreen: printExtent))
        case 5: printerMode = true; printBuf = ""
        default: break
        }
    }

    /// プリンタコントローラ中の制御文字 (PrnParseControl)
    private func printerControl(_ v: UInt32) {
        switch v {
        case 0x00, 0x11, 0x13: break
        case 0x0E, 0x0F, 0x1B: control(v)
        default: printBuf.unicodeScalars.append(Unicode.Scalar(v)!)
        }
    }

    private func decPrivate(_ f: Character) {
        switch f {
        case "i":
            // CSQ_i_Mode (DECMC)
            switch p0(0) {
            case 1: if printerCtrlEnabled { onPrint?(.text(currentLineForPrint() + "\r\n")) }
            case 4: autoPrintMode = false
            case 5: if printerCtrlEnabled { autoPrintMode = true }
            default: break
            }
        case "h", "l":
            let on = f == "h"
            for m in params {
                switch m {
                case 1: appCursor = on
                case 12: if cursorCtrlEnabled { cursorBlink = on }   // att610 カーソル点滅
                case 19: printExtent = on                             // DECPEX
                case 5: reverseScreen = on
                case 6: originMode = on; moveTo(0, 0)
                case 7: autowrap = on
                case 25: cursorVisible = on
                case 38: if on { enterTEK([]) }   // DECTEK
                case 47, 1047:
                    if on { enterAlt() } else { leaveAlt() }
                case 1048:
                    if on { saveCursor() } else { restoreCursor() }
                case 1049:
                    if on {
                        saveCursor(); enterAlt()
                        for y in 0..<rows { lines[y] = Line(cols: cols) }
                    } else {
                        leaveAlt(); restoreCursor()
                    }
                case 1000, 1002, 1003: mouseMode = on ? m : 0
                // 拡張マウスの形式 (MouseReportExtMode) はどれか 1 つ。リセットはどれでも「なし」に戻す
                case 1006: mouseSGR = on; mouseSGRPixels = false
                case 1016: mouseSGR = on; mouseSGRPixels = on      // SGR-Pixels (f10c93025 #575)
                case 2004: bracketedPaste = on
                default: break
                }
            }
        case "n":
            if p0(0) == 6 {
                onResponse?("\u{1B}[?\(cy + 1);\(cx + 1)R")
            }
        default: break
        }
    }

    private func sgr() {
        if params.isEmpty { attr = CellAttr(); return }
        var i = 0
        while i < params.count {
            let v = params[i] < 0 ? 0 : params[i]
            // 38 / 48 のあとに ':' で続くサブパラメータ (38:2::r:g:b など)。ほかの SGR として読まない
            var sub: [Int] = []
            var k = i
            if v == 38 || v == 48 {
                while k < subNext.count && subNext[k] && k + 1 < params.count { k += 1; sub.append(params[k]) }
            }
            switch v {
            case 0: attr = CellAttr()
            case 1: attr.bold = true
            case 2: attr.dim = true
            case 3: attr.italic = true
            case 4: attr.underline = true
            case 5, 6: attr.blink = true
            case 7: attr.reverse = true
            case 8: attr.invisible = true
            case 9: attr.strike = true
            case 21, 22: attr.bold = false; attr.dim = false
            case 23: attr.italic = false
            case 24: attr.underline = false
            case 25: attr.blink = false
            case 27: attr.reverse = false
            case 28: attr.invisible = false
            case 29: attr.strike = false
            case 30...37: attr.fg = .idx(UInt8(v - 30))
            case 39: attr.fg = .def
            case 40...47: attr.bg = .idx(UInt8(v - 40))
            case 49: attr.bg = .def
            // aixterm 形式の明るい色 (ts.ColorFlag & CF_AIXTERM16)。オフのとき 100 は文字色と背景色を戻す
            case 90...97: if aixterm16Color { attr.fg = .idx(UInt8(v - 90 + 8)) }
            case 100 where !aixterm16Color: attr.fg = .def; attr.bg = .def
            case 100...107: if aixterm16Color { attr.bg = .idx(UInt8(v - 100 + 8)) }
            // 256 色 / フルカラー (CF_XTERM256)。オフなら 38 / 48 は何もしない (続く値はそれぞれ SGR として読まれる)
            case 38 where !xterm256Color, 48 where !xterm256Color: break
            case 38, 48:
                var color: TColor?
                func c(_ n: Int) -> UInt8 { UInt8(max(0, min(255, n))) }
                if !sub.isEmpty {
                    // 38:5:n / 38:2:r:g:b (本家) / 38:2:id:r:g:b / 38:2::r:g:b (ITU T.416・xterm)
                    if sub[0] == 5, sub.count >= 2, sub[1] >= 0 {
                        color = .idx(c(sub[1]))
                    } else if sub[0] == 2 {
                        let rgb = sub.count >= 5 ? Array(sub[2...4]) : Array(sub.dropFirst())
                        if rgb.count == 3 { color = .rgb(c(rgb[0]), c(rgb[1]), c(rgb[2])) }
                    }
                } else if i + 1 < params.count, params[i + 1] == 2 || params[i + 1] == 5 {
                    let mode = params[i + 1]
                    k = i + 1
                    // 38;5:n / 38;2:r:g:b のようにモードのあとが ':' のもの
                    var rest: [Int] = []
                    while k < subNext.count && subNext[k] && k + 1 < params.count { k += 1; rest.append(params[k]) }
                    if rest.isEmpty {
                        // 38;5;n / 38;2;r;g;b (足りなければ残りを読み捨てる)
                        let end = min(params.count - 1, k + (mode == 5 ? 1 : 3))
                        if end > k { rest = Array(params[(k + 1)...end]) }
                        k = end
                    }
                    if mode == 5, let n = rest.first, n >= 0 {
                        color = .idx(c(n))
                    } else if mode == 2 {
                        let rgb = rest.count >= 4 ? Array(rest.suffix(3)) : rest
                        if rgb.count == 3 { color = .rgb(c(rgb[0]), c(rgb[1]), c(rgb[2])) }
                    }
                }
                if let c = color {
                    if v == 38 { attr.fg = c } else { attr.bg = c }
                }
            default: break
            }
            i = max(i, k) + 1
        }
    }

    /// XSequence (OSC Ps ; Pt)。bel: BEL で終わった (色の問い合わせの応答も BEL で終える。157a1093c)
    private func oscDispatch(bel: Bool) {
        // Ps のあとに ';' があるか (HasParamStr)。OSC 104 / 110 などは ';' なしでも動く
        let semi = oscBuf.firstIndex(of: ";")
        let code = String(oscBuf[..<(semi ?? oscBuf.endIndex)])
        let body: String? = semi.map { String(oscBuf[oscBuf.index(after: $0)...]) }
        guard !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isNumber }), let mode = Int(code.prefix(9)) else { return }
        switch mode {
        case 0, 1, 2:
            // XSequence: AcceptTitleChangeRequest が無効なら受け取らない。空ならリモートタイトルを消す
            guard let body = body, titleChangeMode != .off else { return }
            remoteTitle = body.isEmpty ? nil : body
            onTitle?(body)
        case 4, 5:
            // Change/Query color palette / special color: Pc ; spec ; Pc ; spec ...
            guard let body = body else { return }
            var num = 0
            var spec: String?
            for ch in body.unicodeScalars {
                if spec == nil {
                    if ch.value >= 0x30 && ch.value <= 0x39 { num = min(num &* 10 &+ Int(ch.value - 0x30), 0xFFFF_FFF) }
                    else if ch == ";" { spec = "" }
                    else { break }
                } else if ch == ";" {
                    colorSequence(mode, num, spec!, bel: bel)
                    num = 0; spec = nil
                } else {
                    spec!.unicodeScalars.append(ch)
                }
            }
            if let s = spec { colorSequence(mode, num, s, bel: bel) }
        case 10...19:
            // Change/Query VT-Window fg/bg, ... highlight fg: ';' で区切ると次の番号の色
            guard let body = body else { return }
            var m = mode
            for spec in body.split(separator: ";", omittingEmptySubsequences: false) {
                colorSequence(m, 0, String(spec), bel: bel)
                m += 1
            }
        case 52:
            if let body = body { clipboardSequence(body) }
        case 104, 105:
            // Reset color palette / special color
            if let body = body {
                var num: Int? = 0
                for ch in body.unicodeScalars {
                    if ch.value >= 0x30 && ch.value <= 0x39 {
                        if let n = num { num = min(n &* 10 &+ Int(ch.value - 0x30), 0xFFFF_FFF) }
                    } else if ch == ";" {
                        // 数字でないものがあった番号は CS_UNSPEC (104 ならパレット全部、105 なら特殊色全部)
                        resetColor(Terminal.xtColorSlot(mode, num))
                        num = 0
                    } else {
                        num = nil
                    }
                }
                if let n = num { resetColor(Terminal.xtColorSlot(mode, n)) }
            } else {
                resetColor(Terminal.xtColorSlot(mode, nil))
            }
        case 110...119:
            // Reset VT-Window fg/bg ... highlight fg。続く数字 (; 区切り) もその番号の色を戻す
            resetColor(Terminal.xtColorSlot(mode, nil))
            if let body = body {
                var num: Int? = 0
                for ch in body.unicodeScalars {
                    if ch.value >= 0x30 && ch.value <= 0x39 {
                        num = min((num ?? 0) &* 10 &+ Int(ch.value - 0x30), 0xFFFF_FFF)
                    } else if ch == ";" {
                        if let n = num { resetColor(Terminal.xtColorSlot(n, nil)) }
                        num = 0
                    } else {
                        num = nil
                        break
                    }
                }
                if let n = num { resetColor(Terminal.xtColorSlot(n, nil)) }
            }
        default: break
        }
    }

    // MARK: - OSC の色 (vtterm.c XsProcColor / XtColor2TTColor / XsParseColor、vtdisp.c DispSetColor など)

    /// XtColor2TTColor: OSC の番号と色番号から Tera Term の色 (CS_*)。xt は nil = 番号なし (CS_UNSPEC)
    static func xtColorSlot(_ mode: Int, _ xt: Int?) -> ColorTarget? {
        switch mode >= 100 ? mode - 100 : mode {
        case 4:
            switch xt {
            case 256?: return .slot(.boldFG)
            case 257?: return .slot(.underFG)
            case 258?: return .slot(.blinkFG)
            case 259?: return .slot(.reverseBG)     // xterm と同じ動作 (7751c9ea3 #616)
            case nil: return mode == 104 ? .allANSI : nil
            case let n?: return n <= 255 ? .slot(.ansi(n)) : nil
            }
        case 5:
            switch xt {
            case 0?: return .slot(.boldFG)
            case 1?: return .slot(.underFG)
            case 2?: return .slot(.blinkFG)
            case 3?: return .slot(.reverseBG)
            case nil: return mode == 105 ? .allSpecial : nil
            default: return nil
            }
        case 10: return .slot(.normalFG)
        case 11: return .slot(.normalBG)
        case 15: return .slot(.tekFG)
        case 16: return .slot(.tekBG)
        case 17: return .slot(.boldBG)       // 太字属性の背景色 (ffc65ed6e #532)
        case 19: return .slot(.boldFG)       // 太字属性の文字色 (ffc65ed6e #532)
        default: return nil
        }
    }

    /// 8 色モードの 16 色の番号 (GetIndex256From16: 明るい / 暗い組が入れ替わっている。82e8173c8)
    static func index256From16(_ n: Int) -> Int {
        let t = [0, 9, 10, 11, 12, 13, 14, 15, 8, 1, 2, 3, 4, 5, 6, 7]
        return n >= 0 && n < 16 ? t[n] : n
    }

    /// シーケンスの色番号から、表示の 256 色表 (vt->ANSIColor) の番号
    private func storedSlot(_ s: ColorSlot) -> ColorSlot {
        if case .ansi(let n) = s, eightColorMode { return .ansi(Terminal.index256From16(n)) }
        return s
    }

    /// XsProcColor: "?" なら問い合わせに答え、色の指定ならその色にする
    private func colorSequence(_ mode: Int, _ num: Int, _ spec: String, bel: Bool) {
        guard case .slot(let slot)? = Terminal.xtColorSlot(mode, num) else { return }
        if spec == "?" {
            // DispGetColor: パレットは今の色、ほかの色は設定の色 (ts.VTColor など) を返す (本家と同じ)
            let c: RGB
            if case .ansi = slot {
                let st = storedSlot(slot)
                c = colorOverrides[st] ?? configuredColor?(st) ?? RGB(0, 0, 0)
            } else {
                c = configuredColor?(slot) ?? RGB(0, 0, 0)
            }
            let rgb = String(format: "rgb:%04x/%04x/%04x", Int(c.r) * 257, Int(c.g) * 257, Int(c.b) * 257)
            let str = mode == 4 || mode == 5 ? "\(mode);\(num);" + rgb : "\(mode);" + rgb
            // SendOSCstr: BEL で来たら BEL、でなければ ST で終える
            respond("\u{1B}]" + str + (bel ? "\u{07}" : "\u{1B}\\"))
        } else if let c = Terminal.parseXColor(spec) {
            colorOverrides[storedSlot(slot)] = c
            dirty = true
            onColorsChanged?()
        }
    }

    /// DispResetColor
    private func resetColor(_ t: ColorTarget?) {
        guard let t = t else { return }
        switch t {
        case .slot(let s): colorOverrides[storedSlot(s)] = nil
        case .allANSI:
            colorOverrides = colorOverrides.filter { if case .ansi = $0.key { return false } else { return true } }
        case .allSpecial:
            // CS_SP_ALL: 太字の文字色・点滅の文字色・反転の背景色
            for s in [ColorSlot.boldFG, .blinkFG, .reverseBG] { colorOverrides[s] = nil }
        }
        dirty = true
        onColorsChanged?()
    }

    /// DispResetColor(CS_ALL): OSC で変えた色をすべて戻す (メニューのリセット)
    public func resetColors() {
        guard !colorOverrides.isEmpty else { return }
        colorOverrides = [:]
        dirty = true
        onColorsChanged?()
    }

    /// XsParseColor: rgb:R/G/B (1〜4 桁) と #RGB (1〜4 桁ずつ)。sscanf の %Nx と同じく長さで決める
    static func parseXColor(_ spec: String) -> RGB? {
        let u = Array(spec.utf8)
        func hex(_ s: ArraySlice<UInt8>) -> Int? {
            guard !s.isEmpty else { return nil }
            var v = 0
            for b in s {
                switch b {
                case 0x30...0x39: v = v * 16 + Int(b - 0x30)
                case 0x41...0x46: v = v * 16 + Int(b - 0x41 + 10)
                case 0x61...0x66: v = v * 16 + Int(b - 0x61 + 10)
                default: return nil
                }
            }
            return v
        }
        var r = 0, g = 0, b = 0
        if u.count >= 4, String(decoding: u[0..<4], as: UTF8.self).lowercased() == "rgb:" {
            let w: Int
            switch u.count {
            case 9: w = 1
            case 12: w = 2
            case 15: w = 3
            case 18: w = 4
            default: return nil
            }
            // rgb:%Nx/%Nx/%Nx
            let a = 4, sep1 = a + w, bb = sep1 + 1, sep2 = bb + w, c = sep2 + 1
            guard u[sep1] == 0x2F, u[sep2] == 0x2F, let x = hex(u[a..<sep1]), let y = hex(u[bb..<sep2]), let z = hex(u[c..<(c + w)]) else { return nil }
            switch w {
            case 1: (r, g, b) = (x * 17, y * 17, z * 17)
            case 2: (r, g, b) = (x, y, z)
            case 3: (r, g, b) = (x >> 4, y >> 4, z >> 4)
            default: (r, g, b) = (x >> 8, y >> 8, z >> 8)
            }
        } else if u.first == 0x23 {
            let w: Int
            switch u.count {
            case 4: w = 1
            case 7: w = 2
            case 10: w = 3
            case 13: w = 4
            default: return nil
            }
            guard let x = hex(u[1..<(1 + w)]), let y = hex(u[(1 + w)..<(1 + 2 * w)]), let z = hex(u[(1 + 2 * w)..<(1 + 3 * w)]) else { return nil }
            switch w {
            case 1: (r, g, b) = (x << 4, y << 4, z << 4)
            case 2: (r, g, b) = (x, y, z)
            case 3: (r, g, b) = (x >> 4, y >> 4, z >> 4)
            default: (r, g, b) = (x >> 8, y >> 8, z >> 8)
            }
        } else {
            return nil
        }
        guard r <= 255, g <= 255, b <= 255 else { return nil }
        return RGB(UInt8(r), UInt8(g), UInt8(b))
    }

    /// XsProcClipboard (OSC 52 ; Pc ; Pd)
    private func clipboardSequence(_ buff: String) {
        let u = Array(buff.unicodeScalars)
        var i = 0
        while i < u.count && "cps01234567".unicodeScalars.contains(u[i]) { i += 1 }
        guard i < u.count, u[i] == ";" else { return }
        let header = String(String.UnicodeScalarView(u[0...i]))
        let data = String(String.UnicodeScalarView(u[(i + 1)...]))
        if data == "?" {
            if clipboardAccess.contains(.read) {
                if notifyClipboardAccess { onClipboardNotice?(.read) }
                guard let text = onClipboardRead?() else { return }
                // CBStartPasteB64: 送信の文字コードにして Base64
                let b = sendEncoding == .utf8 ? Array(text.utf8) : sendEncoding.encode(text)
                respond("\u{1B}]52;" + header + Terminal.base64Encode(b) + "\u{1B}\\")
            } else if notifyClipboardAccess {
                onClipboardNotice?(.readRejected)
            }
        } else if clipboardAccess.contains(.write) {
            var dec = StreamDecoder(encoding: receiveEncoding)
            let text = dec.decode(Terminal.base64Decode(data))
            if notifyClipboardAccess { onClipboardNotice?(.write(text)) }
            onClipboardWrite?(text)
        } else if notifyClipboardAccess {
            onClipboardNotice?(.writeRejected)
        }
    }

    private static let b64chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    static func base64Encode(_ b: [UInt8]) -> String {
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            let n = min(3, b.count - i)
            let v = (UInt32(b[i]) << 16) | (n > 1 ? UInt32(b[i + 1]) << 8 : 0) | (n > 2 ? UInt32(b[i + 2]) : 0)
            out.append(b64chars[Int(v >> 18) & 63])
            out.append(b64chars[Int(v >> 12) & 63])
            out.append(n > 1 ? b64chars[Int(v >> 6) & 63] : 0x3D)
            out.append(n > 2 ? b64chars[Int(v) & 63] : 0x3D)
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// ttlib b64decode: 知らない文字は飛ばし、= で終わる
    static func base64Decode(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var acc: UInt32 = 0, bits = 0
        for c in s.utf8 {
            let v: UInt32
            switch c {
            case 0x41...0x5A: v = UInt32(c - 0x41)
            case 0x61...0x7A: v = UInt32(c - 0x61 + 26)
            case 0x30...0x39: v = UInt32(c - 0x30 + 52)
            case 0x2B: v = 62
            case 0x2F: v = 63
            case 0x3D: return out
            default: continue
            }
            acc = (acc << 6) | v
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }
}
