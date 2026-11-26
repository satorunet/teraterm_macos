import Foundation
import Network
import Darwin
import TeraCore

/// 接続の種類 (Tera Term の「新しい接続」ダイアログに相当)
enum ConnectionSpec: Equatable {
    case ssh(host: String, port: Int, user: String, keyFile: String)
    case telnet(host: String, port: Int)
    case rawTCP(host: String, port: Int)
    case serial(SerialParams)
    case shell

    /// TCP/IP (ssh / Telnet / 生の TCP)。TTProxy を通るもの
    var isNetwork: Bool {
        switch self {
        case .ssh, .telnet, .rawTCP: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .ssh(let h, let p, let u, _):
            let who = u.isEmpty ? h : "\(u)@\(h)"
            return p == 22 ? who : "\(who):\(p)"
        case .telnet(let h, let p): return p == 23 ? h : "\(h):\(p)"
        case .rawTCP(let h, let p): return "\(h):\(p)"
        case .serial(let s): return "\((s.path as NSString).lastPathComponent) \(s.baud)"
        case .shell: return Lang.m("CONN_LOCAL_SHELL", "ローカルシェル")
        }
    }

    /// TTL の connect '...' やコマンドライン引数の書式から作る (Tera Term + TTSSH のコマンドライン。TTCommandLine)
    /// 例: "host:22 /ssh /user=root", "host /telnet", "host 23", "telnet://host:23", "ssh://user@host", "/C=1 /BAUD=9600"
    /// base: いまの接続 (ホストやポートの指定がなければこちらを使う)
    static func parse(_ text: String, base: ConnectionSpec? = nil) -> ConnectionSpec? {
        if TTCommandLine.tokens(text).contains(where: { $0.lowercased() == "/shell" }) { return .shell }
        return from(TTCommandLine.parse(text), base: base)
    }

    static func from(_ cl: TTCommandLine, base: ConnectionSpec? = nil) -> ConnectionSpec? {
        switch cl.portType {
        case .serial?:
            var s = SerialParams()
            if case .serial(let b)? = base { s = b } else {
                // FlowCtrlRTS / FlowCtrlDTR は設定 (ts) のまま (コマンドラインにはない)
                let h = ConnHistory.serial
                s.rts = h.rts; s.dtr = h.dtr
            }
            if let d = cl.comDevice {
                s.path = d
            } else if let n = cl.comPort {
                // Mac に COMn はないので、SerialPort.list() の n 番目 (1 から)。範囲外は今のポート (なければ最初のポート)
                let ports = SerialPort.list()
                if n >= 1 && n <= ports.count { s.path = ports[n - 1] }
            }
            if s.path.isEmpty { s.path = SerialPort.list().first ?? "" }
            if let v = cl.baud { s.baud = v }
            if let v = cl.dataBit, v == 7 || v == 8 { s.dataBits = v }
            if let v = cl.parity, ["none", "odd", "even", "mark", "space"].contains(v) { s.parity = v }
            if let v = cl.stopBit { s.stopBits = v == "1" ? 1 : 2 }
            if let v = cl.flowCtrl {
                switch v {
                case "x": s.flow = "xon"
                case "hard", "rtscts": s.flow = "rts"
                case "dsrdtr": s.flow = "dsr"
                default: s.flow = "none"
                }
            }
            return s.path.isEmpty ? nil : .serial(s)
        case .tcpip?:
            guard let host = cl.host, !host.isEmpty else {
                // /P= や /T= だけ: 今のホストを使う
                guard let b = base else { return nil }
                switch b {
                case .ssh(let h, _, _, _), .telnet(let h, _), .rawTCP(let h, _):
                    var c2 = cl; c2.host = h
                    return from(c2, base: nil)
                default: return nil
                }
            }
            let (kind, port) = cl.tcpProtocol
            switch kind {
            case .ssh: return .ssh(host: host, port: port, user: cl.user ?? "", keyFile: cl.keyFile ?? "")
            case .telnet: return .telnet(host: host, port: port)
            case .raw: return .rawTCP(host: host, port: port)
            }
        default:
            return base
        }
    }

    /// ssh に足す引数 (/auth= /timeout=)。TTSSH の認証方法の指定に近いもの
    static func sshArguments(_ cl: TTCommandLine) -> [String] {
        var a: [String] = []
        switch cl.auth {
        case "password"?: a += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
        case "publickey"?, "pageant"?: a += ["-o", "PreferredAuthentications=publickey"]
        case "challenge"?, "keyboard-interactive"?: a += ["-o", "PreferredAuthentications=keyboard-interactive"]
        default: break
        }
        if let t = cl.timeout, t > 0 { a += ["-o", "ConnectTimeout=\(t)"] }
        return a
    }
}

struct SerialParams: Equatable {
    var path = ""
    var baud = 9600
    var dataBits = 8
    var parity = "none"     // none / odd / even / mark / space (mark / space は SerialLineMode で作る)
    var stopBits = 1
    var flow = "none"       // none / xon / rts
    /// FlowCtrlRTS / FlowCtrlDTR (#934 e4ddcf535 / 92ab12cf1): 0 Disable, 1 Enable, 2 Handshake, 3 Toggle (RTS だけ)
    var rts = 1
    var dtr = 1

    /// ttset.c _ReadIniFile: INI にないときはフロー制御から決める (RTS/CTS なら RTS は Handshake、DSR/DTR なら DTR は Handshake)
    static func defaultRTS(flow: String) -> Int { flow == "rts" ? SerialParams.handshake : SerialParams.enable }
    static func defaultDTR(flow: String) -> Int { flow == "dsr" ? SerialParams.handshake : SerialParams.enable }
    /// tttypes.h IdDisable / IdEnable / IdHandshake / IdToggle
    static let disable = 0, enable = 1, handshake = 2, toggle = 3
}

protocol Connection: AnyObject {
    var onData: (([UInt8]) -> Void)? { get set }
    var onClose: ((String?) -> Void)? { get set }
    /// つながった (waitsForConnection のときだけ呼ばれる)
    var onConnected: (() -> Void)? { get set }
    /// start() のあと、つながるまで待つもの (TCP・ssh)。false ならすぐ使える
    var waitsForConnection: Bool { get }
    func start() throws
    func write(_ bytes: [UInt8])
    /// binary: Telnet の CommBinaryOut (CR はいつも CR NUL)。false は CommTextOut (CR LF はそのまま)
    func write(_ bytes: [UInt8], binary: Bool)
    func resize(cols: Int, rows: Int)
    func close()
    func sendBreak()
    /// 端末リセットのとき (commlib.c CommLock(FALSE)): 止めていた相手に送信を再開させる
    func unlock()
}

extension Connection {
    func write(_ bytes: [UInt8], binary: Bool) { write(bytes) }
    func unlock() {}
}

struct ConnError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

// MARK: - 疑似端末で外部コマンドを動かす (ssh / ローカルシェル)

final class PTYConnection: Connection {
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?
    var onConnected: (() -> Void)?
    /// ssh: 最初に何か出したら「つながった」とする (ssh 自身のエラー "ssh: ..." は除く。失敗なら ssh が終わる)
    let waitsForConnection: Bool
    private var reportedReady = false
    private let argv: [String]
    private var env: [String: String]
    private var master: Int32 = -1
    private var pid: pid_t = 0
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "pty.read", qos: .userInteractive)
    private var initialSize: winsize
    private var closed = false
    /// 最後に出た文字 (ssh が失敗して終わったとき、理由の行を拾う)
    private var tail: [UInt8] = []
    /// ssh 自身が失敗して終わった (終了コード 255)。認証失敗なども含む
    private(set) var sshFailed = false
    /// 端末に出す 1 行の理由 (ssh のエラー行は ssh 自身がもう端末に出している)
    private(set) var sshFailSummary = ""
    /// HOME_CHDIR: ホームディレクトリで始める (false ならアプリのいまのフォルダのまま)
    var chdirHome = true

    init(argv: [String], cols: Int, rows: Int, extraEnv: [String: String] = [:], waitForOutput: Bool = false) {
        self.argv = argv
        waitsForConnection = waitForOutput
        var e = ProcessInfo.processInfo.environment
        e["TERM"] = "xterm-256color"
        e["COLORTERM"] = "truecolor"
        e["LANG"] = e["LANG"] ?? "ja_JP.UTF-8"
        e["TERM_PROGRAM"] = "TeraMac"
        for (k, v) in extraEnv { e[k] = v }
        self.env = e
        initialSize = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    func start() throws {
        // fork 後の子プロセスではメモリ確保できないので、先に C 文字列を用意しておく
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let home = strdup(chdirHome ? NSHomeDirectory() : FileManager.default.currentDirectoryPath)
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(home)
        }
        var m: Int32 = -1
        var ws = initialSize
        let p = forkpty(&m, nil, nil, &ws)
        if p < 0 { throw ConnError(msg: Lang.m("CONN_PTY_FAILED", "疑似端末を作れませんでした (errno %d)", errno)) }
        if p == 0 {
            _ = chdir(home)
            cArgs.withUnsafeBufferPointer { a in
                cEnv.withUnsafeBufferPointer { e in
                    _ = execve(a[0]!, a.baseAddress, e.baseAddress)
                }
            }
            _exit(127)
        }
        pid = p
        master = m
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        source = src
        src.resume()
    }

    /// 読む側のバッファ (毎回 64KB を確保して 0 で埋めない)
    private var readBuf = [UInt8](repeating: 0, count: 65536)
    /// メインスレッドに渡す前にためておく分。渡す処理がまだ走っていなければ 1 回だけ頼む
    private var pending: [UInt8] = []
    private var deliverScheduled = false
    private let pendingLock = NSLock()

    private func readAvailable() {
        // 出せるだけまとめて読む (pty は 1 回に 1KB 程度しか返さないので、そのつどメインへ渡すと遅い)
        var got: [UInt8] = []
        var eof = false
        while true {
            let n = readBuf.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if n > 0 { got.append(contentsOf: readBuf[0..<n]); if got.count >= 1 << 20 { break } }
            else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { eof = true; break }
            else if errno == EINTR { continue }
            else { break }
        }
        if !got.isEmpty {
            pendingLock.lock()
            pending.append(contentsOf: got)
            let schedule = !deliverScheduled
            deliverScheduled = true
            pendingLock.unlock()
            if schedule { DispatchQueue.main.async { self.deliver() } }
        }
        if eof { finish() }
    }

    private func deliver() {
        pendingLock.lock()
        let chunk = pending
        pending = []
        deliverScheduled = false
        pendingLock.unlock()
        guard !chunk.isEmpty else { return }
        if waitsForConnection && !reportedReady {
            let head = String(decoding: chunk.prefix(5), as: UTF8.self)
            if head != "ssh: " {
                reportedReady = true
                onConnected?()
            }
        }
        if waitsForConnection {
            tail.append(contentsOf: chunk.suffix(4096))
            if tail.count > 4096 { tail.removeFirst(tail.count - 4096) }
        }
        onData?(chunk)
    }

    private func finish() {
        source?.cancel()
        source = nil
        var status: Int32 = 0
        if pid > 0 { waitpid(pid, &status, 0) }
        let code = (status >> 8) & 0xFF
        DispatchQueue.main.async {
            guard !self.closed else { return }
            self.deliver()
            self.closed = true
            if self.master >= 0 { Darwin.close(self.master); self.master = -1 }
            if code == 255 && self.waitsForConnection {
                self.sshFailed = true
                let hint = PTYConnection.sshHint(self.tail)
                self.sshFailSummary = Lang.m("MENU_CONNECT_FAILED", "接続できませんでした") + ": "
                    + (hint.isEmpty ? "ssh " + Lang.m("CONN_EXIT_CODE", "終了コード %d", code) : hint)
                self.onClose?(PTYConnection.sshReason(self.tail, code: code))
                return
            }
            self.onClose?(code == 0 ? nil : Lang.m("CONN_EXIT_CODE", "終了コード %d", code))
        }
    }

    /// ssh の最後のエラー行 + わかりやすい説明
    static func sshLastLine(_ out: [UInt8]) -> String {
        var text = String(decoding: out, as: UTF8.self)
        if let re = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]") {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        let lines = text.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasSuffix("password:") && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last ?? ""
    }

    static func sshHint(_ out: [UInt8]) -> String {
        let l = sshLastLine(out).lowercased()
        var hint = ""
        if l.contains("permission denied") || l.contains("too many authentication failures") {
            hint = Lang.m("SSH_FAIL_AUTH", "認証に失敗しました。ユーザー名・パスワード・鍵を確かめてください。")
        } else if l.contains("connection refused") {
            hint = Lang.m("SSH_FAIL_REFUSED", "相手が接続を拒否しました。ポート番号や、相手で SSH が動いているかを確かめてください。")
        } else if l.contains("timed out") {
            hint = Lang.m("SSH_FAIL_TIMEOUT", "時間内に応答がありませんでした。アドレス・ネットワーク・ファイアウォールを確かめてください。")
        } else if l.contains("could not resolve hostname") {
            hint = Lang.m("SSH_FAIL_RESOLVE", "ホスト名が見つかりませんでした。")
        } else if l.contains("host key verification failed") || l.contains("remote host identification has changed") {
            hint = Lang.m("SSH_FAIL_HOSTKEY", "ホスト鍵の確認に失敗しました (~/.ssh/known_hosts と違います)。")
        } else if l.contains("no route to host") || l.contains("network is unreachable") {
            hint = Lang.m("SSH_FAIL_ROUTE", "相手まで届きません。ネットワークを確かめてください。")
        } else if l.contains("connection closed") || l.contains("connection reset") {
            hint = Lang.m("SSH_FAIL_CLOSED", "相手に接続を切られました。")
        }
        return hint
    }

    static func sshReason(_ out: [UInt8], code: Int32) -> String {
        let last = sshLastLine(out), hint = sshHint(out)
        let codeText = Lang.m("CONN_EXIT_CODE", "終了コード %d", code)
        if last.isEmpty { return hint.isEmpty ? "ssh: " + codeText : hint + "\n(ssh " + codeText + ")" }
        return (hint.isEmpty ? "" : hint + "\n\n") + last + "\n(ssh " + codeText + ")"
    }

    func write(_ bytes: [UInt8]) {
        guard master >= 0 else { return }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, $0.count) }
            if n > 0 { off += n } else if errno == EAGAIN { usleep(1000) } else { break }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard master >= 0 else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &ws)
    }

    func close() {
        guard !closed else { return }
        if pid > 0 { kill(pid, SIGHUP) }
        let p = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if p > 0 { kill(p, SIGKILL) }
        }
    }

    func sendBreak() {
        if master >= 0 { tcsendbreak(master, 0) }
    }
}

// MARK: - TCP (Telnet / 生の TCP)

final class TCPConnection: Connection {
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?
    private let host: String
    private let port: Int
    private let telnet: Bool
    private var conn: NWConnection?
    private var cols = 80, rows = 24
    private var nawsEnabled = false
    /// TelBinRecv / TelBinSend (BINARY オプションが有効)
    private var binaryRecv = false
    private var binarySend = false
    /// 受信した CR の直後の NUL を捨てる (CommRead1Byte の TelCRFlag)
    private var crFlag = false
    private var closed = false
    var onConnected: (() -> Void)?
    let waitsForConnection = true
    /// /B (TelBin): BINARY を自分から申し込む
    var requestBinary = false
    /// こちらから WILL BINARY / DO BINARY を送って返事を待っている (返事にまた WILL / DO を返さない)
    private var sentWillBinary = false
    private var sentDoBinary = false
    /// /timeout= (秒)。0 は OS 任せ
    var timeout = 0
    private var ready = false
    /// TermType (TERMINAL-TYPE のサブネゴシエーションで送る端末の種類)
    var termType = "xterm-256color"
    /// TelKeepAliveInterval (秒。0 = 送らない): 最後に送ってからこれだけたったら IAC NOP を送る
    var keepAliveInterval = 0
    /// TTProxy: プロキシを通して接続する (nil / none ならじかに)
    var proxy: ProxyConfig?
    private var handshake: ProxyHandshake?
    private let queue = DispatchQueue(label: "tcp")
    private var keepAliveTimer: DispatchSourceTimer?
    /// cv.LastSendTime
    private var lastSendTime = Date()
    private let sendLock = NSLock()
    /// ts.TelPort: この番号のときだけこちらからネゴシエーションを始める (OnCommStart)
    private static let telPort = 23

    // Telnet 受信の状態
    private enum TState { case data, iac, opt(UInt8), sb, sbIac }
    private var tstate: TState = .data
    private var sbBuf: [UInt8] = []

    private let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251
    private let SB: UInt8 = 250, SE: UInt8 = 240, NOP: UInt8 = 241
    private let OPT_BINARY: UInt8 = 0, OPT_ECHO: UInt8 = 1, OPT_SGA: UInt8 = 3, OPT_TTYPE: UInt8 = 24, OPT_NAWS: UInt8 = 31

    init(host: String, port: Int, telnet: Bool, cols: Int, rows: Int) {
        self.host = host; self.port = port; self.telnet = telnet
        self.cols = cols; self.rows = rows
    }

    func start() throws {
        let viaProxy = proxy?.isEnabled == true
        // IDN (#1493): プロキシのホスト名も ACE 形式で引く (TTProxy 1.0.0.28)
        let destHost = viaProxy ? IDN.hostNameToASCII(proxy!.host) : host
        let destPort = viaProxy ? proxy!.effectivePort : port
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: destPort)), destPort > 0 else { throw ConnError(msg: Lang.m("CONN_BAD_PORT", "ポート番号がおかしいです")) }
        let c = NWConnection(host: NWEndpoint.Host(destHost), port: p, using: .tcp)
        conn = c
        let q = queue
        // プロキシのときは ConnectionTimeout (TTProxy) も使う
        let limit = timeout > 0 ? timeout : (viaProxy ? proxy!.timeout : 0)
        if limit > 0 {
            q.asyncAfter(deadline: .now() + .seconds(limit)) { [weak self] in
                guard let self = self, !self.ready else { return }
                self.finish(Lang.m("CONN_CONNECT_TIMEOUT", "接続できませんでした: タイムアウト (%d 秒)", limit))
                c.cancel()
            }
        }
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                if viaProxy { self.beginProxy() } else { self.didConnect(leftover: []) }
            case .failed(let e):
                self.finish(Lang.m("CONN_CONNECT_FAILED_DETAIL", "接続できませんでした: %s", e.localizedDescription))
            case .waiting(let e):
                self.finish(Lang.m("CONN_CONNECT_FAILED_DETAIL", "接続できませんでした: %s", e.localizedDescription))
                c.cancel()
            case .cancelled:
                self.finish(nil)
            default: break
            }
        }
        c.start(queue: q)
    }

    /// つながった (プロキシのときは中継が始まった)。leftover: プロキシの応答に続いて届いていたもの
    private func didConnect(leftover: [UInt8]) {
        ready = true
        DispatchQueue.main.async { if !self.closed { self.onConnected?() } }
        if telnet && port == TCPConnection.telPort {
            // OnCommStart: Telnet でポートが TelPort のときだけ、こちらからネゴシエーションを始める
            var opts: [UInt8] = [IAC, WILL, OPT_TTYPE, IAC, WILL, OPT_NAWS, IAC, DO, OPT_SGA, IAC, DO, OPT_ECHO]
            if requestBinary {
                opts += [IAC, WILL, OPT_BINARY, IAC, DO, OPT_BINARY]
                sentWillBinary = true; sentDoBinary = true
            }
            sendRaw(opts)
            startKeepAlive()   // TelStartKeepAliveThread
        }
        if !leftover.isEmpty {
            let bytes = telnet ? telnetFilter(leftover) : leftover
            if !bytes.isEmpty { DispatchQueue.main.async { self.onData?(bytes) } }
        }
        receive()
    }

    // MARK: プロキシ (TTProxy の hooked connect → begin_relay_*)

    private func beginProxy() {
        guard let cfg = proxy else { didConnect(leftover: []); return }
        let h = ProxyHandshake(config: cfg, host: host, port: port)
        handshake = h
        handleProxy(h.start())
    }

    private func handleProxy(_ o: ProxyHandshake.Output) {
        if !o.send.isEmpty { conn?.send(content: Data(o.send), completion: .contentProcessed { _ in }) }
        switch o.result {
        case .connected(let rest)?:
            handshake = nil
            didConnect(leftover: rest)
        case .failed(let m)?:
            handshake = nil
            finish(Lang.m("CONN_CONNECT_FAILED_DETAIL", "接続できませんでした: %s", m))
            conn?.cancel()
        case nil:
            conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self = self, let h = self.handshake else { return }
                var out = ProxyHandshake.Output()
                if let d = data, !d.isEmpty { out = h.feed([UInt8](d)) }
                if out.result == nil && (done || err != nil) {
                    let c = h.closed()
                    out.send += c.send
                    out.result = c.result
                }
                self.handleProxy(out)
            }
        }
    }

    // MARK: Telnet Keep-alive (telnet.c TelKeepAliveThread / TelSendNOP)

    private func startKeepAlive() {
        guard keepAliveInterval > 0, keepAliveTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self = self, !self.closed, self.keepAliveInterval > 0 else { return }
            self.sendLock.lock()
            let last = self.lastSendTime
            self.sendLock.unlock()
            if Date().timeIntervalSince(last) >= Double(self.keepAliveInterval) { self.sendRaw([self.IAC, self.NOP]) }
        }
        keepAliveTimer = t
        t.resume()
    }

    private func finish(_ msg: String?) {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        DispatchQueue.main.async {
            guard !self.closed else { return }
            self.closed = true
            self.onClose?(msg)
        }
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                let bytes = self.telnet ? self.telnetFilter([UInt8](d)) : [UInt8](d)
                if !bytes.isEmpty { DispatchQueue.main.async { self.onData?(bytes) } }
            }
            if done || err != nil {
                self.conn?.cancel()
                self.finish(nil)
                return
            }
            self.receive()
        }
    }

    private func telnetFilter(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for b in input {
            switch tstate {
            case .data:
                if crFlag {
                    crFlag = false
                    if b == 0 { continue }   // CR NUL の NUL
                }
                if b == IAC { tstate = .iac }
                else {
                    out.append(b)
                    if b == 0x0D && !binaryRecv { crFlag = true }
                }
            case .iac:
                switch b {
                case IAC: out.append(IAC); tstate = .data
                case DO, DONT, WILL, WONT: tstate = .opt(b)
                case SB: sbBuf = []; tstate = .sb
                default: tstate = .data
                }
            case .opt(let verb):
                negotiate(verb, b)
                tstate = .data
            case .sb:
                if b == IAC { tstate = .sbIac } else { sbBuf.append(b) }
            case .sbIac:
                if b == SE {
                    subnegotiation(sbBuf)
                    tstate = .data
                } else {
                    sbBuf.append(b); tstate = .sb
                }
            }
        }
        return out
    }

    private func negotiate(_ verb: UInt8, _ opt: UInt8) {
        switch verb {
        case DO:
            if opt == OPT_BINARY && sentWillBinary {
                sentWillBinary = false; binarySend = true   // こちらの WILL への返事
            } else if opt == OPT_TTYPE || opt == OPT_SGA || opt == OPT_BINARY {
                if opt == OPT_BINARY { binarySend = true }
                sendRaw([IAC, WILL, opt])
            } else if opt == OPT_NAWS {
                sendRaw([IAC, WILL, opt]); nawsEnabled = true; sendNAWS()
            } else {
                sendRaw([IAC, WONT, opt])
            }
        case DONT:
            if opt == OPT_BINARY && sentWillBinary { sentWillBinary = false; binarySend = false; break }   // 断られた
            if opt == OPT_NAWS { nawsEnabled = false }
            if opt == OPT_BINARY { binarySend = false }
            sendRaw([IAC, WONT, opt])
        case WILL:
            if opt == OPT_BINARY && sentDoBinary {
                sentDoBinary = false; binaryRecv = true   // こちらの DO への返事
            } else if opt == OPT_ECHO || opt == OPT_SGA || opt == OPT_BINARY {
                if opt == OPT_BINARY { binaryRecv = true }
                sendRaw([IAC, DO, opt])
            } else {
                sendRaw([IAC, DONT, opt])
            }
        case WONT:
            if opt == OPT_BINARY && sentDoBinary { sentDoBinary = false; binaryRecv = false; break }   // 断られた
            if opt == OPT_BINARY { binaryRecv = false }
            sendRaw([IAC, DONT, opt])
        default: break
        }
    }

    private func subnegotiation(_ b: [UInt8]) {
        if b.count >= 2 && b[0] == OPT_TTYPE && b[1] == 1 {
            // ts.TermType をそのまま送る
            sendRaw([IAC, SB, OPT_TTYPE, 0] + Array(termType.utf8) + [IAC, SE])
        }
    }

    private func sendNAWS() {
        guard nawsEnabled else { return }
        func esc(_ v: Int) -> [UInt8] {
            let hi = UInt8((v >> 8) & 0xFF), lo = UInt8(v & 0xFF)
            return (hi == IAC ? [IAC, IAC] : [hi]) + (lo == IAC ? [IAC, IAC] : [lo])
        }
        sendRaw([IAC, SB, OPT_NAWS] + esc(cols) + esc(rows) + [IAC, SE])
    }

    private func sendRaw(_ b: [UInt8]) {
        sendLock.lock()
        lastSendTime = Date()
        sendLock.unlock()
        conn?.send(content: Data(b), completion: .contentProcessed { _ in })
    }

    func write(_ bytes: [UInt8]) { write(bytes, binary: false) }

    /// ttcmn_buff.c: IAC は二重にする。CR は TelBinSend でなければ CR NUL。
    /// テキスト (CommTextOut / OutControl) は改行コード CR のときだけ CR NUL で、CR+LF はそのまま。
    /// バイナリ (CommBinaryOut) はどの CR も CR NUL (CR LF も CR NUL LF)
    func write(_ bytes: [UInt8], binary: Bool) {
        guard telnet else { sendRaw(bytes); return }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            out.append(b)
            if b == IAC { out.append(IAC) }
            else if b == 0x0D && !binarySend {
                let lf = i + 1 < bytes.count && bytes[i + 1] == 0x0A
                if binary || !lf { out.append(0x00) }
            }
            i += 1
        }
        sendRaw(out)
    }

    /// Are You There (コントロールメニュー)
    func sendAreYouThere() {
        if telnet { sendRaw([IAC, 246]) }
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
        if telnet { sendNAWS() }
    }

    func close() {
        conn?.cancel()
    }

    /// TelSendBreak: Telnet でなくても IAC BREAK を送る (Tera Term と同じ)
    func sendBreak() {
        sendRaw([IAC, 243])
    }

    /// CommLock(FALSE): TCP では XON を送る
    func unlock() { sendRaw([0x11]) }

    /// Telnet のネゴシエーションをしている (cv.TelFlag)
    var isTelnet: Bool { telnet }
}

// MARK: - シリアルポート

enum SerialPort {
    static func list() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming-Port") }
            .sorted()
            .map { "/dev/" + $0 }
    }

    static let baudRates = [110, 300, 600, 1200, 2400, 4800, 9600, 14400, 19200, 38400, 57600, 115200,
                            230400, 460800, 921600]
}

final class SerialConnection: Connection {
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?
    var onConnected: (() -> Void)?
    let waitsForConnection = false
    /// いまの設定 (setbaud・設定の変更でも変わる。ポートは変わらない)
    private(set) var params: SerialParams
    /// マーク / スペースのパリティのためのバイトの直し方 (SerialLineMode)
    private var lineModeValue = SerialLineMode(dataBits: 8, parity: "none", stopBits: 1)
    private let lineModeLock = NSLock()
    private var lineMode: SerialLineMode {
        get { lineModeLock.lock(); defer { lineModeLock.unlock() }; return lineModeValue }
        set { lineModeLock.lock(); lineModeValue = newValue; lineModeLock.unlock() }
    }
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "serial.read")
    private var closed = false
    /// 1 文字ごとの送信遅延 (ミリ秒)
    var charDelayMs = 0
    var lineDelayMs = 0
    private let writeQueue = DispatchQueue(label: "serial.write")

    init(params: SerialParams) { self.params = params; flow = params.flow }

    func start() throws {
        fd = open(params.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 {
            let e = errno
            throw ConnError(msg: Lang.m("CONN_SERIAL_OPEN_FAILED", "%s を開けませんでした: %s", params.path, String(cString: strerror(e))) +
                            (e == EBUSY ? "\n" + Lang.m("CONN_SERIAL_BUSY", "(ほかのアプリが使っています)") : ""))
        }
        _ = ioctl(fd, TIOCEXCL)
        try configure()
        // CommResetSerial: dcb.fRtsControl = FlowCtrlRTS / fDtrControl = FlowCtrlDTR (#934)
        applyModemLines()
        tcflush(fd, TCIOFLUSH)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        source = src
        src.resume()
    }

    /// いまの速度 (setbaud で変わる)
    private lazy var currentBaud = params.baud

    /// ポートの設定 (速度・データ・パリティ・ストップ・フロー制御) をかける。開いたときとポートのリセットで使う
    private func configure() throws {
        var t = termios()
        if tcgetattr(fd, &t) != 0 { throw ConnError(msg: Lang.m("CONN_SERIAL_GETATTR_FAILED", "ポートの設定を読めませんでした")) }
        guard let mode = SerialLineMode.make(dataBits: params.dataBits, parity: params.parity, stopBits: params.stopBits) else {
            throw ConnError(msg: Lang.m("CONN_SERIAL_UNSUPPORTED_FORMAT", "%d ビット・パリティ %s は Mac のシリアルポートでは使えません", params.dataBits, params.parity))
        }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE)
        switch mode.dataBits {
        case 5: t.c_cflag |= tcflag_t(CS5)
        case 6: t.c_cflag |= tcflag_t(CS6)
        case 7: t.c_cflag |= tcflag_t(CS7)
        default: t.c_cflag |= tcflag_t(CS8)
        }
        t.c_cflag &= ~tcflag_t(PARENB | PARODD)
        if mode.parity == "even" { t.c_cflag |= tcflag_t(PARENB) }
        if mode.parity == "odd" { t.c_cflag |= tcflag_t(PARENB | PARODD) }
        if mode.stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) } else { t.c_cflag &= ~tcflag_t(CSTOPB) }
        t.c_cflag &= ~tcflag_t(CRTSCTS | CDTR_IFLOW | CDSR_OFLOW)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        // commlib.c CommResetSerial (#934): 送信側 (fOutxCtsFlow / fOutxDsrFlow) はフロー制御で、
        // 受信側 (RTS / DTR の Handshake) は FlowCtrlRTS / FlowCtrlDTR で決める
        if flow == "rts" { t.c_cflag |= tcflag_t(CCTS_OFLOW) }
        if params.rts == SerialParams.handshake { t.c_cflag |= tcflag_t(CRTS_IFLOW) }
        if flow == "xon" { t.c_iflag |= tcflag_t(IXON | IXOFF) }
        if flow == "dsr" { t.c_cflag |= tcflag_t(CDSR_OFLOW) }
        if params.dtr == SerialParams.handshake { t.c_cflag |= tcflag_t(CDTR_IFLOW) }
        // VMIN/VTIME: 届いた分だけすぐ返す
        withUnsafeMutablePointer(to: &t.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1; cc[Int(VTIME)] = 0
            }
        }
        cfsetspeed(&t, speed_t(currentBaud))
        if tcsetattr(fd, TCSANOW, &t) != 0 {
            // 標準外の速度は IOSSIOSPEED で設定する
            cfsetspeed(&t, speed_t(B9600))
            _ = tcsetattr(fd, TCSANOW, &t)
        }
        var sp = speed_t(currentBaud)
        let IOSSIOSPEED: UInt = 0x8008_5402
        if ioctl(fd, IOSSIOSPEED, &sp) != 0 && tcsetattr(fd, TCSANOW, &t) != 0 {
            throw ConnError(msg: Lang.m("CONN_SERIAL_BAUD_FAILED", "通信速度 %d に設定できませんでした", currentBaud))
        }
        lineMode = mode
    }

    /// 開いたままデータ長・パリティ・ストップビットを変える (CommResetSerial と同じく設定をかけ直す)
    @discardableResult
    func setLineParams(dataBits: Int, parity: String, stopBits: Int) -> Bool {
        guard fd >= 0 else { return false }
        let old = params
        params.dataBits = dataBits
        params.parity = parity
        params.stopBits = stopBits
        do {
            try configure()
            return true
        } catch {
            params = old
            try? configure()
            return false
        }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            let chunk = lineMode.receive(Array(buf[0..<n]))
            DispatchQueue.main.async { self.onData?(chunk) }
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            // USB シリアルを抜いたときなど
            DispatchQueue.main.async { self.shutdown(msg: Lang.m("CONN_SERIAL_DISCONNECTED", "ポートが切断されました")) }
        }
    }

    func write(_ bytes: [UInt8]) {
        let f = fd
        let cd = charDelayMs, ld = lineDelayMs
        let toggle = params.rts == SerialParams.toggle
        writeQueue.async {
            guard f >= 0 else { return }
            let bytes = self.lineMode.transmit(bytes)
            // RTS_CONTROL_TOGGLE: 送っている間だけ RTS を上げる
            var rtsBit: Int32 = TIOCM_RTS
            if toggle { _ = ioctl(f, TIOCMBIS, &rtsBit) }
            defer { if toggle { tcdrain(f); _ = ioctl(f, TIOCMBIC, &rtsBit) } }
            if cd == 0 && ld == 0 {
                var off = 0
                var tries = 0
                while off < bytes.count && tries < 2000 {
                    let n = bytes[off...].withUnsafeBufferPointer { Darwin.write(f, $0.baseAddress, $0.count) }
                    if n > 0 { off += n; tries = 0 } else { tries += 1; usleep(1000) }
                }
            } else {
                for b in bytes {
                    var c = b
                    var tries = 0
                    while Darwin.write(f, &c, 1) != 1 && tries < 2000 { tries += 1; usleep(1000) }
                    if cd > 0 { usleep(useconds_t(cd * 1000)) }
                    if b == 0x0D && ld > 0 { usleep(useconds_t(ld * 1000)) }
                }
            }
        }
    }

    func resize(cols: Int, rows: Int) {}

    /// ブレークの長さ (SendBreakTime、ミリ秒)
    var breakMs = 1000

    /// CommSendBreak: ブレークを SendBreakTime ミリ秒出す。送信の順番を守るため送信のキューで行う
    func sendBreak() {
        let f = fd, ms = breakMs
        writeQueue.async {
            guard f >= 0 else { return }
            _ = ioctl(f, TIOCSBRK)
            usleep(useconds_t(max(0, ms) * 1000))
            _ = ioctl(f, TIOCCBRK)
        }
    }

    /// ポートのリセット (CommResetSerial): 送受信のバッファを捨てて、ポートの設定をかけ直す
    func resetPort() {
        guard fd >= 0 else { return }
        tcflush(fd, TCIOFLUSH)
        try? configure()
        tcflush(fd, TCIOFLUSH)
    }

    /// CommLock(FALSE): ハードウェアのフロー制御なら RTS (DSR/DTR なら DTR) を上げ、それ以外は XON を送る
    func unlock() {
        guard fd >= 0 else { return }
        switch flow {
        case "rts": var b: Int32 = TIOCM_RTS; _ = ioctl(fd, TIOCMBIS, &b)
        case "dsr": var b: Int32 = TIOCM_DTR; _ = ioctl(fd, TIOCMBIS, &b)
        default: write([0x11])
        }
    }

    // MARK: - マクロからの操作 (setbaud / setdtr / setrts / setflowctrl / getmodemstatus)

    private(set) var flow = "none"

    @discardableResult
    func setBaud(_ baud: Int) -> Bool {
        guard fd >= 0, baud > 0 else { return false }
        currentBaud = baud
        params.baud = baud
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return false }
        cfsetspeed(&t, speed_t(baud))
        if tcsetattr(fd, TCSANOW, &t) == 0 { return true }
        var sp = speed_t(baud)
        let IOSSIOSPEED: UInt = 0x8008_5402
        return ioctl(fd, IOSSIOSPEED, &sp) == 0
    }

    /// 1: XON/XOFF 2: RTS/CTS 3: なし 4: DSR/DTR (Tera Term の番号)
    @discardableResult
    func setFlow(_ mode: Int) -> Bool {
        guard fd >= 0, (1...4).contains(mode) else { return false }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return false }
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        t.c_cflag &= ~tcflag_t(CDTR_IFLOW | CDSR_OFLOW)
        switch mode {
        case 1: t.c_iflag |= tcflag_t(IXON | IXOFF); flow = "xon"
        case 2: t.c_cflag |= tcflag_t(CRTSCTS); flow = "rts"
        case 4: t.c_cflag |= tcflag_t(CDTR_IFLOW | CDSR_OFLOW); flow = "dsr"
        default: flow = "none"
        }
        params.flow = flow
        return tcsetattr(fd, TCSANOW, &t) == 0
    }

    /// フロー制御なしのときだけ変えられる (Tera Term と同じ)
    func setModemLine(_ bit: Int32, _ on: Bool) {
        guard fd >= 0, flow == "none" else { return }
        setLine(bit, on)
    }

    /// RTS / DTR をじかに上げ下げする (シリアルポート設定の RTS / DTR のチェック: EscapeCommFunction SETRTS / CLRRTS)
    func setLine(_ bit: Int32, _ on: Bool) {
        guard fd >= 0 else { return }
        var b = bit
        _ = ioctl(fd, on ? TIOCMBIS : TIOCMBIC, &b)
    }

    /// RTS / DTR がいま上がっているか
    func lineState(_ bit: Int32) -> Bool? {
        guard fd >= 0 else { return nil }
        var bits: Int32 = 0
        guard ioctl(fd, TIOCMGET, &bits) == 0 else { return nil }
        return bits & bit != 0
    }

    /// FlowCtrlRTS / FlowCtrlDTR を変えて、ポートの設定と線の状態をかけ直す (serial_pp.cpp SetComStatus / PSN_APPLY)
    func setRTSDTR(rts: Int, dtr: Int, flow f: String? = nil) {
        guard fd >= 0 else { return }
        params.rts = rts
        params.dtr = dtr
        if let f = f { flow = f; params.flow = f }
        try? configure()
        applyModemLines()
    }

    /// Disable は下げる、Enable・Handshake は上げる、Toggle は送るときだけ上げる (ふだんは下げておく)
    private func applyModemLines() {
        guard fd >= 0 else { return }
        setLine(TIOCM_RTS, params.rts == SerialParams.enable || params.rts == SerialParams.handshake)
        setLine(TIOCM_DTR, params.dtr != SerialParams.disable)
    }

    /// ビット: 1=CTS 2=DSR 4=RI 8=DCD
    func modemStatus() -> Int? {
        guard fd >= 0 else { return nil }
        var bits: Int32 = 0
        guard ioctl(fd, TIOCMGET, &bits) == 0 else { return nil }
        var n = 0
        if bits & TIOCM_CTS != 0 { n |= 1 }
        if bits & TIOCM_DSR != 0 { n |= 2 }
        if bits & TIOCM_RI != 0 { n |= 4 }
        if bits & TIOCM_CD != 0 { n |= 8 }
        return n
    }

    func close() { shutdown(msg: nil) }

    private func shutdown(msg: String?) {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        let f = fd
        fd = -1
        writeQueue.async { if f >= 0 { Darwin.close(f) } }
        onClose?(msg)
    }
}

/// - termType: TermType (Telnet の TERMINAL-TYPE)。keepAlive: TelKeepAliveInterval (秒)
/// - proxy: TTProxy の設定 (Telnet / 生の TCP はこの中でプロキシに、ssh は sshArgs の ProxyCommand と sshEnv で)
func makeConnection(_ spec: ConnectionSpec, cols: Int, rows: Int, sshArgs: [String] = [], sshEnv: [String: String] = [:],
                    timeout: Int? = nil, telnetBinary: Bool = false, termType: String = "xterm-256color", keepAlive: Int = 0,
                    proxy: ProxyConfig? = nil) -> Connection {
    switch spec {
    case .ssh(let uhost, let port, let user, let key):
        // IDN (#1493): ssh には ACE 形式 (xn--) のホスト名を渡す
        let host = IDN.hostNameToASCII(uhost)
        // マクロの scpsend / scprecv が同じ接続を使えるように ControlMaster を使う。
        // -e none: TTSSH にはエスケープ文字 (~.) がない
        var a = ["/usr/bin/ssh", "-e", "none", "-o", "ControlMaster=auto", "-o", "ControlPath=\(sshControlPath(host: host, port: port, user: user))", "-o", "ControlPersist=no"]
        a += sshArgs
        if port != 22 { a += ["-p", String(port)] }
        if !key.isEmpty { a += ["-i", (key as NSString).expandingTildeInPath] }
        a.append(user.isEmpty ? host : "\(user)@\(host)")
        return PTYConnection(argv: a, cols: cols, rows: rows, extraEnv: sshEnv, waitForOutput: true)
    case .telnet(let uh, let p):
        // IDN (#1493): 名前解決とプロキシへ送るホスト名は ACE 形式 (IdnHostNameToAscii)
        let h = IDN.hostNameToASCII(uh)
        let c = TCPConnection(host: h, port: p, telnet: true, cols: cols, rows: rows)
        c.timeout = timeout ?? 0
        c.requestBinary = telnetBinary
        c.termType = termType
        c.keepAliveInterval = max(0, keepAlive)
        c.proxy = proxy
        return c
    case .rawTCP(let uh, let p):
        let h = IDN.hostNameToASCII(uh)
        let c = TCPConnection(host: h, port: p, telnet: false, cols: cols, rows: rows)
        c.timeout = timeout ?? 0
        c.proxy = proxy
        return c
    case .serial(let s):
        return SerialConnection(params: s)
    case .shell:
        // ローカルシェルの設定 (CygTerm の SHELL / TERM / ENV_x / LOGIN_SHELL / HOME_CHDIR)
        let ls = LocalShellSettings.load()
        var env = ls.environment
        if !ls.term.isEmpty { env["TERM"] = ls.term }
        let c = PTYConnection(argv: ls.loginShell ? [ls.shellPath, "-l"] : [ls.shellPath], cols: cols, rows: rows, extraEnv: env)
        c.chdirHome = ls.homeChdir
        return c
    }
}

/// ssh の接続を共有するソケットの場所 (scp がログインし直さずに使う)
func sshControlPath(host: String, port: Int, user: String) -> String {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("teramac-ssh")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let name = "\(user.isEmpty ? NSUserName() : user)@\(host):\(port)"
    var h: UInt64 = 1469598103934665603
    for b in name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return (dir as NSString).appendingPathComponent(String(h, radix: 36))
}
