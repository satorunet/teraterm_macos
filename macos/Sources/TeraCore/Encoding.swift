import Foundation

/// 端末の文字コード (Tera Term の「漢字-受信/送信」に相当)
/// 本家の並び・名前は ttlib_charset.cpp KanjiList。1 バイトの文字コード (ISO8859-x / CPxxx / KOI8-R) は
/// 本家と同じ対応表 (mapping/*.map → SBCSTables.swift) で変換する (#510 6a854d5ab)。
/// rawValue は設定 (UserDefaults) に保存する名前。前からある 4 つはそのまま、ほかは INI の名前
public enum TermEncoding: String, CaseIterable {
    case utf8 = "UTF-8"
    case sjis = "Shift_JIS"
    case eucjp = "EUC-JP"
    /// JIS (ISO-2022-JP, 7 ビット)。ESC $ B で漢字、ESC ( B / ESC ( J で英数、ESC ( I と SO/SI で半角カナ
    case jis = "JIS"
    case iso8859_1 = "ISO8859-1", iso8859_2 = "ISO8859-2", iso8859_3 = "ISO8859-3", iso8859_4 = "ISO8859-4"
    case iso8859_5 = "ISO8859-5", iso8859_6 = "ISO8859-6", iso8859_7 = "ISO8859-7", iso8859_8 = "ISO8859-8"
    case iso8859_9 = "ISO8859-9", iso8859_10 = "ISO8859-10", iso8859_11 = "ISO8859-11", iso8859_13 = "ISO8859-13"
    case iso8859_14 = "ISO8859-14", iso8859_15 = "ISO8859-15", iso8859_16 = "ISO8859-16"
    /// KOI8-R (RFC 1489。本家 IdKOI8_NEW)
    case koi8r = "KOI8-R"
    /// 韓国語 CP949 / 中国語 CP936 / CP950 (本家 IdKoreanCP949 / IdCnGB2312 / IdCnBig5)
    case ks5601 = "KS5601", gb2312 = "GB2312", big5 = "BIG5"
    case cp437 = "CP437", cp737 = "CP737", cp775 = "CP775", cp850 = "CP850", cp852 = "CP852", cp855 = "CP855"
    case cp857 = "CP857", cp860 = "CP860", cp861 = "CP861", cp862 = "CP862", cp863 = "CP863", cp864 = "CP864"
    case cp865 = "CP865", cp866 = "CP866", cp869 = "CP869", cp874 = "CP874"
    case cp1250 = "CP1250", cp1251 = "CP1251", cp1252 = "CP1252", cp1253 = "CP1253", cp1254 = "CP1254"
    case cp1255 = "CP1255", cp1256 = "CP1256", cp1257 = "CP1257", cp1258 = "CP1258"

    /// ttlib_charset.cpp KanjiList: (文字コード, 設定画面の名前 (nil は出さない), INI の名前)。この順に並べる
    public static let kanjiList: [(code: TermEncoding, gui: String?, ini: String)] = [
        (.utf8, "UTF-8", "UTF-8"),
        (.iso8859_1, "ISO8859-1 Latin-1 Western European", "ISO8859-1"),
        (.iso8859_2, "ISO8859-2 Latin-2 Central European", "ISO8859-2"),
        (.iso8859_3, "ISO8859-3 Latin-3 South European", "ISO8859-3"),
        (.iso8859_4, "ISO8859-4 Latin-4 North European", "ISO8859-4"),
        (.iso8859_5, "ISO8859-5 Latin/Cyrillic", "ISO8859-5"),
        (.iso8859_6, "ISO8859-6 Latin/Arabic", "ISO8859-6"),
        (.iso8859_7, "ISO8859-7 Latin/Greek", "ISO8859-7"),
        (.iso8859_8, "ISO8859-8 Latin/Hebrew", "ISO8859-8"),
        (.iso8859_9, "ISO8859-9 Latin-5 Turkish", "ISO8859-9"),
        (.iso8859_10, "ISO8859-10 Latin-6 Nordic", "ISO8859-10"),
        (.iso8859_11, "ISO8859-11 Latin/Thai", "ISO8859-11"),
        (.iso8859_13, "ISO8859-13 Latin-7 Baltic Rim", "ISO8859-13"),
        (.iso8859_14, "ISO8859-14 Latin-8 Celtic", "ISO8859-14"),
        (.iso8859_15, "ISO8859-15 Latin-9", "ISO8859-15"),
        (.iso8859_16, "ISO8859-16 Latin-10 South-Eastern European", "ISO8859-16"),
        // 日本語
        (.sjis, "SJIS (CP932)", "SJIS"),
        (.eucjp, nil, "EUC-JP"),
        (.eucjp, "EUC", "EUC"),
        (.jis, "JIS", "JIS"),
        // Russian
        (.cp1251, "CP1251 Windows-1251", "Windows-1251"),
        (.koi8r, "KOI8-R (RFC 1489)", "KOI8-R"),
        (.cp866, "CP866 Cyrillic Russian", "CP866"),
        // 本家はここに ISO8859-5 をもう一度並べる (同じ名前なので Mac では 1 つだけにする)
        // Korean
        (.ks5601, "KS5601 (CP949)", "KS5601"),
        (.gb2312, "GB2312 (CP936)", "GB2312"),
        (.big5, "Big5 (CP950)", "BIG5"),
        // https://www.unicode.org/L2/L1999/99325-E.htm
        (.cp437, "CP437 Latin (US)", "CP437"),
        (.cp737, "CP737 Greek (A)", "CP737"),
        (.cp775, "CP775 BaltRim", "CP775"),
        (.cp850, "CP850 Latin (A)", "CP850"),
        (.cp852, "CP852 Latin (B)", "CP852"),
        (.cp855, "CP855 Cyrillic (A)", "CP855"),
        (.cp857, "CP857 Turkish", "CP857"),
        (.cp860, "CP860 Portuguese", "CP860"),
        (.cp861, "CP861 Icelandic", "CP861"),
        (.cp862, "CP862 Hebrew", "CP862"),
        (.cp863, "CP863 Canada F", "CP863"),
        (.cp864, "CP864 Arabic", "CP864"),
        (.cp865, "CP865 Nordic", "CP865"),
        // 本家はここに CP866 をもう一度並べる (同じ名前なので 1 つだけ)
        (.cp869, "CP869 Greek (B)", "CP869"),
        (.cp874, "CP874 Thai", "CP874"),
        // https://learn.microsoft.com/en-us/windows/win32/intl/code-page-identifiers
        (.cp1250, "CP1250 Central European", "CP1250"),
        (.cp1251, "CP1251 Cyrillic", "CP1251"),
        (.cp1252, "CP1252 Latin 1", "CP1252"),
        (.cp1253, "CP1253 Greek", "CP1253"),
        (.cp1254, "CP1254 Turkish", "CP1254"),
        (.cp1255, "CP1255 Hebrew", "CP1255"),
        (.cp1256, "CP1256 Arabic", "CP1256"),
        (.cp1257, "CP1257 Baltic", "CP1257"),
        (.cp1258, "CP1258 Vietnamese", "CP1258"),
    ]

    /// 設定画面の一覧 (CodeStrGUI のあるもの。coding_pp.cpp)
    public static var guiList: [(code: TermEncoding, name: String)] {
        kanjiList.compactMap { e in e.gui.map { (e.code, $0) } }
    }

    /// GetKanjiCodeStr: INI に書く名前 (最初に見つかったもの)
    public var iniName: String { TermEncoding.kanjiList.first { $0.code == self }?.ini ?? "UTF-8" }

    /// 設定画面での名前
    public var displayName: String { TermEncoding.kanjiList.first { $0.code == self && $0.gui != nil }?.gui ?? rawValue }

    /// GetKanjiCodeFromStr: INI の名前 (大文字小文字も区別) から。空・知らない名前は UTF-8。
    /// /KR= /KT= と KanjiReceive / KanjiSend はこれで読む (5.2 で UTF8m はなくなったので UTF-8 になる)
    public static func fromKanjiCodeStr(_ s: String) -> TermEncoding {
        kanjiList.first { $0.ini == s }?.code ?? .utf8
    }

    /// INI の名前と完全に同じなら (GetKanjiCodeFromStr で UTF-8 に落ちるかどうかを見分ける)
    public static func exactKanjiCodeStr(_ s: String) -> TermEncoding? {
        kanjiList.first { $0.ini == s }?.code
    }

    /// buffer.c IsDBCS: 2 バイト文字コード (曖昧幅は全角、絵文字は全角)
    public var isDBCS: Bool {
        switch self {
        case .sjis, .eucjp, .jis, .ks5601, .gb2312, .big5: return true
        default: return false
        }
    }

    /// 日本語の文字コード (LangIsJapanese)
    public var isJapanese: Bool { self == .sjis || self == .eucjp || self == .jis }

    /// 1 バイトの文字コード (ISO8859-x / CPxxx / KOI8-R)。対応表
    var sbcsTable: [UInt16]? {
        switch self {
        case .iso8859_1: return nil
        case .iso8859_2: return SBCSTables.iso8859_2
        case .iso8859_3: return SBCSTables.iso8859_3
        case .iso8859_4: return SBCSTables.iso8859_4
        case .iso8859_5: return SBCSTables.iso8859_5
        case .iso8859_6: return SBCSTables.iso8859_6
        case .iso8859_7: return SBCSTables.iso8859_7
        case .iso8859_8: return SBCSTables.iso8859_8
        case .iso8859_9: return SBCSTables.iso8859_9
        case .iso8859_10: return SBCSTables.iso8859_10
        case .iso8859_11: return SBCSTables.iso8859_11
        case .iso8859_13: return SBCSTables.iso8859_13
        case .iso8859_14: return SBCSTables.iso8859_14
        case .iso8859_15: return SBCSTables.iso8859_15
        case .iso8859_16: return SBCSTables.iso8859_16
        case .koi8r: return SBCSTables.koi8_r
        case .cp437: return SBCSTables.cp437
        case .cp737: return SBCSTables.cp737
        case .cp775: return SBCSTables.cp775
        case .cp850: return SBCSTables.cp850
        case .cp852: return SBCSTables.cp852
        case .cp855: return SBCSTables.cp855
        case .cp857: return SBCSTables.cp857
        case .cp860: return SBCSTables.cp860
        case .cp861: return SBCSTables.cp861
        case .cp862: return SBCSTables.cp862
        case .cp863: return SBCSTables.cp863
        case .cp864: return SBCSTables.cp864
        case .cp865: return SBCSTables.cp865
        case .cp866: return SBCSTables.cp866
        case .cp869: return SBCSTables.cp869
        case .cp874: return SBCSTables.cp874
        case .cp1250: return SBCSTables.cp1250
        case .cp1251: return SBCSTables.cp1251
        case .cp1252: return SBCSTables.cp1252
        case .cp1253: return SBCSTables.cp1253
        case .cp1254: return SBCSTables.cp1254
        case .cp1255: return SBCSTables.cp1255
        case .cp1256: return SBCSTables.cp1256
        case .cp1257: return SBCSTables.cp1257
        case .cp1258: return SBCSTables.cp1258
        default: return nil
        }
    }

    /// 1 バイトの文字コードか (ISO8859-1 も含む)
    public var isSBCS: Bool { self == .iso8859_1 || sbcsTable != nil }

    /// ISO8859-x (本家 ParseEnglish。対応がないバイトは 0x80 以上もそのまま U+00xx として出す)
    var isISO8859: Bool { rawValue.hasPrefix("ISO8859-") }

    /// UnicodeFromSBCS: 1 バイト → Unicode。対応がなければ nil
    func sbcsToUnicode(_ b: UInt8) -> UInt32? {
        if self == .iso8859_1 { return UInt32(b) }
        guard let t = sbcsTable else { return nil }
        let u = t[Int(b)]
        return u == 0xFFFF ? nil : UInt32(u)
    }

    private static var reverseCache: [TermEncoding: [UInt16: UInt8]] = [:]
    private static let reverseLock = NSLock()

    /// UnicodeToSBCS: Unicode → 1 バイト。対応がなければ nil (送るときは ?)。
    /// 本家の ISO8859-1 は U+0100 以上も下位 8 ビットにしてしまうが、Mac では ? にする
    func unicodeToSBCS(_ u: UInt32) -> UInt8? {
        if self == .iso8859_1 { return u < 0x100 ? UInt8(u) : nil }
        guard u < 0x10000, let t = sbcsTable else { return nil }
        TermEncoding.reverseLock.lock()
        defer { TermEncoding.reverseLock.unlock() }
        if let m = TermEncoding.reverseCache[self] { return m[UInt16(u)] }
        var m: [UInt16: UInt8] = [:]
        for (i, v) in t.enumerated() where v != 0xFFFF && m[v] == nil { m[v] = UInt8(i) }   // 本家は前から探して最初のもの
        TermEncoding.reverseCache[self] = m
        return m[UInt16(u)]
    }

    var nsEncoding: String.Encoding {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        switch self {
        case .utf8: return .utf8
        case .sjis, .jis: return .shiftJIS
        case .eucjp: return .japaneseEUC
        // makeoutputstring.cpp: code_page 949 / 936 / 950
        case .ks5601: return cf(.dosKorean)
        case .gb2312: return cf(.dosChineseSimplif)
        case .big5: return cf(.dosChineseTrad)
        default: return .isoLatin1   // 1 バイトの文字コードは対応表を使うので使わない
        }
    }

    /// JIS で送るときの漢字イン・漢字アウト・半角カナ (KanjiIn / KanjiOut / KatakanaSend)。
    /// encode(_:) が使う。設定を変えたら入れ直す
    public static var jisSendOptions = JISSendOptions()

    public func encode(_ s: String) -> [UInt8] { encode(s, jis: TermEncoding.jisSendOptions) }

    /// 1 回分を変換する。JIS は最後に英数へ戻す (続けて送るなら JISEncoder を使う)
    public func encode(_ s: String, jis: JISSendOptions) -> [UInt8] {
        if self == .utf8 { return Array(s.utf8) }
        if self == .jis {
            var e = JISEncoder(options: jis)
            return e.encode(s) + e.finish()
        }
        if isSBCS {
            // makeoutputstring.cpp: UnicodeToISO8859 / UnicodeToCodePage。変換できない文字は ?
            return s.unicodeScalars.map { unicodeToSBCS($0.value) ?? 0x3F }
        }
        if let d = s.data(using: nsEncoding, allowLossyConversion: true) { return [UInt8](d) }
        return Array(s.utf8)
    }
}

/// JIS 送信の設定 (エンコーディングタブの「漢字イン」「漢字アウト」「半角カナ」)
public struct JISSendOptions: Equatable {
    /// KanjiIn: "B" → ESC $ B, "@" → ESC $ @
    public var kanjiIn: UInt8 = 0x42
    /// KanjiOut: "B" → ESC ( B, "J" → ESC ( J, "H" → ESC ( H
    public var kanjiOut: UInt8 = 0x42
    /// KatakanaSend=7: 半角カナを SO/SI と 7 ビットで送る (8 なら 8 ビットのまま)
    public var katakana7 = false
    public init() {}
    /// INI の文字列から (makeoutputstring.cpp GetKanjiInCodeFromIni / GetKanjiOutCodeFromIni)。
    /// 知らない値は KanjiIn = B、KanjiOut = J。H は AllowWrongSequence のときだけ (ないなら J)
    public init(kanjiIn: String, kanjiOut: String, katakana7: Bool, allowWrongSequence: Bool = false) {
        self.kanjiIn = kanjiIn == "@" ? 0x40 : 0x42
        switch kanjiOut {
        case "B": self.kanjiOut = 0x42
        case "H": self.kanjiOut = allowWrongSequence ? 0x48 : 0x4A
        default: self.kanjiOut = 0x4A
        }
        self.katakana7 = katakana7
    }
}

/// JIS の送信 (makeoutputstring.cpp MakeOutputString の IdJIS)。直前の文字集合を覚えているので、
/// 漢字のあとの漢字アウトは次に英数 (または制御文字) を送るときに付く
public struct JISEncoder {
    public var options: JISSendOptions
    private enum Mode { case ascii, kana, kanji }
    private var mode = Mode.ascii
    public init(options: JISSendOptions = JISSendOptions()) { self.options = options }

    /// U+0100 未満の文字の前: 漢字アウト、7 ビットカナなら SI で戻す
    private mutating func toASCII(_ out: inout [UInt8]) {
        if mode == .kanji { out += [0x1B, 0x28, options.kanjiOut] }
        if options.katakana7 && mode == .kana { out.append(0x0F) }
        mode = .ascii
    }

    public mutating func encode(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        for u in s.unicodeScalars {
            if u.value < 0x100 { toASCII(&out) }
            guard let d = String(Character(u)).data(using: .shiftJIS), !d.isEmpty, d.count <= 2 else {
                out.append(0x3F)   // CP932 にない文字は ?
                continue
            }
            let b = [UInt8](d)
            if u.value < 0x100 {
                out.append(b[0])
            } else if (0xFF61...0xFF9F).contains(u.value), b.count == 1 {
                if options.katakana7 {
                    if mode != .kana { out.append(0x0E) }
                    out.append(b[0] & 0x7F)
                } else {
                    out.append(b[0])
                }
                mode = .kana
            } else if b.count == 2 {
                let (j1, j2) = JISCodec.sjisToJIS(b[0], b[1])
                if mode != .kanji { out += [0x1B, 0x24, options.kanjiIn]; mode = .kanji }
                out += [j1, j2]
            } else {
                out.append(b[0])
            }
        }
        return out
    }

    /// 英数に戻す (まとめて変換するとき最後に付ける)
    public mutating func finish() -> [UInt8] {
        var out: [UInt8] = []
        toASCII(&out)
        return out
    }
}

/// バイト列を少しずつ受け取り、文字の途中で切れた分は次回に回して文字列にする
public struct StreamDecoder {
    public var encoding: TermEncoding
    private var pending: [UInt8] = []

    public init(encoding: TermEncoding) { self.encoding = encoding }

    private var jis = JISCodec.Decoder()
    /// KatakanaReceive=7 (JIS のとき)。charset.cpp CharSetInit2: GR は G3 (漢字) になり、
    /// 0xA1–0xFE の 2 バイトは 8 ビットの JIS 漢字として読む。8 (既定) なら GR は G2 (半角カナ)
    public var jis7Katakana: Bool {
        get { jis.jis7Katakana }
        set { jis.jis7Katakana = newValue }
    }

    /// 文字の途中で残っているバイトと JIS の文字集合 (漢字イン / SO) を捨てる。
    /// 漢字コードを変えたとき (TTXKanjiMenu 0.1.7 CallResetCharSet → ResetCharSet → CharSetInit)
    public mutating func reset() {
        pending = []
        let k = jis.jis7Katakana
        jis = JISCodec.Decoder()
        jis.jis7Katakana = k
    }

    public mutating func decode(_ input: [UInt8]) -> String {
        if encoding == .jis { return jis.decode(input) }
        if encoding.isSBCS { pending = []; return decodeSBCS(input) }
        let bytes = pending + input
        pending = []
        let cut = completeLength(bytes)
        if cut < bytes.count { pending = Array(bytes[cut...]) }
        if cut == 0 { return "" }
        let body = Array(bytes[0..<cut])
        switch encoding {
        case .utf8:
            return String(decoding: body, as: UTF8.self)
        default:
            if let s = String(bytes: body, encoding: encoding.nsEncoding) { return s }
            return decodeCharByChar(body)
        }
    }

    /// 1 バイトの文字コード (charset.cpp ParseEnglish / ParseCodePage)。
    /// 対応表にないバイト: ISO8859-x はそのまま U+00xx (ParseFirst の後半)、CPxxx / KOI8-R は捨てる
    private func decodeSBCS(_ b: [UInt8]) -> String {
        var out = String.UnicodeScalarView()
        let e = encoding
        for c in b {
            if c < 0x80 { out.append(Unicode.Scalar(c)); continue }
            if let u = e.sbcsToUnicode(c), let sc = Unicode.Scalar(u) {
                out.append(sc)
            } else if e.isISO8859 {
                out.append(Unicode.Scalar(c))
            }
        }
        return String(out)
    }

    /// 1 文字ずつに分けて変換する (壊れたバイトがあっても残りは読めるように)
    private func decodeCharByChar(_ b: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i < b.count {
            let n = max(1, charLength(b, i))
            let end = min(b.count, i + n)
            if let s = String(bytes: b[i..<end], encoding: encoding.nsEncoding) {
                out += s
            } else {
                out += "\u{FFFD}"
            }
            i = end
        }
        return out
    }

    /// i 番目から始まる 1 文字のバイト数 (足りなくても期待される長さを返す)
    private func charLength(_ b: [UInt8], _ i: Int) -> Int {
        let c = b[i]
        switch encoding {
        case .utf8:
            if c < 0x80 { return 1 }
            if c & 0xE0 == 0xC0 { return 2 }
            if c & 0xF0 == 0xE0 { return 3 }
            if c & 0xF8 == 0xF0 { return 4 }
            return 1
        case .sjis, .jis:
            if (0x81...0x9F).contains(c) || (0xE0...0xFC).contains(c) { return 2 }
            return 1
        case .eucjp:
            if c == 0x8E { return 2 }
            if c == 0x8F { return 3 }
            if (0xA1...0xFE).contains(c) { return 2 }
            return 1
        case .ks5601, .gb2312, .big5:
            // charset.cpp ParseFirstKR / ParseFirstCn: 0x81–0xFE は 2 バイト文字の 1 バイト目
            return (0x81...0xFE).contains(c) ? 2 : 1
        default:
            return 1
        }
    }

    /// 末尾の途中の文字を除いた長さ
    private func completeLength(_ b: [UInt8]) -> Int {
        if encoding == .utf8 {
            // 末尾から最大 3 バイト戻って先頭バイトを探す
            var i = b.count - 1
            var back = 0
            while i >= 0 && back < 4 {
                let c = b[i]
                if c & 0xC0 != 0x80 {
                    let need = charLength(b, i)
                    return (b.count - i) < need ? i : b.count
                }
                i -= 1; back += 1
            }
            return b.count
        }
        var i = 0
        while i < b.count {
            let n = charLength(b, i)
            if i + n > b.count { return i }
            i += n
        }
        return b.count
    }
}

/// JIS (ISO-2022-JP) の変換。漢字は JIS X 0208 を Shift_JIS に計算で直して読む
enum JISCodec {
    static func jisToSJIS(_ j1: UInt8, _ j2: UInt8) -> (UInt8, UInt8) {
        let s1 = UInt8((Int(j1) + 1) >> 1 + (j1 <= 0x5E ? 0x70 : 0xB0))
        let s2: UInt8
        if j1 & 1 == 1 { s2 = j2 + (j2 >= 0x60 ? 0x20 : 0x1F) } else { s2 = j2 + 0x7E }
        return (s1, s2)
    }

    static func sjisToJIS(_ s1: UInt8, _ s2: UInt8) -> (UInt8, UInt8) {
        var j1 = Int(s1) - (s1 <= 0x9F ? 0x70 : 0xB0)
        j1 <<= 1
        let j2: Int
        if s2 < 0x9F {
            j1 -= 1
            j2 = Int(s2) - (s2 >= 0x80 ? 0x20 : 0x1F)
        } else {
            j2 = Int(s2) - 0x7E
        }
        return (UInt8(truncatingIfNeeded: j1), UInt8(truncatingIfNeeded: j2))
    }

    /// 送信 (既定の設定で 1 回分。最後は英数に戻す)
    static func encode(_ s: String) -> [UInt8] {
        var e = JISEncoder(options: TermEncoding.jisSendOptions)
        return e.encode(s) + e.finish()
    }

    /// 受信: 文字集合を切り替えるエスケープシーケンスだけ読み取り、それ以外の ESC は端末へそのまま渡す
    struct Decoder {
        enum Mode { case ascii, kanji, kana }
        var mode = Mode.ascii
        /// SO (0x0E) で半角カナ、SI (0x0F) で戻る
        var shiftOut = false
        /// KatakanaReceive=7: GR (0xA1–0xFE) を漢字として読む
        var jis7Katakana = false
        private var pending: [UInt8] = []

        mutating func decode(_ input: [UInt8]) -> String {
            let b = pending + input
            pending = []
            var out = ""
            var i = 0
            func sjis(_ s1: UInt8, _ s2: UInt8) -> String {
                String(bytes: [s1, s2], encoding: .shiftJIS) ?? "\u{FFFD}"
            }
            while i < b.count {
                let c = b[i]
                if c == 0x1B {
                    // ESC $ @ / ESC $ B / ESC $ ( B, ESC ( B / ESC ( J / ESC ( I
                    if i + 1 >= b.count { pending = Array(b[i...]); break }
                    let c1 = b[i + 1]
                    if c1 == 0x24 {
                        if i + 2 >= b.count { pending = Array(b[i...]); break }
                        let c2 = b[i + 2]
                        if c2 == 0x40 || c2 == 0x42 { mode = .kanji; i += 3; continue }
                        if c2 == 0x28 {
                            if i + 3 >= b.count { pending = Array(b[i...]); break }
                            if b[i + 3] == 0x42 || b[i + 3] == 0x40 { mode = .kanji; i += 4; continue }
                        }
                    } else if c1 == 0x28 {
                        if i + 2 >= b.count { pending = Array(b[i...]); break }
                        let c2 = b[i + 2]
                        if c2 == 0x42 || c2 == 0x4A || c2 == 0x48 { mode = .ascii; i += 3; continue }
                        if c2 == 0x49 { mode = .kana; i += 3; continue }
                    }
                    out.unicodeScalars.append(Unicode.Scalar(c)); i += 1; continue
                }
                if c == 0x0E { shiftOut = true; i += 1; continue }
                if c == 0x0F { shiftOut = false; i += 1; continue }
                if c < 0x21 || c == 0x7F {
                    out.unicodeScalars.append(Unicode.Scalar(c)); i += 1; continue
                }
                if c >= 0xA1 && c <= 0xFE && jis7Katakana {
                    // GR = G3 (漢字): 8 ビットの JIS 漢字 (2 バイト目は 0x21–0x7E か 0xA1–0xFE)
                    if i + 1 >= b.count { pending = [c]; break }
                    let c2 = b[i + 1]
                    if (0x21...0x7E).contains(c2) || (0xA1...0xFE).contains(c2) {
                        let (s1, s2) = JISCodec.jisToSJIS(c & 0x7F, c2 & 0x7F)
                        out += sjis(s1, s2)
                        i += 2
                    } else {
                        out += "\u{FFFD}"; i += 1
                    }
                    continue
                }
                if c >= 0x80 {
                    // 8 ビットの半角カナ (JIS8) と、それ以外はそのまま Shift_JIS として読む
                    if (0xA1...0xDF).contains(c) { out.unicodeScalars.append(Unicode.Scalar(0xFF61 + UInt32(c - 0xA1))!) }
                    else { out += "\u{FFFD}" }
                    i += 1; continue
                }
                if shiftOut || mode == .kana {
                    if (0x21...0x5F).contains(c) { out.unicodeScalars.append(Unicode.Scalar(0xFF61 + UInt32(c - 0x21))!) }
                    else { out.unicodeScalars.append(Unicode.Scalar(c)) }
                    i += 1; continue
                }
                if mode == .kanji {
                    if i + 1 >= b.count { pending = [c]; break }
                    let c2 = b[i + 1]
                    if (0x21...0x7E).contains(c2) {
                        let (s1, s2) = JISCodec.jisToSJIS(c, c2)
                        out += sjis(s1, s2)
                        i += 2
                    } else {
                        out += "\u{FFFD}"; i += 1
                    }
                    continue
                }
                out.unicodeScalars.append(Unicode.Scalar(c)); i += 1
            }
            return out
        }
    }
}
