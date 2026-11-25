// Tera Term のコマンドライン (connect マクロのパラメータ) を読む
// ttset.c の _ParseParam / ParseHostName、ttxssh.c の TTXParseParam、ttlib の GetParamAlloc / DequoteParam を移したもの
// (Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project, BSD 3-Clause)

import Foundation

public struct TTCommandLine: Equatable {
    public enum PortType: Equatable { case tcpip, serial, namedPipe, file }

    /// 指定された接続の種類 (nil = 指定なし。今の設定のまま)
    public var portType: PortType?
    public var host: String?
    public var tcpPort: Int?
    /// /T=0 /T=1 (Tera Term の ts.Telnet)
    public var telnet: Int?
    /// /B (Telnet バイナリ)
    public var telBin: Bool?
    /// TTSSH の Enabled。true: /ssh /ssh1 /ssh2 /t=2 ssh://  false: /nossh /telnet /T=0 /T=1
    public var ssh: Bool?
    public var sshVersion: Int?
    /// telnet:// で指定された (ポートがなければ 23)
    public var telnetURL = false
    public var user: String?
    public var password: String?
    public var keyFile: String?
    /// /auth= の値 (password / publickey / challenge / keyboard-interactive / pageant)
    public var auth: String?
    public var ask4passwd = false
    /// /C=n の n (1〜)。範囲外は 0
    public var comPort: Int?
    /// /C=/dev/cu.xxx (Mac だけ: デバイスを直接書く)
    public var comDevice: String?
    public var baud: Int?
    public var dataBit: Int?
    /// none / odd / even / mark / space
    public var parity: String?
    /// "1" / "1.5" / "2"
    public var stopBit: String?
    /// none / x / hard / rtscts / dsrdtr
    public var flowCtrl: String?
    public var delayPerChar: Int?
    public var delayPerLine: Int?
    /// /W= ウインドウのタイトル
    public var title: String?
    /// /TIMEOUT= (秒)
    public var timeout: Int?
    /// /M= マクロ
    public var macro: String?
    /// /L= ログ
    public var logFile: String?
    /// /FD= ファイル転送のフォルダ
    public var fileDir: String?
    /// /KR= /KT=
    public var kanjiRecv: String?
    public var kanjiSend: String?
    /// TTProxy の -proxy= / -noproxy / protocol://proxy:port/realhost で置き換えたプロキシ (nil なら設定のまま)
    public var proxy: ProxyURL?
    /// 解釈しなかったオプション
    public var unknown: [String] = []

    public init() {}

    // MARK: - 切り出し

    /// GetParamAlloc: 空白・タブ区切り。" で囲めば空白を含められる。; (囲みの外) で終わり
    public static func tokens(_ param: String) -> [String] {
        let s = Array(param.unicodeScalars)
        var out: [String] = []
        var i = 0
        while true {
            while i < s.count && (s[i] == " " || s[i] == "\t") { i += 1 }
            if i >= s.count || s[i] == ";" { break }
            var dest: [Unicode.Scalar] = []
            var quoted = false
            while i < s.count && (quoted || (s[i] != ";" && s[i] != " " && s[i] != "\t")) {
                if s[i] == "\"" {
                    if i + 1 < s.count && s[i + 1] == "\"" {
                        dest.append(s[i]); i += 1
                    } else {
                        quoted.toggle()
                    }
                }
                dest.append(s[i]); i += 1
            }
            if !quoted && dest.last == ";" { dest.removeLast() }
            var t = String.UnicodeScalarView(); t.append(contentsOf: dest)
            out.append(String(t))
        }
        return out
    }

    /// DequoteParam: " を外す。囲みの中の "" は " 1 文字
    public static func dequote(_ src: String) -> String {
        let s = Array(src.unicodeScalars)
        var out = String.UnicodeScalarView()
        var quoted = false
        var i = 0
        while i < s.count {
            if s[i] != "\"" {
                out.append(s[i]); i += 1
                continue
            }
            i += 1
            if i < s.count && s[i] == "\"" && quoted {
                out.append(s[i]); i += 1
            } else {
                quoted.toggle()
            }
        }
        return String(out)
    }

    /// ParsePortName: サービス名か数字 (sscanf %d と同じく先頭の数字だけ読む)
    public static func parsePort(_ s: String) -> Int {
        switch s.lowercased() {
        case "telnet": return 23
        case "ssh": return 22
        case "http": return 80
        case "ftp": return 21
        default: break
        }
        if let se = getservbyname(s, "tcp") { return Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: se.pointee.s_port))) }
        return scanInt(s) ?? 0
    }

    /// sscanf("%d") と同じ: 先頭の空白・符号・数字。読めなければ nil
    public static func scanInt(_ s: String) -> Int? {
        var it = s.unicodeScalars.makeIterator()
        var c = it.next()
        while let x = c, x == " " || x == "\t" || x == "\n" || x == "\r" { c = it.next() }
        var neg = false
        if let x = c, x == "+" || x == "-" { neg = x == "-"; c = it.next() }
        var v = 0, any = false
        while let x = c, x.value >= 0x30 && x.value <= 0x39 {
            v = v &* 10 &+ Int(x.value - 0x30); any = true
            if v > Int(Int32.max) { v = Int(Int32.max) }
            c = it.next()
        }
        return any ? (neg ? -v : v) : nil
    }

    private static func percentDecode(_ s: String) -> String { s.removingPercentEncoding ?? s }

    // MARK: - 解釈

    /// Tera Term (+ TTSSH) のコマンドラインを読む。先頭に実行ファイル名は付けない
    public static func parse(_ param: String, maxComPort: Int = 256) -> TTCommandLine {
        var r = TTCommandLine()
        var paramPort: PortType?
        var paramTCP = 0
        var paramTel = 2
        var paramBin = 2
        var paramCom = 0
        var comGiven = false
        var hostNameFlag = false
        var justAfterHost = false

        // TTProxy (TTXParseParam) が先に自分の語を取り除く
        let px = ProxyCommandLine.strip(tokens(param))
        r.proxy = px.proxy
        for raw in px.rest {
            var t = dequote(raw)
            let l = t.lowercased()

            // --- TTSSH が先に読むもの ---
            if t.hasPrefix("/") || t.hasPrefix("-") {
                let o = String(t.dropFirst())
                let ol = o.lowercased()
                var handled = true
                if o.hasPrefix("ssh") {
                    let rest = String(o.dropFirst(3))
                    switch rest {
                    case "": r.ssh = true
                    case "1": r.ssh = true; r.sshVersion = 1
                    case "2": r.ssh = true; r.sshVersion = 2
                    default:
                        if rest.hasPrefix("-") { break }   // /ssh-L など (ポート転送) は Mac の ssh に任せず無視
                        r.unknown.append(t)
                    }
                } else if ol.hasPrefix("t=") && o.dropFirst(2) == "2" {
                    r.ssh = true
                } else if o == "1" { r.sshVersion = 1
                } else if o == "2" { r.sshVersion = 2
                } else if o == "nossh" { r.ssh = false
                } else if o == "telnet" { r.ssh = false; r.telnet = 1
                } else if o.hasPrefix("auth=") { r.auth = String(o.dropFirst(5)).lowercased()
                } else if o.hasPrefix("user=") { r.user = String(o.dropFirst(5))
                } else if o.hasPrefix("passwd=") { r.password = String(o.dropFirst(7))
                } else if o.hasPrefix("keyfile=") { r.keyFile = String(o.dropFirst(8))
                } else if o == "ask4passwd" { r.ask4passwd = true
                } else if o == "nosecuritywarning" {
                } else {
                    handled = false
                }
                if ol.hasPrefix("t=") && (o.dropFirst(2) == "0" || o.dropFirst(2) == "1") {
                    r.ssh = false   // TTSSH は無効にして、Tera Term にも /T= を読ませる
                    handled = false
                }
                if handled { continue }
            } else if l.hasPrefix("ssh://") || l.hasPrefix("ssh1://") || l.hasPrefix("ssh2://")
                        || l.hasPrefix("slogin://") || l.hasPrefix("slogin1://") || l.hasPrefix("slogin2://") {
                let colon = t.firstIndex(of: ":")!
                let before = t[t.index(before: colon)]
                if before == "1" { r.sshVersion = 1 } else if before == "2" { r.sshVersion = 2 }
                var p = String(t[t.index(colon, offsetBy: 3)...])
                if let slash = p.firstIndex(of: "/") { p = String(p[..<slash]) }
                if let at = p.firstIndex(of: "@") {
                    var userPart = String(p[..<at])
                    if let c = userPart.firstIndex(of: ":") {
                        r.password = percentDecode(String(userPart[userPart.index(after: c)...]))
                        userPart = String(userPart[..<c])
                    }
                    r.user = percentDecode(userPart)
                    p = String(p[p.index(after: at)...])
                }
                if (p.hasPrefix("[") && p.hasSuffix("]")) || (!p.hasPrefix("[") && !p.contains(":")) { p += ":22" }
                r.ssh = true
                t = p
            } else if let at = t.firstIndex(of: "@") {
                // user@host (TTSSH がユーザ名を取る)
                r.user = String(t[..<at])
                t = String(t[t.index(after: at)...])
            }

            // --- Tera Term 本体 (TTSSH が消したものは Tera Term には見えない) ---
            if hostNameFlag { justAfterHost = true; hostNameFlag = false }
            defer { justAfterHost = false }
            let u = t.uppercased()
            func val(_ n: Int) -> String { String(t.dropFirst(n)) }
            if u.hasPrefix("/SPEED=") { paramPort = .serial; r.baud = scanInt(val(7)) ?? 0
            } else if u.hasPrefix("/BAUD=") { paramPort = .serial; r.baud = scanInt(val(6)) ?? 0
            } else if u == "/B" { paramPort = .tcpip; paramBin = 1
            } else if u.hasPrefix("/C=") {
                paramPort = .serial
                let v = val(3)
                if v.hasPrefix("/") {
                    r.comDevice = v
                } else {
                    paramCom = scanInt(v) ?? 0
                    if paramCom < 1 || paramCom > maxComPort { paramCom = 0 }
                    comGiven = true
                }
            } else if u.hasPrefix("/CDATABIT=") { paramPort = .serial; r.dataBit = scanInt(val(10))
            } else if u.hasPrefix("/CPARITY=") { paramPort = .serial; r.parity = val(9).lowercased()
            } else if u.hasPrefix("/CSTOPBIT=") { paramPort = .serial; r.stopBit = val(10)
            } else if u.hasPrefix("/CFLOWCTRL=") { paramPort = .serial; r.flowCtrl = val(11).lowercased()
            } else if u.hasPrefix("/CDELAYPERCHAR=") { paramPort = .serial; r.delayPerChar = scanInt(val(15)) ?? 0
            } else if u.hasPrefix("/CDELAYPERLINE=") { paramPort = .serial; r.delayPerLine = scanInt(val(15)) ?? 0
            } else if u.hasPrefix("/FD=") { r.fileDir = val(4)
            } else if u.hasPrefix("/KR=") { r.kanjiRecv = val(4)
            } else if u.hasPrefix("/KT=") { r.kanjiSend = val(4)
            } else if u.hasPrefix("/L=") { r.logFile = val(3)
            } else if u.hasPrefix("/M=") { r.macro = val(3)
            } else if u.hasPrefix("/P=") { paramPort = .tcpip; paramTCP = parsePort(val(3))
            } else if u == "/PIPE" || u == "/NAMEDPIPE" { paramPort = .namedPipe
            } else if u == "/T=0" { paramPort = .tcpip; paramTel = 0
            } else if u == "/T=1" { paramPort = .tcpip; paramTel = 1
            } else if u.hasPrefix("/W=") { r.title = val(3)
            } else if u.hasPrefix("/TIMEOUT=") {
                if let v = scanInt(val(9)), v >= 0 { r.timeout = v }
            } else if t.hasPrefix("/") {
                r.unknown.append(t)
            } else if !t.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = t.trimmingCharacters(in: .whitespaces)
                let c = parsePort(trimmed)
                if justAfterHost && c > 0 {
                    paramTCP = c
                } else {
                    r.host = trimmed
                    if paramPort != .namedPipe {
                        paramPort = .tcpip
                        hostNameFlag = true
                    }
                }
            }
        }

        // TTProxy: ホストの指定がなければ protocol://proxy:port/realhost の realhost (SetConnectHostName)
        if r.host == nil, let rh = px.realHost, !rh.isEmpty {
            r.host = rh
            if paramPort == nil { paramPort = .tcpip }
        }
        if var h = r.host, paramPort == .tcpip {
            // ParseHostName
            let hl = h.lowercased()
            if hl.hasPrefix("telnet://") || hl.hasPrefix("tn3270://") {
                h = String(h.dropFirst(9))
                if h.hasSuffix("/") { h.removeLast() }
                r.telnetURL = true
            }
            var rest = Substring(h)
            if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
                let addr = String(h[h.index(after: h.startIndex)..<close])
                rest = h[h.index(after: close)...]
                if let c = rest.firstIndex(of: ":") { paramTCP = parsePort(String(rest[rest.index(after: c)...])) }
                else if r.telnetURL { paramTCP = 23 }
                h = addr
            } else if let c = h.firstIndex(of: ":") {
                paramTCP = parsePort(String(h[h.index(after: c)...]))
                h = String(h[..<c])
            } else if r.telnetURL {
                paramTCP = 23
            }
            r.host = h
        }

        r.portType = paramPort
        switch paramPort {
        case .tcpip?:
            if paramTCP != 0 { r.tcpPort = paramTCP }
            if paramTel < 2 { r.telnet = paramTel }
            if paramBin < 2 { r.telBin = paramBin == 1 }
        case .serial?:
            if comGiven && paramCom > 0 { r.comPort = paramCom } else if comGiven { r.comPort = 0 }
            if let b = r.baud, b == 0 { r.baud = nil }
        default:
            break
        }
        return r
    }

    // MARK: - どう接続するか (Mac 版の決まり)

    public enum TCPKind: Equatable { case ssh, telnet, raw }

    /// TCP のときの接続方法とポート。
    /// Tera Term は TERATERM.INI の [TTSSH] Enabled と TCPPort に従う。Mac 版の既定 (配布の TERATERM.INI と同じ考え方):
    /// - /ssh・ssh:// → SSH (ポートの指定がなければ 22)
    /// - /nossh・/telnet・/T=0・/T=1 → Telnet (/T=0 は Telnet ネゴシエーションなしの TCP)。ポートの指定がなければ 23
    /// - telnet:// → Telnet
    /// - どれもなければ: ポート 22 か指定なし → SSH、それ以外のポート (23 など) → Telnet
    public var tcpProtocol: (TCPKind, Int) {
        func telnetKind() -> TCPKind { telnet == 0 ? .raw : .telnet }
        if ssh == true { return (.ssh, tcpPort ?? 22) }
        if ssh == false || telnetURL { return (telnetKind(), tcpPort ?? 23) }
        if let p = tcpPort, p != 22 { return (telnetKind(), p) }
        return (.ssh, tcpPort ?? 22)
    }
}
