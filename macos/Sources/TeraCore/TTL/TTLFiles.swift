// ファイル操作・パスワード関係のマクロコマンド。
// teraterm/ttpmacro の ttl.cpp (TTLFileOpen ほか) / ttl_gui.cpp (TTLGetPassword, TTLGetPassword2) /
// ttmenc.c (Encrypt/Decrypt) / ttmenc2.c (Encrypt2*) / ttmlib.c (GetAbsPath, TTMSetDir) を Swift に移したもの。
// 元のコード: Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project (BSD 3-Clause)
//
// Windows のファイル API を POSIX に置き換えている。
// - ファイルハンドル: fileHandles[0..15] (FHandle[] と同じ番号)。中身は open(2) の fd
// - filelock: flock(2) (排他、アドバイザリロック)
// - getfileattr / setfileattr: Windows の属性値 <-> POSIX (書き込み権 / UF_HIDDEN / ディレクトリ)
// - パスワードファイル: WritePrivateProfileString と同じ形式の INI (CRLF)

import Foundation
import CommonCrypto
import Security

// MARK: - 追加の状態 (インタプリタごと)

private final class TTLFileExtra {
    /// filelock 中のハンドル (同じハンドルで 2 回目の LockFile は失敗する Windows に合わせる)
    var locked = Array(repeating: false, count: 16)
}
private let fileExtraLock = NSLock()
private var fileExtras: [ObjectIdentifier: TTLFileExtra] = [:]

// MARK: - 小物

/// _stricmp (ASCII だけ大文字小文字を無視)
private func asciiCaseEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    if a.count != b.count { return false }
    for (x, y) in zip(a, b) {
        let lx = (x >= 0x41 && x <= 0x5A) ? x + 0x20 : x
        let ly = (y >= 0x41 && y <= 0x5A) ? y + 0x20 : y
        if lx != ly { return false }
    }
    return true
}

private func isSep(_ b: UInt8) -> Bool { b == 0x5C || b == 0x2F }

/// GetFileNamePosW (ttlib_static_cpp.cpp)。':' がドライブ以外にあれば nil
private func getFileNamePos(_ p: [UInt8]) -> (dirLen: Int, fnPos: Int)? {
    var ptr = 0
    if p.count >= 2 && p[1] == 0x3A { ptr = 2 }
    if ptr < p.count && isSep(p[ptr]) { ptr += 1 }
    var dirPtr = ptr, fnPtr = ptr
    while ptr < p.count {
        let b = p[ptr]
        let old = ptr
        ptr += 1
        if b == 0x3A { return nil }
        if isSep(b) { dirPtr = old; fnPtr = ptr }
    }
    return (dirPtr, fnPtr)
}

/// DeleteSlashW。Mac では '/' も区切りなので両方消す
private func deleteSlash(_ p: [UInt8]) -> [UInt8] {
    var s = p
    while let l = s.last, isSep(l) { s.removeLast() }
    return s
}

private func posixWrite(_ fd: Int32, _ bytes: [UInt8]) -> Int {
    if fd < 0 || bytes.isEmpty { return 0 }
    var done = 0
    while done < bytes.count {
        let n = bytes[done...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        done += n
    }
    return done
}

/// 1 バイトずつ読むのと同じ結果になるように、まとめて読んで最後にファイルポインタを合わせる
private struct FDReader {
    let fd: Int32
    let base: off_t
    var buf = [UInt8](repeating: 0, count: 4096)
    var len = 0, idx = 0
    var consumed: off_t = 0
    var valid: Bool
    init(_ fd: Int32) {
        self.fd = fd
        base = fd >= 0 ? lseek(fd, 0, SEEK_CUR) : -1
        valid = base >= 0
    }
    mutating func peek() -> UInt8? {
        if !valid { return nil }
        if idx >= len {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return nil }
            len = n
            idx = 0
        }
        return buf[idx]
    }
    mutating func next() -> UInt8? {
        guard let b = peek() else { return nil }
        idx += 1
        consumed += 1
        return b
    }
    func finish() { if valid { lseek(fd, base + consumed, SEEK_SET) } }
}

private let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

// MARK: - INI (GetPrivateProfileString / WritePrivateProfileString)

/// パスワードファイル (setpassword / getpassword) 用の INI。
/// Windows と同じく、書き換えるのは該当する行だけで、ほかの行・改行コードはそのまま残す。
/// 新しく書く行の改行は CRLF。
struct TTLProfileFile {
    enum Enc { case ansi, utf8, utf8BOM, utf16LE }
    var lines: [String] = []
    var eols: [String] = []
    var enc: Enc = .ansi

    init() {}

    /// ファイルを読む。なければ nil
    init?(path: String) {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        var b = [UInt8](d)
        var text: String
        if b.starts(with: [0xFF, 0xFE]) {
            enc = .utf16LE
            text = String(data: Data(b[2...]), encoding: .utf16LittleEndian) ?? ""
        } else if b.starts(with: [0xEF, 0xBB, 0xBF]) {
            enc = .utf8BOM
            b.removeFirst(3)
            text = String(decoding: b, as: UTF8.self)
        } else if b.allSatisfy({ $0 < 0x80 }) {
            enc = .ansi
            text = String(decoding: b, as: UTF8.self)
        } else if let s = String(data: d, encoding: .utf8) {
            enc = .utf8
            text = s
        } else {
            // BOM なしは Windows では ANSI (日本語版は CP932)
            enc = .ansi
            text = String(data: d, encoding: cp932) ?? String(decoding: b, as: UTF8.self)
        }
        // 行に分ける (CR, LF, CRLF)
        var it = Array(text.unicodeScalars)[...]
        var line = String.UnicodeScalarView()
        while let c = it.first {
            it = it.dropFirst()
            if c == "\r" {
                var eol = "\r"
                if it.first == "\n" { it = it.dropFirst(); eol = "\r\n" }
                lines.append(String(line)); eols.append(eol); line = String.UnicodeScalarView()
            } else if c == "\n" {
                lines.append(String(line)); eols.append("\n"); line = String.UnicodeScalarView()
            } else {
                line.append(c)
            }
        }
        if !line.isEmpty { lines.append(String(line)); eols.append("") }
    }

    private static func trim(_ s: Substring) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }

    private static func sectionName(_ line: String) -> String? {
        let t = trim(Substring(line))
        guard t.hasPrefix("[") else { return nil }
        var n = t.dropFirst()
        if let e = n.firstIndex(of: "]") { n = n[..<e] }
        return trim(n)
    }

    private static func keyOf(_ line: String) -> (String, String) {
        if let eq = line.firstIndex(of: "=") {
            return (trim(line[..<eq]), trim(line[line.index(after: eq)...]))
        }
        return (trim(Substring(line)), "")
    }

    /// 最初に見つかったセクションの範囲 (見出し行, 終わり)
    private func findSection(_ section: String) -> (Int, Int)? {
        var start: Int?
        for (i, l) in lines.enumerated() {
            if let n = TTLProfileFile.sectionName(l) {
                if start != nil { return (start!, i) }
                if n.caseInsensitiveCompare(section) == .orderedSame { start = i }
            }
        }
        if let s = start { return (s, lines.count) }
        return nil
    }

    private func findKey(_ sec: (Int, Int), _ key: String) -> Int? {
        for i in (sec.0 + 1)..<sec.1 {
            let t = TTLProfileFile.trim(Substring(lines[i]))
            if t.isEmpty { continue }
            if TTLProfileFile.keyOf(lines[i]).0.caseInsensitiveCompare(key) == .orderedSame { return i }
        }
        return nil
    }

    /// GetPrivateProfileString (前後の空白を除き、全体が引用符で囲まれていれば外す)
    func get(_ section: String, _ key: String) -> String? {
        guard let sec = findSection(section), let i = findKey(sec, key) else { return nil }
        var v = TTLProfileFile.keyOf(lines[i]).1
        if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    /// WritePrivateProfileString。key が nil ならセクションごと、value が nil ならキーを消す
    mutating func set(_ section: String, _ key: String?, _ value: String?) {
        guard let sec = findSection(section) else {
            guard let key = key, let value = value else { return }
            if let l = eols.indices.last, eols[l].isEmpty { eols[l] = "\r\n" }
            lines += ["[\(section)]", "\(key)=\(value)"]
            eols += ["\r\n", "\r\n"]
            return
        }
        guard let key = key else {
            lines.removeSubrange(sec.0..<sec.1)
            eols.removeSubrange(sec.0..<sec.1)
            return
        }
        if let i = findKey(sec, key) {
            if let value = value {
                lines[i] = "\(TTLProfileFile.keyOf(lines[i]).0)=\(value)"
            } else {
                lines.remove(at: i)
                eols.remove(at: i)
            }
            return
        }
        guard let value = value else { return }
        // セクションの最後の空でない行の後ろに足す
        var last = sec.0
        for i in (sec.0 + 1)..<sec.1 where !TTLProfileFile.trim(Substring(lines[i])).isEmpty { last = i }
        if eols[last].isEmpty { eols[last] = "\r\n" }
        lines.insert("\(key)=\(value)", at: last + 1)
        eols.insert("\r\n", at: last + 1)
    }

    var text: String {
        var s = ""
        for (l, e) in zip(lines, eols) { s += l; s += e }
        return s
    }

    func data() -> Data {
        let t = text
        switch enc {
        case .utf16LE:
            return Data([0xFF, 0xFE]) + (t.data(using: .utf16LittleEndian) ?? Data())
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(t.utf8)
        case .utf8:
            return Data(t.utf8)
        case .ansi:
            return t.data(using: cp932) ?? Data(t.utf8)
        }
    }

    /// 書く (同じファイルを上書き。属性などは残る)
    func write(_ path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        if fd < 0 { return false }
        defer { close(fd) }
        let d = [UInt8](data())
        return posixWrite(fd, d) == d.count
    }

    static func getString(_ path: String, _ section: String, _ key: String) -> String {
        TTLProfileFile(path: path)?.get(section, key) ?? ""
    }

    @discardableResult
    static func writeString(_ path: String, _ section: String, _ key: String?, _ value: String?) -> Bool {
        let existing = TTLProfileFile(path: path)
        if existing == nil && (key == nil || value == nil) { return true }
        var f = existing ?? TTLProfileFile()
        f.set(section, key, value)
        return f.write(path)
    }
}

// MARK: - ttmenc.c (setpassword / getpassword の暗号化)

/// MSVC の rand() (srand で決まる列)
struct TTLMSRand {
    var holdrand: UInt32
    init(_ seed: UInt32) { holdrand = seed }
    mutating func next() -> Int {
        holdrand = holdrand &* 214013 &+ 2531011
        return Int((holdrand >> 16) & 0x7fff)
    }
}

enum TTLPasswordCrypto {
    private static func encSeparate(_ s: [UInt8], _ i: inout Int, _ b: inout UInt8) -> Bool {
        let cptr = i / 8
        let c0 = cptr < s.count ? s[cptr] : 0
        if c0 == 0 { return false }
        let bptr = i % 8
        let c1 = cptr + 1 < s.count ? s[cptr + 1] : 0
        let d = (UInt32(c0) << 8) | UInt32(c1)
        b = UInt8((d >> UInt32(10 - bptr)) & 0x3f)
        i += 6
        return true
    }

    private static func nextB(_ b: inout UInt8) {
        if b < 0x30 { b = 0x30 } else if b < 0x40 { b = 0x40 } else if b < 0x50 { b = 0x50 }
        else if b < 0x60 { b = 0x60 } else if b < 0x70 { b = 0x70 } else { b = 0x21 }
    }

    private static func encCharacterize(_ c: UInt8, _ b: inout UInt8) -> UInt8 {
        var d = c &+ b
        if d > 0x7e { d = d &- 0x5e }
        nextB(&b)
        return d
    }

    /// Encrypt()。seed は srand(LOWORD(GetTickCount())) に渡す値
    static func encrypt(_ input: [UInt8], seed: UInt32) -> [UInt8] {
        if input.isEmpty || input[0] == 0 { return [] }
        var rnd = TTLMSRand(seed)
        var r = UInt8(rnd.next() & 0x3f)
        let r2 = (~r) & 0x3f
        var out: [UInt8] = [r]
        var i = 0
        var b: UInt8 = 0
        while encSeparate(input, &i, &b) {
            r = UInt8(rnd.next() & 0x3f)
            out.append((b &+ r) & 0x3f)
            out.append(r)
        }
        out.append(r2)
        b = 0x21
        for k in 0..<out.count { out[k] = encCharacterize(out[k], &b) }
        return out
    }

    /// 実際に使う種 (LOWORD(GetTickCount()))
    static func tickSeed() -> UInt32 {
        UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000)) & 0xFFFF
    }

    private static func decCharacter(_ c: UInt8, _ b: inout UInt8) -> UInt8 {
        var d: UInt8 = c < b ? (0x5e &+ c &- b) : (c &- b)
        d &= 0x3f
        nextB(&b)
        return d
    }

    /// Decrypt()
    static func decrypt(_ input: [UInt8]) -> [UInt8] {
        let j = input.count
        if j == 0 { return [] }
        var b: UInt8 = 0x21
        var temp = input.map { decCharacter($0, &b) }
        if (temp[0] ^ temp[j - 1]) != 0x3f { return [] }
        var out: [UInt8] = [0]
        var i = 1, k = 0
        while i < j - 2 {
            temp[i] = (temp[i] &- temp[i + 1]) & 0x3f
            // DecCombine
            let cptr = k / 8, bptr = k % 8
            while out.count < cptr + 2 { out.append(0) }
            if bptr == 0 { out[cptr] = 0 }
            let d = (UInt32(out[cptr]) << 8) | (UInt32(temp[i]) << UInt32(10 - bptr))
            out[cptr] = UInt8((d >> 8) & 0xff)
            out[cptr + 1] = UInt8(d & 0xff)
            k += 6
            i += 2
        }
        if let z = out.firstIndex(of: 0) { out.removeSubrange(z...) }
        return out
    }
}

// MARK: - ttmenc2.c (setpassword2 / getpassword2)

enum TTLEncrypt2 {
    static let saltLen = 16
    static let iter1 = 1001
    static let iter2 = 210001
    static let ikLen = 32
    static let ivLen = 16
    static let pwdMaxLen = 203
    static let profileLen = 381      // 2 + 16 + 64 + 16 + 203 + 16 + 64
    static let base64Len = 508
    static let maxLineLen = 512
    // 各部分の位置
    static let oKeySalt = 2, oKeyHash = 18, oPassSalt = 82, oPassStr = 98, oEncSalt = 301, oEncHash = 317

    static func pbkdf2(_ pass: [UInt8], _ salt: [UInt8], _ iter: Int, _ len: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: len)
        let r = pass.withUnsafeBufferPointer { p -> Int32 in
            p.baseAddress!.withMemoryRebound(to: Int8.self, capacity: max(p.count, 1)) { pp in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pp, p.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iter), &out, len)
            }
        }
        return r == 0 ? out : nil
    }

    static func hmac512(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA512), key, key.count, data, data.count, &out)
        return out
    }

    /// AES-256-CTR (OpenSSL と同じ 128bit ビッグエンディアンのカウンタ)
    static func aesCTR(_ key: [UInt8], _ iv: [UInt8], _ data: [UInt8]) -> [UInt8]? {
        var ref: CCCryptorRef?
        var st = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                         CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
                                         CCModeOptions(kCCModeOptionCTR_BE), &ref)
        guard st == kCCSuccess, let c = ref else { return nil }
        defer { CCCryptorRelease(c) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        st = CCCryptorUpdate(c, data, data.count, &out, out.count, &moved)
        return st == kCCSuccess && moved == data.count ? out : nil
    }

    static func randomBytes(_ n: Int) -> [UInt8]? {
        var b = [UInt8](repeating: 0, count: n)
        return SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess ? b : nil
    }

    private static let b64chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    static func b64encode(_ s: [UInt8]) -> [UInt8] {
        var d: [UInt8] = []
        var i = 0
        while i + 3 <= s.count {
            let b = (UInt32(s[i]) << 16) | (UInt32(s[i + 1]) << 8) | UInt32(s[i + 2])
            d += [b64chars[Int((b >> 18) & 0x3f)], b64chars[Int((b >> 12) & 0x3f)],
                  b64chars[Int((b >> 6) & 0x3f)], b64chars[Int(b & 0x3f)]]
            i += 3
        }
        let rest = s.count - i
        if rest == 1 {
            let b = UInt32(s[i])
            d += [b64chars[Int((b >> 2) & 0x3f)], b64chars[Int((b << 4) & 0x3f)], 0x3D, 0x3D]
        } else if rest == 2 {
            let b = (UInt32(s[i]) << 8) | UInt32(s[i + 1])
            d += [b64chars[Int((b >> 10) & 0x3f)], b64chars[Int((b >> 4) & 0x3f)], b64chars[Int((b << 2) & 0x3f)], 0x3D]
        }
        return d
    }

    private static func b64val(_ c: UInt8) -> UInt32? {
        switch c {
        case 0x41...0x5A: return UInt32(c - 0x41)
        case 0x61...0x7A: return UInt32(c - 0x61 + 26)
        case 0x30...0x39: return UInt32(c - 0x30 + 52)
        case 0x2B: return 62
        case 0x2F: return 63
        default: return nil
        }
    }

    /// b64decode (空白は飛ばし、それ以外の不正な文字で止まる)
    static func b64decode(_ src: [UInt8], max: Int) -> [UInt8] {
        var dst: [UInt8] = []
        var b: UInt32 = 0
        var state = 0
        for ch in src {
            if ch == 0x20 || (ch >= 0x09 && ch <= 0x0D) { continue }
            guard let c = b64val(ch) else { break }
            b = (b << 6) | c
            state += 1
            if state == 4 {
                for v in [(b >> 16) & 0xff, (b >> 8) & 0xff, b & 0xff] where dst.count < max { dst.append(UInt8(v)) }
                state = 0
                b = 0
                if dst.count >= max { return dst }
            }
        }
        if state == 2 {
            b <<= 4
            if dst.count < max { dst.append(UInt8((b >> 8) & 0xff)) }
        } else if state == 3 {
            b <<= 6
            if dst.count < max { dst.append(UInt8((b >> 16) & 0xff)) }
            if dst.count < max { dst.append(UInt8((b >> 8) & 0xff)) }
        }
        return dst
    }

    /// Encrypt2 のプロファイル (381 バイト) を作る。salt は省略すると乱数
    static func makeProfile(key: [UInt8], pass: [UInt8], encryptStr: [UInt8],
                            keySalt: [UInt8]? = nil, passSalt: [UInt8]? = nil, encSalt: [UInt8]? = nil) -> [UInt8]? {
        if pass.count > pwdMaxLen { return nil }
        guard let ks = keySalt ?? randomBytes(saltLen),
              let kh = pbkdf2(key, ks, iter1, Int(CC_SHA512_DIGEST_LENGTH)),
              let ps = passSalt ?? randomBytes(saltLen),
              let es = encSalt ?? randomBytes(saltLen),
              let keyIV = pbkdf2(encryptStr, ps, iter2, ikLen + ivLen) else { return nil }
        var p = [UInt8](repeating: 0, count: profileLen)
        p[0] = 0x00; p[1] = 0x02
        p.replaceSubrange(oKeySalt..<(oKeySalt + saltLen), with: ks)
        p.replaceSubrange(oKeyHash..<(oKeyHash + 64), with: kh)
        p.replaceSubrange(oPassSalt..<(oPassSalt + saltLen), with: ps)
        // 暗号化はひと続きの CTR: パスワード(203, NUL 詰め) → EncSalt(16) → HMAC(64)
        var plain = pass + [UInt8](repeating: 0, count: pwdMaxLen - pass.count)
        plain += es
        plain += [UInt8](repeating: 0, count: 64)
        guard let ct = aesCTR(Array(keyIV[0..<ikLen]), Array(keyIV[ikLen...]), plain) else { return nil }
        p.replaceSubrange(oPassStr..<(oPassStr + pwdMaxLen), with: ct[0..<pwdMaxLen])
        p.replaceSubrange(oEncSalt..<(oEncSalt + saltLen), with: ct[pwdMaxLen..<(pwdMaxLen + saltLen)])
        guard let hk = pbkdf2(encryptStr, Array(p[oEncSalt..<(oEncSalt + saltLen)]), iter1, 64) else { return nil }
        let hash = hmac512(hk, Array(p[0..<oEncHash]))
        let ksStream = ct[(pwdMaxLen + saltLen)...]
        p.replaceSubrange(oEncHash..<profileLen, with: zip(hash, ksStream).map { $0 ^ $1 })
        return p
    }

    /// 復号 (Encrypt2EncDec ENCRYPT2_DECRYPT)。HMAC が合えば 203 バイトのパスワード領域
    static func decryptProfile(_ p: [UInt8], encryptStr: [UInt8]) -> [UInt8]? {
        guard p.count == profileLen,
              let keyIV = pbkdf2(encryptStr, Array(p[oPassSalt..<(oPassSalt + saltLen)]), iter2, ikLen + ivLen),
              let pt = aesCTR(Array(keyIV[0..<ikLen]), Array(keyIV[ikLen...]), Array(p[oPassStr..<profileLen])),
              let hk = pbkdf2(encryptStr, Array(p[oEncSalt..<(oEncSalt + saltLen)]), iter1, 64) else { return nil }
        let hash = hmac512(hk, Array(p[0..<oEncHash]))
        let tag = Array(pt[(pwdMaxLen + saltLen)...])
        // CRYPTO_memcmp と同じく最後まで比べる
        var diff: UInt8 = 0
        for (a, b) in zip(hash, tag) { diff |= a ^ b }
        return diff == 0 ? Array(pt[0..<pwdMaxLen]) : nil
    }

    static func cString(_ b: [UInt8]) -> [UInt8] {
        if let z = b.firstIndex(of: 0) { return Array(b[..<z]) }
        return b
    }

    /// PwdFileReadln。nil は EOF (1 バイトも読めなかった)
    static func pwdReadln(_ d: [UInt8], _ pos: inout Int) -> [UInt8]? {
        var line: [UInt8] = []
        var endFile = true
        while pos < d.count {
            let b = d[pos]
            pos += 1
            endFile = false
            if b == 0x0D {
                if pos < d.count && d[pos] == 0x0A { pos += 1 }
                break
            } else if b == 0x0A {
                break
            } else if line.count < maxLineLen - 1 {
                line.append(b)
            }
        }
        return endFile ? nil : line
    }

    static func parseLine(_ line: [UInt8]) -> [UInt8]? {
        guard line.count == base64Len else { return nil }
        let p = b64decode(line, max: profileLen + 1)
        guard p.count == profileLen, p[0] == 0x00, p[1] == 0x02 else { return nil }
        return p
    }

    /// Encrypt2ProfileSearch。最後に一致した行のプロファイルと、その行の後ろの位置
    static func search(_ d: [UInt8], _ key: [UInt8]) -> (profile: [UInt8], cpos: Int)? {
        var pos = 0
        var found: ([UInt8], Int)?
        while let line = pwdReadln(d, &pos), !line.isEmpty {
            guard let p = parseLine(line),
                  let kh = pbkdf2(key, Array(p[oKeySalt..<(oKeySalt + saltLen)]), iter1, 64) else { continue }
            if kh == Array(p[oKeyHash..<(oKeyHash + 64)]) { found = (p, pos) }
            // 一致しても止めない (元のコードと同じ)
        }
        return found
    }

    private static func readFile(_ path: String) -> [UInt8]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let d = FileManager.default.contents(atPath: path) else { return nil }
        return [UInt8](d)
    }

    private static func writeFile(_ path: String, _ d: [UInt8]) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        if fd < 0 { return false }
        defer { close(fd) }
        return posixWrite(fd, d) == d.count
    }

    /// Encrypt2SetPassword
    static func setPassword(_ path: String, key: [UInt8], pass: [UInt8], encryptStr: [UInt8]) -> Int {
        if pass.count > pwdMaxLen { return 0 }
        // OPEN_ALWAYS
        let fd = open(path, O_RDWR | O_CREAT, 0o666)
        if fd < 0 { return 0 }
        close(fd)
        guard var d = readFile(path) else { return 0 }
        var update = false
        if let old = search(d, key) {
            let padded = pass + [UInt8](repeating: 0, count: pwdMaxLen - pass.count)
            if let op = decryptProfile(old.profile, encryptStr: encryptStr), op == padded { return 1 }
            update = true
        }
        guard let p = makeProfile(key: key, pass: pass, encryptStr: encryptStr) else { return 0 }
        let line = b64encode(p) + [0x0D, 0x0A]
        if update {
            // Encrypt2ProfileUpdate: 一致した行の後ろから 508+2 戻って上書き
            guard let old = search(d, key) else { return 0 }
            let at = old.cpos - base64Len - 2
            if at < 0 { return 0 }
            if d.count < at + line.count { d += [UInt8](repeating: 0, count: at + line.count - d.count) }
            d.replaceSubrange(at..<(at + line.count), with: line)
        } else {
            d += line
        }
        return writeFile(path, d) ? 1 : 0
    }

    /// Encrypt2GetPassword。成功なら (1, パスワード)
    static func getPassword(_ path: String, key: [UInt8], encryptStr: [UInt8]) -> (Int, [UInt8]) {
        guard let d = readFile(path), let f = search(d, key) else { return (0, []) }
        guard let pw = decryptProfile(f.profile, encryptStr: encryptStr) else { return (0, []) }
        return (1, cString(pw))
    }

    static func isPassword(_ path: String, key: [UInt8]) -> Int {
        guard let d = readFile(path) else { return 0 }
        return search(d, key) != nil ? 1 : 0
    }

    /// Encrypt2DelPassword
    static func delPassword(_ path: String, key: [UInt8]) -> Int {
        guard access(path, R_OK | W_OK) == 0, var d = readFile(path) else { return 0 }
        if !key.isEmpty {
            guard let f = search(d, key) else { return 0 }
            let at = f.cpos - base64Len - 2
            if at < 0 { return 0 }
            let tail = Array(d[f.cpos...])
            d = Array(d[0..<at]) + tail
            return writeFile(path, d) ? 1 : 0
        }
        // Encrypt2 の行だけ全部消す (空行があればそこで終わる。元のコードと同じ)
        var out: [UInt8] = []
        var pos = 0
        while let line = pwdReadln(d, &pos), !line.isEmpty {
            if parseLine(line) == nil { out += line + [0x0D, 0x0A] }
        }
        return writeFile(path, out) ? 1 : 0
    }
}

// MARK: - コマンド

extension TTLInterpreter {
    private var fileExtra: TTLFileExtra {
        fileExtraLock.lock()
        defer { fileExtraLock.unlock() }
        let k = ObjectIdentifier(self)
        if let e = fileExtras[k] { return e }
        let e = TTLFileExtra()
        fileExtras[k] = e
        return e
    }

    private func setLocked(_ i: Int, _ on: Bool) {
        fileExtraLock.lock()
        defer { fileExtraLock.unlock() }
        let k = ObjectIdentifier(self)
        let e = fileExtras[k] ?? TTLFileExtra()
        fileExtras[k] = e
        e.locked[i] = on
    }

    /// HandleGet。使えないハンドルは -1 (以降の読み書きは何もしない)
    private func fdOf(_ fhi: Int) -> Int32 {
        guard fhi >= 0 && fhi < fileHandles.count, let h = fileHandles[fhi] else { return -1 }
        return h.fileDescriptor
    }

    /// HandlePut
    private func handlePut(_ fd: Int32, _ path: String) -> Int {
        if fd < 0 { return -1 }
        for i in 0..<fileHandles.count where fileHandles[i] == nil {
            fileHandles[i] = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            filePaths[i] = path
            filePointer[i] = 0
            setLocked(i, false)
            return i
        }
        return -1
    }

    /// GetAbsPath。失敗する (':' がドライブ以外にある) なら nil
    private func getAbsPathC(_ s: [UInt8]) -> String? {
        if getFileNamePos(s) == nil { return nil }
        return s.isEmpty ? curDir : absPath(s)
    }

    private func pathOf(_ s: [UInt8]) -> String { s.isEmpty ? curDir : absPath(s) }

    /// GetAbsPath が作る文字列そのもの (CurrentDir + '\\' + 名前。"." や ".." は畳まない)。
    /// fileconcat / filecopy の「同じファイル」判定 (_stricmp) に使う
    private func getAbsPathRaw(_ s: [UInt8]) -> String {
        var p = TTLInterpreter.windowsPath(s.u8)
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        if p.hasPrefix("/") { return p }
        return curDir.hasSuffix("/") ? curDir + p : curDir + "/" + p
    }

    /// 同じファイルの実体か (別名・"." 入りのパスで同じものを指すとき)
    private func sameFileObject(_ a: String, _ b: String) -> Bool {
        var s1 = stat(), s2 = stat()
        guard stat(a, &s1) == 0, stat(b, &s2) == 0 else { return false }
        return s1.st_dev == s2.st_dev && s1.st_ino == s2.st_ino
    }

    /// マクロを始めたときのフォルダ (移植元ではプロセスのカレントフォルダ)。
    /// setdir / changedir では変わらない。CreateFile に相対パスをそのまま渡すコマンドや exec の既定のフォルダ
    var initialDir: String {
        var d = (macroPath as NSString).deletingLastPathComponent
        let cwd = FileManager.default.currentDirectoryPath
        if d.isEmpty { d = cwd } else if !d.hasPrefix("/") { d = (cwd as NSString).appendingPathComponent(d) }
        return (d as NSString).standardizingPath
    }

    /// 相対パスを initialDir 基準にする (GetAbsPath を通さずに Win32 API に渡す名前)
    func initialDirPath(_ s: [UInt8]) -> String {
        var p = TTLInterpreter.windowsPath(s.u8)
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        if !p.hasPrefix("/") { p = (initialDir as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    private func isWritable(_ st: stat) -> Bool { (st.st_mode & S_IWUSR) != 0 }

    // MARK: fileclose / fileopen / filecreate

    func cmdFileClose() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if fhi >= 0 && fhi < fileHandles.count, let h = fileHandles[fhi] {
            try? h.close()
            fileHandles[fhi] = nil
            filePaths[fhi] = ""
            setLocked(fhi, false)
        }
        return 0
    }

    func cmdFileOpen() -> Int {
        var err = 0
        let vid = getIntVar(&err)
        let fname = getStrVal(&err)
        let append = getIntVal(&err)
        var readonly = 0
        if checkParameterGiven() { readonly = getIntVal(&err) }
        if err == 0 && (fname.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        guard let path = getAbsPathC(fname) else { setIntVal(vid, -1); return 0 }
        let fd = readonly != 0 ? open(path, O_RDONLY) : open(path, O_RDWR | O_CREAT, 0o666)
        if fd < 0 { setIntVal(vid, -1); return 0 }
        var st = stat()
        if fstat(fd, &st) != 0 || (st.st_mode & S_IFMT) == S_IFDIR { close(fd); setIntVal(vid, -1); return 0 }
        let fhi = handlePut(fd, path)
        if fhi == -1 { setIntVal(vid, -1); close(fd); return 0 }
        setIntVal(vid, Int32(fhi))
        if append != 0 { lseek(fd, 0, SEEK_END) }
        return 0
    }

    func cmdFileCreate() -> Int {
        var err = 0
        let vid = getIntVar(&err)
        let fname = getStrVal(&err)
        if err == 0 && (fname.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { setResult(1); return err }
        guard let path = getAbsPathC(fname) else { setIntVal(vid, -1); setResult(-1); return 0 }
        var fd: Int32 = -1
        var st = stat()
        if !(stat(path, &st) == 0 && ((st.st_mode & S_IFMT) == S_IFDIR || !isWritable(st))) {
            fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o666)
        }
        setResult(fd < 0 ? 2 : 0)
        let fhi = handlePut(fd, path)
        setIntVal(vid, Int32(fhi))
        if fhi == -1 && fd >= 0 { close(fd) }
        return 0
    }

    // MARK: filelock / fileunlock

    func cmdFileLock() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        if err != 0 { return err }
        var timeout: Int? = nil     // 省略: 無限に待つ
        if checkParameterGiven() {
            let t = getIntVal(&err)
            if err != 0 { return err }
            if t >= 0 { timeout = t }
        }
        var result = 1
        if fd >= 0 {
            let start = Date()
            repeat {
                if !fileExtra.locked[fhi] && flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    setLocked(fhi, true)
                    result = 0
                    break
                }
                if cancelled { break }
                usleep(1000)
            } while timeout == nil || Date().timeIntervalSince(start) < Double(timeout!)
        }
        setResult(result)
        return 0
    }

    func cmdFileUnLock() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        endOfLine(&err)
        if err != 0 { return err }
        if fd >= 0 && fileExtra.locked[fhi] && flock(fd, LOCK_UN) == 0 {
            setLocked(fhi, false)
            setResult(0)
        } else {
            setResult(1)
        }
        return 0
    }

    // MARK: 読み書き

    func cmdFileReadln() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        let vid = getStrVar(&err)
        endOfLine(&err)
        if err != 0 { return err }
        var s: [UInt8] = []
        var endLine = false
        var endFile = true
        var r = FDReader(fd)
        while !endLine, let b = r.next() {
            endFile = false
            switch b {
            case 0x0D:
                if r.peek() == 0x0A { _ = r.next() }
                endLine = true
            case 0x0A:
                endLine = true
            default:
                if s.count < MaxStrLen - 1 { s.append(b) }
            }
        }
        r.finish()
        setResult(endFile ? 1 : 0)
        setStrVal(vid, s)
        return 0
    }

    func cmdFileRead() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        let n = getIntVal(&err)
        let vid = getStrVar(&err)
        endOfLine(&err)
        if err == 0 && (n < 1 || n > MaxStrLen - 1) { err = E.syntax }
        if err != 0 { return err }
        var s: [UInt8] = []
        var endFile = false
        var r = FDReader(fd)
        for _ in 0..<n {
            guard let b = r.next() else { endFile = true; break }
            s.append(b)
        }
        r.finish()
        setResult(endFile ? 1 : 0)
        setStrVal(vid, s)
        return 0
    }

    func cmdFileWrite(_ ln: Bool) -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        if err != 0 { return err }
        let p = linePtr
        let s = getStrVal(&err)
        if err == 0 {
            if getFirstChar() != 0 { return E.syntax }
            _ = posixWrite(fd, s)
        } else if err == E.typeMismatch {
            err = 0
            linePtr = p
            let v = getIntVal(&err)
            if err != 0 { return err }
            if getFirstChar() != 0 { return E.syntax }
            _ = posixWrite(fd, [UInt8(truncatingIfNeeded: v & 0xff)])
        } else {
            return err
        }
        if ln { _ = posixWrite(fd, [0x0D, 0x0A]) }
        return 0
    }

    // MARK: ファイルポインタ

    func cmdFileMarkPtr() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        endOfLine(&err)
        if err != 0 { return err }
        var pos = fd >= 0 ? lseek(fd, 0, SEEK_CUR) : -1
        if pos < 0 { pos = 0 }
        if fhi >= 0 && fhi < filePointer.count { filePointer[fhi] = UInt64(pos) }
        return 0
    }

    func cmdFileSeek() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        let off = getIntVal(&err)
        let origin = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        // SetFilePointer: 0=FILE_BEGIN 1=FILE_CURRENT 2=FILE_END (lseek と同じ値)
        if fd >= 0 && (0...2).contains(origin) { lseek(fd, off_t(off), Int32(origin)) }
        return 0
    }

    func cmdFileSeekBack() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        endOfLine(&err)
        if err != 0 { return err }
        if fd >= 0 { lseek(fd, off_t(filePointer[fhi]), SEEK_SET) }
        return 0
    }

    func cmdFileStrSeek() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        let str = getStrVal(&err)
        if err == 0 && (str.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        let pos = fd >= 0 ? lseek(fd, 0, SEEK_CUR) : -1
        if pos < 0 { return 0 }
        let len = str.count
        var i = 0
        var r = FDReader(fd)
        repeat {
            guard let b = r.next() else { break }
            if b == str[i] {
                i += 1
            } else if i > 0 {
                i = 0
                if b == str[0] { i = 1 }
            }
        } while i != len
        if i == len {
            setResult(1)
            r.finish()
        } else {
            setResult(0)
            lseek(fd, pos, SEEK_SET)
        }
        return 0
    }

    func cmdFileStrSeek2() -> Int {
        var err = 0
        let fhi = getIntVal(&err)
        let fd = fdOf(fhi)
        let str = getStrVal(&err)
        if err == 0 && (str.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        let pos = fd >= 0 ? lseek(fd, 0, SEEK_CUR) : -1
        if pos < 0 { return 0 }
        let len = str.count
        var i = 0
        var cur = pos      // 本物のファイルポインタの代わり
        var pos2 = pos
        var last: Bool
        repeat {
            last = pos2 <= 0
            var b: UInt8 = 0
            let c = pread(fd, &b, 1, cur)
            if c == 1 { cur += 1 }
            // win16_llseek(FH, -2, 1): 先頭より前には動かず -1 (エラー) を返す
            if cur - 2 >= 0 { cur -= 2; pos2 = cur } else { pos2 = -1 }
            if c == 1 {
                if b == str[len - 1 - i] {
                    i += 1
                } else if i > 0 {
                    i = 0
                    if b == str[len - 1] { i = 1 }
                }
            }
        } while !last && i != len
        if i == len {
            // 1 バイト目で見つかったときはゼロオフセットにする
            if pos2 == -1 { cur = 0 }
            lseek(fd, cur, SEEK_SET)
            setResult(1)
        } else {
            setResult(0)
            lseek(fd, pos, SEEK_SET)
        }
        return 0
    }

    // MARK: ファイル単位の操作

    func cmdFileConcat() -> Int {
        var err = 0
        let f1 = getStrVal(&err)
        let f2 = getStrVal(&err)
        if err == 0 && (f1.isEmpty || f2.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { setResult(1); return err }
        guard let p1 = getAbsPathC(f1) else { setResult(-1); return 0 }
        guard let p2 = getAbsPathC(f2) else { setResult(-2); return 0 }
        // _stricmp(FName1, FName2): GetAbsPath の文字列どうし (畳まない) を比べる
        if asciiCaseEqual(Array(getAbsPathRaw(f1).utf8), Array(getAbsPathRaw(f2).utf8)) { setResult(2); return 0 }
        var st = stat()
        if stat(p1, &st) == 0 && ((st.st_mode & S_IFMT) == S_IFDIR || !isWritable(st)) { setResult(3); return 0 }
        let fd1 = open(p1, O_WRONLY | O_CREAT, 0o666)
        if fd1 < 0 { setResult(3); return 0 }
        lseek(fd1, 0, SEEK_END)
        var result = 0
        // 移植元では FH1 を共有なしで開いているので、同じファイルを指す 2 つ目は開けない。
        // フォルダも CreateFile では開けない。どちらも何もせず result = 0
        var st2 = stat()
        let srcIsDir = stat(p2, &st2) == 0 && (st2.st_mode & S_IFMT) == S_IFDIR
        let fd2 = (srcIsDir || sameFileObject(p1, p2)) ? -1 : open(p2, O_RDONLY)
        if fd2 >= 0 {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let c = buf.withUnsafeMutableBytes { read(fd2, $0.baseAddress, $0.count) }
                if c < 0 { result = -4; break }
                if c == 0 { break }
                if posixWrite(fd1, Array(buf[0..<c])) != c { result = -5; break }
            }
            close(fd2)
        }
        close(fd1)
        setResult(result)
        return 0
    }

    func cmdFileCopy() -> Int {
        var err = 0
        let f1 = getStrVal(&err)
        let f2 = getStrVal(&err)
        if err == 0 && (f1.isEmpty || f2.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { setResult(1); return err }
        guard let p1 = getAbsPathC(f1) else { setResult(-1); return 0 }
        guard let p2 = getAbsPathC(f2) else { setResult(-2); return 0 }
        if asciiCaseEqual(Array(getAbsPathRaw(f1).utf8), Array(getAbsPathRaw(f2).utf8)) { setResult(-3); return 0 }
        // 別の書き方で同じファイルを指すとき CopyFileW は失敗する
        if sameFileObject(p1, p2) { setResult(-4); return 0 }
        // CopyFileW(src, dst, FALSE): 上書きする。コピー元はファイルのみ、読み取り専用の先は失敗
        var s1 = stat(), s2 = stat()
        guard stat(p1, &s1) == 0, (s1.st_mode & S_IFMT) != S_IFDIR else { setResult(-4); return 0 }
        if stat(p2, &s2) == 0 && ((s2.st_mode & S_IFMT) == S_IFDIR || !isWritable(s2)) { setResult(-4); return 0 }
        if copyfile(p1, p2, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT | COPYFILE_XATTR)) != 0 {
            setResult(-4)
            return 0
        }
        setResult(0)
        return 0
    }

    func cmdFileDelete() -> Int {
        var err = 0
        let f = getStrVal(&err)
        if err == 0 && (f.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { setResult(1); return err }
        guard let p = getAbsPathC(f) else { setResult(-1); return 0 }
        // DeleteFileW は読み取り専用のファイルを消せない
        var st = stat()
        if lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && !isWritable(st) { setResult(-1); return 0 }
        setResult(unlink(p) == 0 ? 0 : -1)
        return 0
    }

    func cmdFileRename() -> Int {
        var err = 0
        let f1 = getStrVal(&err)
        let f2 = getStrVal(&err)
        if err == 0 && (f1.isEmpty || f2.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { setResult(1); return err }
        if asciiCaseEqual(f1, f2) { setResult(2); return 0 }
        guard let p1 = getAbsPathC(f1) else { setResult(-1); return 0 }
        guard let p2 = getAbsPathC(f2) else { setResult(-2); return 0 }
        // MoveFileW: 移動先があれば失敗。別ボリュームへのファイル移動はできる
        do {
            try FileManager.default.moveItem(atPath: p1, toPath: p2)
        } catch {
            setResult(-3)
            return 0
        }
        setResult(0)
        return 0
    }

    func cmdFileSearch() -> Int {
        var err = 0
        let f = getStrVal(&err)
        if err == 0 && (f.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        var st = stat()
        setResult(lstat(pathOf(f), &st) == 0 ? 1 : 0)
        return 0
    }

    func cmdFileStat() -> Int {
        var err = 0
        let f = getStrVal(&err)
        if err == 0 && f.isEmpty { err = E.syntax }
        if err != 0 { return err }
        guard let p = getAbsPathC(f) else { setResult(-1); return 0 }
        // CreateFileW(GENERIC_READ, OPEN_EXISTING): フォルダは開けない
        let fd = open(p, O_RDONLY)
        if fd < 0 { setResult(-1); return 0 }
        var st = stat()
        let ok = fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) != S_IFDIR
        close(fd)
        if !ok { setResult(-1); return 0 }

        if checkParameterGiven() {
            let id = getIntVar(&err)
            if err != 0 { return err }
            setIntVal(id, Int32(truncatingIfNeeded: st.st_size))
        }
        if checkParameterGiven() {
            let id = getStrVar(&err)
            if err != 0 { return err }
            var t = st.st_mtimespec.tv_sec
            var tmv = tm()
            localtime_r(&t, &tmv)
            var buf = [Int8](repeating: 0, count: 128)
            strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &tmv)
            setStrVal(id, String(cString: buf).ttl)
        }
        if checkParameterGiven() {
            let id = getStrVar(&err)
            if err != 0 { return err }
            // ドライブ文字: 指定されたパスに書いてあればその文字、Mac のパスは '?' (元のコードで英字以外のとき)
            var d: UInt8 = 0x3F
            if f.count >= 2 && f[1] == 0x3A {
                let c = f[0]
                if c >= 0x61 && c <= 0x7A { d = c - 0x20 } else if c >= 0x41 && c <= 0x5A { d = c }
            }
            setStrVal(id, [d])
        }
        setResult(0)
        return 0
    }

    func cmdFileTruncate() -> Int {
        var err = 0
        let f = getStrVal(&err)
        if err == 0 && f.isEmpty { err = E.syntax }
        if err != 0 { return err }
        guard let p = getAbsPathC(f) else { setResult(-1); return 0 }
        var size = 0
        if checkParameterGiven() {
            size = getIntVal(&err)
            if err != 0 { return err }
        } else {
            setResult(-1)
            return E.syntax
        }
        var result = -1
        var st = stat()
        if !(stat(p, &st) == 0 && ((st.st_mode & S_IFMT) == S_IFDIR || !isWritable(st))) {
            let fd = open(p, O_RDWR | O_CREAT, 0o666)
            if fd >= 0 {
                if size >= 0 && ftruncate(fd, off_t(size)) == 0 { result = 0 }
                close(fd)
            }
        }
        setResult(result)
        return 0
    }

    // MARK: findfirst / findnext / findclose

    /// FindFirstFileW と同じように探す。見つかった名前を順に返す
    private func findFiles(_ path: String) -> [String] {
        let dir = (path as NSString).deletingLastPathComponent
        let pat = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        if pat.isEmpty || pat == "/" { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.isEmpty ? "/" : dir) else { return [] }
        // Windows のワイルドカード: '*' '?'。'[' は普通の文字。"*.*" は全部、"x.*" は拡張子なしの "x" も
        func esc(_ s: String) -> String {
            var r = ""
            for c in s { if c == "[" || c == "]" || c == "\\" { r.append("\\") }; r.append(c) }
            return r
        }
        var pats = [esc(pat == "*.*" ? "*" : pat)]
        if pat.hasSuffix(".*") && pat != "*.*" { pats.append(esc(String(pat.dropLast(2)))) }
        func match(_ n: String) -> Bool {
            pats.contains { fnmatch($0, n, FNM_CASEFOLD) == 0 }
        }
        var found = names.map { $0.precomposedStringWithCanonicalMapping }.filter(match)
        // NTFS の並び (大文字にした UTF-16 の順)
        found.sort { Array($0.uppercased().utf16).lexicographicallyPrecedes(Array($1.uppercased().utf16)) }
        // ルート以外のフォルダには "." と ".." がある
        if dir != "/" && !dir.isEmpty { found = [".", ".."].filter(match) + found }
        return found
    }

    func cmdFindFirst() -> Int {
        var err = 0
        let dh = getIntVar(&err)
        var dir = getStrVal(&err)
        let nameId = getStrVar(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if dir.isEmpty { dir = Array("*.*".utf8) }
        let path = absPath(dir)
        var i = 0
        while i < dirEnums.count && dirEnums[i] != nil { i += 1 }
        if i < dirEnums.count {
            let list = findFiles(path)
            if let first = list.first {
                dirEnums[i] = (list, 1)
                setStrVal(nameId, ttlTrunc(first.ttl))
            } else {
                i = -1
            }
        } else {
            i = -1
        }
        setIntVal(dh, Int32(i))
        if i < 0 {
            setResult(0)
            setStrVal(nameId, [])
        } else {
            setResult(1)
        }
        return 0
    }

    func cmdFindNext() -> Int {
        var err = 0
        let dh = getIntVal(&err)
        let nameId = getStrVar(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if dh >= 0 && dh < dirEnums.count, let e = dirEnums[dh], e.pos < e.paths.count {
            setStrVal(nameId, ttlTrunc(e.paths[e.pos].ttl))
            dirEnums[dh] = (e.paths, e.pos + 1)
            setResult(1)
        } else {
            setStrVal(nameId, [])
            setResult(0)
        }
        return 0
    }

    func cmdFindClose() -> Int {
        var err = 0
        let dh = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if dh >= 0 && dh < dirEnums.count { dirEnums[dh] = nil }
        return 0
    }

    // MARK: フォルダ

    func cmdFolderCreate() -> Int {
        var err = 0
        let f = getStrVal(&err)
        if err == 0 && (f.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { setResult(1); return err }
        guard let p = getAbsPathC(f) else { setResult(-1); return 0 }
        setResult(mkdir(p, 0o777) == 0 ? 0 : 2)
        return 0
    }

    func cmdFolderDelete() -> Int {
        var err = 0
        let f = getStrVal(&err)
        if err == 0 && (f.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { setResult(1); return err }
        guard let p = getAbsPathC(f) else { setResult(-1); return 0 }
        // RemoveDirectoryW: 空のフォルダだけ
        setResult(rmdir(p) == 0 ? 0 : 2)
        return 0
    }

    func cmdFolderSearch() -> Int {
        var err = 0
        let f = getStrVal(&err)
        if err == 0 && (f.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        var st = stat()
        setResult(stat(pathOf(f), &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR ? 1 : 0)
        return 0
    }

    // MARK: 属性

    /// Windows のファイル属性値 (GetFileAttributesW) に直す。なければ nil
    static func windowsAttributes(_ path: String) -> Int? {
        var st = stat()
        if lstat(path, &st) != 0 { return nil }
        var a = 0
        let isLink = (st.st_mode & S_IFMT) == S_IFLNK
        var target = st
        if isLink {
            a |= 0x400     // FILE_ATTRIBUTE_REPARSE_POINT
            if stat(path, &target) != 0 { target = st }
        }
        if (target.st_mode & S_IFMT) == S_IFDIR {
            a |= 0x10      // FILE_ATTRIBUTE_DIRECTORY
        } else {
            a |= 0x20      // FILE_ATTRIBUTE_ARCHIVE (Windows のふつうのファイル)
        }
        if (target.st_mode & S_IWUSR) == 0 { a |= 0x1 }                // READONLY
        let name = (path as NSString).lastPathComponent
        if (st.st_flags & UInt32(UF_HIDDEN)) != 0 || (name.hasPrefix(".") && name != "." && name != "..") {
            a |= 0x2       // HIDDEN
        }
        return a
    }

    func cmdGetFileAttr() -> Int {
        var err = 0
        let f = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        setResult(TTLInterpreter.windowsAttributes(pathOf(f)) ?? -1)
        return 0
    }

    func cmdSetFileAttr() -> Int {
        var err = 0
        let f = getStrVal(&err)
        let attr = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        guard let p = getAbsPathC(f) else { setResult(0); return 0 }
        var st = stat()
        if stat(p, &st) != 0 { setResult(0); return 0 }
        var ok = true
        // READONLY <-> 書き込み権
        if (attr & 0x1) != 0 {
            let m = st.st_mode & ~(S_IWUSR | S_IWGRP | S_IWOTH)
            if m != st.st_mode { ok = chmod(p, m) == 0 }
        } else if (st.st_mode & S_IWUSR) == 0 {
            ok = chmod(p, st.st_mode | S_IWUSR) == 0
        }
        // HIDDEN <-> UF_HIDDEN
        let hidden = UInt32(UF_HIDDEN)
        let flags = (attr & 0x2) != 0 ? (st.st_flags | hidden) : (st.st_flags & ~hidden)
        if ok && flags != st.st_flags { ok = chflags(p, flags) == 0 }
        setResult(ok ? 1 : 0)
        return 0
    }

    // MARK: getdir / setdir / makepath / basename / dirname

    func cmdGetDir() -> Int {
        var err = 0
        let vid = getStrVar(&err)
        endOfLine(&err)
        if err != 0 { return err }
        setStrVal(vid, ttlTrunc(curDir.ttl))
        return 0
    }

    func cmdSetDir() -> Int {
        var err = 0
        let s = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        // TTMSetDir: 移れなければそのまま
        if s.isEmpty { return 0 }
        let p = absPath(s)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { curDir = p }
        return 0
    }

    func cmdMakePath() -> Int {
        var err = 0
        let vid = getStrVar(&err)
        var dir = getStrVal(&err)
        let name = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        // AppendSlash。Windows 風のパス ('\' だけ使っている) なら '\'、それ以外は '/'
        if let l = dir.last, isSep(l) {
        } else {
            dir.append(dir.contains(0x5C) && !dir.contains(0x2F) ? 0x5C : 0x2F)
        }
        setStrVal(vid, ttlTrunc(dir + name))
        return 0
    }

    func cmdBasename() -> Int {
        var err = 0
        let vid = getStrVar(&err)
        let src = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if let pos = getFileNamePos(src) { setStrVal(vid, Array(src[pos.fnPos...])) } else { setStrVal(vid, []) }
        return 0
    }

    func cmdDirname() -> Int {
        var err = 0
        let vid = getStrVar(&err)
        let src = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        let s = deleteSlash(src)
        if let pos = getFileNamePos(s) { setStrVal(vid, deleteSlash(Array(s[0..<pos.dirLen]))) } else { setStrVal(vid, []) }
        return 0
    }

    // MARK: checksum / crc

    static func checksumValue(_ t: ChecksumType, _ c: UnsafeRawBufferPointer) -> UInt32 {
        switch t {
        case .checksum8, .checksum16, .checksum32:
            var v: UInt32 = 0
            for b in c { v = v &+ UInt32(b) }
            return t == .checksum8 ? v & 0xFF : t == .checksum16 ? v & 0xFFFF : v
        case .crc16:
            var r: UInt32 = 0xFFFF
            for b in c {
                r ^= UInt32(b)
                for _ in 0..<8 { r = (r & 1) != 0 ? (r >> 1) ^ 0x8408 : r >> 1 }
            }
            return r ^ 0xFFFF
        case .crc32:
            var r: UInt32 = 0xFFFFFFFF
            for b in c {
                r ^= UInt32(b)
                for _ in 0..<8 { r = (r & 1) != 0 ? (r >> 1) ^ 0xEDB88320 : r >> 1 }
            }
            return r ^ 0xFFFFFFFF
        }
    }

    func cmdChecksum(_ t: ChecksumType) -> Int {
        var err = 0
        let vid = getIntVar(&err)
        let s = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if s.isEmpty { return 0 }
        let v = s.withUnsafeBytes { TTLInterpreter.checksumValue(t, $0) }
        setIntVal(vid, Int32(bitPattern: v))
        return 0
    }

    func cmdChecksumFile(_ t: ChecksumType) -> Int {
        var err = 0
        let vid = getIntVar(&err)
        let s = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if s.isEmpty { return 0 }
        var result = -1
        // CreateFile(Str) に GetAbsPath を通さずに渡すので、相対パスは最初のフォルダ基準 (setdir は効かない)
        let p = initialDirPath(s)
        var st = stat()
        // 開けない・フォルダ・空のファイル (CreateFileMapping が失敗する) は -1
        if stat(p, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR, st.st_size > 0,
           let d = try? Data(contentsOf: URL(fileURLWithPath: p), options: .alwaysMapped) {
            let v = d.withUnsafeBytes { TTLInterpreter.checksumValue(t, $0) }
            setIntVal(vid, Int32(bitPattern: v))
            result = 0
        }
        setResult(result)
        return 0
    }

    // MARK: setpassword / getpassword / ispassword / delpassword

    func cmdGetPassword() -> Int {
        var err = 0
        let file = getStrVal(&err)
        let key = getStrVal(&err)
        let vid = getStrVar(&err)
        endOfLine(&err)
        if err != 0 { return err }
        setStrVal(vid, [])
        if file.isEmpty || key.isEmpty { return 0 }
        let ini = absPath(file)
        var result = 0
        var pass: [UInt8] = []
        let enc = TTLProfileFile.getString(ini, "Password", key.u8)
        if enc.isEmpty {
            guard let input = host?.ttlInputBox(key.u8, title: "Enter password", defaultValue: "", secret: true) else {
                // 閉じるボタンでマクロを終える
                status = .end
                return 0
            }
            pass = ttlTrunc(input.ttl)
            if !pass.isEmpty {
                let e = TTLPasswordCrypto.encrypt(pass, seed: TTLPasswordCrypto.tickSeed())
                if TTLProfileFile.writeString(ini, "Password", key.u8, e.u8) { result = 1 }
            }
        } else {
            pass = TTLPasswordCrypto.decrypt(enc.ttl)
            result = 1
        }
        if result == 1 { setStrVal(vid, pass) }
        setResult(result)
        return 0
    }

    func cmdSetPassword() -> Int {
        var err = 0
        let file = getStrVal(&err)
        let key = getStrVal(&err)
        let pass = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if file.isEmpty || key.isEmpty || pass.isEmpty { return E.syntax }
        let ini = absPath(file)
        let e = TTLPasswordCrypto.encrypt(pass, seed: TTLPasswordCrypto.tickSeed())
        setResult(TTLProfileFile.writeString(ini, "Password", key.u8, e.u8) ? 1 : 0)
        return 0
    }

    func cmdIsPassword() -> Int {
        var err = 0
        let file = getStrVal(&err)
        let key = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if file.isEmpty || key.isEmpty { return E.syntax }
        let v = TTLProfileFile.getString(absPath(file), "Password", key.u8)
        setResult(v.isEmpty ? 0 : 1)
        return 0
    }

    func cmdDelPassword() -> Int {
        var err = 0
        let file = getStrVal(&err)
        let key = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if file.isEmpty { return 0 }
        let ini = absPath(file)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ini, isDirectory: &isDir), !isDir.boolValue else { return 0 }
        if key.isEmpty {
            TTLProfileFile.writeString(ini, "Password", nil, nil)
        } else {
            TTLProfileFile.writeString(ini, "Password", key.u8, nil)
        }
        return 0
    }

    // MARK: setpassword2 / getpassword2 / ispassword2 / delpassword2

    func cmdGetPassword2() -> Int {
        var err = 0
        let file = getStrVal(&err)
        let key = getStrVal(&err)
        let vid = getStrVar(&err)
        if err == 0 { setStrVal(vid, []) }
        let encStr = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if file.isEmpty || key.isEmpty || encStr.isEmpty { return E.syntax }
        let path = absPath(file)
        var result = 0
        var pass: [UInt8] = []
        if TTLEncrypt2.isPassword(path, key: key) == 0 {
            // 閉じるボタンでも終わらない (元のコードと同じ)
            let input = host?.ttlInputBox(key.u8, title: "Enter password", defaultValue: "", secret: true) ?? ""
            pass = ttlTrunc(input.ttl)
            if !pass.isEmpty {
                result = TTLEncrypt2.setPassword(path, key: key, pass: pass, encryptStr: encStr)
            }
        } else {
            (result, pass) = TTLEncrypt2.getPassword(path, key: key, encryptStr: encStr)
        }
        if result == 1 { setStrVal(vid, pass) }
        setResult(result)
        return 0
    }

    func cmdSetPassword2() -> Int {
        var err = 0
        let file = getStrVal(&err)
        let key = getStrVal(&err)
        let pass = getStrVal(&err)
        let encStr = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if file.isEmpty || key.isEmpty || pass.isEmpty || encStr.isEmpty { return E.syntax }
        setResult(TTLEncrypt2.setPassword(absPath(file), key: key, pass: pass, encryptStr: encStr))
        return 0
    }

    func cmdIsPassword2() -> Int {
        var err = 0
        let file = getStrVal(&err)
        let key = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if file.isEmpty || key.isEmpty { return E.syntax }
        setResult(TTLEncrypt2.isPassword(absPath(file), key: key))
        return 0
    }

    func cmdDelPassword2() -> Int {
        var err = 0
        let file = getStrVal(&err)
        let key = getStrVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if file.isEmpty { return E.syntax }
        _ = TTLEncrypt2.delPassword(absPath(file), key: key)
        return 0
    }
}
