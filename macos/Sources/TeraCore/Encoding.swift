import Foundation

/// 端末の文字コード (Tera Term の「漢字-受信/送信」に相当)
public enum TermEncoding: String, CaseIterable {
    case utf8 = "UTF-8"
    case sjis = "Shift_JIS"
    case eucjp = "EUC-JP"

    var nsEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .sjis: return .shiftJIS
        case .eucjp: return .japaneseEUC
        }
    }

    public func encode(_ s: String) -> [UInt8] {
        if self == .utf8 { return Array(s.utf8) }
        if let d = s.data(using: nsEncoding, allowLossyConversion: true) { return [UInt8](d) }
        return Array(s.utf8)
    }
}

/// バイト列を少しずつ受け取り、文字の途中で切れた分は次回に回して文字列にする
public struct StreamDecoder {
    public var encoding: TermEncoding
    private var pending: [UInt8] = []

    public init(encoding: TermEncoding) { self.encoding = encoding }

    public mutating func decode(_ input: [UInt8]) -> String {
        let bytes = pending + input
        pending = []
        let cut = completeLength(bytes)
        if cut < bytes.count { pending = Array(bytes[cut...]) }
        if cut == 0 { return "" }
        let body = Array(bytes[0..<cut])
        switch encoding {
        case .utf8:
            return String(decoding: body, as: UTF8.self)
        case .sjis, .eucjp:
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
        case .sjis:
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
