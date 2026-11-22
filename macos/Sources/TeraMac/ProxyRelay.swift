// ssh の ProxyCommand として動く中継 (TeraMac --proxy-connect <host> <port>)。
// TTProxy は Winsock をフックして TTSSH の接続もプロキシに通す。Mac 版の SSH は /usr/bin/ssh なので、
// ProxyCommand にこのアプリ自身を指定し、TTProxy と同じやりとり (TeraCore の ProxyHandshake) をしてから
// 標準入出力とソケットをつなぐ。設定は環境変数 TERAMAC_PROXY_* (ProxyConfig.environment) で受け取る。

import Foundation
import Darwin
import TeraCore

enum ProxyRelay {
    static let argument = "--proxy-connect"

    /// このアプリの実行ファイル
    static var executablePath: String? { Bundle.main.executablePath ?? CommandLine.arguments.first }

    /// main.swift の最初で呼ぶ。--proxy-connect でなければ何もしない (戻る)
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard a.count >= 2, a[1] == argument else { return }
        guard a.count >= 4, let port = Int(a[3]) else {
            fail("使い方: \(argument) <ホスト> <ポート>")
        }
        guard let cfg = ProxyConfig(environment: ProcessInfo.processInfo.environment), cfg.isEnabled else {
            fail("プロキシの設定がありません")
        }
        exit(run(config: cfg, host: a[2], port: port))
    }

    private static func fail(_ m: String) -> Never {
        FileHandle.standardError.write(("TTProxy: " + m + "\r\n").data(using: .utf8)!)
        exit(1)
    }

    private static func run(config: ProxyConfig, host: String, port: Int) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let timeoutMs = config.timeout > 0 ? Int32(config.timeout * 1000) : -1
        let fd = connectTCP(config.host, config.effectivePort, timeoutMs: timeoutMs)
        guard fd >= 0 else { fail("プロキシ \(config.host):\(config.effectivePort) に接続できません") }
        defer { close(fd) }

        // プロキシとのやりとり
        let h = ProxyHandshake(config: config, host: host, port: port)
        var out = h.start()
        var leftover: [UInt8] = []
        handshake: while true {
            if !out.send.isEmpty && !writeAll(fd, out.send) { fail("プロキシに送れません") }
            if let r = out.result {
                switch r {
                case .connected(let rest): leftover = rest
                case .failed(let m): fail(m)
                }
                break handshake
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&p, 1, timeoutMs)
            if n == 0 { fail("プロキシからの応答がありません (タイムアウト)") }
            if n < 0 { if errno == EINTR { continue }; fail("プロキシとの通信に失敗しました") }
            var buf = [UInt8](repeating: 0, count: 4096)
            let r = read(fd, &buf, buf.count)
            out = r > 0 ? h.feed(Array(buf[0..<r])) : h.closed()
        }
        if !leftover.isEmpty && !writeAll(STDOUT_FILENO, leftover) { return 1 }

        // 中継: 標準入力 → ソケット、ソケット → 標準出力
        var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0), pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        var stdinOpen = true
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            fds[0].fd = stdinOpen ? STDIN_FILENO : -1
            let n = poll(&fds, 2, -1)
            if n < 0 { if errno == EINTR { continue }; return 1 }
            if stdinOpen && fds[0].revents != 0 {
                let r = read(STDIN_FILENO, &buf, buf.count)
                if r > 0 {
                    if !writeAll(fd, Array(buf[0..<r])) { return 0 }
                } else {
                    stdinOpen = false
                    shutdown(fd, SHUT_WR)
                }
            }
            if fds[1].revents != 0 {
                let r = read(fd, &buf, buf.count)
                if r <= 0 { return 0 }
                if !writeAll(STDOUT_FILENO, Array(buf[0..<r])) { return 0 }
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ b: [UInt8]) -> Bool {
        var off = 0
        while off < b.count {
            let n = b[off...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    /// getaddrinfo で引いたアドレスに順につなぐ (timeoutMs < 0 なら待ち続ける)
    private static func connectTCP(_ host: String, _ port: Int, timeoutMs: Int32) -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0 else { return -1 }
        defer { freeaddrinfo(res) }
        var ai = res
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s < 0 { continue }
            let flags = fcntl(s, F_GETFL)
            _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
            var ok = Darwin.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0
            if !ok && errno == EINPROGRESS {
                var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, timeoutMs) == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                    ok = err == 0
                }
            }
            if ok {
                _ = fcntl(s, F_SETFL, flags)
                return s
            }
            close(s)
        }
        return -1
    }
}
