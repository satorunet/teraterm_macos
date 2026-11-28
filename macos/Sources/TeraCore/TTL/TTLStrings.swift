// 文字列・日時・環境まわりのマクロコマンド
// ttpmacro/ttl.cpp の TTLCode2Str 〜 TTLUptime などをそのまま移したもの。
// 文字列は Tera Term 5 と同じく UTF-8 のバイト列で扱う (長さ・位置はバイト数)。
import Foundation
import Darwin
import COniguruma

// MARK: - 小さな道具 (C の標準関数のかわり)

private let chBackslash: UInt8 = 0x5C
private let chPercent: UInt8 = 0x25

/// C の isspace
private func cIsSpace(_ b: UInt8) -> Bool { b == 0x20 || (b >= 0x09 && b <= 0x0D) }
private func cIsDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

/// sscanf の %d (と %u) 相当。読めた数を返す。読めなければ nil。
/// 桁あふれは MSVC と同じく 32bit で折り返す
private func scanDecimal(_ s: [UInt8], _ i: inout Int) -> Int32? {
    var p = i
    while p < s.count, cIsSpace(s[p]) { p += 1 }
    var neg = false
    if p < s.count, s[p] == 0x2B || s[p] == 0x2D { neg = s[p] == 0x2D; p += 1 }
    var v: UInt32 = 0
    var digits = 0
    while p < s.count, cIsDigit(s[p]) {
        v = v &* 10 &+ UInt32(s[p] - 0x30)
        p += 1; digits += 1
    }
    if digits == 0 { return nil }
    i = p
    return Int32(bitPattern: neg ? 0 &- v : v)
}

/// sscanf の %i で "0x..." を読む (str2int で 0x / $ で始まるときだけ使う)
private func scanHex(_ s: [UInt8], _ i: inout Int) -> Int32? {
    var p = i + 2   // "0x"
    var v: UInt32 = 0
    while p < s.count, let d = TTLInterpreter.hexVal(s[p]) {
        v = v &* 16 &+ UInt32(d)
        p += 1
    }
    i = p
    return Int32(bitPattern: v)
}

/// strncat_s(dest, MaxStrLen, src, _TRUNCATE)
private func strCat(_ dest: inout [UInt8], _ src: [UInt8]) {
    let room = MaxStrLen - 1 - dest.count
    if room <= 0 { return }
    var s = src
    if let z = s.firstIndex(of: 0) { s.removeSubrange(z...) }
    dest += s.prefix(room)
}

/// C 文字列として見る (最初の NUL まで)
private func cStr(_ b: [UInt8]) -> [UInt8] {
    if let z = b.firstIndex(of: 0) { return Array(b[..<z]) }
    return b
}

/// ASCII だけの大文字小文字を無視した比較 (_stricmp)
private func asciiLower(_ b: [UInt8]) -> [UInt8] { b.map { ($0 >= 0x41 && $0 <= 0x5A) ? $0 + 0x20 : $0 } }

/// RestoreNewLine (ttlib.c): \\ \n \t \0 を置き換える
private func restoreNewLineC(_ t: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    let n = t.count
    while i < n {
        if t[i] == chBackslash {
            let nx: UInt8 = i + 1 < n ? t[i + 1] : 0
            switch nx {
            case chBackslash: out.append(chBackslash); i += 1
            case 0x6E: out.append(0x0A); i += 1      // n
            case 0x74: out.append(0x09); i += 1      // t
            case 0x30: out.append(0); i += 1         // 0
            default: out.append(chBackslash)
            }
        } else {
            out.append(t[i])
        }
        i += 1
    }
    return cStr(out)
}

// MARK: strftime

/// isInvalidStrftimeChar (ttlib_static_cpp.cpp)
private func isInvalidStrftimeChar(_ f: [UInt8]) -> Bool {
    let valid = Set("aAbBcdHIjmMpSUwWxXyYzZ%".utf8)
    let n = f.count
    func at(_ k: Int) -> UInt8 { k < n ? f[k] : 0 }
    var i = 0
    while i < n {
        if f[i] == chPercent {
            if at(i + 1) != 0 {
                var p = i + 1
                if at(i + 2) != 0 && at(i + 1) == 0x23 { p = i + 2 }   // '#'
                if valid.contains(at(p)) { i = p } else { return true }
            } else {
                return true
            }
        }
        i += 1
    }
    return false
}

/// MSVC (C ロケール) の strftime の書き方を Darwin の strftime に合わせて書き直す
private func msvcStrftimeToDarwin(_ f: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    let n = f.count
    var i = 0
    while i < n {
        let c = f[i]
        if c != chPercent || i + 1 >= n { out.append(c); i += 1; continue }
        var p = i + 1
        var alt = false
        if f[p] == 0x23, p + 1 < n { alt = true; p += 1 }
        let code = f[p]
        switch code {
        case UInt8(ascii: "c"):
            out += Array((alt ? "%A, %B %d, %Y %H:%M:%S" : "%m/%d/%y %H:%M:%S").utf8)
        case UInt8(ascii: "x"):
            out += Array((alt ? "%A, %B %d, %Y" : "%m/%d/%y").utf8)
        case UInt8(ascii: "X"):
            out += Array("%H:%M:%S".utf8)
        case UInt8(ascii: "d"), UInt8(ascii: "H"), UInt8(ascii: "I"), UInt8(ascii: "j"), UInt8(ascii: "m"),
             UInt8(ascii: "M"), UInt8(ascii: "S"), UInt8(ascii: "U"), UInt8(ascii: "w"), UInt8(ascii: "W"),
             UInt8(ascii: "y"), UInt8(ascii: "Y"):
            // %#d などは先頭の 0 を取る
            out += alt ? [chPercent, 0x2D, code] : [chPercent, code]
        default:
            out += [chPercent, code]
        }
        i = p + 1
    }
    return out
}

// MARK: sprintf

/// "%" と変換文字の間が正しいか。ttl.cpp と同じく鬼車 (ASCII, Ruby 文法) で調べる。
/// 合えば (幅が *, 精度が *)。nil = 合わない。正規表現が作れないときは .error
private enum PrintfSpec { case ok(Bool, Bool), bad, error }
private func checkPrintfSpec(_ s: [UInt8]) -> PrintfSpec {
    let pattern = Array("^%[-+0 #]*([1-9][0-9]*|\\*)?(?:\\.([0-9]*|\\*))?$".utf8)
    switch TTLRegex.search(pattern, in: s, option: 0,
                           encoding: teramac_onig_encoding("ASCII"), syntax: teramac_onig_syntax("DEFAULT")) {
    case .error: return .error
    case .noMatch: return .bad
    case .match(let m):
        if m.position != 0 { return .bad }        // r != 0
        if m.groups.count != 3 { return .error }  // region->num_regs != 3
        func isStar(_ r: Range<Int>?) -> Bool { r.map { Array(s[$0]) == [0x2A] } ?? false }
        return .ok(isStar(m.groups[1]), isStar(m.groups[2]))
    }
}

/// _snprintf_s(buf, MaxStrLen, _TRUNCATE, fmt, ...) の結果 (最初の NUL まで)
private func cFormat(_ fmt: [UInt8], _ args: [CVarArg]) -> [UInt8] {
    var buf = [CChar](repeating: 0, count: MaxStrLen)
    let f = fmt.map { CChar(bitPattern: $0) } + [0]
    f.withUnsafeBufferPointer { fp in
        withVaList(args) { va in
            _ = vsnprintf(&buf, MaxStrLen, fp.baseAddress!, va)
        }
    }
    return cStr(buf.map { UInt8(bitPattern: $0) })
}

// MARK: UCRT の浮動小数点出力 (%a/%A と inf/nan の綴り)

/// MSVC (UCRT) の atof。"nan(ind)" と "nan(snan)" だけ UCRT の値にして、ほかは atof
private func ucrtAtof(_ s: [UInt8]) -> Double {
    var p = 0
    while p < s.count, cIsSpace(s[p]) { p += 1 }
    var neg = false
    if p < s.count, s[p] == 0x2B || s[p] == 0x2D { neg = s[p] == 0x2D; p += 1 }
    let c = cStr(s)
    let rest = asciiLower(Array(c[min(p, c.count)...]))
    if rest.starts(with: Array("nan(ind)".utf8)) {
        // 不定値 (符号ビット付きの quiet NaN)。"-" が付くと符号が消える
        let v = Double(bitPattern: 0xFFF8_0000_0000_0000)
        return neg ? -v : v
    }
    if rest.starts(with: Array("nan(snan)".utf8)) {
        let v = Double(bitPattern: 0x7FF4_0000_0000_0000)
        return neg ? -v : v
    }
    let cs = s.map { CChar(bitPattern: $0) } + [0]
    return atof(cs)
}

/// "%..." (変換文字まで) の書式を UCRT と同じに整える。
/// %a/%A と、inf/nan は自前。それ以外 (有限の e/f/g) は nil を返して vsnprintf に任せる
private func ucrtFormatDouble(_ spec: [UInt8], _ stars: [Int32], _ v: Double) -> [UInt8]? {
    guard let conv = spec.last else { return nil }
    let upper = conv == UInt8(ascii: "A") || conv == UInt8(ascii: "E")
        || conv == UInt8(ascii: "G") || conv == UInt8(ascii: "F")
    let isA = conv == UInt8(ascii: "a") || conv == UInt8(ascii: "A")
    if v.isFinite && !isA { return nil }

    // 書式を読む
    var minus = false, plus = false, space = false, zero = false, alt = false
    var width = 0
    var prec: Int? = nil
    var i = 1
    var starIdx = 0
    while i < spec.count - 1 {
        switch spec[i] {
        case 0x2D: minus = true
        case 0x2B: plus = true
        case 0x20: space = true
        case 0x30: zero = true
        case 0x23: alt = true
        default: break
        }
        if [0x2D, 0x2B, 0x20, 0x30, 0x23].contains(spec[i]) { i += 1 } else { break }
    }
    if i < spec.count - 1, spec[i] == 0x2A {
        let w = starIdx < stars.count ? Int(stars[starIdx]) : 0
        starIdx += 1; i += 1
        if w < 0 { minus = true; width = -w } else { width = w }
    } else {
        while i < spec.count - 1, cIsDigit(spec[i]) { width = width * 10 + Int(spec[i] - 0x30); i += 1 }
    }
    if i < spec.count - 1, spec[i] == 0x2E {
        i += 1
        if i < spec.count - 1, spec[i] == 0x2A {
            let pv = starIdx < stars.count ? Int(stars[starIdx]) : 0
            starIdx += 1; i += 1
            prec = pv < 0 ? nil : pv
        } else {
            var pv = 0
            while i < spec.count - 1, cIsDigit(spec[i]) { pv = pv * 10 + Int(spec[i] - 0x30); i += 1 }
            prec = pv
        }
    }

    let bits = v.bitPattern
    let negative = (bits >> 63) != 0
    let sign: [UInt8] = negative ? [0x2D] : (plus ? [0x2B] : (space ? [0x20] : []))
    var prefix: [UInt8] = []   // "0x" (ゼロ埋めはこの後ろ)
    var body: [UInt8]
    var zeroPad = zero && !minus

    if !v.isFinite {
        zeroPad = false
        if v.isInfinite {
            body = Array("inf".utf8)
        } else {
            let mant = bits & 0x000F_FFFF_FFFF_FFFF
            let quiet = (mant & 0x0008_0000_0000_0000) != 0
            if !quiet {
                body = Array("nan(snan)".utf8)
            } else if negative && mant == 0x0008_0000_0000_0000 {
                body = Array("nan(ind)".utf8)
            } else {
                body = Array("nan".utf8)
            }
        }
        if upper { body = body.map { ($0 >= 0x61 && $0 <= 0x7A) ? $0 - 0x20 : $0 } }
    } else {
        // %a: 0xh.hhhhhhhhhhhhhp±d (既定は 13 桁、末尾の 0 も出す)
        let expBits = Int((bits >> 52) & 0x7FF)
        var mant = bits & 0x000F_FFFF_FFFF_FFFF
        var lead: UInt64
        var exp: Int
        if expBits == 0 {
            lead = 0
            exp = mant == 0 ? 0 : -1022
        } else {
            lead = 1
            exp = expBits - 1023
        }
        let digits = prec ?? 13
        if digits < 13 {
            // 落とす桁を四捨五入 (半分以上で切り上げ)
            let drop = UInt64(4 * (13 - digits))
            let half: UInt64 = 1 << (drop - 1)
            let rest = mant & ((1 << drop) - 1)
            mant >>= drop
            if rest >= half {
                mant += 1
                if mant >> UInt64(4 * digits) != 0 {   // 先頭の桁まで繰り上がった
                    mant &= (1 << UInt64(4 * digits)) - 1
                    lead += 1
                }
            }
        }
        let hexd = Array((upper ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
        prefix = Array((upper ? "0X" : "0x").utf8)
        body = [hexd[Int(lead)]]
        if digits > 0 || alt { body.append(0x2E) }
        let shown = min(digits, 13)
        for k in stride(from: shown - 1, through: 0, by: -1) {
            body.append(hexd[Int((mant >> UInt64(4 * k)) & 0xF)])
        }
        if digits > 13 { body += [UInt8](repeating: 0x30, count: digits - 13) }
        body.append(upper ? UInt8(ascii: "P") : UInt8(ascii: "p"))
        body.append(exp < 0 ? 0x2D : 0x2B)
        body += Array(String(abs(exp)).utf8)
    }

    var out: [UInt8]
    let len = sign.count + prefix.count + body.count
    if width > len {
        let pad = width - len
        if minus {
            out = sign + prefix + body + [UInt8](repeating: 0x20, count: pad)
        } else if zeroPad {
            out = sign + prefix + [UInt8](repeating: 0x30, count: pad) + body
        } else {
            out = [UInt8](repeating: 0x20, count: pad) + sign + prefix + body
        }
    } else {
        out = sign + prefix + body
    }
    return ttlTrunc(out)
}

// MARK: exec で起動したものを終わるまで持っておく

#if os(macOS)
private final class ExecKeeper {
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]
    func keep(_ p: Process) {
        lock.lock(); running[ObjectIdentifier(p)] = p; lock.unlock()
    }
    func drop(_ p: Process) {
        lock.lock(); running[ObjectIdentifier(p)] = nil; lock.unlock()
    }
}
private let execKeeper = ExecKeeper()
#endif

// MARK: 環境変数 (Windows と同じく名前の大文字小文字は区別しない)

private func envLookupName(_ name: String) -> String? {
    if name.isEmpty { return nil }
    if getenv(name) != nil { return name }
    let l = name.lowercased()
    return ProcessInfo.processInfo.environment.keys.first { $0.lowercased() == l }
}
private func envGet(_ name: String) -> String? {
    guard let n = envLookupName(name), let v = getenv(n) else { return nil }
    return String(cString: v)
}

/// ExpandEnvironmentStrings (RtlExpandEnvironmentStrings_U と同じ手順)。
/// '%' から次の '%' までを名前として引き、あれば値に置き換えて閉じ '%' の後ろから続ける。
/// 無い名前 (空の名前、閉じ '%' が無いときも) は開き '%' 1 文字だけを写して、その直後から続ける。
/// よって '%UNDEF%HOME%' は '%UNDEF' + HOME の値。$VAR などは展開しない
private func expandEnvironmentStrings(_ s: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    while i < s.count {
        if s[i] == chPercent, let close = s[(i + 1)...].firstIndex(of: chPercent),
           let v = envGet(Array(s[(i + 1)..<close]).u8) {
            out += v.ttl
            i = close + 1
        } else {
            out.append(s[i])
            i += 1
        }
    }
    return out
}

// MARK: - コマンド

extension TTLInterpreter {

    func cmdCode2Str() -> Int {
        var err = 0
        let id = getStrVar(&err)
        var num: Int32 = 0
        getIntVal(&num, &err)
        endOfLine(&err)
        if err != 0 { return err }
        var str: [UInt8] = []
        for c in 0..<4 {
            let d = UInt8(truncatingIfNeeded: num >> ((3 - c) * 8))
            if !str.isEmpty || d != 0 { str.append(d) }
        }
        setStrVal(id, str)
        return err
    }

    func cmdStr2Code() -> Int {
        var err = 0
        let id = getIntVar(&err)
        let str = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        let len = str.count
        let c = min(len, 4)
        var num: UInt32 = 0
        var i = c
        while i >= 1 {
            num = num &* 256 &+ UInt32(str[len - i])
            i -= 1
        }
        setIntVal(id, Int32(bitPattern: num))
        return err
    }

    func cmdInt2Str() -> Int {
        var err = 0
        let id = getStrVar(&err)
        var num: Int32 = 0
        getIntVal(&num, &err)
        endOfLine(&err)
        if err != 0 { return err }
        setStrVal(id, String(num).ttl)
        return err
    }

    func cmdStr2Int() -> Int {
        var err = 0
        let id = getIntVar(&err)
        var str = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        // TTL では 16 進を $ で書くので 0x に直す
        if str.first == 0x24 { str = [0x30, 0x78] + str.dropFirst() }
        var num: Int32 = 0
        var p = 0
        let isHex = str.count >= 2 && str[0] == 0x30 && (str[1] | 0x20) == 0x78
        if let v = isHex ? scanHex(str, &p) : scanDecimal(str, &p) {
            num = v
            setResult(1)
        } else {
            num = 0
            setResult(0)
        }
        setIntVal(id, num)
        return err
    }

    func cmdStrCompare() -> Int {
        var err = 0
        let s1 = getStrVal(&err)
        let s2 = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        // strcmp は unsigned char で比べる
        let r: Int
        if s1 == s2 { r = 0 } else { r = s1.lexicographicallyPrecedes(s2) ? -1 : 1 }
        setResult(r)
        return err
    }

    func cmdStrConcat() -> Int {
        var err = 0
        let id = getStrVar(&err)
        let str = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        var dest = ttlTrunc(strVarPtr(id))
        strCat(&dest, str)
        setStrVal(id, dest)
        return err
    }

    func cmdStrCopy() -> Int {
        var err = 0
        let str = getStrVal(&err)
        var from: Int32 = 0, len: Int32 = 0
        getIntVal(&from, &err)
        getIntVal(&len, &err)
        let id = getStrVar(&err)
        endOfLine(&err)
        if err != 0 { return err }
        var f = Int(from), l = Int(len)
        if f < 1 { f = 1 }
        let srcLen = str.count - f + 1
        if l > srcLen { l = srcLen }
        if l < 0 { l = 0 }
        setStrVal(id, l == 0 ? [] : Array(str[(f - 1)..<(f - 1 + l)]))
        return err
    }

    func cmdStrInsert() -> Int {
        var err = 0
        let id = getStrVar(&err)
        var index: Int32 = 0
        getIntVal(&index, &err)
        let str = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        var dest = ttlTrunc(strVarPtr(id))
        let srcLen = dest.count
        if index <= 0 || Int(index) > srcLen + 1 { err = E.syntax }
        if srcLen + str.count + 1 > MaxStrLen { err = E.syntax }
        if err != 0 { return err }
        dest.insert(contentsOf: str, at: Int(index) - 1)
        setStrVal(id, dest)
        return err
    }

    func cmdStrJoin() -> Int {
        var err = 0
        let id = getStrVar(&err)
        let delim = getStrVal(&err)
        var maxvar: Int32 = 9
        if checkParameterGiven() { getIntVal(&maxvar, &err) }
        endOfLine(&err)
        if err != 0 { return err }
        if maxvar < 1 || maxvar > 9 { return E.syntax }
        var dest: [UInt8] = []
        for i in 0..<Int(maxvar) {
            if let (t, vid) = checkVar("groupmatchstr\(i + 1)") {
                if t != .string { return E.syntax }
                strCat(&dest, strVarPtr(vid))
                if i < Int(maxvar) - 1 { strCat(&dest, delim) }
            }
        }
        setStrVal(id, dest)
        return err
    }

    func cmdStrLen() -> Int {
        var err = 0
        let str = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        setResult(str.count)
        return err
    }

    func cmdStrMatch() -> Int {
        var err = 0
        let target = getStrVal(&err)
        let pattern = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        let ret = findRegexStringOne(pattern, target)
        setResult(ret > 0 ? ret : 0)
        return err
    }

    func cmdStrRemove() -> Int {
        var err = 0
        let id = getStrVar(&err)
        var index: Int32 = 0, len: Int32 = 0
        getIntVal(&index, &err)
        getIntVal(&len, &err)
        endOfLine(&err)
        if err != 0 { return err }
        var dest = ttlTrunc(strVarPtr(id))
        let srcLen = dest.count
        if len <= 0 || index <= 0 || Int(index) - 1 + Int(len) > srcLen { return E.syntax }
        dest.removeSubrange((Int(index) - 1)..<(Int(index) - 1 + Int(len)))
        setStrVal(id, dest)
        return err
    }

    func cmdStrReplace() -> Int {
        var err = 0
        let id = getStrVar(&err)
        var pos32: Int32 = 0
        getIntVal(&pos32, &err)
        let oldStr = getStrVal(&err)
        let newStr = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }

        let src = strVarPtr(id)
        var pos = Int(pos32)
        if pos > src.count || pos <= 0 { setResult(0); return err }
        pos -= 1
        let tmp = ttlTrunc(src)
        guard pos < tmp.count else { setResult(0); return err }
        // pos 文字目以降で oldstr (正規表現) を探す
        var ret = findRegexStringOne(oldStr, Array(tmp[pos...]))
        if ret == 0 { setResult(0); return err }
        if ret < 0 { setResult(-1); return err }
        ret -= 1
        guard let (t, mid) = checkVar("matchstr"), t == .string else { setResult(0); return err }
        let matchLen = strVarPtr(mid).count
        var dest = Array(tmp[0..<min(tmp.count, pos + ret)])
        strCat(&dest, newStr)
        let restStart = pos + ret + matchLen
        if restStart < tmp.count { strCat(&dest, Array(tmp[restStart...])) }
        setStrVal(id, dest)
        setResult(1)
        return err
    }

    func cmdStrScan() -> Int {
        var err = 0
        let s1 = getStrVal(&err)
        let s2 = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if s1.isEmpty || s2.isEmpty { setResult(0); return err }
        var found = 0
        if s2.count <= s1.count {
            for i in 0...(s1.count - s2.count) where s1[i] == s2[0] {
                if Array(s1[i..<(i + s2.count)]) == s2 { found = i + 1; break }
            }
        }
        setResult(found)
        return err
    }

    func cmdStrSpecial() -> Int {
        var err = 0
        let id = getStrVar(&err)
        if err != 0 { return err }
        if checkParameterGiven() {
            let src = getStrVal(&err)
            endOfLine(&err)
            if err != 0 { return err }
            setStrVal(id, restoreNewLineC(src))
        } else {
            setStrVal(id, restoreNewLineC(ttlTrunc(strVarPtr(id))))
        }
        return err
    }

    func cmdStrSplit() -> Int {
        let maxVarNum = 9
        var err = 0
        let src = getStrVal(&err)
        let delim = getStrVal(&err)
        var maxvar: Int32 = 9
        var omit = false
        if checkParameterGiven() {
            getIntVal(&maxvar, &err)
        } else {
            maxvar = 9
            omit = true
        }
        endOfLine(&err)
        if err != 0 { return err }
        if maxvar < 1 || Int(maxvar) > maxVarNum { return E.syntax }
        // 区切りは 1 バイトだけ
        if delim.count != 1 { return E.syntax }
        let d = delim[0]

        var count = 1
        var tokStart = [0]
        var cuts: [Int] = []      // NUL にした位置
        var i = 0
        // 省略時は余りを捨てるために 1 つ余分に進める
        while i < src.count && count < Int(maxvar) + (omit ? 1 : 0) {
            if src[i] == d {
                cuts.append(i)
                count += 1
                if count <= maxVarNum { tokStart.append(i + 1) }
            }
            i += 1
        }
        for k in 1...count where k <= maxVarNum {
            let s = tokStart[k - 1]
            let e = k - 1 < cuts.count ? cuts[k - 1] : src.count
            setGroupMatchStr(k, Array(src[s..<e]))
        }
        if count < maxVarNum {
            for k in (count + 1)...maxVarNum { setGroupMatchStr(k, []) }
        }
        setResult(count)
        return err
    }

    func cmdStrTrim() -> Int {
        var err = 0
        let id = getStrVar(&err)
        let trimChars = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        let src = ttlTrunc(strVarPtr(id))
        // 消す文字の表 (バイト単位)
        var table = [Bool](repeating: false, count: 256)
        for b in trimChars { table[Int(b)] = true }
        var start = 0
        while start < src.count, table[Int(src[start])] { start += 1 }
        var end = src.count - 1
        while end >= 0, table[Int(src[end])] { end -= 1 }
        setStrVal(id, start <= end ? Array(src[start...end]) : [])
        return err
    }

    func cmdToLower() -> Int {
        var err = 0
        let id = getStrVar(&err)
        let str = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        setStrVal(id, str.map { ($0 >= 0x41 && $0 <= 0x5A) ? $0 + 0x20 : $0 })
        return err
    }

    func cmdToUpper() -> Int {
        var err = 0
        let id = getStrVar(&err)
        let str = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        setStrVal(id, str.map { ($0 >= 0x61 && $0 <= 0x7A) ? $0 - 0x20 : $0 })
        return err
    }

    // MARK: 日付・時刻

    /// setdate / settime の引数を sscanf("%u") で読む
    private func scanDateField(_ s: [UInt8], _ from: Int, _ cut: Int) -> Bool {
        // Str[cut] = 0 してから &Str[from] を読む
        guard from < s.count else { return false }
        var piece = Array(s[from..<min(s.count, cut)])
        piece = cStr(piece)
        var p = 0
        return scanDecimal(piece, &p) != nil
    }

    func cmdSetDate() -> Int {
        var err = 0
        let str = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if !scanDateField(str, 0, 4) { return 0 }
        if !scanDateField(str, 5, 7) { return 0 }
        if !scanDateField(str, 8, 10) { return 0 }
        // SetLocalTime にあたる。アプリから Mac の時計は変えられない。
        // 元も SetLocalTime の失敗は無視していて result は変えない
        return err
    }

    func cmdSetTime() -> Int {
        var err = 0
        let str = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if !scanDateField(str, 0, 2) { return 0 }
        if !scanDateField(str, 3, 5) { return 0 }
        if !scanDateField(str, 6, 8) { return 0 }
        return err
    }

    func cmdGetTime(_ w: Rsv) -> Int {
        var err = 0
        let id = getStrVar(&err)
        var format: [UInt8]
        var setRes = false
        var tz: [UInt8]?
        if checkParameterGiven() {
            format = getStrVal(&err)
            if isInvalidStrftimeChar(format) {
                setResult(2)
                return 0
            }
            setRes = true
            if checkParameterGiven() {
                let t = getStrVal(&err)
                if err != 0 { return err }
                tz = t
            }
        } else {
            format = Array((w == .getTime ? "%H:%M:%S" : "%Y-%m-%d").utf8)
        }
        endOfLine(&err)
        if err != 0 { return err }

        // タイムゾーンの指定があれば localtime に効かせる
        let savedTZ = getenv("TZ").map { String(cString: $0) }
        if let tz = tz {
            if tz.isEmpty { unsetenv("TZ") } else { setenv("TZ", tz.u8, 1) }
            tzset()
        }
        defer {
            if tz != nil {
                if let s = savedTZ, !s.isEmpty { setenv("TZ", s, 1) } else { unsetenv("TZ") }
                tzset()
            }
        }

        var t = time(nil)
        var tmv = tm()
        localtime_r(&t, &tmv)
        let f = msvcStrftimeToDarwin(format).map { CChar(bitPattern: $0) } + [0]
        var out = [CChar](repeating: 0, count: MaxStrLen)
        let n = strftime_l(&out, MaxStrLen, f, &tmv, nil)
        if n > 0 {
            setStrVal(id, Array(out[0..<n]).map { UInt8(bitPattern: $0) })
            if setRes { setResult(0) }
        } else {
            if setRes { setResult(1) }
        }
        return err
    }

    // MARK: 環境変数

    func cmdGetEnv() -> Int {
        var err = 0
        let name = getStrVal(&err)
        let id = getStrVar(&err)
        endOfLine(&err)
        if err != 0 { return err }
        setStrVal(id, envGet(name.u8)?.ttl ?? [])
        return err
    }

    func cmdSetEnv() -> Int {
        var err = 0
        let name = getStrVal(&err)
        let value = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        // _wputenv_s: 名前が空や '=' を含むときは失敗 (何もしない)。値が空なら消す
        let n = name.u8
        if n.isEmpty || name.contains(0x3D) { return err }
        let key = envLookupName(n) ?? n
        if value.isEmpty { unsetenv(key) } else { setenv(key, value.u8, 1) }
        return err
    }

    func cmdExpandEnv() -> Int {
        var err = 0
        let id = getStrVar(&err)
        if err != 0 { return err }
        if checkParameterGiven() {
            let src = getStrVal(&err)
            endOfLine(&err)
            if err != 0 { return err }
            setStrVal(id, expandEnvironmentStrings(src))
        } else {
            setStrVal(id, expandEnvironmentStrings(strVarPtr(id)))
        }
        return err
    }

    // MARK: その他

    /// tt-version.h の TT_VERSION_MAJOR / TT_VERSION_MINOR (移植元のソースの値)
    static let ttVersionMajor: Int32 = 5
    static let ttVersionMinor: Int32 = 8

    func cmdGetVer() -> Int {
        var err = 0
        let id = getStrVar(&err)
        var compare = false
        var compMajor: Int32 = 0, compMinor: Int32 = 0
        if checkParameterGiven() {
            let s = getStrVal(&err)
            // sscanf(Str1, "%d.%d", ...) != 2 なら -2
            var p = 0
            var ok = false
            if let a = scanDecimal(s, &p), p < s.count, s[p] == 0x2E {
                p += 1
                if let b = scanDecimal(s, &p) { compMajor = a; compMinor = b; ok = true }
            }
            if !ok {
                setResult(-2)
                return 0
            }
            compare = true
        }
        endOfLine(&err)
        if err != 0 { return err }
        let maj = TTLInterpreter.ttVersionMajor, min = TTLInterpreter.ttVersionMinor
        setStrVal(id, "\(maj).\(min)".ttl)
        if compare {
            let cur = maj &* 10000 &+ min
            let comp = compMajor &* 10000 &+ compMinor
            setResult(cur < comp ? -1 : (cur == comp ? 0 : 1))
        }
        return err
    }

    func cmdGetIPv4Addr() -> Int {
        var err = 0
        let aid = getAryVar(.strArray, &err)
        let nid = getIntVar(&err)
        endOfLine(&err)
        if err != 0 { return err }

        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else {
            setResult(-1)
            setIntVal(nid, 0)
            return err
        }
        defer { freeifaddrs(ifap) }
        let arySize = vars[aid].strAry.count
        var num = 0
        var result = 1
        var p = ifap
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            if flags & IFF_UP == 0 { continue }
            if flags & IFF_LOOPBACK != 0 { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            if num < arySize {
                var e = 0
                let id = getStrVarFromArray(aid, num, &e)
                setStrVal(id, String(cString: buf).ttl)
            } else {
                result = 0
            }
            num += 1
        }
        setResult(result)
        setIntVal(nid, Int32(truncatingIfNeeded: num))
        return err
    }

    func cmdGetIPv6Addr() -> Int {
        var err = 0
        let aid = getAryVar(.strArray, &err)
        let nid = getIntVar(&err)
        endOfLine(&err)
        if err != 0 { return err }

        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else {
            setResult(-1)
            setIntVal(nid, 0)
            return err
        }
        defer { freeifaddrs(ifap) }
        let arySize = vars[aid].strAry.count
        var num = 0
        var result = 1
        var p = ifap
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            if flags & IFF_UP == 0 { continue }
            if flags & IFF_LOOPBACK != 0 { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            let bytes: [UInt8] = withUnsafeBytes(of: a) { Array($0) }
            // DNS に載せられるもの (= リンクローカル fe80::/10 以外) だけ
            if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { continue }
            // myInetNtop: 省略しない形 (xxxx:xxxx:...)
            var s = ""
            for i in 0..<16 {
                s += String(format: "%02x", bytes[i])
                if i != 15 && (i & 1) == 1 { s += ":" }
            }
            if num < arySize {
                var e = 0
                let id = getStrVarFromArray(aid, num, &e)
                setStrVal(id, s.ttl)
            } else {
                result = 0
            }
            num += 1
        }
        setResult(result)
        setIntVal(nid, Int32(truncatingIfNeeded: num))
        return err
    }

    func cmdRandom() -> Int {
        var err = 0
        let id = getIntVar(&err)
        var maxNum: Int32 = 0
        getIntVal(&maxNum, &err)
        if (err == 0 && getFirstChar() != 0) || maxNum <= 0 { err = E.syntax }
        if err != 0 { return err }
        let m = UInt32(bitPattern: maxNum &+ 1)
        // 2**32 % x == (2**32 - x) % x
        let randMin = (0 &- m) % m
        var g = SystemRandomNumberGenerator()
        var num: UInt32
        repeat { num = g.next() } while num < randMin
        setIntVal(id, Int32(bitPattern: num % m))
        return err
    }

    func cmdRotate(left: Bool) -> Int {
        var err = 0
        let id = getIntVar(&err)
        var x: Int32 = 0, n: Int32 = 0
        getIntVal(&x, &err)
        getIntVal(&n, &err)
        endOfLine(&err)
        if err != 0 { return err }
        if !left { n = 0 &- n }
        n %= 32
        if n < 0 { n += 32 }
        if n == 0 {
            setIntVal(id, x)
        } else {
            let u = UInt32(bitPattern: x)
            setIntVal(id, Int32(bitPattern: (u << UInt32(n)) | (u >> UInt32(32 - n))))
        }
        return err
    }

    func cmdUptime() -> Int {
        var err = 0
        let id = getIntVar(&err)
        endOfLine(&err)
        if err != 0 { return err }
        // GetTickCount: 起動してからのミリ秒 (スリープ中も進む)。32bit で折り返す
        let ms = clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000
        setIntVal(id, Int32(bitPattern: UInt32(truncatingIfNeeded: ms)))
        return err
    }

    /// Windows の特殊フォルダ名 → いちばん近い Mac のフォルダ
    static func specialFolder(_ type: [UInt8]) -> String? {
        let home = NSHomeDirectory()
        func h(_ s: String) -> String { (home as NSString).appendingPathComponent(s) }
        switch String(decoding: asciiLower(type), as: UTF8.self) {
        case "allusersdesktop": return "/Users/Shared"
        case "allusersstartmenu", "allusersprograms": return "/Applications"
        case "allusersstartup": return "/Library/LaunchAgents"
        case "desktop": return h("Desktop")
        case "favorites": return home
        case "fonts": return "/Library/Fonts"
        case "mydocuments": return h("Documents")
        case "nethood", "printhood", "recent", "sendto", "templates": return home
        case "programs", "startmenu": return h("Applications")
        case "startup": return h("Library/LaunchAgents")
        default: return nil
        }
    }

    func cmdGetSpecialFolder() -> Int {
        var err = 0
        let id = getStrVar(&err)
        if err != 0 { return err }
        let type = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if let f = TTLInterpreter.specialFolder(type) {
            setStrVal(id, ttlTrunc(f.ttl))
            setResult(1)
        } else {
            setStrVal(id, [])
            setResult(0)
        }
        return err
    }

    func cmdGetTTDir() -> Int {
        var err = 0
        let id = getStrVar(&err)
        endOfLine(&err)
        if err != 0 { return err }
        guard let dir = host?.ttlAppDirectory() else {
            setStrVal(id, [])
            setResult(0)
            return err
        }
        setStrVal(id, dir.ttl)
        setResult(1)
        return err
    }

    func cmdExec() -> Int {
        var err = 0
        let cmd = getStrVal(&err)
        var wait: Int32 = 0
        var dir: [UInt8] = []
        if checkParameterGiven() {
            let mode = getStrVal(&err)
            if err != 0 { return err }
            switch String(decoding: asciiLower(mode), as: UTF8.self) {
            case "hide", "minimize", "maximize", "show": break   // Mac では使わない
            default: err = E.syntax
            }
            if checkParameterGiven() {
                getIntVal(&wait, &err)
                if err != 0 { return err }
                if checkParameterGiven() {
                    dir = getStrVal(&err)
                    if err != 0 { return err }
                }
            }
        }
        if err == 0 && (cmd.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }

        #if !os(macOS)
        // iPhone / iPad ではほかのプログラムを起動できない (CreateProcess が失敗したのと同じ)
        setResult(-1)
        return err
        #else
        // コマンド行は Mac らしく /bin/sh -c で動かす。
        // 作業フォルダの既定は (CreateProcess に NULL を渡すのと同じく) マクロを始めたときのフォルダ。
        // setdir / changedir では変わらない。4 番目の引数の相対パスも同じフォルダ基準
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd.u8]
        p.standardInput = FileHandle.nullDevice
        let d = dir.isEmpty ? initialDir : initialDirPath(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue else {
            setResult(-1)   // CreateProcess が失敗する (フォルダが無い)
            return err
        }
        p.currentDirectoryURL = URL(fileURLWithPath: d)
        p.terminationHandler = { execKeeper.drop($0) }
        execKeeper.keep(p)
        do {
            try p.run()
        } catch {
            execKeeper.drop(p)
            setResult(-1)
            return err
        }
        // sh が 126 (実行できない) / 127 (見つからない) で終わったら、起動できなかったとみなして -1
        func notStarted() -> Bool {
            !p.isRunning && p.terminationReason == .exit
                && (p.terminationStatus == 126 || p.terminationStatus == 127)
        }
        if wait != 0 {
            while p.isRunning {
                if cancelled { return err }
                usleep(10_000)
            }
            setResult(notStarted() ? -1 : Int(p.terminationStatus))
        } else {
            // 待たないときも、見つからないなどはすぐ分かるので少しだけ様子を見る
            var waited = 0
            while p.isRunning && waited < 200 && !cancelled {
                usleep(10_000)
                waited += 10
            }
            setResult(notStarted() ? -1 : 0)
        }
        return err
        #endif
    }

    func cmdSetExitCode() -> Int {
        var err = 0
        var v: Int32 = 0
        getIntVal(&v, &err)
        endOfLine(&err)
        if err != 0 { return err }
        exitCode = Int(v)
        return err
    }

    // MARK: sprintf / sprintf2

    func cmdSprintf(_ getvar: Bool) -> Int {
        enum ArgType { case integer, double, string, none }
        var err = 0
        var varId = 0
        if getvar {
            varId = getStrVar(&err)
            if err != 0 { setResult(4); return err }
        }
        let fmt = getStrVal(&err)
        if err != 0 { setResult(1); return err }

        var buf: [UInt8] = []
        var sub: [UInt8] = []
        let limit = MaxStrLen - 1
        var p = 0
        while p < fmt.count {
            let c = fmt[p]
            if !sub.isEmpty {
                var type = ArgType.none
                switch c {
                case chPercent:
                    if sub.count == 1 {          // "%%" -> "%"
                        strCat(&buf, [chPercent])
                        sub = []
                    } else {
                        strCat(&buf, sub)        // 手前までそのまま
                        sub = [c]
                    }
                case UInt8(ascii: "c"), UInt8(ascii: "d"), UInt8(ascii: "i"), UInt8(ascii: "o"),
                     UInt8(ascii: "u"), UInt8(ascii: "x"), UInt8(ascii: "X"),
                     UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "f"), UInt8(ascii: "g"),
                     UInt8(ascii: "G"), UInt8(ascii: "a"), UInt8(ascii: "A"), UInt8(ascii: "s"):
                    switch c {
                    case UInt8(ascii: "s"): type = .string
                    case UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "f"), UInt8(ascii: "g"),
                         UInt8(ascii: "G"), UInt8(ascii: "a"), UInt8(ascii: "A"): type = .double
                    default: type = .integer
                    }
                    // "%" と変換文字の間が正しいか
                    let wStar: Bool, pStar: Bool
                    switch checkPrintfSpec(sub) {
                    case .ok(let w, let pr): wStar = w; pStar = pr
                    case .bad: setResult(2); return E.syntax
                    case .error: setResult(-1); return 0
                    }
                    if sub.count < limit { sub.append(c) }
                    var numWidth: Int32 = 0, numPrec: Int32 = 0
                    if wStar {
                        var te = 0
                        getIntVal(&numWidth, &te)
                        if te != 0 { setResult(3); return te }
                    }
                    if pStar {
                        var te = 0
                        getIntVal(&numPrec, &te)
                        if te != 0 { setResult(3); return te }
                    }
                    var stars: [CVarArg] = []
                    if wStar { stars.append(numWidth) }
                    if pStar { stars.append(numPrec) }
                    var out: [UInt8]
                    if type == .string || type == .double {
                        var te = 0
                        let s = getStrVal(&te)
                        if te != 0 { setResult(3); return te }
                        let cs = s.map { CChar(bitPattern: $0) } + [0]
                        if type == .string {
                            out = cs.withUnsafeBufferPointer { cFormat(sub, stars + [$0.baseAddress!]) }
                        } else {
                            let d = ucrtAtof(s)
                            var starVals: [Int32] = []
                            if wStar { starVals.append(numWidth) }
                            if pStar { starVals.append(numPrec) }
                            out = ucrtFormatDouble(sub, starVals, d) ?? cFormat(sub, stars + [d])
                        }
                    } else {
                        var te = 0
                        var num: Int32 = 0
                        getIntVal(&num, &te)
                        if te != 0 { setResult(3); return te }
                        out = cFormat(sub, stars + [num])
                    }
                    strCat(&buf, out)
                    sub = []
                default:
                    if sub.count < limit { sub.append(c) }
                }
            } else if c == chPercent {
                sub.append(c)
            } else if buf.count < limit {
                buf.append(c)
            } else {
                break
            }
            p += 1
        }
        if !sub.isEmpty { strCat(&buf, sub) }

        if getvar {
            setStrVal(varId, buf)
        } else {
            setInputStr(buf)
        }
        setResult(0)
        return err
    }
}
