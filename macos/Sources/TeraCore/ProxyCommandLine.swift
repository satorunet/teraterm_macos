// TTProxy のコマンドライン (-proxy=URL / -noproxy / protocol://proxy:port/realhost)
// TTProxy/TTProxy.h TTXParseParam と ProxyWSockHook.h ProxyInfo::parse / parseType / parsePort / urldecode、
// ProxyWSockHook::parseURL を移したもの (Copyright (C) 1999-2014 YebisuyaHompo, (C) 2004- TeraTerm Project, BSD 3-Clause)
//   1.0.0.9  接続先ポート番号が 0 のときは Tera Term に任せる (プロキシにしない)
//   1.0.0.13 "protocol://proxy:port" (/ のない形) はプロキシにしない (Tera Term の telnet://host:port と重なるため)
//   1.0.0.19 / 1.0.0.22 空白を含む引数・途中からの " のクオート (TTCommandLine.tokens / dequote)
//   1.0.0.23 -noproxy (-proxy=none:// と同じ)

import Foundation

/// コマンドラインで指定したプロキシ (TTProxy の defaultProxy を置き換える)
public struct ProxyURL: Equatable {
    /// ProxyInfo::Type
    public enum Kind: Equatable {
        /// TYPE_NONE: プロキシを使わない
        case none
        /// TYPE_NONE_FORCE: none:// と -noproxy。プロキシを使わない
        case noneForce
        case http, telnet, socks4, socks5
        /// TYPE_SSL / TYPE_*_SSL (Mac 版の TTProxy は SSL に対応していない)
        case ssl, httpSSL, telnetSSL, socks4SSL, socks5SSL
    }
    public var kind: Kind = .none
    public var host: String = ""
    /// 0 なら種類ごとの既定 (ProxyInfo::getPort)
    public var port: Int = 0
    public var user: String = ""
    public var pass: String = ""
    public init() {}

    /// SSL を使う種類 (Mac では接続できない)
    public var isSSL: Bool { [.ssl, .httpSSL, .telnetSSL, .socks4SSL, .socks5SSL].contains(kind) }

    /// ProxySettings の ProxyType の値 ("none" / "http" / "telnet" / "socks4" / "socks5")
    public var typeName: String {
        switch kind {
        case .http: return "http"
        case .telnet: return "telnet"
        case .socks4: return "socks4"
        case .socks5: return "socks5"
        default: return "none"
        }
    }

    /// proxy_type_table (大文字小文字は区別しない)
    static func parseType(_ s: String) -> Kind {
        guard !s.unicodeScalars.contains(where: { $0.value >= 0x80 }) else { return .none }
        switch s.lowercased() {
        case "http": return .http
        case "socks", "socks5": return .socks5
        case "socks4": return .socks4
        case "telnet": return .telnet
        case "none": return .noneForce
        case "http+ssl": return .httpSSL
        case "socks+ssl", "socks5+ssl": return .socks5SSL
        case "socks4+ssl": return .socks4SSL
        case "telnet+ssl": return .telnetSSL
        case "ssl", "none+ssl": return .ssl
        default: return .none
        }
    }

    /// ProxyInfo::parsePort: 1〜65535 の数字だけ。0・空・数字以外は -1
    static func parsePort(_ s: Substring) -> Int {
        guard let f = s.unicodeScalars.first, f.value >= 0x31 && f.value <= 0x39 else { return -1 }
        var v = 0
        for c in s.unicodeScalars {
            guard c.value >= 0x30 && c.value <= 0x39 else { return -1 }
            v = v * 10 + Int(c.value - 0x30)
            if v > 65535 { return -1 }
        }
        return v == 0 ? -1 : v
    }

    /// ProxyInfo::urldecode (%xx をバイトに。UTF-8 として読む)
    static func urldecode(_ s: Substring) -> String {
        let b = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        func hex(_ c: UInt8) -> Int? {
            switch c {
            case 0x30...0x39: return Int(c - 0x30)
            case 0x41...0x46: return Int(c - 0x41 + 10)
            case 0x61...0x66: return Int(c - 0x61 + 10)
            default: return nil
            }
        }
        while i < b.count {
            if b[i] == 0x25, i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                out.append(UInt8(h << 4 | l)); i += 3
            } else {
                out.append(b[i]); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// ProxyInfo::parse: url を読んで proxy に入れる。戻り値は "/" の後ろ (実際の接続先)、"/" がなければ url 全体。
    /// 読めなければ nil (proxy.kind は none)
    static func parse(_ url: String, into proxy: inout ProxyURL) -> String? {
        proxy = ProxyURL()
        guard let sep = url.range(of: "://") else { return nil }
        proxy.kind = parseType(String(url[..<sep.lowerBound]))
        if proxy.kind == .none { return nil }
        var p = url[sep.upperBound...]
        // user:pass があれば格納する (残り全体で最初の @ まで)
        if let at = p.firstIndex(of: "@") {
            let up = p[..<at]
            if let c = up.firstIndex(of: ":") {
                proxy.user = urldecode(up[..<c])
                proxy.pass = urldecode(up[up.index(after: c)...])
            } else {
                proxy.user = urldecode(up)
            }
            p = p[p.index(after: at)...]
        }
        // ホスト名を格納する ([IPv6]:port)
        var start = p.startIndex
        var i = p.startIndex
        var inBracket = false
        var host: String?
        while i < p.endIndex && p[i] != "/" {
            let ch = p[i]
            if ch == "[" {
                inBracket = true
            } else if inBracket && ch == "]" {
                inBracket = false
            } else if !inBracket && ch == ":" {
                if p[start] == "[" && p.distance(from: start, to: i) >= 2 {
                    host = String(p[p.index(after: start)..<p.index(before: i)])
                } else {
                    host = String(p[start..<i])
                }
                start = p.index(after: i)
            }
            i = p.index(after: i)
        }
        if proxy.kind != .noneForce && proxy.kind != .ssl {
            if host == nil {
                if start >= i { proxy.kind = .none; return nil }
                proxy.host = String(p[start..<i])
            } else {
                proxy.host = host!
                proxy.port = parsePort(p[start..<i])
                if proxy.port < 0 { proxy = ProxyURL(); return nil }
            }
        } else if let h = host {
            proxy.host = h
        }
        if i < p.endIndex && p[i] == "/" { return String(p[p.index(after: i)...]) }
        return url
    }

    /// ProxyWSockHook::parseURL: 読めたら (戻り値が nil でなければ) defaultProxy をこれに置き換える。
    /// prefix: -proxy= のとき true。prefix でない (ふつうの引数) のときに残りに "://" があれば (telnet://host など)
    /// プロキシは使わない (TYPE_NONE)。"/" の後ろが空でもプロキシは使わない
    public static func parseURL(_ url: String, prefix: Bool) -> (realHost: String?, proxy: ProxyURL)? {
        var proxy = ProxyURL()
        guard var realhost = parse(url, into: &proxy) else { return nil }
        if realhost.contains("://") && !prefix { proxy.kind = .none }
        var rh: String? = realhost
        if realhost.isEmpty { rh = nil; proxy.kind = .none; realhost = "" }
        return (rh, proxy)
    }

    /// 使うときの形: プロキシを使わないなら nil
    public var usesProxy: Bool {
        switch kind {
        case .none, .noneForce: return false
        default: return true
        }
    }
}

/// TTXParseParam: コマンドラインの語から TTProxy のものを取り除く。
/// 戻り値: Tera Term 本体に渡す語・置き換えたプロキシ (nil なら設定のまま)・実際の接続先 (protocol://proxy/realhost)
public enum ProxyCommandLine {
    public static func strip(_ tokens: [String]) -> (rest: [String], proxy: ProxyURL?, realHost: String?) {
        var rest: [String] = []
        var proxy: ProxyURL?
        var realHost: String?
        for raw in tokens {
            let o = TTCommandLine.dequote(raw)
            let sc = Array(o.unicodeScalars)
            if let f = sc.first, f == "-" || f == "/" {
                if sc.count >= 7 && sc[6] == "=" && String(String.UnicodeScalarView(sc[1..<6])).lowercased() == "proxy" {
                    if let r = ProxyURL.parseURL(String(String.UnicodeScalarView(sc[7...])), prefix: true) { proxy = r.proxy }
                    continue
                }
                if String(String.UnicodeScalarView(sc[1...])).lowercased() == "noproxy" {
                    // -noproxy は -proxy=none:// の別名
                    if let r = ProxyURL.parseURL("none://", prefix: true) { proxy = r.proxy }
                    continue
                }
            } else if let r = ProxyURL.parseURL(o, prefix: false), let rh = r.realHost, !rh.contains("://") {
                // protocol://proxy:port/realhost: このプロキシで realhost へつなぐ
                proxy = r.proxy
                realHost = rh
                continue
            }
            // "://" を含む (telnet://host など) はプロキシの指定ではないので Tera Term に任せ、設定のプロキシはそのまま使う。
            // 本家 TTProxy はこのとき defaultProxy を TYPE_NONE で上書きし、INI のプロキシ設定が効かなくなる (不具合なので合わせない)
            rest.append(raw)
        }
        return (rest, proxy, realHost)
    }
}
