import Foundation
import Darwin
import CSSH2
import TeraCore

// アプリの中の SSH (Mac の App Store 版から写したもの)。iPhone / iPad には ssh コマンドがないので libssh2 でつなぐ。
// 鍵は「鍵」フォルダ (Documents/keys。ファイル App から入れられる) のものを試す。
// 認証は TTSSH と同じく、つないだあとに「SSH 認証」ダイアログで聞く (パスワード / 鍵 / キーボードインタラクティブ)。
// known_hosts は設定フォルダの known_hosts (OpenSSH の書き方) を使う。

enum BuiltinSSH {
    /// known_hosts (設定フォルダ)
    static var knownHostsPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tera Term SP")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("known_hosts").path
    }

    private static var initialized = false
    static func initialize() {
        if !initialized { libssh2_init(0); initialized = true }
    }
}

/// 認証や警告をウインドウに聞く (SSH の糸から呼ぶ。答えが出るまで待つ)
protocol SSH2Asker: AnyObject {
    /// ホスト鍵の確認。known: 一致しない鍵があった。true なら続ける、add: known_hosts に足す / 上書きする
    func confirmHostKey(host: String, port: Int, fingerprint: String, keyType: String, mismatch: Bool) -> (proceed: Bool, add: Bool)
    /// SSH 認証。methods: サーバーが受け付ける方法。nil ならやめる
    func askAuth(user: String, host: String, methods: [String], failed: Bool, keyFile: String) -> SSH2AuthAnswer?
    /// キーボードインタラクティブの問い (echo: 入力を見せる)
    func askChallenge(name: String, instruction: String, prompts: [(text: String, echo: Bool)]) -> [String]?
    /// (App Store 版) ~/.ssh フォルダを使う許可をもらう。選んだら true
    func askSSHFolder() -> Bool
}

struct SSH2AuthAnswer {
    enum Method { case password, publicKey, keyboardInteractive, useSSHDir }
    var method: Method
    var user: String
    var secret: String      // パスワード / 鍵のパスフレーズ
    var keyFile: String
}

final class SSH2Connection: Connection {
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?
    var onConnected: (() -> Void)?
    var waitsForConnection: Bool { true }
    /// 認証や警告を聞く相手 (ウインドウ)
    var asker: SSH2Asker?

    /// 接続先 (~/.ssh/config の HostName / Port で置き換わる)
    var host: String
    var port: Int
    var user: String
    /// 接続ダイアログなどで入れたホスト名 (~/.ssh/config の Host と比べる)
    let alias: String
    /// ユーザー名を指定されたか (なければ ~/.ssh/config の User、それもなければ Mac のユーザー名)
    private let userGiven: Bool
    /// ~/.ssh を使っている間の許可 (App Store 版はしおり)
    /// 試す鍵 (指定がないとき: config の IdentityFile と ~/.ssh/id_*)
    private var keyCandidates: [String] = []
    var keyFile: String
    /// 先にわかっているパスワード (接続ダイアログ・TTMenu・マクロの connect)。最初の 1 回だけ使う
    var password: String?
    /// 鍵のパスフレーズ (確認用。ふだんは SSH 認証ダイアログで聞く)
    var keyPassphrase = ""
    /// 認証方法の指定 (/auth=password / publickey / challenge)
    var preferredAuth: String?
    var termType = "xterm-256color"
    var timeout = 0
    var keepAliveInterval = 0
    private var cols: Int, rows: Int

    private var sock: Int32 = -1
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var wake: [Int32] = [-1, -1]
    private let lock = NSLock()
    private var outBuf: [UInt8] = []
    private var pendingSize: (Int, Int)?
    private var closing = false
    private var finished = false

    init(host: String, port: Int, user: String, keyFile: String, cols: Int, rows: Int) {
        self.host = host; self.port = port; self.alias = host; self.keyFile = keyFile
        self.userGiven = !user.isEmpty
        self.user = user
        self.cols = cols; self.rows = rows
    }

    func start() throws {
        BuiltinSSH.initialize()
        guard pipe(&wake) == 0 else { throw ConnError(msg: Lang.m("SSH2_ERR_INTERNAL", "内部の準備に失敗しました")) }
        _ = fcntl(wake[0], F_SETFL, O_NONBLOCK)
        let t = Thread { [self] in self.run() }
        t.name = "ssh2 \(host)"
        t.start()
    }

    func write(_ bytes: [UInt8]) {
        lock.lock(); outBuf += bytes; lock.unlock()
        poke()
    }

    func resize(cols: Int, rows: Int) {
        lock.lock(); pendingSize = (cols, rows); lock.unlock()
        poke()
    }

    func close() {
        lock.lock(); closing = true; lock.unlock()
        poke()
    }

    func sendBreak() {}

    private func poke() {
        var b: UInt8 = 1
        if wake[1] >= 0 { _ = Darwin.write(wake[1], &b, 1) }
    }

    // MARK: - 糸の中

    private func fail(_ msg: String) {
        finish(msg)
    }

    private func finish(_ msg: String?) {
        if finished { return }
        finished = true
        if let ch = channel { libssh2_channel_free(ch); channel = nil }
        if let s = session {
            libssh2_session_disconnect_ex(s, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(s); session = nil
        }
        if sock >= 0 { Darwin.close(sock); sock = -1 }
        for i in 0..<2 where wake[i] >= 0 { Darwin.close(wake[i]); wake[i] = -1 }
        DispatchQueue.main.async { self.onClose?(msg) }
    }

    private func lastError() -> String {
        guard let s = session else { return "" }
        var p: UnsafeMutablePointer<CChar>?
        var n: Int32 = 0
        libssh2_session_last_error(s, &p, &n, 0)
        return p.map { String(cString: $0) } ?? ""
    }

    /// 試す鍵: 「鍵」フォルダ (Documents/keys) の中のファイル (.pub と known_hosts は除く)
    private func prepareSSHDir(applyConfig: Bool = true) {
        guard keyFile.isEmpty else { return }
        let dir = SPPaths.keysDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        keyCandidates = names.sorted().filter { !$0.hasSuffix(".pub") && !$0.hasPrefix(".") && $0 != "known_hosts" }
            .map { dir + "/" + $0 }
    }

    private func run() {
        prepareSSHDir()
        // 1. TCP でつなぐ
        do { sock = try connectSocket() } catch { return fail(error.localizedDescription) }
        // 2. SSH の握手 (ここまではブロッキング)
        guard let s = libssh2_session_init_ex(nil, nil, nil, nil) else { return fail(Lang.m("SSH2_ERR_INTERNAL", "内部の準備に失敗しました")) }
        session = s
        libssh2_session_set_blocking(s, 1)
        if timeout > 0 { libssh2_session_set_timeout(s, timeout * 1000) }
        if libssh2_session_handshake(s, sock) != 0 {
            return fail(Lang.m("SSH2_ERR_HANDSHAKE", "SSH の接続を始められませんでした: %s", lastError()))
        }
        libssh2_session_set_timeout(s, 0)
        // 3. ホスト鍵を確かめる
        guard checkHostKey(s) else { return finish(Lang.m("SSH2_ERR_HOSTKEY", "ホスト鍵を確かめられなかったので、切断しました")) }
        // 4. 認証
        switch authenticate(s) {
        case .ok: break
        case .cancelled: return finish(Lang.m("SSH2_ERR_AUTH_CANCELLED", "認証をやめました"))
        case .failed(let m): return fail(m)
        }
        // 5. 端末を開く (pty-req は ts.TermType)
        guard let ch = libssh2_channel_open_ex(s, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) else {
            return fail(Lang.m("SSH2_ERR_CHANNEL", "端末を開けませんでした: %s", lastError()))
        }
        channel = ch
        let term = termType.isEmpty ? "xterm" : termType
        if libssh2_channel_request_pty_ex(ch, term, UInt32(term.utf8.count), nil, 0, Int32(cols), Int32(rows), 0, 0) != 0 {
            return fail(Lang.m("SSH2_ERR_CHANNEL", "端末を開けませんでした: %s", lastError()))
        }
        if libssh2_channel_process_startup(ch, "shell", 5, nil, 0) != 0 {
            return fail(Lang.m("SSH2_ERR_CHANNEL", "端末を開けませんでした: %s", lastError()))
        }
        if keepAliveInterval > 0 { libssh2_keepalive_config(s, 1, UInt32(keepAliveInterval)) }
        libssh2_session_set_blocking(s, 0)
        DispatchQueue.main.async { self.onConnected?() }
        loop(s, ch)
    }

    private func connectSocket() throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw ConnError(msg: Lang.m("SSH2_ERR_RESOLVE", "%s が見つかりません (%s)", host, String(cString: gai_strerror(rc))))
        }
        defer { freeaddrinfo(res) }
        var lastErr = ECONNREFUSED
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                // つなぐのを待つ時間 (/timeout=。なければ 30 秒)
                let flags = fcntl(fd, F_GETFL)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                var ok = Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0
                if !ok && errno == EINPROGRESS {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&p, 1, Int32((timeout > 0 ? timeout : 30) * 1000)) == 1 {
                        var e: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &len)
                        ok = e == 0
                        if !ok { lastErr = e }
                    } else { lastErr = ETIMEDOUT }
                } else if !ok { lastErr = errno }
                if ok {
                    _ = fcntl(fd, F_SETFL, flags)
                    return fd
                }
                Darwin.close(fd)
            }
            ai = a.pointee.ai_next
        }
        throw ConnError(msg: Lang.m("SSH2_ERR_CONNECT", "%s:%d につなげませんでした (%s)", host, port, String(cString: strerror(lastErr))))
    }

    // MARK: ホスト鍵

    private func checkHostKey(_ s: OpaquePointer) -> Bool {
        var len = 0
        var type: Int32 = 0
        guard let key = libssh2_session_hostkey(s, &len, &type), let kh = libssh2_knownhost_init(s) else { return false }
        defer { libssh2_knownhost_free(kh) }
        // ~/.ssh が使えれば OpenSSH と同じ known_hosts、なければアプリの設定フォルダの known_hosts
        let path = BuiltinSSH.knownHostsPath
        if FileManager.default.fileExists(atPath: path) {
            libssh2_knownhost_readfile(kh, path, LIBSSH2_KNOWNHOST_FILE_OPENSSH)
        }
        let typeMask = Int32(LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW)
        var found: UnsafeMutablePointer<libssh2_knownhost>?
        let r = libssh2_knownhost_checkp(kh, host, Int32(port), key, len, typeMask, &found)
        if r == LIBSSH2_KNOWNHOST_CHECK_MATCH { return true }
        let mismatch = r == LIBSSH2_KNOWNHOST_CHECK_MISMATCH
        let (fp, kt) = fingerprint(s, type: type)
        guard let a = asker else { return false }
        let ans = a.confirmHostKey(host: host, port: port, fingerprint: fp, keyType: kt, mismatch: mismatch)
        guard ans.proceed else { return false }
        if ans.add {
            let name = port == 22 ? host : "[\(host)]:\(port)"
            // OpenSSH の known_hosts は書き直さず、1 行を足す (libssh2 が読めない行も残すため)。
            // 鍵が変わったときは、その名前の古い行 (平文のもの) を消してから足す
            var newEntry: UnsafeMutablePointer<libssh2_knownhost>?
            libssh2_knownhost_addc(kh, name, nil, key, len, nil, 0, typeMask | knownHostKeyType(type), &newEntry)
            var line = [CChar](repeating: 0, count: 16384)
            var outLen = 0
            if let ne = newEntry, libssh2_knownhost_writeline(kh, ne, &line, line.count, &outLen, LIBSSH2_KNOWNHOST_FILE_OPENSSH) == 0 {
                var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                if mismatch {
                    text = text.components(separatedBy: "\n").filter { l in
                        let f = l.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                        return !f.split(separator: ",").contains(where: { String($0) == name })
                    }.joined(separator: "\n")
                }
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                text += String(cString: line)
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        return true
    }

    private func knownHostKeyType(_ t: Int32) -> Int32 {
        switch t {
        case LIBSSH2_HOSTKEY_TYPE_RSA: return Int32(LIBSSH2_KNOWNHOST_KEY_SSHRSA)
        case LIBSSH2_HOSTKEY_TYPE_DSS: return Int32(LIBSSH2_KNOWNHOST_KEY_SSHDSS)
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return Int32(LIBSSH2_KNOWNHOST_KEY_ECDSA_256)
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return Int32(LIBSSH2_KNOWNHOST_KEY_ECDSA_384)
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return Int32(LIBSSH2_KNOWNHOST_KEY_ECDSA_521)
        case LIBSSH2_HOSTKEY_TYPE_ED25519: return Int32(LIBSSH2_KNOWNHOST_KEY_ED25519)
        default: return Int32(LIBSSH2_KNOWNHOST_KEY_UNKNOWN)
        }
    }

    /// "SHA256:xxxx" (OpenSSH と同じ書き方) と鍵の種類
    private func fingerprint(_ s: OpaquePointer, type: Int32) -> (String, String) {
        var fp = ""
        if let h = libssh2_hostkey_hash(s, LIBSSH2_HOSTKEY_HASH_SHA256) {
            let d = Data(bytes: h, count: 32)
            fp = "SHA256:" + d.base64EncodedString().replacingOccurrences(of: "=", with: "")
        }
        let names: [Int32: String] = [LIBSSH2_HOSTKEY_TYPE_RSA: "ssh-rsa", LIBSSH2_HOSTKEY_TYPE_DSS: "ssh-dss",
                                      LIBSSH2_HOSTKEY_TYPE_ECDSA_256: "ecdsa-sha2-nistp256", LIBSSH2_HOSTKEY_TYPE_ECDSA_384: "ecdsa-sha2-nistp384",
                                      LIBSSH2_HOSTKEY_TYPE_ECDSA_521: "ecdsa-sha2-nistp521", LIBSSH2_HOSTKEY_TYPE_ED25519: "ssh-ed25519"]
        return (fp, names[type] ?? "?")
    }

    // MARK: 認証

    private enum AuthResult { case ok, cancelled, failed(String) }

    private func authenticate(_ s: OpaquePointer) -> AuthResult {
        var failed = false
        var tries = 0
        while tries < 6 {
            tries += 1
            // サーバーが受け付ける方法 (none で通ったら NULL)
            let list = libssh2_userauth_list(s, user, UInt32(user.utf8.count))
            if list == nil {
                if libssh2_userauth_authenticated(s) != 0 { return .ok }
            }
            let methods = list.map { String(cString: $0).split(separator: ",").map(String.init) } ?? []
            // 最初の 1 回: わかっているパスワード / 鍵ファイルをそのまま試す (ダイアログを出さない)
            if tries == 1 {
                if let pw = password, !pw.isEmpty, preferredAuth != "publickey", methods.contains("password") {
                    password = nil
                    if userauthPassword(s, user, pw) { return .ok }
                    failed = true
                    continue
                }
                if preferredAuth != "password", preferredAuth != "challenge", methods.contains("publickey") {
                    // 鍵の指定があればそれ、なければ ~/.ssh の鍵を順に (パスフレーズのないもの)
                    for k in keyFile.isEmpty ? keyCandidates : [keyFile] {
                        if userauthKey(s, user, k, keyPassphrase) { return .ok }
                    }
                }
            }
            guard let a = asker else { return .failed(Lang.m("SSH2_ERR_AUTH", "認証に失敗しました")) }
            guard let ans = a.askAuth(user: user, host: alias, methods: methods, failed: failed, keyFile: keyFile.isEmpty ? (keyCandidates.first ?? "") : keyFile) else { return .cancelled }
            if ans.user != user {
                // ユーザー名を変えた: libssh2 は同じ接続で別のユーザーを試せる
                user = ans.user
            }
            let ok: Bool
            switch ans.method {
            case .useSSHDir:
                // SSH認証の画面で ~/.ssh を選んだ: その鍵 (パスフレーズのないもの) を順に試し、だめならもう一度聞く
                // (つないだあとなので、HostName / Port は変えない)
                prepareSSHDir(applyConfig: false)
                ok = keyCandidates.contains { userauthKey(s, user, $0, "") }
            case .password: ok = userauthPassword(s, user, ans.secret)
            case .publicKey:
                keyFile = ans.keyFile
                ok = userauthKey(s, user, ans.keyFile, ans.secret)
            case .keyboardInteractive: ok = userauthKbdInt(s, user)
            }
            if ok { return .ok }
            failed = true
        }
        return .failed(Lang.m("SSH2_ERR_AUTH", "認証に失敗しました"))
    }

    private func userauthPassword(_ s: OpaquePointer, _ u: String, _ pw: String) -> Bool {
        libssh2_userauth_password_ex(s, u, UInt32(u.utf8.count), pw, UInt32(pw.utf8.count), nil) == 0
    }

    private func userauthKey(_ s: OpaquePointer, _ u: String, _ file: String, _ pass: String) -> Bool {
        let path = (file as NSString).expandingTildeInPath
        // App Store 版: 鍵ファイルは利用者が選んだもの (しおり) を開いて使う
        let scoped = SSHKeyAccess.startAccessing(URL(fileURLWithPath: path))
        defer { scoped?.stopAccessingSecurityScopedResource() }
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let pem = [UInt8](data)
        return pem.withUnsafeBufferPointer { b in
            b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { p in
                libssh2_userauth_publickey_frommemory(s, u, u.utf8.count, nil, 0, p, b.count, pass.isEmpty ? nil : pass) == 0
            }
        }
    }

    /// キーボードインタラクティブ。libssh2 の C の呼び戻しから self を探すため、session の abstract に置く
    private func userauthKbdInt(_ s: OpaquePointer, _ u: String) -> Bool {
        let abstract = libssh2_session_abstract(s)
        abstract?.pointee = Unmanaged.passUnretained(self).toOpaque()
        let cb: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32, Int32,
                               UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?, UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
                               UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Void = { name, nameLen, instr, instrLen, n, prompts, responses, abs in
            guard let abs = abs, let me = abs.pointee.map({ Unmanaged<SSH2Connection>.fromOpaque($0).takeUnretainedValue() }),
                  let responses = responses else { return }
            func str(_ p: UnsafePointer<CChar>?, _ n: Int) -> String {
                guard let p = p, n > 0 else { return "" }
                return String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
            }
            var ps: [(String, Bool)] = []
            for i in 0..<Int(n) {
                let pr = prompts![i]
                ps.append((str(pr.text.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, Int(pr.length)), pr.echo != 0))
            }
            let ans = n == 0 ? [] : (me.asker?.askChallenge(name: str(name, Int(nameLen)), instruction: str(instr, Int(instrLen)),
                                                            prompts: ps.map { (text: $0.0, echo: $0.1) }) ?? [])
            for i in 0..<Int(n) { cssh2_set_response(responses, Int32(i), i < ans.count ? ans[i] : "") }
        }
        return libssh2_userauth_keyboard_interactive_ex(s, u, UInt32(u.utf8.count), cb) == 0
    }

    // MARK: 送受信

    private func loop(_ s: OpaquePointer, _ ch: OpaquePointer) {
        var buf = [UInt8](repeating: 0, count: 32768)
        var pending: [UInt8] = []
        while true {
            // 1. 外からの頼み (書く・大きさ・閉じる)
            lock.lock()
            pending += outBuf; outBuf.removeAll()
            let size = pendingSize; pendingSize = nil
            let wantClose = closing
            lock.unlock()
            if wantClose { return finish(nil) }
            if let (c, r) = size {
                cols = c; rows = r
                _ = libssh2_channel_request_pty_size_ex(ch, Int32(c), Int32(r), 0, 0)
            }
            // 2. 書く
            while !pending.isEmpty {
                let n = pending.withUnsafeBufferPointer { b in
                    b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { libssh2_channel_write_ex(ch, 0, $0, b.count) }
                }
                if n > 0 { pending.removeFirst(n) } else { break }
            }
            // 3. 読む (標準出力と標準エラー)
            for stream: Int32 in [0, SSH_EXTENDED_DATA_STDERR] {
                while true {
                    let n = buf.withUnsafeMutableBufferPointer { b in
                        b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { libssh2_channel_read_ex(ch, stream, $0, b.count) }
                    }
                    if n > 0 {
                        let chunk = Array(buf[0..<n])
                        DispatchQueue.main.async { self.onData?(chunk) }
                    } else if n == Int(LIBSSH2_ERROR_EAGAIN) || n == 0 {
                        break
                    } else {
                        return finish(Lang.m("SSH2_ERR_IO", "接続が切れました: %s", lastError()))
                    }
                }
            }
            if libssh2_channel_eof(ch) != 0 { return finish(nil) }
            // 4. 待つ (ソケットか、外からの頼み)
            var next: Int32 = 0
            if keepAliveInterval > 0 { libssh2_keepalive_send(s, &next) }
            let dir = libssh2_session_block_directions(s)
            var ev: Int16 = Int16(POLLIN)
            if dir & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 || !pending.isEmpty { ev |= Int16(POLLOUT) }
            var fds = [pollfd(fd: sock, events: ev, revents: 0), pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
            let waitMs: Int32 = keepAliveInterval > 0 ? max(1000, next * 1000) : 30000
            _ = poll(&fds, 2, waitMs)
            if fds[1].revents != 0 {
                var junk = [UInt8](repeating: 0, count: 64)
                while Darwin.read(wake[0], &junk, 64) > 0 {}
            }
        }
    }
}

/// 鍵ファイルを読むための許可 (App Store 版はサンドボックスなので、利用者が選んだファイルの「しおり」を覚えておく)
enum SSHKeyAccess {
    private static let key = "SSHKeyBookmarks"

    /// 選んだファイルのしおりを保存する
    static func remember(_ url: URL) {
        #if APPSTORE
        guard let b = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        all[url.path] = b
        UserDefaults.standard.set(all, forKey: key)
        #endif
    }

    /// しおりから読む許可をもらう (もらえたらその URL。使い終わったら stopAccessingSecurityScopedResource)
    static func startAccessing(_ url: URL) -> URL? {
        #if APPSTORE
        guard let b = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data])?[url.path] else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: b, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              u.startAccessingSecurityScopedResource() else { return nil }
        return u
        #else
        return nil
        #endif
    }
}
