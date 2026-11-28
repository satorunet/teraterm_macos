import Foundation
import Network
import Darwin
import TeraCore

// Mac 版 (macos/Sources/TeraMac/Connection.swift) の Connection と TCP (Telnet) をそのまま写したもの
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

