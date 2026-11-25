// TTProxy (TTProxy/ProxyWSockHook.h) のプロキシとのやりとり:
// begin_relay_http / begin_relay_socks4 / begin_relay_socks5 / begin_relay_telnet を、
// ソケットを持たない状態機械にしたもの (受け取ったバイトを渡すと、送るバイトと結果を返す)。
// Telnet / 生の TCP 接続 (Network.framework) と、ssh の ProxyCommand (--proxy-connect) の両方で使う。
// 元のコード: Copyright (C) 1999-2014 YebisuyaHompo, (C) 2004- TeraTerm Project (BSD 3-Clause)

import Foundation

/// TTProxy の設定のうち、接続に使うもの ([TTProxy] ProxyType / ProxyHost / ProxyPort / ProxyUser / ProxyPass /
/// ConnectionTimeout / SocksResolve / Telnet*Prompt)
public struct ProxyConfig: Equatable {
    public enum Kind: String { case none, http, telnet, socks4, socks5 }
    /// SocksResolve (RESOLVE_AUTO / RESOLVE_REMOTE / RESOLVE_LOCAL)
    public enum Resolve: String { case auto, remote, local }

    public var kind: Kind
    public var host: String
    /// ProxyPort (0 = 種類ごとの既定。ProxyInfo::getPort)
    public var port: Int
    public var user: String
    public var pass: String
    /// ConnectionTimeout (秒。0 = 待ち続ける)
    public var timeout: Int
    public var resolve: Resolve
    /// TelnetHostnamePrompt / TelnetUsernamePrompt / TelnetPasswordPrompt / TelnetConnectedMessage / TelnetErrorMessage
    public var telnetPrompts: [String]

    public static let defaultTelnetPrompts = [">> Host name: ", "Username:", "Password:", "-- Connected to ", "!!!!!!!!"]

    public init(kind: Kind, host: String, port: Int = 0, user: String = "", pass: String = "", timeout: Int = 10,
                resolve: Resolve = .auto, telnetPrompts: [String] = ProxyConfig.defaultTelnetPrompts) {
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
        self.pass = pass
        self.timeout = timeout
        self.resolve = resolve
        self.telnetPrompts = telnetPrompts
    }

    /// 設定の文字から (ProxyInfo::parseType: "socks" は SOCKS5。ホストがなければ使わない)
    public init(type: String, host: String, port: Int, user: String, pass: String, timeout: Int, resolve: String,
                telnetPrompts: [String]) {
        var k = Kind(rawValue: type.lowercased()) ?? (type.lowercased() == "socks" ? .socks5 : .none)
        if host.isEmpty { k = .none }
        self.init(kind: k, host: host, port: port, user: user, pass: pass, timeout: timeout,
                  resolve: Resolve(rawValue: resolve.lowercased()) ?? .auto,
                  telnetPrompts: telnetPrompts.count == 5 ? telnetPrompts : ProxyConfig.defaultTelnetPrompts)
    }

    public var isEnabled: Bool { kind != .none && !host.isEmpty }

    /// ProxyInfo::getPort: 0 なら SOCKS 1080 / TELNET 23 / HTTP 80
    public var effectivePort: Int {
        if port != 0 { return port }
        switch kind {
        case .socks4, .socks5: return 1080
        case .telnet: return 23
        case .http: return 80
        case .none: return 0
        }
    }

    // MARK: - 環境変数 (ssh の ProxyCommand で動かす --proxy-connect に渡す)

    public static let envPrefix = "TERAMAC_PROXY_"

    public var environment: [String: String] {
        var e: [String: String] = [
            "TYPE": kind.rawValue, "HOST": host, "PORT": String(port), "USER": user, "PASS": pass,
            "TIMEOUT": String(timeout), "RESOLVE": resolve.rawValue,
        ]
        for (i, p) in telnetPrompts.enumerated() { e["PROMPT\(i)"] = p }
        var r: [String: String] = [:]
        for (k, v) in e { r[ProxyConfig.envPrefix + k] = v }
        return r
    }

    public init?(environment env: [String: String]) {
        func g(_ k: String) -> String? { env[ProxyConfig.envPrefix + k] }
        guard let t = g("TYPE"), let h = g("HOST") else { return nil }
        let prompts = (0..<5).map { g("PROMPT\($0)") ?? ProxyConfig.defaultTelnetPrompts[$0] }
        self.init(type: t, host: h, port: Int(g("PORT") ?? "") ?? 0, user: g("USER") ?? "", pass: g("PASS") ?? "",
                  timeout: Int(g("TIMEOUT") ?? "") ?? 10, resolve: g("RESOLVE") ?? "auto", telnetPrompts: prompts)
    }
}

/// プロキシとのやりとり (接続先 realhost:realport への中継を頼む)
public final class ProxyHandshake {
    public enum Result: Equatable {
        /// 中継が始まった。leftover: プロキシの応答の後に続いて届いていたデータ (端末に渡す)
        case connected(leftover: [UInt8])
        case failed(String)
    }
    public struct Output: Equatable {
        public var send: [UInt8] = []
        public var result: Result?
        public init(send: [UInt8] = [], result: Result? = nil) {
            self.send = send
            self.result = result
        }
    }

    /// ja_JP.lng [TTProxy] MSG_PROXY_UNAUTHORIZED / MSG_PROXY_BAD_REQUEST
    public static var msgUnauthorized: String { Lang.t("TTProxy", "MSG_PROXY_UNAUTHORIZED", "プロキシの認証に失敗しました。") }
    public static var msgBadRequest: String { Lang.t("TTProxy", "MSG_PROXY_BAD_REQUEST", "プロキシの設定により接続できません。") }

    /// ホスト名をローカルで引く: IPv4 なら 4 バイト、IPv6 なら 16 バイト。ipv4Only は gethostbyname (SOCKS4)
    public typealias Resolver = (_ host: String, _ ipv4Only: Bool) -> [UInt8]?

    private let config: ProxyConfig
    private let realHost: String
    private let realPort: Int
    private let resolver: Resolver
    private var buf: [UInt8] = []
    private var finished = false

    private enum State {
        case httpStatus, httpHeaders(status: Int)
        case socks5Method, socks5Auth, socks5Reply
        case socks4Reply
        case telnet
    }
    private var state: State

    public init(config: ProxyConfig, host: String, port: Int, resolver: Resolver? = nil) {
        self.config = config
        realHost = host
        realPort = port
        self.resolver = resolver ?? ProxyHandshake.systemResolver
        switch config.kind {
        case .http, .none: state = .httpStatus
        case .socks5: state = .socks5Method
        case .socks4: state = .socks4Reply
        case .telnet: state = .telnet
        }
    }

    /// "[v6]:port" か "host:port" (strchr(realhost, ':'))
    private var hostPort: String { realHost.contains(":") ? "[\(realHost)]:\(realPort)" : "\(realHost):\(realPort)" }

    /// つないだ直後に送るもの
    public func start() -> Output {
        var o = Output()
        switch config.kind {
        case .none:
            o.result = .connected(leftover: [])
            finished = true
        case .http:
            var s = "CONNECT \(hostPort) HTTP/1.1\r\n"
            s += "Host: \(hostPort)\r\n"
            if !config.user.isEmpty {
                s += "Proxy-Authorization: Basic \(Data((config.user + ":" + config.pass).utf8).base64EncodedString())\r\n"
            }
            s += "\r\n"
            o.send = Array(s.utf8)
        case .socks5:
            // SOCKS5_AUTH_NOAUTH と、ユーザー名があれば SOCKS5_AUTH_USERPASS
            o.send = config.user.isEmpty ? [5, 1, 0] : [5, 2, 0, 2]
        case .socks4:
            switch socks4Request() {
            case .success(let b): o.send = b
            case .failure(let m): o.result = .failed(m.text); finished = true
            }
        case .telnet:
            break   // プロンプトを待つ
        }
        return o
    }

    /// プロキシから届いたバイト
    public func feed(_ bytes: [UInt8]) -> Output {
        guard !finished else { return Output() }
        buf += bytes
        var o = Output()
        process(&o)
        if o.result != nil { finished = true }
        return o
    }

    /// プロキシが切った (recv() == 0 は SOCKET_ERROR)
    public func closed() -> Output {
        guard !finished else { return Output() }
        finished = true
        var o = Output()
        if case .telnet = state {
            o.result = .failed(ProxyHandshake.msgBadRequest)
        } else {
            o.result = .failed(Lang.m("XFER_PROXY_CLOSED", "プロキシとの接続が切れました"))
        }
        return o
    }

    private struct Message: Error { let text: String }

    private func process(_ o: inout Output) {
        while o.result == nil {
            switch state {
            case .httpStatus:
                guard let line = takeLine() else { return }
                // status_code = atoi(strchr(buf, ' '))
                let s = String(decoding: line, as: UTF8.self)
                var code = 0
                if let sp = s.firstIndex(of: " ") {
                    let digits = s[s.index(after: sp)...].drop(while: { $0 == " " }).prefix(while: { $0.isASCII && $0.isNumber })
                    code = Int(digits) ?? 0
                }
                state = .httpHeaders(status: code)
            case .httpHeaders(let code):
                guard let line = takeLine() else { return }
                guard line == [0x0D, 0x0A] || line == [0x0A] else { continue }
                if code == 200 {
                    o.result = .connected(leftover: buf)
                    buf = []
                } else if code == 401 || code == 407 {
                    o.result = .failed(ProxyHandshake.msgUnauthorized)
                } else {
                    o.result = .failed(ProxyHandshake.msgBadRequest + "(HTTP: status code \(code))")
                }
            case .socks5Method:
                guard let b = take(2) else { return }
                if b[0] != 5 || b[1] == 0xFF { o.result = .failed(ProxyHandshake.msgBadRequest); return }
                switch b[1] {
                case 0:
                    appendSocks5Request(&o)
                case 2:
                    let u = Array(config.user.utf8.prefix(255)), p = Array(config.pass.utf8.prefix(255))
                    o.send += [1, UInt8(u.count)] + u + [UInt8(p.count)] + p
                    state = .socks5Auth
                default:
                    o.result = .failed(ProxyHandshake.msgBadRequest)
                }
            case .socks5Auth:
                guard let b = take(2) else { return }
                if b[1] != 0 { o.result = .failed(ProxyHandshake.msgUnauthorized); return }
                appendSocks5Request(&o)
            case .socks5Reply:
                guard buf.count >= 4 else { return }
                let ver = buf[0], rep = buf[1], atyp = buf[3]
                if ver != 5 || rep != 0 {
                    o.result = .failed(ProxyHandshake.msgBadRequest + "(SOCKS5:VER \(ver) REP \(rep) ATYP \(atyp))")
                    return
                }
                let need: Int
                switch atyp {
                case 1: need = 4 + 4 + 2
                case 3:
                    guard buf.count >= 5 else { return }
                    need = 4 + 1 + Int(buf[4]) + 2
                case 4: need = 4 + 16 + 2
                default: need = 4
                }
                guard buf.count >= need else { return }
                buf.removeFirst(need)
                o.result = .connected(leftover: buf)
                buf = []
            case .socks4Reply:
                guard let b = take(8) else { return }
                var m = ""
                if b[0] != 0 { m = ProxyHandshake.msgBadRequest }
                else if b[1] == 92 || b[1] == 93 { m = ProxyHandshake.msgUnauthorized }
                else if b[1] != 90 { m = ProxyHandshake.msgBadRequest }
                if !m.isEmpty {
                    o.result = .failed(m + "(SOCKS4:VN \(b[0]) CD \(b[1]))")
                } else {
                    o.result = .connected(leftover: buf)
                    buf = []
                }
            case .telnet:
                // wait_for_prompt: 行 (LF まで) ごと、または届いた分でプロンプトを探す (strstr)
                let nl = buf.firstIndex(of: 0x0A)
                let end = nl.map { $0 + 1 } ?? buf.count
                guard end > 0 else { return }
                let text = String(decoding: buf[0..<end], as: UTF8.self)
                var hit: Int?
                for (i, p) in config.telnetPrompts.enumerated() where !p.isEmpty && text.contains(p) { hit = i; break }
                guard let h = hit else {
                    if nl != nil { buf.removeFirst(end); continue }   // この行にはない: 次の行へ
                    return   // 行の途中: 続きを待つ
                }
                buf.removeFirst(end)
                switch h {
                case 0: o.send += Array("\(hostPort)\n".utf8)
                case 1: o.send += Array("\(config.user)\n".utf8)
                case 2: o.send += Array("\(config.pass)\n".utf8)
                case 3:
                    o.result = .connected(leftover: buf)
                    buf = []
                default:
                    o.result = .failed(ProxyHandshake.msgBadRequest)
                }
            }
        }
    }

    private func take(_ n: Int) -> [UInt8]? {
        guard buf.count >= n else { return nil }
        let r = Array(buf[0..<n])
        buf.removeFirst(n)
        return r
    }

    /// LF までの 1 行 (LF を含む)
    private func takeLine() -> [UInt8]? {
        guard let i = buf.firstIndex(of: 0x0A) else { return nil }
        let r = Array(buf[0...i])
        buf.removeFirst(i + 1)
        return r
    }

    private func appendSocks5Request(_ o: inout Output) {
        var r: [UInt8] = [5, 1, 0]
        let addr = config.resolve != .remote ? resolver(realHost, false) : nil
        if let a = addr, a.count == 4 || a.count == 16 {
            r.append(a.count == 4 ? 1 : 4)
            r += a
        } else if config.resolve == .local {
            o.result = .failed(Lang.m("XFER_HOST_NOT_FOUND", "ホスト %s が見つかりません", realHost))
            return
        } else {
            let name = Array(realHost.utf8.prefix(255))
            r += [3, UInt8(name.count)] + name
        }
        r += [UInt8((realPort >> 8) & 0xFF), UInt8(realPort & 0xFF)]
        o.send += r
        state = .socks5Reply
    }

    private func socks4Request() -> Swift.Result<[UInt8], Message> {
        var r: [UInt8] = [4, 1, UInt8((realPort >> 8) & 0xFF), UInt8(realPort & 0xFF)]
        var v4a = false
        // 数字で始まれば inet_addr
        if let c = realHost.first, c.isASCII, c.isNumber, let a = ProxyHandshake.ipv4(realHost) {
            r += a
        } else if config.resolve != .remote, let a = resolver(realHost, true), a.count == 4 {
            r += a
        } else if config.resolve == .local {
            return .failure(Message(text: Lang.m("XFER_HOST_NOT_FOUND", "ホスト %s が見つかりません", realHost))
)
        } else {
            r += [0, 0, 0, 1]   // SOCKS4a
            v4a = true
        }
        r += Array(config.user.utf8) + [0]
        if v4a { r += Array(realHost.utf8) + [0] }
        return .success(r)
    }

    /// inet_addr (INADDR_NONE なら nil)
    public static func ipv4(_ s: String) -> [UInt8]? {
        let a = inet_addr(s)
        guard a != INADDR_NONE else { return nil }
        return withUnsafeBytes(of: a) { Array($0) }   // ネットワークバイト順のまま
    }

    /// getaddrinfo / gethostbyname
    public static func systemResolver(_ host: String, _ ipv4Only: Bool) -> [UInt8]? {
        var hints = addrinfo()
        hints.ai_family = ipv4Only ? AF_INET : AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = first.pointee.ai_addr else { return nil }
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) }
            }
        case AF_INET6 where !ipv4Only:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
            }
        default:
            return nil
        }
    }
}
