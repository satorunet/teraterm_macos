// Tera Term のファイル転送プロトコル (XMODEM / YMODEM / ZMODEM / Kermit / B-Plus / Quick-VAN)。
// プロトコル本体は Tera Term の ttpfile/*.c をそのままコンパイルした CTeraFile ターゲット。
// ここは teraterm/filesys_proto.cpp に相当するドライバ (Parse の呼び出し、タイマー、結果通知)。
//
// スレッドモデル:
//   FileTransfer の全メソッドは init で渡した `queue` (既定はメインキュー) の上で呼ぶこと。
//   send / onProgress / onFinish / onMessage もすべてそのキューの上で呼ばれる。
//   send は start()/feed()/タイマーの処理中に同期的に呼ばれる。send の中から feed() を呼んでも
//   安全 (データは溜められ、処理中のループが続けて読む) だが、ループバック等では非同期にする方がよい。
//
// 回線との関係:
//   feed() には Telnet 処理後の受信データを、send で渡されるバイト列は (必要なら Telnet の
//   IAC 二重化などをして) そのまま回線へ送る。Windows 版の CommRead1Byte / CommBinaryOut と同じ位置。

import Foundation
import CTeraFile

public enum FileTransferKind: Equatable {
    case xmodemSend, xmodemRecv
    case ymodemSend, ymodemRecv
    case zmodemSend, zmodemRecv
    case kermitSend, kermitRecv, kermitGet, kermitFinish
    case bplusSend, bplusRecv
    case quickvanSend, quickvanRecv
    /// ZMODEM 自動起動 (端末が ZRQINIT / ZRINIT を検出したとき。IdZAutoR / IdZAutoS)
    case zmodemAutoRecv, zmodemAutoSend
    /// B-Plus 自動起動 (IdBPAuto)
    case bplusAutoRecv
    /// recvfile (ttpfile/raw.c): 受信データをそのままファイルへ。autoStopSec 秒受信がなければ成功で終わる
    case rawRecv

    /// 送信ファイルを必要とするか (Kermit Get はリモートのファイル名)
    public var takesFileName: Bool {
        switch self {
        case .xmodemSend, .xmodemRecv, .ymodemSend, .zmodemSend, .zmodemAutoSend,
             .kermitSend, .kermitGet, .bplusSend, .quickvanSend, .rawRecv:
            return true
        default:
            return false
        }
    }

    /// Windows 版のダイアログタイトル (filesys_proto.cpp の Tit*)
    public var title: String {
        switch self {
        case .kermitRecv: return "Kermit Receive"
        case .kermitGet: return "Kermit Get"
        case .kermitSend: return "Kermit Send"
        case .kermitFinish: return "Kermit Finish"
        case .xmodemRecv: return "XMODEM Receive"
        case .xmodemSend: return "XMODEM Send"
        case .ymodemRecv: return "YMODEM Receive"
        case .ymodemSend: return "YMODEM Send"
        case .zmodemRecv, .zmodemAutoRecv: return "ZMODEM Receive"
        case .zmodemSend, .zmodemAutoSend: return "ZMODEM Send"
        case .bplusRecv, .bplusAutoRecv: return "B-Plus Receive"
        case .bplusSend: return "B-Plus Send"
        case .quickvanRecv: return "Quick-VAN Receive"
        case .quickvanSend: return "Quick-VAN Send"
        case .rawRecv: return "Receiving file"
        }
    }
}

/// XMODEM オプション (xmodem.h)
public enum XmodemOption {
    public static let check = 1      // XoptCheck
    public static let crc = 2        // XoptCRC
    public static let oneKCRC = 3    // Xopt1kCRC
    public static let oneKCksum = 4  // Xopt1kCksum
}

/// プロトコルが参照する TTTSet / TComVar の項目。既定値は Tera Term 同梱の TERATERM.INI と同じ。
/// Windows 版の `ts` と同じく、マクロ (xmodemrecv 等) によって書き換えられ次の転送へ持ち越される項目がある
/// (applyMacroParameters を参照)。
public struct FileTransferOptions: Equatable {
    // [Tera Term] XmodemOpt=checksum → XoptCheck
    public var xmodemOpt: Int = XmodemOption.check
    // XmodemBin=on (XMODEM 受信のバイナリ / ZMODEM 送信のバイナリ)
    public var xmodemBin: Bool = true
    public var xmodemRcvCommand: String = ""        // XmodemRcvCommand=
    public var ymodemRcvCommand: String = ""        // YmodemRcvCommand=
    public var zmodemRcvCommand: String = "rz"      // ZmodemRcvCommand=rz
    public var zmodemDataLen: Int = 1024            // ZmodemDataLen=1024
    public var zmodemWinSize: Int = 32767           // ZmodemWinSize=32767
    public var zmodemEscCtl: Bool = false           // ZmodemEscCtl=off
    public var bplusEscCtl: Bool = false            // BPEscCtl=off
    public var qvWinSize: Int = 8                   // QVWinSize=8
    public var kermitLongPacket: Bool = false       // KmtLongPacket=off
    public var kermitFileAttr: Bool = false         // KmtFileAttr=off
    public var autoFileRename: Bool = true          // AutoFileRename=on (FT_RENAME: 既存ファイルは上書きせず番号を付ける)
    // XmodemTimeouts=10,3,10,20,60
    public var xmodemTimeOutInit = 10, xmodemTimeOutInitCRC = 3, xmodemTimeOutShort = 10,
               xmodemTimeOutLong = 20, xmodemTimeOutVLong = 60
    // YmodemTimeouts=10,3,10,20,60
    public var ymodemTimeOutInit = 10, ymodemTimeOutInitCRC = 3, ymodemTimeOutShort = 10,
               ymodemTimeOutLong = 20, ymodemTimeOutVLong = 60
    // ZmodemTimeouts=10,0,10,3
    public var zmodemTimeOutNormal = 10, zmodemTimeOutTCPIP = 0, zmodemTimeOutInit = 10, zmodemTimeOutFin = 3
    // ログ (XmodemLog / YmodemLog / ZmodemLog / KmtLog / BPLog / QVLog, いずれも off)
    public var xmodemLog = false, ymodemLog = false, zmodemLog = false,
               kermitLog = false, bplusLog = false, quickvanLog = false
    /// XMODEM.LOG 等を書くフォルダ (nil ならカレントディレクトリ)
    public var logDirectory: String?
    /// 回線の種類: true = TCP/IP (PortType=IdTCPIP), false = シリアル
    public var isTCPIP: Bool = true
    public var baudRate: Int = 9600                 // BaudRate=9600 (シリアル時のタイムアウト計算に使用)
    public var dataBits7: Bool = false              // DataBit=8
    /// ZMODEM 送信で実際に使うバイナリフラグ。nil なら xmodemBin。
    /// (Windows 版の zmodemsend は呼ばれた時点の ts.XmodemBin を使い、マクロ引数は次回以降に効く。
    ///  applyMacroParameters がその挙動を再現してここに設定する)
    public var zmodemBinary: Bool?

    /// FileDir= (ts.FileDirW)。changedir で書き換わる。そのままの文字列で持ち、使うときに
    /// FileTransferPaths.fileDirectory で展開する (GetFileDir と同じ)
    public var fileDir: String = ""
    /// ZmodemAuto=off (FT_ZAUTO): 端末が ZRQINIT / ZRINIT を受けたら ZMODEM を自動で始める
    public var zmodemAuto: Bool = false
    /// BPAuto=off (FT_BPAUTO): DLE 'B' で B-Plus を自動で始める
    public var bplusAuto: Bool = false
    /// ReceivefileAutoStopWaitTime=5 (recvfile の引数で書き換わる)
    public var receiveFileAutoStopWaitTime: Int = 5
    /// SendfileDelayType=NoDelay (0=NoDelay 1=PerChar 2=PerLine 3=PerSendSize)
    public var sendfileDelayType: Int = 0
    /// SendfileDelayTick=0 (ms)
    public var sendfileDelayTick: Int = 0
    /// SendfileSize=4096
    public var sendfileSize: Int = 4096

    public init() {}

    /// TERATERM.INI の [Tera Term] セクションから読む (ttset.c と同じキー・既定値)
    public init(ini: IniFile) {
        let s = "Tera Term"
        if let v = ini.string(s, "XmodemOpt") {
            switch v.lowercased() {
            case "crc": xmodemOpt = XmodemOption.crc
            case "1k": xmodemOpt = XmodemOption.oneKCRC
            case "1ksum": xmodemOpt = XmodemOption.oneKCksum
            default: xmodemOpt = XmodemOption.check
            }
        }
        if let v = ini.onOff(s, "XmodemBin") { xmodemBin = v }
        if let v = ini.string(s, "XModemRcvCommand") { xmodemRcvCommand = v }
        if let v = ini.string(s, "YModemRcvCommand") { ymodemRcvCommand = v }
        if let v = ini.string(s, "ZModemRcvCommand") { zmodemRcvCommand = v }
        if let v = ini.int(s, "ZmodemDataLen") { zmodemDataLen = v }
        if let v = ini.int(s, "ZmodemWinSize") { zmodemWinSize = v }
        if let v = ini.onOff(s, "ZmodemEscCtl") { zmodemEscCtl = v }
        if let v = ini.onOff(s, "BPEscCtl") { bplusEscCtl = v }
        if let v = ini.int(s, "QVWinSize") { qvWinSize = v }
        if let v = ini.onOff(s, "KmtLongPacket") { kermitLongPacket = v }
        if let v = ini.onOff(s, "KmtFileAttr") { kermitFileAttr = v }
        if let v = ini.onOff(s, "AutoFileRename") { autoFileRename = v }
        if let v = ini.onOff(s, "XmodemLog") { xmodemLog = v }
        if let v = ini.onOff(s, "YmodemLog") { ymodemLog = v }
        if let v = ini.onOff(s, "ZmodemLog") { zmodemLog = v }
        if let v = ini.onOff(s, "KmtLog") { kermitLog = v }
        if let v = ini.onOff(s, "BPLog") { bplusLog = v }
        if let v = ini.onOff(s, "QVLog") { quickvanLog = v }
        if let v = ini.int(s, "BaudRate") { baudRate = v }
        if let v = ini.string(s, "FileDir") { fileDir = v }
        if let v = ini.onOff(s, "ZmodemAuto") { zmodemAuto = v }
        if let v = ini.onOff(s, "BPAuto") { bplusAuto = v }
        if let v = ini.int(s, "ReceivefileAutoStopWaitTime") { receiveFileAutoStopWaitTime = v }
        if let v = ini.string(s, "SendfileDelayType") {
            switch v.trimmingCharacters(in: .whitespaces).lowercased() {
            case "perchar": sendfileDelayType = 1
            case "perline": sendfileDelayType = 2
            case "persendsize": sendfileDelayType = 3
            default: sendfileDelayType = 0
            }
        }
        if let v = ini.int(s, "SendfileDelayTick") { sendfileDelayTick = v }
        if let v = ini.int(s, "SendfileSize") { sendfileSize = v }
        if let v = ini.string(s, "DataBit") { dataBits7 = v.trimmingCharacters(in: .whitespaces) == "7" }
        func nth(_ key: String, _ i: Int, _ def: Int, min: Int) -> Int? {
            guard let str = ini.string(s, key) else { return nil }
            let parts = str.split(separator: ",", omittingEmptySubsequences: false)
            let v = i < parts.count ? Int(parts[i].trimmingCharacters(in: .whitespaces)) ?? def : def
            return Swift.max(v, min)
        }
        if ini.string(s, "XmodemTimeouts") != nil {
            xmodemTimeOutInit = nth("XmodemTimeouts", 0, 10, min: 1)!
            xmodemTimeOutInitCRC = nth("XmodemTimeouts", 1, 3, min: 1)!
            xmodemTimeOutShort = nth("XmodemTimeouts", 2, 10, min: 1)!
            xmodemTimeOutLong = nth("XmodemTimeouts", 3, 20, min: 1)!
            xmodemTimeOutVLong = nth("XmodemTimeouts", 4, 60, min: 1)!
        }
        if ini.string(s, "YmodemTimeouts") != nil {
            ymodemTimeOutInit = nth("YmodemTimeouts", 0, 10, min: 1)!
            ymodemTimeOutInitCRC = nth("YmodemTimeouts", 1, 3, min: 1)!
            ymodemTimeOutShort = nth("YmodemTimeouts", 2, 10, min: 1)!
            ymodemTimeOutLong = nth("YmodemTimeouts", 3, 20, min: 1)!
            ymodemTimeOutVLong = nth("YmodemTimeouts", 4, 60, min: 1)!
        }
        if ini.string(s, "ZmodemTimeouts") != nil {
            zmodemTimeOutNormal = nth("ZmodemTimeouts", 0, 10, min: 1)!
            zmodemTimeOutTCPIP = nth("ZmodemTimeouts", 1, 0, min: 0)!
            zmodemTimeOutInit = nth("ZmodemTimeouts", 2, 10, min: 1)!
            zmodemTimeOutFin = nth("ZmodemTimeouts", 3, 3, min: 1)!
        }
    }

    private static func isXoptCRC(_ x: Int) -> Bool { (x & 2) != 0 }
    private static func isXopt1k(_ x: Int) -> Bool { ((x - 1) & 2) != 0 }

    /// TTL マクロの引数を Windows 版と同じ経路 (ttl.cpp → ttmdde.c → ttdde.c → filesys_proto.cpp)
    /// で解釈し、`ts` 相当のこの構造体を書き換える。転送を始める直前に呼ぶ。
    ///  - xmodemrecv <file> <binflag> <option>: binaryFlag, xmodemOption
    ///  - xmodemsend <file> <option>: xmodemOption
    ///  - zmodemsend <file> <binflag>: binaryFlag
    ///  - その他のコマンドは引数による設定変更なし
    ///  - recvfile <file> <binflag> <autostop>: autoStopSec (ttdde.c CmdSetRecvFileOpt → ts.ReceivefileAutoStopWaitTime)
    public mutating func applyMacroParameters(kind: FileTransferKind, binaryFlag: Int = 0, xmodemOption: Int = 0,
                                              autoStopSec: Int? = nil) {
        // ttmdde.c SetBinary(): '0' + (BinFlag & 1) → ttdde.c: Command[1] & 1
        let paramBinary = binaryFlag & 1
        switch kind {
        case .xmodemRecv:
            // ttl.cpp TTLXmodemRecv
            var x: Int
            switch xmodemOption {
            case XmodemOption.crc: x = XmodemOption.crc
            case XmodemOption.oneKCRC: x = XmodemOption.crc   // for compatibility
            default: x = XmodemOption.check
            }
            x = Self.ddeXOption(x)
            // filesys_proto.cpp XMODEMStartReceive (macro)
            if Self.isXopt1k(xmodemOpt) {
                xmodemOpt = Self.isXoptCRC(x) ? XmodemOption.oneKCRC : XmodemOption.oneKCksum
            } else {
                xmodemOpt = Self.isXoptCRC(x) ? XmodemOption.crc : XmodemOption.check
            }
            xmodemBin = paramBinary != 0
        case .xmodemSend:
            // ttl.cpp TTLXmodemSend
            var x = xmodemOption == XmodemOption.oneKCRC ? XmodemOption.oneKCRC : XmodemOption.crc
            x = Self.ddeXOption(x)
            // filesys_proto.cpp XMODEMStartSend (macro)
            if Self.isXoptCRC(xmodemOpt) {
                xmodemOpt = Self.isXopt1k(x) ? XmodemOption.oneKCRC : XmodemOption.crc
            } else {
                xmodemOpt = Self.isXopt1k(x) ? XmodemOption.oneKCksum : XmodemOption.check
            }
        case .zmodemSend:
            // filesys_proto.cpp ZMODEMStartSend: Opt = ts.XmodemBin を取ってから ts.XmodemBin = ParamBinaryFlag
            zmodemBinary = xmodemBin
            xmodemBin = paramBinary != 0
        case .rawRecv:
            // ttmdde.c SetRecvFileOption: 負は 0、Word2HexStr で 16 ビット
            if let a = autoStopSec { receiveFileAutoStopWaitTime = Swift.max(0, a) & 0xFFFF }
        default:
            break
        }
    }

    // ttmdde.c SetXOption() + ttdde.c CmdSetXmodemOpt
    private static func ddeXOption(_ x: Int) -> Int {
        var v = (x < 1 || x > 3) ? 1 : x
        v &= 3
        return v == 0 ? 1 : v
    }

    fileprivate var logFlag: Int32 {
        var f: Int32 = 0
        if kermitLog { f |= 2 }
        if xmodemLog { f |= 4 }
        if zmodemLog { f |= 8 }
        if bplusLog { f |= 16 }
        if quickvanLog { f |= 32 }
        if ymodemLog { f |= 64 }
        return f
    }

    fileprivate var ftFlag: Int32 {
        var f: Int32 = 0
        if zmodemEscCtl { f |= 1 }
        if zmodemAuto { f |= 2 }
        if bplusEscCtl { f |= 4 }
        if bplusAuto { f |= 8 }
        if autoFileRename { f |= 16 }
        return f
    }

    fileprivate var kermitOpt: Int32 {
        (kermitLongPacket ? 1 : 0) | (kermitFileAttr ? 2 : 0)
    }
}

public struct FileTransferProgress: Equatable {
    /// "XMODEM (CRC)" 等 (SetDlgProtoText)
    public var protocolText: String = ""
    /// 転送中のファイル (フルパス, SetDlgProtoFileName)
    public var filePath: String?
    public var fileName: String? { filePath.map { ($0 as NSString).lastPathComponent } }
    public var packetNumber: Int = 0
    public var byteCount: Int = 0
    /// 送信時などファイルサイズが分かるとき (SetDlgPercent)
    public var totalBytes: Int?
    public var percent: Double?
    public var elapsed: TimeInterval = 0
}

public final class FileTransfer {
    public let kind: FileTransferKind
    public let files: [String]
    public let receiveDir: String
    public let options: FileTransferOptions
    public let queue: DispatchQueue

    public var onProgress: ((FileTransferProgress) -> Void)?
    /// 終了時に一度だけ。引数は fv->Success (マクロの result = 1 / 0)
    public var onFinish: ((Bool) -> Void)?
    /// プロトコルが MessageBox で出すエラー ("Cannot create file" 等)
    public var onMessage: ((String) -> Void)?
    /// 終了したときプロトコルが読まずに残った受信データ (Windows 版では cv.InBuff に残り、端末が続けて解釈する)。
    /// feed() の中で終わったときは呼ばれず、feed() の戻り値になる。onFinish の直後に呼ばれる
    public var onUnconsumedInput: (([UInt8]) -> Void)?

    /// cv.Ready。false の間 (切断後・未接続で開始) は Parse を呼ばず、回線への送信もしない。
    /// タイマーとキャンセルは動き続け、プロトコルが自分で中断すると (cv->Ready == FALSE → ProtoEnd) 結果 0 で終わる。
    /// Windows 版と同じく、切断しただけでは転送は終わらない。start() の前に false にすると未接続で始める
    public var isReady: Bool = true {
        didSet {
            guard oldValue != isReady, let ft = ft else { return }
            TeraFTSetReady(ft, isReady ? 1 : 0)
            if isReady { pump() }
        }
    }

    public private(set) var isRunning = false
    public private(set) var progress = FileTransferProgress()
    /// 終了後の結果
    public private(set) var succeeded = false

    /// Parse をアイドル時に呼ぶ間隔 (Windows 版は OnIdle で回し続ける)
    public var idleInterval: TimeInterval = 0.1
    /// false (既定) = マクロからの実行と同じ fv->NoMsg = TRUE。true にするとプロトコルのエラー表示を onMessage へ
    public var showsMessages = false

    private let sendHandler: ([UInt8]) -> Void
    private var ft: OpaquePointer?
    private var protoTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var pumping = false
    private var needsPump = false
    private var asyncPumpScheduled = false
    private var pendingCancel = false
    private var finished = false
    private var settingsStrings: [UnsafeMutablePointer<CChar>] = []
    private var feeding = false
    private var unconsumed: [UInt8] = []

    /// - Parameters:
    ///   - files: 送信ファイル (XMODEM 受信では保存ファイル名、Kermit Get ではリモートのファイル名)。
    ///            相対パスは receiveDir (= Tera Term の FileDir) からの相対として解決する (Windows 版と同じ)。
    ///   - receiveDir: 受信フォルダ兼ファイル転送の既定フォルダ (ts.FileDir)
    ///   - send: 回線へ送るバイト列
    public init(kind: FileTransferKind, files: [String], receiveDir: String, options: FileTransferOptions = FileTransferOptions(),
                queue: DispatchQueue = .main, send: @escaping ([UInt8]) -> Void) {
        self.kind = kind
        self.receiveDir = receiveDir
        self.files = files.map { FileTransfer.resolve($0, dir: receiveDir) }
        self.options = options
        self.queue = queue
        self.sendHandler = send
    }

    deinit {
        protoTimer?.cancel()
        idleTimer?.cancel()
        if let ft = ft { TeraFTDestroy(ft) }
        settingsStrings.forEach { free($0) }
    }

    static func resolve(_ path: String, dir: String) -> String {
        FileTransferPaths.resolve(path, fileDir: dir)
    }

    private var protoParams: (proto: Int32, mode: Int32, opt1: Int32, opt2: Int32) {
        let o = options
        switch kind {
        case .kermitRecv: return (Int32(TERAFT_PROTO_KMT), 1, 0, 0)    // IdKmtReceive
        case .kermitGet: return (Int32(TERAFT_PROTO_KMT), 2, 0, 0)     // IdKmtGet
        case .kermitSend: return (Int32(TERAFT_PROTO_KMT), 3, 0, 0)    // IdKmtSend
        case .kermitFinish: return (Int32(TERAFT_PROTO_KMT), 4, 0, 0)  // IdKmtFinish
        case .xmodemRecv: return (Int32(TERAFT_PROTO_XM), 1, Int32(o.xmodemOpt), o.xmodemBin ? 1 : 0)
        case .xmodemSend: return (Int32(TERAFT_PROTO_XM), 2, Int32(o.xmodemOpt), o.xmodemBin ? 1 : 0)
        case .ymodemRecv: return (Int32(TERAFT_PROTO_YM), 1, 1, 0)     // Yopt1K 決め打ち
        case .ymodemSend: return (Int32(TERAFT_PROTO_YM), 2, 1, 0)
        case .zmodemRecv: return (Int32(TERAFT_PROTO_ZM), 1, 0, 0)
        case .zmodemSend: return (Int32(TERAFT_PROTO_ZM), 2, (o.zmodemBinary ?? o.xmodemBin) ? 1 : 0, 0)
        case .zmodemAutoRecv: return (Int32(TERAFT_PROTO_ZM), 3, 0, 0)
        case .zmodemAutoSend: return (Int32(TERAFT_PROTO_ZM), 4, o.xmodemBin ? 1 : 0, 0)   // Opt = ts.XmodemBin
        case .bplusRecv: return (Int32(TERAFT_PROTO_BP), 1, 0, 0)
        case .bplusSend: return (Int32(TERAFT_PROTO_BP), 2, 0, 0)
        case .bplusAutoRecv: return (Int32(TERAFT_PROTO_BP), 3, 0, 0)
        case .quickvanRecv: return (Int32(TERAFT_PROTO_QV), 1, 0, 0)
        case .quickvanSend: return (Int32(TERAFT_PROTO_QV), 2, 0, 0)
        case .rawRecv: return (Int32(TERAFT_PROTO_RAW), 0, Int32(Swift.min(o.receiveFileAutoStopWaitTime, 0xFFFF)), 0)
        }
    }

    private func cstr(_ s: String?) -> UnsafePointer<CChar>? {
        guard let s = s else { return nil }
        let p = strdup(s)!
        settingsStrings.append(p)
        return UnsafePointer(p)
    }

    /// 転送を開始する (OpenProtoDlg + Init)。false のとき転送は始まっていない
    /// (送信ファイルが開けない等。Windows 版ではこの場合マクロの result は更新されない)。
    @discardableResult
    public func start() -> Bool {
        guard ft == nil, !finished else { return false }
        let o = options
        var s = TeraFTSettings()
        s.LogFlag = o.logFlag
        s.FTFlag = o.ftFlag
        s.XmodemOpt = Int32(o.xmodemOpt)
        s.XmodemBin = o.xmodemBin ? 1 : 0
        s.ZmodemDataLen = Int32(o.zmodemDataLen)
        s.ZmodemWinSize = Int32(o.zmodemWinSize)
        s.QVWinSize = Int32(o.qvWinSize)
        s.DataBit = o.dataBits7 ? 1 : 2
        s.Baud = Int32(o.baudRate)
        s.KermitOpt = o.kermitOpt
        s.XmodemTimeOutInit = Int32(o.xmodemTimeOutInit)
        s.XmodemTimeOutInitCRC = Int32(o.xmodemTimeOutInitCRC)
        s.XmodemTimeOutShort = Int32(o.xmodemTimeOutShort)
        s.XmodemTimeOutLong = Int32(o.xmodemTimeOutLong)
        s.XmodemTimeOutVLong = Int32(o.xmodemTimeOutVLong)
        s.YmodemTimeOutInit = Int32(o.ymodemTimeOutInit)
        s.YmodemTimeOutInitCRC = Int32(o.ymodemTimeOutInitCRC)
        s.YmodemTimeOutShort = Int32(o.ymodemTimeOutShort)
        s.YmodemTimeOutLong = Int32(o.ymodemTimeOutLong)
        s.YmodemTimeOutVLong = Int32(o.ymodemTimeOutVLong)
        s.ZmodemTimeOutNormal = Int32(o.zmodemTimeOutNormal)
        s.ZmodemTimeOutTCPIP = Int32(o.zmodemTimeOutTCPIP)
        s.ZmodemTimeOutInit = Int32(o.zmodemTimeOutInit)
        s.ZmodemTimeOutFin = Int32(o.zmodemTimeOutFin)
        s.PortType = o.isTCPIP ? 1 : 2
        s.XModemRcvCommand = cstr(o.xmodemRcvCommand)
        s.YModemRcvCommand = cstr(o.ymodemRcvCommand)
        s.ZModemRcvCommand = cstr(o.zmodemRcvCommand)
        s.LogDir = cstr(o.logDirectory)
        s.NotReady = isReady ? 0 : 1

        var dir = receiveDir
        if !dir.hasSuffix("/") { dir += "/" }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb = TeraFTCallbacks(
            ctx: ctx,
            send: { ctx, buf, len in
                guard let ctx = ctx, let buf = buf else { return }
                let me = Unmanaged<FileTransfer>.fromOpaque(ctx).takeUnretainedValue()
                me.sendHandler(Array(UnsafeBufferPointer(start: buf, count: len)))
            },
            setTimer: { ctx, ms in
                guard let ctx = ctx else { return }
                Unmanaged<FileTransfer>.fromOpaque(ctx).takeUnretainedValue().setProtoTimer(ms: Int(ms))
            },
            info: { ctx, item, a, b, text in
                guard let ctx = ctx else { return }
                Unmanaged<FileTransfer>.fromOpaque(ctx).takeUnretainedValue()
                    .info(item: Int(item), a: a, b: b, text: text.map { String(cString: $0) })
            })

        let p = protoParams
        let cfiles = files.map { strdup($0) }
        defer { cfiles.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = cfiles.map { UnsafePointer($0) }
        let created: OpaquePointer? = ptrs.withUnsafeMutableBufferPointer { buf in
            dir.withCString { d in
                TeraFTCreate(p.proto, p.mode, p.opt1, p.opt2, &s, buf.baseAddress, Int32(cfiles.count), d,
                             options.autoFileRename ? 0 : 1, showsMessages ? 0 : 1, cb)
            }
        }
        guard let handle = created else { return false }
        ft = handle
        isRunning = true
        pumping = true
        let ok = TeraFTInit(handle) != 0
        pumping = false
        if !ok || TeraFTEnded(handle) != 0 {
            // OpenProtoDlg 失敗 → ProtoEnd() (DdeCmnd 前なので EndDdeCmnd は届かない)
            isRunning = false
            protoTimer?.cancel(); protoTimer = nil
            TeraFTDestroy(handle)
            ft = nil
            finished = true
            return false
        }
        startIdleTimer()
        pump()
        return true
    }

    /// 回線から受信したデータ。この中で転送が終わったとき (または転送中でないとき) は、プロトコルが読まなかった残りを返す
    /// (呼び出し側が端末へ渡す。onUnconsumedInput は呼ばれない)
    @discardableResult
    public func feed(_ bytes: [UInt8]) -> [UInt8] {
        guard let ft = ft, isRunning else { return bytes }   // 転送していない: そのまま端末へ
        guard !bytes.isEmpty else { return [] }
        let nested = feeding
        feeding = true
        bytes.withUnsafeBufferPointer { TeraFTFeed(ft, $0.baseAddress, $0.count) }
        pump()
        feeding = nested
        if !nested && finished { return takeUnconsumedInput() }
        return []
    }

    /// 終了後、プロトコルが読まなかった受信データを取り出す (取り出すと空になる)
    public func takeUnconsumedInput() -> [UInt8] {
        let r = unconsumed
        unconsumed = []
        return r
    }

    /// ダイアログの Cancel ボタン相当 (Proto->Cancel)。プロトコルが中断手順を終えると onFinish(false)。
    public func cancel() {
        guard let ft = ft, isRunning else { return }
        if pumping { pendingCancel = true; needsPump = true; return }
        pumping = true
        TeraFTCancel(ft)
        pumping = false
        pump()
    }

    /// 回線切断時などに即座に終了する (プロトコルの中断手順なし)
    public func abort() {
        guard isRunning else { return }
        finish(success: false, sendQVReturn: false)
    }

    // MARK: - pump

    private func pump() {
        guard let ft = ft, isRunning else { return }
        if pumping { needsPump = true; return }
        pumping = true
        var iterations = 0
        while true {
            needsPump = false
            if pendingCancel {
                pendingCancel = false
                TeraFTCancel(ft)
            }
            let before = TeraFTActivity(ft)
            let r = TeraFTParse(ft)
            if r == 0 || TeraFTEnded(ft) != 0 {
                pumping = false
                finish(success: TeraFTSuccess(ft) != 0, sendQVReturn: true)
                return
            }
            iterations += 1
            let progressed = TeraFTActivity(ft) != before
            if !progressed && !needsPump && !pendingCancel && iterations >= 2 { break }
            if iterations >= 4096 {
                // キューを独占しないよう一旦戻る
                scheduleAsyncPump()
                break
            }
        }
        pumping = false
    }

    private func scheduleAsyncPump() {
        guard !asyncPumpScheduled else { return }
        asyncPumpScheduled = true
        queue.async { [weak self] in
            guard let self = self else { return }
            self.asyncPumpScheduled = false
            self.pump()
        }
    }

    private func finish(success: Bool, sendQVReturn: Bool) {
        guard !finished else { return }
        finished = true
        isRunning = false
        protoTimer?.cancel(); protoTimer = nil
        idleTimer?.cancel(); idleTimer = nil
        if let ft = ft {
            // CloseProtoDlg(): Quick-VAN 送信の後は CR を送る (CommBinaryOut なので切断中は送らない)
            if sendQVReturn && kind == .quickvanSend && isReady { sendHandler([0x0d]) }
            // ProtoEnd() の後も cv.InBuff に残ったデータは端末が解釈する
            var rest = [UInt8](repeating: 0, count: TeraFTBufferedBytes(ft))
            if !rest.isEmpty {
                let n = rest.withUnsafeMutableBufferPointer { TeraFTTakeBuffered(ft, $0.baseAddress, $0.count) }
                rest.removeSubrange(n...)
            }
            unconsumed += rest
            TeraFTDestroy(ft)   // ファイルを閉じる
            self.ft = nil
        }
        succeeded = success
        onFinish?(success)
        if !feeding, !unconsumed.isEmpty, let cb = onUnconsumedInput {
            cb(takeUnconsumedInput())
        }
    }

    // MARK: - timers

    private func setProtoTimer(ms: Int) {
        protoTimer?.cancel()
        protoTimer = nil
        guard ms > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(ms))
        t.setEventHandler { [weak self] in self?.protoTimerFired(t) }
        protoTimer = t
        t.resume()
    }

    private func protoTimerFired(_ t: DispatchSourceTimer) {
        guard protoTimer === t, let ft = ft, isRunning else { return }
        protoTimer = nil   // Windows の WM_TIMER は KillTimer してから ProtoDlgTimeOut
        t.cancel()
        if pumping { return }
        pumping = true
        TeraFTTimeOut(ft)
        pumping = false
        if TeraFTEnded(ft) != 0 {
            finish(success: TeraFTSuccess(ft) != 0, sendQVReturn: true)
            return
        }
        pump()
    }

    private func startIdleTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        let iv = max(0.01, idleInterval)
        t.schedule(deadline: .now() + iv, repeating: iv)
        t.setEventHandler { [weak self] in self?.pump() }
        idleTimer = t
        t.resume()
    }

    // MARK: - info

    private func info(item: Int, a: Int64, b: Int64, text: String?) {
        switch item {
        case Int(TERAFT_INFO_INIT_PROGRESS):
            progress.percent = 0
        case Int(TERAFT_INFO_TIME):
            progress.elapsed = TimeInterval(a) / 1000
        case Int(TERAFT_INFO_PACKET_NUM):
            progress.packetNumber = Int(a)
        case Int(TERAFT_INFO_BYTE_COUNT):
            progress.byteCount = Int(a)
        case Int(TERAFT_INFO_PERCENT):
            progress.totalBytes = Int(b)
            progress.percent = b == 0 ? 100 : 100 * Double(a) / Double(b)
        case Int(TERAFT_INFO_PROTO_TEXT):
            progress.protocolText = text ?? ""
        case Int(TERAFT_INFO_FILE_NAME):
            progress.filePath = text
        case Int(TERAFT_INFO_MESSAGE):
            // C 側の TTMessageBoxW は既定の英語しか渡さないので、本家が言語ファイルで引く文言はここで引き直す
            var m = text ?? ""
            if m == "Cannot open file" { m = Lang.t("Tera Term", "MSG_CANTOPEN_FILE_ERROR", m) }
            onMessage?(m)
            return
        default:
            return
        }
        onProgress?(progress)
    }
}
