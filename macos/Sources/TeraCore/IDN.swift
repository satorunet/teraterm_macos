// 国際化ドメイン名 (IDN)。issue #1493 (7572aa927): 接続先のホスト名に ASCII 以外の文字があれば、
// 名前解決・プロキシへ送る前に ACE 形式 (xn--) に直す (teraterm/common/idn.cpp IdnHostNameToAscii)。
// 本家は Windows の IdnToAscii を使う。Mac には使える API がないので、RFC 3492 (Punycode) をここで書く。

import Foundation

public enum IDN {
    /// IdnHostNameToAscii: ASCII だけならそのまま。ASCII 以外を含むラベルは "xn--" + Punycode。
    /// 変換できなかったときは元のホスト名をそのまま返す
    public static func hostNameToASCII(_ host: String) -> String {
        guard host.unicodeScalars.contains(where: { $0.value >= 0x80 }) else { return host }
        // IDNA (RFC 3490 3.1): 「。」「．」「｡」もラベルの区切り
        let dots: Set<Unicode.Scalar> = [".", "\u{3002}", "\u{FF0E}", "\u{FF61}"]
        var labels: [String] = []
        var cur = String.UnicodeScalarView()
        for u in host.unicodeScalars {
            if dots.contains(u) { labels.append(String(cur)); cur = String.UnicodeScalarView() } else { cur.append(u) }
        }
        labels.append(String(cur))
        var out: [String] = []
        for l in labels {
            guard l.unicodeScalars.contains(where: { $0.value >= 0x80 }) else { out.append(l); continue }
            // Nameprep (RFC 3491) の近似: 互換分解 + 合成 (NFKC) と小文字化
            let prepped = l.precomposedStringWithCompatibilityMapping.lowercased()
            guard let p = punycodeEncode(prepped) else { return host }
            let ace = "xn--" + p
            guard ace.utf8.count <= 63 else { return host }
            out.append(ace)
        }
        return out.joined(separator: ".")
    }

    // MARK: - RFC 3492 Punycode

    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 0x80

    private static func adapt(_ delta: Int, _ numPoints: Int, _ first: Bool) -> Int {
        var d = first ? delta / damp : delta / 2
        d += d / numPoints
        var k = 0
        while d > ((base - tMin) * tMax) / 2 {
            d /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * d / (d + skew)
    }

    private static func digit(_ d: Int) -> Character {
        // 0-25 → a-z, 26-35 → 0-9
        Character(Unicode.Scalar(UInt8(d < 26 ? 0x61 + d : 0x30 + d - 26)))
    }

    /// RFC 3492 6.3 encoding procedure。あふれたら nil
    public static func punycodeEncode(_ s: String) -> String? {
        let input = s.unicodeScalars.map { Int($0.value) }
        var output = ""
        for c in input where c < 0x80 { output.append(Character(Unicode.Scalar(UInt8(c)))) }
        let b = output.unicodeScalars.count
        var h = b
        if b > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while h < input.count {
            guard let m = input.filter({ $0 >= n }).min() else { break }
            let (mul, o1) = (m - n).multipliedReportingOverflow(by: h + 1)
            if o1 { return nil }
            let (d2, o2) = delta.addingReportingOverflow(mul)
            if o2 || d2 > Int(Int32.max) { return nil }
            delta = d2
            n = m
            for c in input {
                if c < n {
                    delta += 1
                    if delta > Int(Int32.max) { return nil }
                }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, h + 1, h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }
}
