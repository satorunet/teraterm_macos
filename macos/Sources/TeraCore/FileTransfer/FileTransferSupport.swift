// ファイル転送まわりの、端末ウインドウから使う Windows 版と同じ決まりごと
//  - FileTransferPaths: ts.FileDir (changedir) と転送ファイル名の解決 (ttlib_types.cpp GetFileDir, filesys_proto.cpp)
//  - FileTransferOptions.loadTeraTermIni: TERATERM.INI の転送設定
//  - SendFilePlan: sendfile の読み込み・改行の正規化・送信の区切り (sendmem.cpp, fileread.cpp LoadFileWW)
//  - TransferAutoStartScanner: ZMODEM / B-Plus の自動起動 (vtterm.c CANSeen / DLESeen)

import Foundation

public enum FileTransferPaths {
    /// Windows の既定のダウンロードフォルダ (FOLDERID_Downloads) にあたるもの
    public static var downloadsDirectory: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    }

    /// ExpandEnvironmentStrings と同じく %VAR% を展開する。Mac では $VAR / ${VAR} / 先頭の ~ も展開する。
    /// 定義されていない変数はそのまま残す。%USERPROFILE% / %HOMEPATH% は (環境に無ければ) ホームフォルダ
    public static func expandEnvironment(_ s: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        func lookup(_ name: String) -> String? {
            if let v = env[name] { return v }
            if let (_, v) = env.first(where: { $0.key.uppercased() == name.uppercased() }) { return v }
            switch name.uppercased() {
            case "USERPROFILE", "HOMEPATH", "HOME": return NSHomeDirectory()
            default: return nil
            }
        }
        var out = ""
        let c = Array(s)
        var i = 0
        while i < c.count {
            if c[i] == "%", let j = c[(i + 1)...].firstIndex(of: "%"), j > i + 1 {
                let name = String(c[(i + 1)..<j])
                if let v = lookup(name) { out += v; i = j + 1; continue }
            } else if c[i] == "$" && i + 1 < c.count {
                if c[i + 1] == "{", let j = c[(i + 2)...].firstIndex(of: "}"), j > i + 2 {
                    let name = String(c[(i + 2)..<j])
                    if let v = lookup(name) { out += v; i = j + 1; continue }
                } else {
                    var j = i + 1
                    while j < c.count && (c[j].isLetter || c[j].isNumber || c[j] == "_") && c[j].isASCII { j += 1 }
                    if j > i + 1, let v = lookup(String(c[(i + 1)..<j])) { out += v; i = j; continue }
                }
            }
            out.append(c[i])
            i += 1
        }
        if out == "~" || out.hasPrefix("~/") { out = (out as NSString).expandingTildeInPath }
        return out
    }

    /// GetFileDir(): FileDir が設定されていて (環境変数を展開して) フォルダがあればそれ、なければダウンロード。
    /// Windows のパス (C:\dir) は Mac のパスに寄せる。相対パスはホームフォルダから
    /// (Windows 版はプロセスのカレントフォルダ。Mac のアプリでは / になるので、ホームにしている)
    public static func fileDirectory(_ raw: String, env: [String: String] = ProcessInfo.processInfo.environment,
                                     folderExists: (String) -> Bool = FileTransferPaths.folderExists) -> String {
        if !raw.isEmpty {
            var d = TTLInterpreter.windowsPath(expandEnvironment(raw, env: env))
            if !d.hasPrefix("/") { d = (NSHomeDirectory() as NSString).appendingPathComponent(d) }
            if folderExists(d) { return d }
        }
        return downloadsDirectory
    }

    public static func folderExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// マクロが渡したファイル名 (そのままの文字列) を、filesys_proto.cpp と同じく
    /// 相対パスなら FileDir からの相対として解決する (IsRelativePathW → GetFileDir + "\" + filename)
    public static func resolve(_ name: String, fileDir: String) -> String {
        var p = TTLInterpreter.windowsPath(name)
        if p == "~" || p.hasPrefix("~/") { p = (p as NSString).expandingTildeInPath }
        if p.hasPrefix("/") { return p }
        return (fileDir as NSString).appendingPathComponent(p)
    }
}

extension FileTransferOptions {
    /// 転送設定を読む TERATERM.INI の候補 (先にあるものを使う)
    ///  1. UserDefaults "TeraTermIniPath" (TERATERM.INI を読み込んだときに保存しておくパス)
    ///  2. ~/Library/Application Support/Tera Term Mac/TERATERM.INI
    public static func teraTermIniCandidates(defaults: UserDefaults = .standard) -> [String] {
        var r: [String] = []
        if let p = defaults.string(forKey: "TeraTermIniPath"), !p.isEmpty { r.append((p as NSString).expandingTildeInPath) }
        if let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            r.append(sup.appendingPathComponent("Tera Term Mac").appendingPathComponent("TERATERM.INI").path)
        }
        return r
    }

    /// 候補の最初に読める TERATERM.INI から作る。無ければ既定値 (Tera Term 同梱の TERATERM.INI と同じ)
    public static func loadTeraTermIni(paths: [String] = FileTransferOptions.teraTermIniCandidates()) -> (options: FileTransferOptions, path: String?) {
        for p in paths {
            if let d = FileManager.default.contents(atPath: p), let ini = IniFile(data: d) {
                return (FileTransferOptions(ini: ini), p)
            }
        }
        return (FileTransferOptions(), nil)
    }
}

/// sendfile の送り方 (sendmem.cpp SendMemSendFileCom / SendMemContinuously)
public struct SendFilePlan: Equatable {
    public enum Chunk: Equatable {
        /// テキスト: 改行は CR だけに正規化済み。送るときに端末の改行コード・文字コードにする (CommTextOutW)
        case text(String)
        /// バイナリ: そのまま (CommBinaryBuffOut)
        case binary([UInt8])
    }
    public var chunks: [Chunk]
    /// 各チャンクの後に待つ時間 (ms)。最後のチャンクの後は待たない
    public var delayMs: Int

    public init(chunks: [Chunk], delayMs: Int) {
        self.chunks = chunks
        self.delayMs = delayMs
    }

    /// 貼り付け (clipboar.c CBSendStart → SendMem): 改行 (CR) ごとに区切り、各行のあと PasteDelayPerLine だけ待つ
    public static func paste(_ text: String, delayPerLine: Int) -> SendFilePlan {
        var chunks: [Chunk] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ch == "\r" { chunks.append(.text(cur)); cur = "" }
        }
        if !cur.isEmpty { chunks.append(.text(cur)) }
        return SendFilePlan(chunks: chunks, delayMs: max(0, delayPerLine))
    }

    /// LoadFileWW (LoadFileU8C): UTF-8 BOM は取る、UTF-16 LE/BE の BOM があれば UTF-16、BOM がなければ
    /// Windows はシステムのコードページ。Mac では UTF-8 として読めれば UTF-8、だめなら CP932。
    /// 文字列は最初の NUL で終わる (strlen / wcslen)。その後 NormalizeLineBreakCR (CR LF / LF → CR)
    public static func decodeText(_ data: Data) -> String {
        let b = [UInt8](data)
        var s: String
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF {
            s = String(decoding: b[3...], as: UTF8.self)
        } else if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE {
            s = utf16(b[2...], bigEndian: false)
        } else if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF {
            s = utf16(b[2...], bigEndian: true)
        } else {
            let body = b.firstIndex(of: 0).map { Array(b[..<$0]) } ?? b
            if let u = String(bytes: body, encoding: .utf8) {
                s = u
            } else {
                let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
                s = String(data: Data(body), encoding: cp932) ?? String(decoding: body, as: UTF8.self)
            }
        }
        if let z = s.unicodeScalars.firstIndex(of: "\u{0}") { s = String(s.unicodeScalars[..<z]) }
        return normalizeLineBreakCR(s)
    }

    private static func utf16(_ b: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        var i = b.startIndex
        while i + 1 < b.endIndex {
            let u = bigEndian ? (UInt16(b[i]) << 8 | UInt16(b[i + 1])) : (UInt16(b[i + 1]) << 8 | UInt16(b[i]))
            if u == 0 { break }
            units.append(u)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// NormalizeLineBreakCR: CR LF → CR, LF → CR
    public static func normalizeLineBreakCR(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var prevCR = false
        for u in s.unicodeScalars {
            if u == "\n" {
                if !prevCR { out.append("\r") }
                prevCR = false
                continue
            }
            prevCR = u == "\r"
            out.append(u)
        }
        return String(out)
    }

    /// - Parameters:
    ///   - delayType: SendfileDelayType (0=NoDelay 1=PerChar 2=PerLine 3=PerSendSize)
    ///   - delayTick: SendfileDelayTick (ms)
    ///   - sendSize: SendfileSize (PerSendSize のときの 1 回の送信バイト数。テキストは UTF-16 換算)
    public static func make(data: Data, binary: Bool, delayType: Int, delayTick: Int, sendSize: Int) -> SendFilePlan {
        let tick = max(0, delayTick)
        // SendMemInitDelay: PerChar / PerLine は tick が 0 なら遅延なし (全力送信)
        var type = delayType
        if (type == 1 || type == 2) && tick == 0 { type = 0 }
        if type == 3 && sendSize <= 0 { type = 0 }
        if binary {
            let b = [UInt8](data)
            var chunks: [[UInt8]] = []
            switch type {
            case 1:
                chunks = b.map { [$0] }
            case 2:
                // 行ごと (CR, LF, CR LF の後で区切る)
                var cur: [UInt8] = []
                var i = 0
                while i < b.count {
                    cur.append(b[i])
                    if b[i] == 0x0D && i + 1 < b.count && b[i + 1] == 0x0A { cur.append(0x0A); i += 1 }
                    if b[i] == 0x0D || b[i] == 0x0A { chunks.append(cur); cur = [] }
                    i += 1
                }
                if !cur.isEmpty { chunks.append(cur) }
            case 3:
                var i = 0
                while i < b.count { chunks.append(Array(b[i..<min(b.count, i + sendSize)])); i += sendSize }
            default:
                if !b.isEmpty { chunks = [b] }
            }
            return SendFilePlan(chunks: chunks.map { .binary($0) }, delayMs: type == 0 ? 0 : tick)
        }
        let text = decodeText(data)
        var chunks: [String] = []
        switch type {
        case 1:
            chunks = text.unicodeScalars.map { String($0) }
        case 2:
            var cur = String.UnicodeScalarView()
            for u in text.unicodeScalars {
                cur.append(u)
                if u == "\r" { chunks.append(String(cur)); cur = String.UnicodeScalarView() }
            }
            if !cur.isEmpty { chunks.append(String(cur)) }
        case 3:
            // send_len & ~1 バイト = UTF-16 で sendSize/2 単位 (サロゲートペアは分けない)
            let limit = max(1, sendSize / 2)
            var cur = String.UnicodeScalarView()
            var n = 0
            for u in text.unicodeScalars {
                let w = u.value > 0xFFFF ? 2 : 1
                if n > 0 && n + w > limit { chunks.append(String(cur)); cur = String.UnicodeScalarView(); n = 0 }
                cur.append(u)
                n += w
            }
            if !cur.isEmpty { chunks.append(String(cur)) }
        default:
            if !text.isEmpty { chunks = [text] }
        }
        return SendFilePlan(chunks: chunks.map { .text($0) }, delayMs: type == 0 ? 0 : tick)
    }
}

/// 端末が受信データを解釈しているときの ZMODEM / B-Plus の自動起動 (vtterm.c ParseControl の CAN/DLE と CANSeen / DLESeen)。
/// ZmodemAuto / BPAuto が on のとき、CAN / DLE とその後の判定に使ったバイトは端末に渡さない (Windows 版と同じく消費される)
public struct TransferAutoStartScanner {
    public enum Trigger: Equatable {
        /// CAN 'B' '0' '0' (ZRQINIT) → IdZAutoR
        case zmodemReceive
        /// CAN 'B' '0' '1' (ZRINIT) → IdZAutoS
        case zmodemSend
        /// DLE 'B' → IdBPAuto
        case bplusReceive
    }
    public var zmodemAuto: Bool
    public var bplusAuto: Bool
    private enum Mode { case first, can(Int), dle }
    private var mode: Mode = .first

    public init(zmodemAuto: Bool = false, bplusAuto: Bool = false) {
        self.zmodemAuto = zmodemAuto
        self.bplusAuto = bplusAuto
    }

    /// - Returns: display = 端末へ渡すバイト, trigger = 自動起動するもの, rest = 起動した転送へ渡す残り
    public mutating func scan(_ bytes: [UInt8]) -> (display: [UInt8], trigger: Trigger?, rest: [UInt8]) {
        guard zmodemAuto || bplusAuto || !isFirst else { return (bytes, nil, []) }
        var display: [UInt8] = []
        display.reserveCapacity(bytes.count)
        for (i, b) in bytes.enumerated() {
            var trig: Trigger?
            switch mode {
            case .first:
                if b == 0x18 && zmodemAuto { mode = .can(0); continue }
                if b == 0x10 && bplusAuto { mode = .dle; continue }
                display.append(b)
            case .can(let st):
                if st == 0 && b == 0x42 { mode = .can(1); continue }      // 'B'
                if st == 1 && b == 0x30 { mode = .can(2); continue }      // '0'
                if st == 2 && b == 0x30 { trig = .zmodemReceive }
                if st == 2 && b == 0x31 { trig = .zmodemSend }
                mode = .first
            case .dle:
                if b == 0x42 { trig = .bplusReceive }
                mode = .first
            }
            if let t = trig { return (display, t, Array(bytes[(i + 1)...])) }
        }
        return (display, nil, [])
    }

    private var isFirst: Bool { if case .first = mode { return true } else { return false } }
}
