// 正規表現 (鬼車 / Oniguruma)。Tera Term のマクロと同じライブラリ・同じ既定値 (UTF-8, Ruby 文法) を使う
import Foundation
import COniguruma

struct TTLRegexMatch {
    /// マッチした位置 (0 始まりのバイト位置)
    var position: Int
    /// 0 = 全体、1〜 = グループ。マッチしなかったグループは nil
    var groups: [Range<Int>?]
}

enum TTLRegexResult {
    case match(TTLRegexMatch)
    case noMatch
    case error(String)
}

enum TTLRegex {
    /// 鬼車の初期化はスレッドセーフではないので、まとめて 1 つずつ使う
    private static let lock = NSLock()

    static let optionNames: [String: OnigOptionType] = [
        "SINGLELINE": 1 << 3, "MULTILINE": 1 << 2, "IGNORECASE": 1, "EXTEND": 1 << 1,
        "FIND_LONGEST": 1 << 4, "FIND_NOT_EMPTY": 1 << 5, "NEGATE_SINGLELINE": 1 << 6,
        "DONT_CAPTURE_GROUP": 1 << 7, "CAPTURE_GROUP": 1 << 8,
    ]

    static var defaultEncoding: OnigEncoding { teramac_onig_encoding("UTF8") }
    static var defaultSyntax: UnsafeMutablePointer<OnigSyntaxType> { teramac_onig_syntax("RUBY") }

    /// pattern を target の中から探す
    static func search(_ pattern: [UInt8], in target: [UInt8], option: OnigOptionType = 0,
                       encoding: OnigEncoding? = nil, syntax: UnsafeMutablePointer<OnigSyntaxType>? = nil) -> TTLRegexResult {
        lock.lock()
        defer { lock.unlock() }
        var enc: OnigEncoding? = encoding ?? defaultEncoding
        _ = onig_initialize(&enc, 1)
        var reg: OnigRegex?
        var einfo = OnigErrorInfo()
        let pat = pattern.isEmpty ? [UInt8(0)] : pattern
        let r = pat.withUnsafeBufferPointer { p in
            onig_new(&reg, p.baseAddress, p.baseAddress! + pattern.count, option, enc, syntax ?? defaultSyntax, &einfo)
        }
        if r != ONIG_NORMAL {
            var buf = [UInt8](repeating: 0, count: 256)
            _ = withUnsafeMutablePointer(to: &einfo) { e in
                buf.withUnsafeMutableBufferPointer { b in teramac_onig_error_string(b.baseAddress, Int32(r), e) }
            }
            return .error(String(cString: buf))
        }
        defer { onig_free(reg) }
        guard let region = onig_region_new() else { return .error("memory") }
        defer { onig_region_free(region, 1) }
        let tgt = target.isEmpty ? [UInt8(0)] : target
        let pos = tgt.withUnsafeBufferPointer { t -> Int32 in
            let s = t.baseAddress!
            let e = s + target.count
            return Int32(truncatingIfNeeded: onig_search(reg, s, e, s, e, region, 0))
        }
        if pos >= 0 {
            var groups: [Range<Int>?] = []
            for i in 0..<Int(region.pointee.num_regs) {
                let b = Int(region.pointee.beg[i]), e = Int(region.pointee.end[i])
                groups.append(b < 0 ? nil : b..<max(b, e))
            }
            return .match(TTLRegexMatch(position: Int(pos), groups: groups))
        }
        if pos == ONIG_MISMATCH { return .noMatch }
        return .error("search error \(pos)")
    }
}
