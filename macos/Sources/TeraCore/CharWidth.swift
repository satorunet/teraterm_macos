/// 文字の表示幅 (0 = 前の文字に合成, 1 = 半角, 2 = 全角)
/// buffer.c IsCombiningChar + BuffIsHalfWidthFromCode / BuffIsHalfWidthFromPropery と同じ順で決める。
/// テーブルは本家の unicode_*.tbl から作った CharWidthTables.swift (scripts/gen_charwidth_tables.py)
///   1. 結合文字 (unicode_combine.tbl) と ZWJ は前の文字に合成 (0)。Spacing Mark (Mc) は
///      本家ではセルを 1 つ広げて合成するので、ここでは幅 1 の文字として置く (桁位置は同じ)
///   2. U+FEFF (BOM / ZWNBSP) は幅 0 (#1219)
///   3. 受信漢字コードが UTF-8 のときだけ「Override Emoji Characters width」を使う (#1127)。
///      emojiWidth: UnicodeEmojiOverride + UnicodeEmojiWidth。nil ならオーバーライドしない。
///      絵文字 (unicode_emoji.tbl) のうち U+1F000 未満はこの幅、それ以上はいつも全角。
///      SJIS / EUC / JIS (DBCS) のときは絵文字はいつも全角
///   4. East_Asian_Width (unicode_asian_width.tbl): W / F は全角、A (曖昧) は UTF-8 なら
///      ambiguousWide (UnicodeAmbiguousWidth) に従い、DBCS ならいつも全角 (#1127)。ほかは半角
public func termCharWidth(_ s: Unicode.Scalar, ambiguousWide: Bool = false, emojiWidth: Int? = nil,
                          kanjiCode: TermEncoding = .utf8) -> Int {
    let v = s.value
    // 結合文字
    if v == 0x200D { return 0 }   // ゼロ幅接合子 (ZWJ)
    switch unicodeCombiningType(v) {
    case 1: return 0
    case 2: return 1
    default: break
    }
    if v == 0xFEFF { return 0 }
    // buffer.c IsDBCS: SJIS / EUC / JIS / KS5601 / GB2312 / BIG5。
    // 1 バイトの文字コード (ISO8859-x / CPxxx / KOI8-R, #510) は DBCS でも UTF-8 でもない: 曖昧幅はいつも半角
    let dbcs = kanjiCode.isDBCS
    if isUnicodeEmoji(v) {
        if kanjiCode == .utf8 {
            if let ew = emojiWidth {
                return v < 0x1F000 ? (ew == 2 ? 2 : 1) : 2
            }
        } else if dbcs {
            return 2
        }
    }
    // 文字属性毎の文字幅
    switch unicodeWidthProperty(v) {
    case UInt8(ascii: "W"), UInt8(ascii: "F"):
        return 2
    case UInt8(ascii: "A"):
        // BuffIsHalfWidthFromPropery: UTF-8 は UnicodeAmbiguousWidth、DBCS は全角、それ以外は半角
        return kanjiCode == .utf8 ? (ambiguousWide ? 2 : 1) : (dbcs ? 2 : 1)
    default:
        return 1
    }
}

/// Tera Term の UnicodeGetWidthProperty。East_Asian_Width 特性 (F/H/W/n/A/N の ASCII)。テーブルにないものは H
public func unicodeWidthProperty(_ v: UInt32) -> UInt8 {
    var lo = 0, hi = unicodeAsianWidthTable.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        let r = unicodeAsianWidthTable[mid]
        if v < r.0 { hi = mid - 1 } else if v > r.1 { lo = mid + 1 } else { return r.2 }
    }
    return UInt8(ascii: "H")
}

/// Tera Term の UnicodeIsCombiningCharacter。0 = 結合文字ではない, 1 = Nonspacing (カーソルは移動しない),
/// 2 = Spacing Mark (カーソル +1)
public func unicodeCombiningType(_ v: UInt32) -> Int {
    var lo = 0, hi = unicodeCombineTable.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        let r = unicodeCombineTable[mid]
        if v < r.0 { hi = mid - 1 } else if v > r.1 { lo = mid + 1 } else { return Int(r.2) }
    }
    return 0
}

/// Tera Term の UnicodeIsEmoji (teraterm/unicode_emoji.tbl, emoji-data.txt の Emoji=Yes)
public func isUnicodeEmoji(_ v: UInt32) -> Bool {
    var lo = 0, hi = unicodeEmojiTable.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        let r = unicodeEmojiTable[mid]
        if v < r.0 { hi = mid - 1 } else if v > r.1 { lo = mid + 1 } else { return true }
    }
    return false
}
