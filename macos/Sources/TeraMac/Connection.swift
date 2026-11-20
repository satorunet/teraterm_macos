import Foundation
import Network
import Darwin

/// 接続の種類 (Tera Term の「新しい接続」ダイアログに相当)
enum ConnectionSpec: Equatable {
    case ssh(host: String, port: Int, user: String, keyFile: String)
    case telnet(host: String, port: Int)
    case rawTCP(host: String, port: Int)
    case serial(SerialParams)
    case shell

    var title: String {
        switch self {
        case .ssh(let h, let p, let u, _):
            let who = u.isEmpty ? h : "\(u)@\(h)"
            return p == 22 ? who : "\(who):\(p)"
        case .telnet(let h, let p): return p == 23 ? h : "\(h):\(p)"
        case .rawTCP(let h, let p): return "\(h):\(p)"
        case .serial(let s): return "\((s.path as NSString).lastPathComponent) \(s.baud)"
        case .shell: return "ローカルシェル"
        }
    }

    /// TTL の connect '...' やコマンドライン引数の書式から作る
    /// 例: "host:22 /ssh /user=root", "host /telnet", "/C=/dev/cu.usbserial /BAUD=9600"
    static func parse(_ text: String) -> ConnectionSpec? {
        var host = ""
        var port: Int?
        var kind = "ssh"
        var user = ""
        var key = ""
        var serialPath: String?
        var baud = 9600
        for raw in text.split(separator: " ") {
            let w = String(raw)
            let l = w.lowercased()
            if l == "/ssh" || l == "/ssh2" { kind = "ssh" }
            else if l == "/telnet" || l == "/t=1" { kind = "telnet" }
            else if l == "/nossh" { kind = "telnet" }
            else if l == "/t=0" { kind = "raw" }
            else if l.hasPrefix("/user=") { user = String(w.dropFirst(6)) }
            else if l.hasPrefix("/keyfile=") { key = String(w.dropFirst(9)) }
            else if l.hasPrefix("/c=") {
                let v = String(w.dropFirst(3))
                serialPath = Int(v).map { _ in SerialPort.list().first ?? "" } ?? v
            }
            else if l.hasPrefix("/baud=") { baud = Int(w.dropFirst(6)) ?? 9600 }
            else if l.hasPrefix("/p=") { port = Int(w.dropFirst(3)) }
            else if l == "/shell" { return .shell }
            else if !w.hasPrefix("/") {
                if let at = w.lastIndex(of: "@"), !w.hasPrefix("[") {
                    user = String(w[..<at]); host = String(w[w.index(after: at)...])
                } else { host = w }
                if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                    // IPv6: [addr] / [addr]:port
                    let rest = host[host.index(after: close)...]
                    if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
                    host = String(host[host.index(after: host.startIndex)..<close])
                } else if let c = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1 {
                    port = Int(host[host.index(after: c)...]); host = String(host[..<c])
                }
            }
        }
        if let p = serialPath {
            var s = SerialParams(); s.path = p; s.baud = baud
            return .serial(s)
        }
        guard !host.isEmpty else { return nil }
        switch kind {
        case "telnet": return .telnet(host: host, port: port ?? 23)
        case "raw": return .rawTCP(host: host, port: port ?? 23)
        default: return .ssh(host: host, port: port ?? 22, user: user, keyFile: key)
        }
    }
}

struct SerialParams: Equatable {
    var path = ""
    var baud = 9600
    var dataBits = 8
    var parity = "none"     // none / odd / even
    var stopBits = 1
    var flow = "none"       // none / xon / rts
}

protocol Connection: AnyObject {
    var onData: (([UInt8]) -> Void)? { get set }
    var onClose: ((String?) -> Void)? { get set }
    func start() throws
    func write(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func close()
    func sendBreak()
}

struct ConnError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

// MARK: - 疑似端末で外部コマンドを動かす (ssh / ローカルシェル)

final class PTYConnection: Connection {
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?
    private let argv: [String]
    private var env: [String: String]
    private var master: Int32 = -1
    private var pid: pid_t = 0
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "pty.read")
    private var initialSize: winsize
    private var closed = false

    init(argv: [String], cols: Int, rows: Int, extraEnv: [String: String] = [:]) {
        self.argv = argv
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
        let home = strdup(NSHomeDirectory())
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(home)
        }
        var m: Int32 = -1
        var ws = initialSize
        let p = forkpty(&m, nil, nil, &ws)
        if p < 0 { throw ConnError(msg: "疑似端末を作れませんでした (errno \(errno))") }
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

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(master, &buf, buf.count)
        if n > 0 {
            let chunk = Array(buf[0..<n])
            DispatchQueue.main.async { self.onData?(chunk) }
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            finish()
        }
    }

    private func finish() {
        source?.cancel()
        source = nil
        var status: Int32 = 0
        if pid > 0 { waitpid(pid, &status, 0) }
        let code = (status >> 8) & 0xFF
        DispatchQueue.main.async {
            guard !self.closed else { return }
            self.closed = true
            if self.master >= 0 { Darwin.close(self.master); self.master = -1 }
            self.onClose?(code == 0 ? nil : "終了コード \(code)")
        }
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
    private var binaryRecv = false
    private var closed = false
    var onConnected: (() -> Void)?

    // Telnet 受信の状態
    private enum TState { case data, iac, opt(UInt8), sb, sbIac }
    private var tstate: TState = .data
    private var sbBuf: [UInt8] = []

    private let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251
    private let SB: UInt8 = 250, SE: UInt8 = 240
    private let OPT_BINARY: UInt8 = 0, OPT_ECHO: UInt8 = 1, OPT_SGA: UInt8 = 3, OPT_TTYPE: UInt8 = 24, OPT_NAWS: UInt8 = 31

    init(host: String, port: Int, telnet: Bool, cols: Int, rows: Int) {
        self.host = host; self.port = port; self.telnet = telnet
        self.cols = cols; self.rows = rows
    }

    func start() throws {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw ConnError(msg: "ポート番号がおかしいです") }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                DispatchQueue.main.async { self.onConnected?() }
                if self.telnet {
                    self.sendRaw([self.IAC, self.WILL, self.OPT_TTYPE, self.IAC, self.WILL, self.OPT_NAWS,
                                  self.IAC, self.DO, self.OPT_SGA, self.IAC, self.DO, self.OPT_ECHO])
                }
                self.receive()
            case .failed(let e):
                self.finish("接続できませんでした: \(e.localizedDescription)")
            case .waiting(let e):
                self.finish("接続できませんでした: \(e.localizedDescription)")
                c.cancel()
            case .cancelled:
                self.finish(nil)
            default: break
            }
        }
        c.start(queue: DispatchQueue(label: "tcp"))
    }

    private func finish(_ msg: String?) {
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
                if b == IAC { tstate = .iac } else { out.append(b) }
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
            if opt == OPT_TTYPE || opt == OPT_SGA || opt == OPT_BINARY {
                sendRaw([IAC, WILL, opt])
            } else if opt == OPT_NAWS {
                sendRaw([IAC, WILL, opt]); nawsEnabled = true; sendNAWS()
            } else {
                sendRaw([IAC, WONT, opt])
            }
        case DONT:
            if opt == OPT_NAWS { nawsEnabled = false }
            sendRaw([IAC, WONT, opt])
        case WILL:
            if opt == OPT_ECHO || opt == OPT_SGA || opt == OPT_BINARY {
                if opt == OPT_BINARY { binaryRecv = true }
                sendRaw([IAC, DO, opt])
            } else {
                sendRaw([IAC, DONT, opt])
            }
        case WONT:
            sendRaw([IAC, DONT, opt])
        default: break
        }
    }

    private func subnegotiation(_ b: [UInt8]) {
        if b.count >= 2 && b[0] == OPT_TTYPE && b[1] == 1 {
            sendRaw([IAC, SB, OPT_TTYPE, 0] + Array("XTERM".utf8) + [IAC, SE])
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
        conn?.send(content: Data(b), completion: .contentProcessed { _ in })
    }

    func write(_ bytes: [UInt8]) {
        guard telnet else { sendRaw(bytes); return }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for b in bytes {
            if b == IAC { out.append(IAC); out.append(IAC) }
            else if b == 0x0D { out.append(0x0D); out.append(0x00) }
            else { out.append(b) }
        }
        // CR LF は CR NUL LF にしない
        var fixed: [UInt8] = []
        var i = 0
        while i < out.count {
            if out[i] == 0x0D && i + 2 < out.count && out[i + 1] == 0 && out[i + 2] == 0x0A {
                fixed += [0x0D, 0x0A]; i += 3
            } else { fixed.append(out[i]); i += 1 }
        }
        sendRaw(fixed)
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
        if telnet { sendNAWS() }
    }

    func close() {
        conn?.cancel()
    }

    func sendBreak() {
        if telnet { sendRaw([IAC, 243]) }
    }
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
    let params: SerialParams
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "serial.read")
    private var closed = false
    /// 1 文字ごとの送信遅延 (ミリ秒)
    var charDelayMs = 0
    var lineDelayMs = 0
    private let writeQueue = DispatchQueue(label: "serial.write")

    init(params: SerialParams) { self.params = params }

    func start() throws {
        fd = open(params.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 {
            let e = errno
            throw ConnError(msg: "\(params.path) を開けませんでした: \(String(cString: strerror(e)))" +
                            (e == EBUSY ? "\n(ほかのアプリが使っています)" : ""))
        }
        _ = ioctl(fd, TIOCEXCL)
        var t = termios()
        if tcgetattr(fd, &t) != 0 { throw ConnError(msg: "ポートの設定を読めませんでした") }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE)
        switch params.dataBits {
        case 5: t.c_cflag |= tcflag_t(CS5)
        case 6: t.c_cflag |= tcflag_t(CS6)
        case 7: t.c_cflag |= tcflag_t(CS7)
        default: t.c_cflag |= tcflag_t(CS8)
        }
        t.c_cflag &= ~tcflag_t(PARENB | PARODD)
        if params.parity == "even" { t.c_cflag |= tcflag_t(PARENB) }
        if params.parity == "odd" { t.c_cflag |= tcflag_t(PARENB | PARODD) }
        if params.stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) } else { t.c_cflag &= ~tcflag_t(CSTOPB) }
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        if params.flow == "rts" { t.c_cflag |= tcflag_t(CRTSCTS) }
        if params.flow == "xon" { t.c_iflag |= tcflag_t(IXON | IXOFF) }
        // VMIN/VTIME: 届いた分だけすぐ返す
        withUnsafeMutablePointer(to: &t.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1; cc[Int(VTIME)] = 0
            }
        }
        let std = speed_t(params.baud)
        cfsetspeed(&t, std)
        if tcsetattr(fd, TCSANOW, &t) != 0 {
            // 標準外の速度は IOSSIOSPEED で設定する
            cfsetspeed(&t, speed_t(B9600))
            _ = tcsetattr(fd, TCSANOW, &t)
        }
        var sp = speed_t(params.baud)
        let IOSSIOSPEED: UInt = 0x8008_5402
        if ioctl(fd, IOSSIOSPEED, &sp) != 0 && tcsetattr(fd, TCSANOW, &t) != 0 {
            throw ConnError(msg: "通信速度 \(params.baud) に設定できませんでした")
        }
        // DTR / RTS を上げる
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIS, &bits)
        tcflush(fd, TCIOFLUSH)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        source = src
        src.resume()
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            let chunk = Array(buf[0..<n])
            DispatchQueue.main.async { self.onData?(chunk) }
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            // USB シリアルを抜いたときなど
            DispatchQueue.main.async { self.shutdown(msg: "ポートが切断されました") }
        }
    }

    func write(_ bytes: [UInt8]) {
        let f = fd
        let cd = charDelayMs, ld = lineDelayMs
        writeQueue.async {
            guard f >= 0 else { return }
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

    func sendBreak() {
        if fd >= 0 { tcsendbreak(fd, 0) }
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

func makeConnection(_ spec: ConnectionSpec, cols: Int, rows: Int) -> Connection {
    switch spec {
    case .ssh(let host, let port, let user, let key):
        var a = ["/usr/bin/ssh"]
        if port != 22 { a += ["-p", String(port)] }
        if !key.isEmpty { a += ["-i", (key as NSString).expandingTildeInPath] }
        a.append(user.isEmpty ? host : "\(user)@\(host)")
        return PTYConnection(argv: a, cols: cols, rows: rows)
    case .telnet(let h, let p):
        return TCPConnection(host: h, port: p, telnet: true, cols: cols, rows: rows)
    case .rawTCP(let h, let p):
        return TCPConnection(host: h, port: p, telnet: false, cols: cols, rows: rows)
    case .serial(let s):
        return SerialConnection(params: s)
    case .shell:
        let sh = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // ログインシェルとして起動 (argv[0] を "-zsh" にする代わりに -l を付ける)
        return PTYConnection(argv: [sh, "-l"], cols: cols, rows: rows)
    }
}
