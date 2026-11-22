import Foundation

/// 端末の文字コード (Tera Term の「漢字-受信/送信」に相当)
public enum TermEncoding: String, CaseIterable {
    case utf8 = "UTF-8"
    case sjis = "Shift_JIS"
    case eucjp = "EUC-JP"
    /// JIS (ISO-2022-JP, 7 ビット)。ESC $ B で漢字、ESC ( B / ESC ( J で英数、ESC ( I と SO/SI で半角カナ
    case jis = "JIS"

    var nsEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .sjis, .jis: return .shiftJIS
        case .eucjp: return .japaneseEUC
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

    public mutating func decode(_ input: [UInt8]) -> String {
        if encoding == .jis { return jis.decode(input) }
        let bytes = pending + input
        pending = []
        let cut = completeLength(bytes)
        if cut < bytes.count { pending = Array(bytes[cut...]) }
        if cut == 0 { return "" }
        let body = Array(bytes[0..<cut])
        switch encoding {
        case .utf8:
            return String(decoding: body, as: UTF8.self)
        case .sjis, .eucjp, .jis:
            if let s = String(bytes: body, encoding: encoding.nsEncoding) { return s }
            return decodeCharByChar(body)
        }
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
