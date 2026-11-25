import AppKit
import TeraCore

// TTSSH / TTProxy の設定メニュー (SSH… / SSH認証… / SSH転送… / SSH鍵生成… / プロキシ…)。
// Tera Term Mac の SSH は /usr/bin/ssh なので、TTSSH の設定を ssh のオプション (-o ...) に直して渡す。
// 値は UserDefaults ("TTSSH.キー名" / "TTProxy.キー名") に置き、TERATERM.INI の [TTSSH] / [TTProxy] と読み書きする。

/// TTSSH の設定 (pvar->settings のうち、OpenSSH に渡せるもの)
struct SSHSettings: Equatable {
    // SSH… (TTSSH: 設定)
    var compression = 0                 // Compression 0..9 (0 = なし)
    var cipherOrder: [String] = []      // TeraMacCiphers  (空 = ssh の標準)
    var kexOrder: [String] = []         // TeraMacKexAlgorithms
    var hostKeyOrder: [String] = []     // TeraMacHostKeyAlgorithms
    var macOrder: [String] = []         // TeraMacMACs
    var knownHostsRW = "~/.ssh/known_hosts"   // KnownHostsFiles (rw;ro)
    var knownHostsRO = ""
    var heartBeat = 300                 // HeartBeat (秒。0 = 無効)
    var forwardAgent = false            // ForwardAgent
    var verifyHostKeyDNS = true         // VerifyHostKeyDNS
    var updateHostkeys = 0              // UpdateHostkeys 0: 無効 1: 有効 2: 確認する
    var logLevel = 0                    // LogLevel (0 = 無効)
    // SSH認証…
    var defaultUserType = 1             // DefaultUserType 0: 入力しない 1: デフォルトユーザ名 2: ログオンユーザ名
    var defaultUserName = ""            // DefaultUserName
    var defaultAuthMethod = 3           // DefaultAuthMethod 3: パスワード 2: 鍵 5: キーボードインタラクティブ 16: エージェント (Pageant)
    var defaultRSAPrivateKeyFile = ""   // DefaultRSAPrivateKeyFile
    // SSH転送…
    var defaultForwarding = ""          // DefaultForwarding  "L8080:host:80;R...;D1080;X"
    var gatewayPorts = false            // TeraMacGatewayPorts (他のホストからの接続を受け入れる → ssh -g)

    static let d = UserDefaults.standard

    static let intKeys: [(String, WritableKeyPath<SSHSettings, Int>)] = [
        ("Compression", \.compression), ("HeartBeat", \.heartBeat), ("UpdateHostkeys", \.updateHostkeys),
        ("LogLevel", \.logLevel), ("DefaultUserType", \.defaultUserType), ("DefaultAuthMethod", \.defaultAuthMethod),
    ]
    static let boolKeys: [(String, WritableKeyPath<SSHSettings, Bool>)] = [
        ("ForwardAgent", \.forwardAgent), ("VerifyHostKeyDNS", \.verifyHostKeyDNS), ("TeraMacGatewayPorts", \.gatewayPorts),
    ]
    static let stringKeys: [(String, WritableKeyPath<SSHSettings, String>)] = [
        ("DefaultUserName", \.defaultUserName), ("DefaultRSAPrivateKeyFile", \.defaultRSAPrivateKeyFile),
        ("DefaultForwarding", \.defaultForwarding),
    ]
    static let listKeys: [(String, WritableKeyPath<SSHSettings, [String]>)] = [
        ("TeraMacCiphers", \.cipherOrder), ("TeraMacKexAlgorithms", \.kexOrder),
        ("TeraMacHostKeyAlgorithms", \.hostKeyOrder), ("TeraMacMACs", \.macOrder),
    ]

    static func load() -> SSHSettings {
        var s = SSHSettings()
        for (k, p) in intKeys where d.object(forKey: "TTSSH." + k) != nil { s[keyPath: p] = d.integer(forKey: "TTSSH." + k) }
        for (k, p) in boolKeys where d.object(forKey: "TTSSH." + k) != nil { s[keyPath: p] = d.bool(forKey: "TTSSH." + k) }
        for (k, p) in stringKeys { if let v = d.string(forKey: "TTSSH." + k) { s[keyPath: p] = v } }
        for (k, p) in listKeys { if let v = d.string(forKey: "TTSSH." + k) { s[keyPath: p] = splitList(v) } }
        if let v = d.string(forKey: "TTSSH.KnownHostsFiles") { s.knownHostsFiles = v }
        return s
    }

    func save() {
        let d = Self.d
        for (k, p) in Self.intKeys { d.set(self[keyPath: p], forKey: "TTSSH." + k) }
        for (k, p) in Self.boolKeys { d.set(self[keyPath: p], forKey: "TTSSH." + k) }
        for (k, p) in Self.stringKeys { d.set(self[keyPath: p], forKey: "TTSSH." + k) }
        for (k, p) in Self.listKeys { d.set(self[keyPath: p].joined(separator: ","), forKey: "TTSSH." + k) }
        d.set(knownHostsFiles, forKey: "TTSSH.KnownHostsFiles")
    }

    /// KnownHostsFiles=読み書き;読み取り専用
    var knownHostsFiles: String {
        get { knownHostsRO.isEmpty ? knownHostsRW : knownHostsRW + ";" + knownHostsRO }
        set {
            let p = newValue.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            knownHostsRW = p.first ?? ""
            knownHostsRO = p.count > 1 ? p[1] : ""
        }
    }

    static func splitList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: INI

    mutating func read(_ ini: IniFile) {
        let S = "TTSSH"
        for (k, p) in Self.intKeys { if let v = ini.int(S, k) { self[keyPath: p] = v } }
        for (k, p) in Self.boolKeys { if let v = ini.onOff(S, k) ?? ini.int(S, k).map({ $0 != 0 }) { self[keyPath: p] = v } }
        for (k, p) in Self.stringKeys { if let v = ini.string(S, k) { self[keyPath: p] = v } }
        for (k, p) in Self.listKeys { if let v = ini.string(S, k) { self[keyPath: p] = Self.splitList(v) } }
        if let v = ini.string(S, "KnownHostsFiles"), !v.isEmpty {
            // Windows の既定 "ssh_known_hosts" (Tera Term のフォルダ) は Mac では ~/.ssh/known_hosts
            knownHostsFiles = v.lowercased() == "ssh_known_hosts" ? "~/.ssh/known_hosts" : v
        }
    }

    func write(_ doc: IniDocument) {
        let S = "TTSSH"
        for (k, p) in Self.intKeys { doc.set(S, k, String(self[keyPath: p])) }
        for (k, p) in Self.boolKeys { doc.set(S, k, self[keyPath: p] ? "1" : "0") }
        for (k, p) in Self.stringKeys { doc.set(S, k, self[keyPath: p]) }
        for (k, p) in Self.listKeys { doc.set(S, k, self[keyPath: p].joined(separator: ",")) }
        doc.set(S, "KnownHostsFiles", knownHostsFiles)
    }

    // MARK: ssh のオプション

    /// ssh に渡す引数 (makeConnection の sshArgs の前に付ける)
    func sshArgs() -> [String] {
        var a: [String] = []
        func o(_ s: String) { a += ["-o", s] }
        if compression > 0 { o("Compression=yes") }
        if !cipherOrder.isEmpty { o("Ciphers=" + cipherOrder.joined(separator: ",")) }
        if !kexOrder.isEmpty { o("KexAlgorithms=" + kexOrder.joined(separator: ",")) }
        if !hostKeyOrder.isEmpty { o("HostKeyAlgorithms=" + hostKeyOrder.joined(separator: ",")) }
        if !macOrder.isEmpty { o("MACs=" + macOrder.joined(separator: ",")) }
        func path(_ p: String) -> String {
            let e = (p as NSString).expandingTildeInPath
            return e.hasPrefix("/") ? e : (AppPaths.setupDirectory as NSString).appendingPathComponent(e)
        }
        if !knownHostsRW.isEmpty && path(knownHostsRW) != path("~/.ssh/known_hosts") { o("UserKnownHostsFile=" + quoted(path(knownHostsRW))) }
        if !knownHostsRO.isEmpty { o("GlobalKnownHostsFile=" + quoted(path(knownHostsRO))) }
        o("ServerAliveInterval=\(max(0, heartBeat))")
        if forwardAgent { o("ForwardAgent=yes") }
        o("VerifyHostKeyDNS=" + (verifyHostKeyDNS ? "yes" : "no"))
        o("UpdateHostKeys=" + ["no", "yes", "ask"][max(0, min(2, updateHostkeys))])
        if logLevel > 0 {
            // TTSSH は TTSSH.LOG に書く。ssh -E で同じ名前のファイルへ
            let levels = ["INFO", "VERBOSE", "DEBUG1", "DEBUG2", "DEBUG3"]
            o("LogLevel=" + levels[min(levels.count - 1, max(0, logLevel / 25))])
            a += ["-E", (AppPaths.setupDirectory as NSString).appendingPathComponent("TTSSH.LOG")]
        }
        switch defaultAuthMethod {
        case 2, 16: o("PreferredAuthentications=publickey,keyboard-interactive,password")
        case 5: o("PreferredAuthentications=keyboard-interactive,password,publickey")
        default: break   // パスワード: ssh の標準の順のまま (公開鍵がなければパスワードを聞く)
        }
        for f in ForwardSpec.parseList(defaultForwarding) { a += f.sshArgs }
        if gatewayPorts { a.append("-g") }
        return a
    }

    private func quoted(_ s: String) -> String { s.contains(" ") ? "\"\(s)\"" : s }

    /// 認証設定の既定のユーザ名 (接続ダイアログに出す)
    var defaultUser: String {
        switch defaultUserType {
        case 0: return ""
        case 2: return NSUserName()
        default: return defaultUserName
        }
    }
}

/// ポート転送の 1 件 (TTSSH の DefaultForwarding の 1 項目。ssh -L / -R / -D と同じ書き方)
struct ForwardSpec: Equatable {
    enum Kind: String { case local = "L", remote = "R", dynamic = "D", x11 = "X" }
    var kind: Kind
    var listen = ""          // リッスンするアドレス (空 = 既定)
    var port = ""
    var host = ""
    var hostPort = ""

    static func parseList(_ s: String) -> [ForwardSpec] { s.split(separator: ";").compactMap { parse(String($0)) } }

    static func parse(_ raw: String) -> ForwardSpec? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let c = t.first, let k = Kind(rawValue: String(c).uppercased()) else { return nil }
        if k == .x11 { return ForwardSpec(kind: .x11) }
        // ':' で区切る ([...] の中は区切らない)
        var parts: [String] = [], cur = "", br = false
        for ch in t.dropFirst() {
            if ch == "[" { br = true } else if ch == "]" { br = false }
            if ch == ":" && !br { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        parts.append(cur)
        var f = ForwardSpec(kind: k)
        if k == .dynamic {
            if parts.count >= 2 { f.listen = parts[0]; f.port = parts[1] } else { f.port = parts[0] }
        } else {
            if parts.count >= 4 { f.listen = parts[0]; parts.removeFirst() }
            guard parts.count == 3 else { return nil }
            (f.port, f.host, f.hostPort) = (parts[0], parts[1], parts[2])
        }
        return f
    }

    var text: String {
        let l = listen.isEmpty ? "" : listen + ":"
        switch kind {
        case .x11: return "X"
        case .dynamic: return "D" + l + port
        default: return kind.rawValue + l + port + ":" + host + ":" + hostPort
        }
    }

    /// 一覧に出す説明 (TTSSH の "Local 8080 to remote host:80" にあたる)
    var display: String {
        let l = listen.isEmpty ? "" : listen + ":"
        switch kind {
        case .x11: return Lang.m("CONN_FWD_X11", "X11 (リモートのXアプリケーションをローカルのXサーバに表示)")
        case .dynamic: return Lang.m("CONN_FWD_DYNAMIC", "ダイナミック %s", l + port)
        case .local: return Lang.m("CONN_FWD_LOCAL", "ローカル %s → リモート %s:%s", l + port, host, hostPort)
        case .remote: return Lang.m("CONN_FWD_REMOTE", "リモート %s → ローカル %s:%s", l + port, host, hostPort)
        }
    }

    var sshArgs: [String] {
        let l = listen.isEmpty ? "" : listen + ":"
        switch kind {
        case .x11: return ["-X"]
        case .dynamic: return ["-D", l + port]
        case .local: return ["-L", l + port + ":" + host + ":" + hostPort]
        case .remote: return ["-R", l + port + ":" + host + ":" + hostPort]
        }
    }
}

/// TTProxy の設定
struct ProxySettings: Equatable {
    var type = "none"            // ProxyType none / http / telnet / socks4 / socks5
    var host = ""                // ProxyHost
    var port = 0                 // ProxyPort
    var user = ""                // ProxyUser
    var pass = ""                // ProxyPass
    var timeout = 10             // ConnectionTimeout
    var resolve = "auto"         // SocksResolve auto / remote / local
    var debugLog = ""            // DebugLog
    var telnetHostnamePrompt = ">> Host name: "
    var telnetUsernamePrompt = "Username:"
    var telnetPasswordPrompt = "Password:"
    var telnetConnectedMessage = "-- Connected to "
    var telnetErrorMessage = "!!!!!!!!"

    static let types = ["none", "http", "telnet", "socks4", "socks5"]
    static let stringKeys: [(String, WritableKeyPath<ProxySettings, String>)] = [
        ("ProxyType", \.type), ("ProxyHost", \.host), ("ProxyUser", \.user), ("ProxyPass", \.pass),
        ("SocksResolve", \.resolve), ("DebugLog", \.debugLog),
        ("TelnetHostnamePrompt", \.telnetHostnamePrompt), ("TelnetUsernamePrompt", \.telnetUsernamePrompt),
        ("TelnetPasswordPrompt", \.telnetPasswordPrompt), ("TelnetConnectedMessage", \.telnetConnectedMessage),
        ("TelnetErrorMessage", \.telnetErrorMessage),
    ]
    static let intKeys: [(String, WritableKeyPath<ProxySettings, Int>)] = [("ProxyPort", \.port), ("ConnectionTimeout", \.timeout)]

    static func load() -> ProxySettings {
        let d = UserDefaults.standard
        var s = ProxySettings()
        for (k, p) in stringKeys { if let v = d.string(forKey: "TTProxy." + k) { s[keyPath: p] = v } }
        for (k, p) in intKeys where d.object(forKey: "TTProxy." + k) != nil { s[keyPath: p] = d.integer(forKey: "TTProxy." + k) }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        for (k, p) in Self.stringKeys { d.set(self[keyPath: p], forKey: "TTProxy." + k) }
        for (k, p) in Self.intKeys { d.set(self[keyPath: p], forKey: "TTProxy." + k) }
    }

    mutating func read(_ ini: IniFile) {
        for (k, p) in Self.stringKeys { if let v = ini.string("TTProxy", k) { self[keyPath: p] = v } }
        for (k, p) in Self.intKeys { if let v = ini.int("TTProxy", k) { self[keyPath: p] = v } }
        type = type.lowercased()
        if type == "socks" { type = "socks5" }
        if !Self.types.contains(type) { type = "none" }
    }

    func write(_ doc: IniDocument) {
        let on = type != "none" && !host.isEmpty
        doc.set("TTProxy", "ProxyType", on ? type : nil)
        doc.set("TTProxy", "ProxyHost", on ? host : nil)
        doc.set("TTProxy", "ProxyPort", on && port != 0 ? String(port) : nil)
        doc.set("TTProxy", "ProxyUser", on && !user.isEmpty ? user : nil)
        doc.set("TTProxy", "ProxyPass", on && !user.isEmpty && !pass.isEmpty ? pass : nil)
        doc.set("TTProxy", "ConnectionTimeout", String(timeout))
        doc.set("TTProxy", "SocksResolve", resolve)
        for (k, p) in Self.stringKeys.dropFirst(6) { doc.set("TTProxy", k, self[keyPath: p]) }
        doc.set("TTProxy", "DebugLog", debugLog.isEmpty ? nil : debugLog)
    }

    /// URL表現 (TTProxy の IDC_URL)
    var url: String {
        guard type != "none", !host.isEmpty else { return "" }
        var s = type + "://"
        if !user.isEmpty { s += user + (pass.isEmpty ? "" : ":" + String(repeating: "*", count: pass.count)) + "@" }
        s += host
        if port != 0 { s += ":\(port)" }
        return s
    }

    /// 接続に使う形 (TeraCore の ProxyHandshake へ渡す)。プロキシを使わなければ nil
    var config: ProxyConfig? {
        let c = ProxyConfig(type: type, host: host, port: port, user: user, pass: pass, timeout: timeout, resolve: resolve,
                            telnetPrompts: [telnetHostnamePrompt, telnetUsernamePrompt, telnetPasswordPrompt,
                                            telnetConnectedMessage, telnetErrorMessage])
        return c.isEnabled ? c : nil
    }

    /// ssh の ProxyCommand。nc では TELNET プロキシと SOCKS5 / HTTP のパスワード認証ができないので、
    /// このアプリ自身を --proxy-connect で動かし、TTProxy と同じやりとり (ProxyHandshake) で中継する。
    /// 設定 (パスワードを含む) はコマンドラインに出さず、環境変数 (sshEnvironment) で渡す
    func sshArgs() -> [String] {
        guard config != nil, let exe = ProxyRelay.executablePath else { return [] }
        let q = "\"" + exe.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`") + "\""
        var a = ["-o", "ProxyCommand=\(q) \(ProxyRelay.argument) %h %p"]
        if timeout > 0 { a += ["-o", "ConnectTimeout=\(timeout)"] }
        return a
    }

    /// ProxyCommand に渡す環境変数
    var sshEnvironment: [String: String] { config?.environment ?? [:] }
}

extension ProxySettings {
    /// TTProxy のコマンドライン (-proxy=URL / -noproxy) で defaultProxy を置き換えたもの (この接続だけ)。
    /// ユーザー名・パスワードも URL のもの (なければ空)。タイムアウト・SocksResolve・Telnet のプロンプトは設定のまま
    func overridden(by u: ProxyURL?) -> ProxySettings {
        guard let u = u else { return self }
        var s = self
        s.type = u.usesProxy ? u.typeName : "none"
        s.host = u.host
        s.port = u.port
        s.user = u.user
        s.pass = u.pass
        return s
    }
}

/// 新しい SSH 接続に足す引数 (SessionWindowController.connect から呼ぶ)
enum SSHSetupArgs {
    static func forConnection(_ spec: ConnectionSpec, proxy: ProxySettings = ProxySettings.load()) -> [String] {
        guard case .ssh = spec else { return [] }
        return proxy.sshArgs() + SSHSettings.load().sshArgs()
    }

    /// ssh を動かすときの環境変数 (プロキシの設定)
    static func environment(_ spec: ConnectionSpec, proxy: ProxySettings = ProxySettings.load()) -> [String: String] {
        guard case .ssh = spec else { return [:] }
        return proxy.sshEnvironment
    }
}

// MARK: - SSH… (TTSSH: 設定)

/// 優先順の一覧 (上へ/下へ と 「<以下の…は使用されません>」の境目)
final class AlgorithmOrderList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let scroll = NSScrollView()
    private(set) var items: [String]   // 境目を含む
    let border: String

    init(enabled: [String], all: [String], border: String) {
        self.border = border
        items = enabled + [border] + all.filter { !enabled.contains($0) }
        super.init()
        let col = NSTableColumn(identifier: .init("a"))
        col.width = 300
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 16
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 320).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 76).isActive = true
    }

    var enabled: [String] { Array(items.prefix(while: { $0 != border })) }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let f = NSTextField(labelWithString: items[row])
        f.font = .systemFont(ofSize: 11)
        if items[row] == border { f.textColor = .secondaryLabelColor }
        return f
    }

    @objc func up() { move(-1) }
    @objc func down() { move(1) }
    private func move(_ d: Int) {
        let r = table.selectedRow
        guard r >= 0, r + d >= 0, r + d < items.count else { return }
        items.swapAt(r, r + d)
        table.reloadData()
        table.selectRowIndexes([r + d], byExtendingSelection: false)
    }

    func view(title: String, upTitle: String, downTitle: String) -> NSView {
        let up = SetupUI.button(upTitle, target: self, action: #selector(up))
        let down = SetupUI.button(downTitle, target: self, action: #selector(down))
        let buttons = SetupUI.column([up, down])
        return SetupUI.column([SetupUI.label(title), SetupUI.row([scroll, buttons])], spacing: 4)
    }
}

enum SSHAlgorithms {
    /// ssh -Q の一覧
    static func supported(_ q: String) -> [String] { run(["/usr/bin/ssh", "-Q", q]).split(separator: "\n").map(String.init) }
    /// ssh -G の標準の順 (key 名は小文字)
    static func defaults() -> [String: [String]] {
        var r: [String: [String]] = [:]
        for line in run(["/usr/bin/ssh", "-G", "-o", "BatchMode=yes", "localhost"]).split(separator: "\n") {
            let p = line.split(separator: " ", maxSplits: 1).map(String.init)
            if p.count == 2, ["ciphers", "kexalgorithms", "hostkeyalgorithms", "macs"].contains(p[0]) {
                r[p[0]] = SSHSettings.splitList(p[1])
            }
        }
        return r
    }
    static func run(_ argv: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class SSHSetupDialog: SheetDialog {
    private var s = SSHSettings.load()
    private let compSlider = NSSlider(value: 0, minValue: 0, maxValue: 9, target: nil, action: nil)
    private var lists: [AlgorithmOrderList] = []
    private let rwField = SetupUI.field(width: 260)
    private let roField = SetupUI.field(width: 260)
    private let hbField = SetupUI.field(width: 60)
    private let agentCheck = SetupUI.check(Lang.t("TTSSH", "DLG_SSHSETUP_FORWARDAGENT", "エージェント転送を有効にする(&A)"))
    private let dnsCheck = SetupUI.check(Lang.t("TTSSH", "DLG_SSHSETUP_VERIFYHOSTKEYDNS", "ホストキーの鍵指紋をDNSで確認する(&V)"))
    private let rotationPopup = SetupUI.popup([Lang.t("TTSSH", "DLG_SSHSETUP_HOSTKEY_ROTATION_NO", "無効"), Lang.t("TTSSH", "DLG_SSHSETUP_HOSTKEY_ROTATION_YES", "有効"), Lang.t("TTSSH", "DLG_SSHSETUP_HOSTKEY_ROTATION_ASK", "確認する")])
    private let logField = SetupUI.field(width: 60)

    func begin(on w: NSWindow) {
        panel.title = Lang.t("TTSSH", "DLG_SSHSETUP_TITLE", "TTSSH: 設定")
        compSlider.numberOfTickMarks = 10
        compSlider.allowsTickMarkValuesOnly = true
        compSlider.integerValue = s.compression
        compSlider.translatesAutoresizingMaskIntoConstraints = false
        compSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let defs = SSHAlgorithms.defaults()
        func list(_ cur: [String], _ q: String, _ key: String, _ border: String) -> AlgorithmOrderList {
            let all = SSHAlgorithms.supported(q)
            let enabled = cur.isEmpty ? (defs[key] ?? all) : cur
            return AlgorithmOrderList(enabled: enabled, all: all + (defs[key] ?? []).filter { !all.contains($0) }, border: border)
        }
        let cipher = list(s.cipherOrder, "cipher", "ciphers", Lang.t("TTSSH", "DLG_SSHSETUP_CIPHER_BORDER", "<以下の暗号アルゴリズムは使用されません>"))
        let kex = list(s.kexOrder, "kex", "kexalgorithms", Lang.t("TTSSH", "DLG_SSHSETUP_KEX_BORDER", "<以下の鍵交換アルゴリズムは使用されません>"))
        let hk = list(s.hostKeyOrder, "key", "hostkeyalgorithms", Lang.t("TTSSH", "DLG_SSHSETUP_HOST_KEY_BORDER", "<以下のホストキーアルゴリズムは使用されません>"))
        let mac = list(s.macOrder, "mac", "macs", Lang.t("TTSSH", "DLG_SSHSETUP_MAC_BORDER", "<以下のMACアルゴリズムは使用されません>"))
        lists = [cipher, kex, hk, mac]
        rwField.stringValue = s.knownHostsRW
        roField.stringValue = s.knownHostsRO
        hbField.stringValue = String(s.heartBeat)
        agentCheck.state = s.forwardAgent ? .on : .off
        dnsCheck.state = s.verifyHostKeyDNS ? .on : .off
        rotationPopup.selectItem(at: max(0, min(2, s.updateHostkeys)))
        logField.stringValue = String(s.logLevel)

        let note = NSTextField(wrappingLabelWithString: Lang.m("CONN_COMPRESS_NOTE", "SSH2: '圧縮レベル' が 0 でなければ圧縮が有効になります (OpenSSH は圧縮レベルを選べません)。"))
        note.preferredMaxLayoutWidth = 520
        note.font = .systemFont(ofSize: 11)
        let left = SetupUI.column([
            SetupUI.row([SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_COMPRESS", "圧縮レベル(&C):")), SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_COMPRESS_NONE", "なし")), compSlider, SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_COMPRESS_HIGHEST", "最高"))]),
            note,
            cipher.view(title: Lang.t("TTSSH", "DLG_SSHSETUP_CIPHER", "優先する暗号アルゴリズムの順(&P)"), upTitle: Lang.t("TTSSH", "DLG_SSHSETUP_CIPHER_UP", "上へ(&1)"), downTitle: Lang.t("TTSSH", "DLG_SSHSETUP_CIPHER_DOWN", "下へ(&2)")),
            kex.view(title: Lang.t("TTSSH", "DLG_SSHSETUP_KEX", "優先する鍵交換アルゴリズムの順(&E) (SSH2のみ)"), upTitle: Lang.t("TTSSH", "DLG_SSHSETUP_KEX_UP", "上へ(&3)"), downTitle: Lang.t("TTSSH", "DLG_SSHSETUP_KEX_DOWN", "下へ(&4)")),
            hk.view(title: Lang.t("TTSSH", "DLG_SSHSETUP_HOST_KEY", "優先するホストキーアルゴリズムの順(&S) (SSH2のみ)"), upTitle: Lang.t("TTSSH", "DLG_SSHSETUP_HOST_KEY_UP", "上へ(&5)"), downTitle: Lang.t("TTSSH", "DLG_SSHSETUP_HOST_KEY_DOWN", "下へ(&6)")),
            mac.view(title: Lang.t("TTSSH", "DLG_SSHSETUP_MAC", "優先するMACアルゴリズムの順(&D) (SSH2のみ)"), upTitle: Lang.t("TTSSH", "DLG_SSHSETUP_MAC_UP", "上へ(&7)"), downTitle: Lang.t("TTSSH", "DLG_SSHSETUP_MAC_DOWN", "下へ(&8)")),
        ], spacing: 8)
        let chooseRW = SetupUI.button("...", target: self, action: #selector(chooseRW))
        let chooseRO = SetupUI.button("...", target: self, action: #selector(chooseRO))
        let known = SetupUI.box(Lang.t("TTSSH", "DLG_SSHSETUP_KNOWNHOST", "SSH Known Hosts"), SetupUI.grid([
            [SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_KNOWNHOST_RW", "読み書き(&W):")), SetupUI.row([rwField, chooseRW])],
            [SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_KNOWNHOST_RO", "読み取り専用(&R):")), SetupUI.row([roField, chooseRO])],
        ]))
        let right = SetupUI.column([
            known,
            SetupUI.row([SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_HEARTBEAT", "&Keepalive")), hbField, SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_HEARTBEAT_UNIT", "秒(0を指定すると無効)"))]),
            agentCheck, dnsCheck,
            SetupUI.row([SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_HOSTKEY_ROTATION", "ホスト公開鍵の自動更新(&N)")), rotationPopup]),
            SetupUI.row([SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_LOGLEVEL", "ログレベル(&L)")), logField, SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_LOGLEVEL_UNIT", "(0を指定すると無効)"))]),
            SetupUI.label(Lang.t("TTSSH", "DLG_SSHSETUP_NOTICE", "いずれの変更も次回のセッション以降有効になります.")),
        ], spacing: 10)
        layout(SetupUI.row([left, right], spacing: 20, align: .top))
        present(on: w)
    }

    @objc private func chooseRW() { choose(rwField) }
    @objc private func chooseRO() { choose(roField) }
    private func choose(_ f: NSTextField) {
        let p = NSOpenPanel()
        p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { f.stringValue = u.path } }
    }

    override func ok() {
        s.compression = compSlider.integerValue
        let defs = SSHAlgorithms.defaults()
        func val(_ l: AlgorithmOrderList, _ key: String) -> [String] { l.enabled == defs[key] ? [] : l.enabled }
        s.cipherOrder = val(lists[0], "ciphers")
        s.kexOrder = val(lists[1], "kexalgorithms")
        s.hostKeyOrder = val(lists[2], "hostkeyalgorithms")
        s.macOrder = val(lists[3], "macs")
        s.knownHostsRW = rwField.stringValue
        s.knownHostsRO = roField.stringValue
        s.heartBeat = max(0, Int(hbField.stringValue) ?? s.heartBeat)
        s.forwardAgent = agentCheck.state == .on
        s.verifyHostKeyDNS = dnsCheck.state == .on
        s.updateHostkeys = rotationPopup.indexOfSelectedItem
        s.logLevel = max(0, Int(logField.stringValue) ?? 0)
        s.save()
        close()
    }
    override func cancel() { close() }
}

// MARK: - SSH認証… (TTSSH: 認証設定)

final class SSHAuthSetupDialog: SheetDialog {
    private var s = SSHSettings.load()
    private let noUser = SetupUI.radio(Lang.t("TTSSH", "DLG_AUTHSETUP_NO_USERNAME", "入力しない(&D)"))
    private let defUser = SetupUI.radio(Lang.t("TTSSH", "DLG_AUTHSETUP_DEFAULT_USERNAME", "デフォルトユーザ名を使用(&S):"))
    private let logonUser = SetupUI.radio(Lang.t("TTSSH", "DLG_AUTHSETUP_LOGON_USERNAME", "ログオンユーザ名を使用(&E):"))
    private let userField = SetupUI.field(width: 180)
    private let mPassword = SetupUI.radio(Lang.t("TTSSH", "DLG_AUTHSETUP_METHOD_PASSWORD", "プレインパスワードを使う(&L)"))
    private let mKey = SetupUI.radio(Lang.t("TTSSH", "DLG_AUTHSETUP_METHOD_RSA", "&RSA/DSA/ECDSA/ED25519鍵を使う"))
    private let mChallenge = SetupUI.radio("SSH2:" + Lang.t("TTSSH", "DLG_AUTH_METHOD_CHALLENGE2", "キーボードインタラクティブ認証を使う"))
    private let mAgent = SetupUI.radio(Lang.m("CONN_USE_SSH_AGENT", "ssh-agent を使う (Pageant にあたるもの)"))
    private let keyField = SetupUI.field(width: 240)

    func begin(on w: NSWindow) {
        panel.title = Lang.t("TTSSH", "DLG_AUTHSETUP_TITLE", "TTSSH: 認証設定")
        for b in [noUser, defUser, logonUser] { b.target = self; b.action = #selector(userTypeChanged(_:)) }
        for b in [mPassword, mKey, mChallenge, mAgent] { b.target = self; b.action = #selector(methodChanged(_:)) }
        [noUser, defUser, logonUser][max(0, min(2, s.defaultUserType))].state = .on
        userField.stringValue = s.defaultUserName
        switch s.defaultAuthMethod {
        case 2: mKey.state = .on
        case 5: mChallenge.state = .on
        case 16: mAgent.state = .on
        default: mPassword.state = .on
        }
        keyField.stringValue = s.defaultRSAPrivateKeyFile.isEmpty ? ConnHistory.lastKeyFile : s.defaultRSAPrivateKeyFile
        let keyButton = SetupUI.button(Lang.m("CONN_PRIVATE_KEY_BUTTON", "秘密鍵(&K)..."), target: self, action: #selector(chooseKey))
        let userBox = SetupUI.box(Lang.t("TTSSH", "DLG_AUTHSETUP_USERNAME", "ユーザ名"), SetupUI.column([
            noUser, SetupUI.row([defUser, userField]),
            SetupUI.row([logonUser, SetupUI.label(Lang.t("TTSSH", "DLG_AUTHSETUP_LOGON_USERNAME_TEXT", "現在のログオンユーザ名 \"%s\"", NSUserName()))]),
        ]))
        let methodBox = SetupUI.box(Lang.t("TTSSH", "DLG_AUTHSETUP_METHOD", "認証方式"), SetupUI.column([
            mPassword, mKey, SetupUI.indent(SetupUI.row([keyButton, keyField])), mChallenge, mAgent,
        ]))
        layout(SetupUI.column([SetupUI.label(Lang.t("TTSSH", "DLG_AUTHSETUP_BANNER", "通常使用する認証設定:")), userBox, methodBox], spacing: 10))
        userTypeChanged(nil)
        methodChanged(nil)
        present(on: w)
    }

    @objc private func userTypeChanged(_ sender: NSButton?) {
        if let b = sender { for r in [noUser, defUser, logonUser] where r !== b { r.state = .off } }
        userField.isEnabled = defUser.state == .on
    }
    @objc private func methodChanged(_ sender: NSButton?) {
        if let b = sender { for r in [mPassword, mKey, mChallenge, mAgent] where r !== b { r.state = .off } }
        keyField.isEnabled = mKey.state == .on
    }
    @objc private func chooseKey() {
        let p = NSOpenPanel()
        p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { self.keyField.stringValue = u.path } }
    }

    override func ok() {
        s.defaultUserType = noUser.state == .on ? 0 : (logonUser.state == .on ? 2 : 1)
        s.defaultUserName = userField.stringValue
        s.defaultAuthMethod = mKey.state == .on ? 2 : (mChallenge.state == .on ? 5 : (mAgent.state == .on ? 16 : 3))
        s.defaultRSAPrivateKeyFile = keyField.stringValue
        s.save()
        // 接続ダイアログの既定に使う
        ConnHistory.lastUser = s.defaultUser
        ConnHistory.lastKeyFile = s.defaultAuthMethod == 2 ? s.defaultRSAPrivateKeyFile : ""
        close()
    }
    override func cancel() { close() }
}

// MARK: - SSH転送… (TTSSH: ポート転送設定)

final class SSHForwardSetupDialog: SheetDialog, NSTableViewDataSource, NSTableViewDelegate {
    private var s = SSHSettings.load()
    private var specs: [ForwardSpec] = []
    private let table = NSTableView()
    private let gatewayCheck = SetupUI.check(Lang.t("TTSSH", "DLG_FWDSETUP_CHECKIDENTITY", "ローカルのポートは他のホストからの接続を受け入れる(&C)"))
    private let xCheck = SetupUI.check(Lang.t("TTSSH", "DLG_FWDSETUP_XAPP", "リモートの&XアプリケーションをローカルのXサーバに表示する"))

    func begin(on w: NSWindow) {
        panel.title = Lang.t("TTSSH", "DLG_FWDSETUP_TITLE", "TTSSH: ポート転送設定")
        let all = ForwardSpec.parseList(s.defaultForwarding)
        specs = all.filter { $0.kind != .x11 }
        xCheck.state = all.contains { $0.kind == .x11 } ? .on : .off
        gatewayCheck.state = s.gatewayPorts ? .on : .off
        let col = NSTableColumn(identifier: .init("f"))
        col.width = 420
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(edit)
        table.target = self
        let sc = NSScrollView()
        sc.documentView = table
        sc.hasVerticalScroller = true
        sc.borderType = .bezelBorder
        sc.translatesAutoresizingMaskIntoConstraints = false
        sc.widthAnchor.constraint(equalToConstant: 430).isActive = true
        sc.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let buttons = SetupUI.column([
            SetupUI.button(Lang.t("TTSSH", "DLG_FWDSETUP_ADD", "追加(&A)..."), target: self, action: #selector(add)),
            SetupUI.button(Lang.t("TTSSH", "DLG_FWDSETUP_EDIT", "編集(&E)..."), target: self, action: #selector(edit)),
            SetupUI.button(Lang.t("TTSSH", "DLG_FWDSETUP_REMOVE", "削除(&R)"), target: self, action: #selector(remove)),
        ])
        let fwdBox = SetupUI.box(Lang.t("TTSSH", "DLG_FWDSETUP_LIST", "ポート転送(&P)"), SetupUI.column([SetupUI.row([sc, buttons], align: .top), gatewayCheck]))
        let xBox = SetupUI.box(Lang.t("TTSSH", "DLG_FWDSETUP_X", "Xクライアントアプリケーションの転送"), xCheck)
        layout(SetupUI.column([fwdBox, xBox], spacing: 10))
        present(on: w)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { specs.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: specs[row].display)
    }

    @objc private func add() {
        ForwardEditDialog(spec: ForwardSpec(kind: .local)).begin(on: panel) { [weak self] f in
            guard let self = self, let f = f else { return }
            self.specs.append(f); self.table.reloadData()
        }
    }
    @objc private func edit() {
        let r = table.selectedRow
        guard r >= 0 else { return }
        ForwardEditDialog(spec: specs[r]).begin(on: panel) { [weak self] f in
            guard let self = self, let f = f else { return }
            self.specs[r] = f; self.table.reloadData()
        }
    }
    @objc private func remove() {
        let r = table.selectedRow
        guard r >= 0 else { return }
        specs.remove(at: r)
        table.reloadData()
    }

    override func ok() {
        var all = specs
        if xCheck.state == .on { all.append(ForwardSpec(kind: .x11)) }
        s.defaultForwarding = all.map { $0.text }.joined(separator: ";")
        s.gatewayPorts = gatewayCheck.state == .on
        s.save()
        close()
    }
    override func cancel() { close() }
}

/// SSHポート転送 (1 件の追加・編集)
final class ForwardEditDialog: SheetDialog {
    private var spec: ForwardSpec
    private var completion: ((ForwardSpec?) -> Void)?
    private let rLocal = SetupUI.radio(Lang.t("TTSSH", "DLG_FWD_LOCAL_PORT", "ローカルのポート(&L)"))
    private let rRemote = SetupUI.radio(Lang.t("TTSSH", "DLG_FWD_REMOTE_PORT", "リモートサーバのポート(&R)"))
    private let rDynamic = SetupUI.radio(Lang.t("TTSSH", "DLG_FWD_DYNAMIC_PORT", "ダイナミックポート(&D)"))
    private let lPort = SetupUI.field(width: 70), lListen = SetupUI.field(width: 110), lHost = SetupUI.field(width: 150), lHostPort = SetupUI.field(width: 70)
    private let rPort = SetupUI.field(width: 70), rListen = SetupUI.field(width: 110), rHost = SetupUI.field(width: 150), rHostPort = SetupUI.field(width: 70)
    private let dPort = SetupUI.field(width: 70), dListen = SetupUI.field(width: 110)

    init(spec: ForwardSpec) { self.spec = spec; super.init() }

    func begin(on w: NSWindow, completion: @escaping (ForwardSpec?) -> Void) {
        self.completion = completion
        panel.title = Lang.t("TTSSH", "DLG_FWD_TITLE", "SSHポート転送")
        for b in [rLocal, rRemote, rDynamic] { b.target = self; b.action = #selector(kindChanged(_:)) }
        switch spec.kind {
        case .remote: rRemote.state = .on; (rPort.stringValue, rListen.stringValue, rHost.stringValue, rHostPort.stringValue) = (spec.port, spec.listen, spec.host, spec.hostPort)
        case .dynamic: rDynamic.state = .on; (dPort.stringValue, dListen.stringValue) = (spec.port, spec.listen)
        default: rLocal.state = .on; (lPort.stringValue, lListen.stringValue, lHost.stringValue, lHostPort.stringValue) = (spec.port, spec.listen, spec.host, spec.hostPort)
        }
        let body = SetupUI.column([
            SetupUI.label(Lang.t("TTSSH", "DLG_FWD_BANNER", "ポート転送を行う向きの選択:")),
            SetupUI.row([rLocal, lPort, SetupUI.label(Lang.t("TTSSH", "DLG_FWD_LOCAL_LISTEN", "リッスン(&I)")), lListen]),
            SetupUI.indent(SetupUI.row([SetupUI.label(Lang.t("TTSSH", "DLG_FWD_LOCAL_REMOTE", "リモート側ホスト(&M)")), lHost, SetupUI.label(Lang.t("TTSSH", "DLG_FWD_LOCAL_REMOTE_PORT", "ポート(&P)")), lHostPort])),
            SetupUI.row([rRemote, rPort, SetupUI.label(Lang.t("TTSSH", "DLG_FWD_REMOTE_LISTEN", "リッスン(&S)")), rListen]),
            SetupUI.indent(SetupUI.row([SetupUI.label(Lang.t("TTSSH", "DLG_FWD_REMOTE_LOCAL", "ローカル側ホスト(&A)")), rHost, SetupUI.label(Lang.t("TTSSH", "DLG_FWD_REMOTE_LOCAL_PORT", "ポート(&O)")), rHostPort])),
            SetupUI.row([rDynamic, dPort, SetupUI.label(Lang.t("TTSSH", "DLG_FWD_DYNAMIC_LISTEN", "リッスン(&T)")), dListen]),
        ], spacing: 8)
        layout(body)
        kindChanged(nil)
        present(on: w)
    }

    @objc private func kindChanged(_ sender: NSButton?) {
        if let b = sender { for r in [rLocal, rRemote, rDynamic] where r !== b { r.state = .off } }
        for f in [lPort, lListen, lHost, lHostPort] { f.isEnabled = rLocal.state == .on }
        for f in [rPort, rListen, rHost, rHostPort] { f.isEnabled = rRemote.state == .on }
        for f in [dPort, dListen] { f.isEnabled = rDynamic.state == .on }
    }

    override func ok() {
        var f: ForwardSpec
        if rRemote.state == .on {
            f = ForwardSpec(kind: .remote, listen: rListen.stringValue, port: rPort.stringValue, host: rHost.stringValue, hostPort: rHostPort.stringValue)
        } else if rDynamic.state == .on {
            f = ForwardSpec(kind: .dynamic, listen: dListen.stringValue, port: dPort.stringValue)
        } else {
            f = ForwardSpec(kind: .local, listen: lListen.stringValue, port: lPort.stringValue, host: lHost.stringValue, hostPort: lHostPort.stringValue)
        }
        f.port = f.port.trimmingCharacters(in: .whitespaces)
        guard !f.port.isEmpty, f.kind == .dynamic || (!f.host.isEmpty && !f.hostPort.isEmpty) else { NSSound.beep(); return }
        close()
        completion?(f)
    }
    override func cancel() { close(); completion?(nil) }
}

// MARK: - SSH鍵生成… (TTSSH: 鍵生成)

final class SSHKeyGenDialog: SheetDialog {
    private let types: [(String, String, Int?)] = [   // 表示, ssh-keygen -t, -b (nil = 固定)
        ("&RSA", "rsa", nil), ("&DSA", "dsa", 1024), ("ECDSA-&256", "ecdsa", 256),
        ("ECDSA-&384", "ecdsa", 384), ("ECDSA-&521", "ecdsa", 521), ("&ED25519", "ed25519", 256),
    ]
    private var radios: [NSButton] = []
    private let bitsField = SetupUI.field(width: 60)
    private let progress = NSTextField(labelWithString: "")
    private let passField = SetupUI.secure(width: 220)
    private let pass2Field = SetupUI.secure(width: 220)
    private let commentField = SetupUI.field(width: 220)
    private let bcryptCheck = SetupUI.check(Lang.t("TTSSH", "DLG_KEYGEN_BCRYPT_KDF", "bcrypt KDF形式(&K)"))
    private let roundsField = SetupUI.field(width: 50)
    private let savePub = SetupUI.button(Lang.t("TTSSH", "DLG_KEYGEN_SAVEPUBLIC", "公開鍵の保存(&I)"))
    private let savePriv = SetupUI.button(Lang.t("TTSSH", "DLG_KEYGEN_SAVEPRIVATE", "秘密鍵の保存(&P)"))
    private var tmpDir: String?
    private var generatedType = "rsa"

    func begin(on w: NSWindow) {
        panel.title = Lang.t("TTSSH", "DLG_KEYGEN_TITLE", "TTSSH: 鍵生成")
        okButton.title = Lang.t("TTSSH", "DLG_KEYGEN_GENERATE", "生成")
        cancelButton.title = Lang.t("TTSSH", "BTN_CLOSE", "閉じる")
        radios = types.map { SetupUI.radio($0.0, target: self, action: #selector(typeChanged(_:))) }
        radios[0].state = .on
        bitsField.stringValue = "3072"
        commentField.stringValue = "\(NSUserName())@\(Host.current().localizedName ?? "localhost")"
        bcryptCheck.state = .on
        bcryptCheck.target = self; bcryptCheck.action = #selector(bcryptChanged)
        roundsField.stringValue = "16"
        savePub.target = self; savePub.action = #selector(savePublic)
        savePriv.target = self; savePriv.action = #selector(savePrivate)
        savePub.isEnabled = false; savePriv.isEnabled = false
        let typeBox = SetupUI.box(Lang.t("TTSSH", "DLG_KEYGEN_KEYTYPE", "鍵の種類"), SetupUI.column([
            SetupUI.row(Array(radios[0..<2])), SetupUI.row(Array(radios[2..<4])), SetupUI.row(Array(radios[4..<6])),
        ]))
        let body = SetupUI.column([
            SetupUI.row([typeBox, SetupUI.column([SetupUI.label(Lang.t("TTSSH", "DLG_KEYGEN_BITS", "ビット数(&B):")), bitsField])], align: .top),
            progress,
            SetupUI.grid([
                [SetupUI.label(Lang.t("TTSSH", "DLG_KEYGEN_PASSPHRASE", "鍵のパスフレーズ:")), passField],
                [SetupUI.label(Lang.t("TTSSH", "DLG_KEYGEN_PASSPHRASE2", "パスフレーズの確認:")), pass2Field],
                [SetupUI.label(Lang.t("TTSSH", "DLG_KEYGEN_COMMENT", "コメント(&O):")), commentField],
            ]),
            SetupUI.row([bcryptCheck, SetupUI.label(Lang.t("TTSSH", "DLG_KEYGEN_BCRYPT_ROUNDS", "ラウンド数(&N):")), roundsField]),
            SetupUI.row([savePub, savePriv]),
        ], spacing: 10)
        layout(body)
        present(on: w)
    }

    @objc private func typeChanged(_ sender: NSButton) {
        for r in radios where r !== sender { r.state = .off }
        let i = radios.firstIndex(of: sender) ?? 0
        if let b = types[i].2 { bitsField.stringValue = String(b); bitsField.isEnabled = false } else {
            bitsField.isEnabled = true
            if (Int(bitsField.stringValue) ?? 0) < 1024 { bitsField.stringValue = "3072" }
        }
    }
    @objc private func bcryptChanged() { roundsField.isEnabled = bcryptCheck.state == .on }

    /// 生成 (ssh-keygen を一時フォルダで動かす。保存ボタンでコピーする)
    override func ok() {
        guard passField.stringValue == pass2Field.stringValue else {
            alert(Lang.t("TTSSH", "MSG_SAVE_PRIVATE_KEY_MISMATCH_ERROR", "パスフレーズが一致しません。")); return
        }
        let i = radios.firstIndex { $0.state == .on } ?? 0
        let t = types[i]
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("teramac-keygen-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var args = ["-q", "-t", t.1, "-N", passField.stringValue, "-C", commentField.stringValue, "-f", dir + "/id"]
        if t.1 == "rsa" || t.1 == "ecdsa" || t.1 == "dsa" { args += ["-b", bitsField.stringValue] }
        if bcryptCheck.state == .on { args += ["-a", String(max(1, Int(roundsField.stringValue) ?? 16))] } else { args += ["-m", "PEM"] }
        progress.stringValue = Lang.t("TTSSH", "MSG_KEYGEN_GENERATING", "生成中...")
        okButton.isEnabled = false
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = args
            let err = Pipe()
            p.standardError = err
            p.standardOutput = err
            p.standardInput = FileHandle.nullDevice
            var msg = ""
            do { try p.run(); p.waitUntilExit() } catch { msg = error.localizedDescription }
            msg += String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.okButton.isEnabled = true
                if p.terminationStatus == 0 && FileManager.default.fileExists(atPath: dir + "/id") {
                    self.tmpDir = dir
                    self.generatedType = t.1
                    self.progress.stringValue = Lang.t("TTSSH", "MSG_KEYGEN_GENERATED", "鍵を生成しました。")
                    self.savePub.isEnabled = true
                    self.savePriv.isEnabled = true
                } else {
                    self.progress.stringValue = ""
                    self.alert(Lang.m("CONN_KEYGEN_FAILED", "鍵を生成できませんでした。\n%s", msg))
                }
            }
        }
    }

    @objc private func savePublic() { save(suffix: ".pub", name: "id_\(generatedType).pub") }
    @objc private func savePrivate() { save(suffix: "", name: "id_\(generatedType)") }

    private func save(suffix: String, name: String) {
        guard let dir = tmpDir else { return }
        let p = NSSavePanel()
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.nameFieldStringValue = name
        p.showsHiddenFiles = true
        p.beginSheetModal(for: panel) { r in
            guard r == .OK, let u = p.url else { return }
            let fm = FileManager.default
            try? fm.removeItem(at: u)
            do {
                try fm.copyItem(atPath: dir + "/id" + suffix, toPath: u.path)
                try fm.setAttributes([.posixPermissions: suffix.isEmpty ? 0o600 : 0o644], ofItemAtPath: u.path)
            } catch { self.alert(Lang.m("CONN_SAVE_FAILED", "保存できませんでした。\n%s", error.localizedDescription)) }
        }
    }

    private func alert(_ s: String) {
        let a = NSAlert()
        a.messageText = "TTSSH"
        a.informativeText = s
        a.beginSheetModal(for: panel)
    }

    override func cancel() {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
        close()
    }
}

// MARK: - プロキシ… (TTProxy)

final class ProxySetupDialog: SheetDialog, NSTextFieldDelegate {
    private var s = ProxySettings.load()
    private let urlField = SetupUI.field(width: 300)
    private let typePopup = SetupUI.popup([Lang.t("TTProxy", "MSG_TYPE_NONE", "プロキシを使用しない"), "HTTP", "TELNET", "SOCKS4", "SOCKS5"])
    private let hostField = SetupUI.field(width: 220)
    private let portField = SetupUI.field(width: 70)
    private let userField = SetupUI.field(width: 160)
    private let passField = SetupUI.secure(width: 160)

    func begin(on w: NSWindow) {
        panel.title = Lang.t("TTProxy", "DLG_SETUP_TITLE", "プロキシの設定")
        urlField.isEditable = false
        typePopup.selectItem(at: ProxySettings.types.firstIndex(of: s.type) ?? 0)
        typePopup.target = self; typePopup.action = #selector(changed)
        hostField.stringValue = s.host
        portField.stringValue = s.port == 0 ? "" : String(s.port)
        userField.stringValue = s.user
        passField.stringValue = s.pass
        for f in [hostField, portField, userField, passField] { f.delegate = self }
        let other = SetupUI.button(Lang.t("TTProxy", "DLG_SETUP_OTHER", "その他の設定(&O)..."), target: self, action: #selector(otherSettings))
        layout(SetupUI.column([
            SetupUI.grid([
                [SetupUI.label(Lang.t("TTProxy", "DLG_SETUP_URL", "URL表現")), urlField],
                [SetupUI.label(Lang.t("TTProxy", "DLG_SETUP_TYPE", "種類(&T)")), typePopup],
                [SetupUI.label(Lang.t("TTProxy", "DLG_SETUP_HOST", "ホスト名(&H)")), hostField],
                [SetupUI.label(Lang.t("TTProxy", "DLG_SETUP_PORT", "ポート番号(&N)")), portField],
                [SetupUI.label(Lang.t("TTProxy", "DLG_SETUP_USER", "ユーザ名(&U)")), userField],
                [SetupUI.label(Lang.t("TTProxy", "DLG_SETUP_PASS", "パスワード(&P)")), passField],
            ]),
            other,
        ], spacing: 10))
        changed()
        present(on: w)
    }

    func controlTextDidChange(_ obj: Notification) { changed() }

    @objc private func changed() {
        read()
        let on = s.type != "none"
        for f in [hostField, portField, userField, passField] { f.isEnabled = on }
        urlField.stringValue = s.url
    }

    private func read() {
        s.type = ProxySettings.types[max(0, typePopup.indexOfSelectedItem)]
        s.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        s.port = Int(portField.stringValue) ?? 0
        s.user = userField.stringValue
        s.pass = passField.stringValue
    }

    @objc private func otherSettings() {
        ProxyOtherDialog(settings: s).begin(on: panel) { [weak self] r in if let r = r { self?.s = r; self?.changed() } }
    }

    override func ok() {
        read()
        if s.type != "none" {
            if s.host.isEmpty { msg(Lang.t("TTProxy", "MSG_EMPTY_HOSTNAME", "プロキシのホスト名を指定してください。")); return }
            if !portField.stringValue.isEmpty && s.port <= 0 { msg(Lang.t("TTProxy", "MSG_ILLEGAL_PORT", "ポート番号には正の整数を指定してください。")); return }
        }
        s.save()
        close()
    }
    override func cancel() { close() }

    private func msg(_ t: String) {
        let a = NSAlert()
        a.messageText = "TTProxy"
        a.informativeText = t
        a.beginSheetModal(for: panel)
    }
}

final class ProxyOtherDialog: SheetDialog {
    private var s: ProxySettings
    private var completion: ((ProxySettings?) -> Void)?
    private let timeoutField = SetupUI.field(width: 50)
    private let logField = SetupUI.field(width: 240)
    private let resolvePopup = SetupUI.popup([Lang.t("TTProxy", "DLG_OTHER_RESOLV_AUTO", "自動的に判断する"), Lang.t("TTProxy", "DLG_OTHER_RESOLV_REMOTE", "プロキシ側で解決する"), Lang.t("TTProxy", "DLG_OTHER_RESOLV_LOCAL", "ローカルで解決する")])
    private let prompts = (0..<5).map { _ in SetupUI.field(width: 200) }

    init(settings: ProxySettings) { s = settings; super.init() }

    func begin(on w: NSWindow, completion: @escaping (ProxySettings?) -> Void) {
        self.completion = completion
        panel.title = Lang.t("TTProxy", "DLG_OTHER_TITLE", "その他の設定")
        timeoutField.stringValue = String(s.timeout)
        logField.stringValue = s.debugLog
        resolvePopup.selectItem(at: ["auto", "remote", "local"].firstIndex(of: s.resolve.lowercased()) ?? 0)
        let vals = [s.telnetHostnamePrompt, s.telnetUsernamePrompt, s.telnetPasswordPrompt, s.telnetConnectedMessage, s.telnetErrorMessage]
        for (f, v) in zip(prompts, vals) { f.stringValue = v }
        let refer = SetupUI.button(Lang.t("TTProxy", "DLG_OTHER_REFER", "参照(&F)..."), target: self, action: #selector(chooseLog))
        layout(SetupUI.column([
            SetupUI.box(Lang.t("TTProxy", "DLG_OTHER_COMMON", "共通の設定"), SetupUI.grid([
                [SetupUI.label(Lang.t("TTProxy", "DLG_OTHER_TIMEOUT", "接続タイムアウト(&T)")), SetupUI.row([timeoutField, SetupUI.label(Lang.t("TTProxy", "DLG_OTHER_SECOND", "秒"))])],
                [SetupUI.label(Lang.t("TTProxy", "DLG_OTHER_LOG", "プロキシとの通信ログ(&L)")), SetupUI.row([logField, refer])],
            ])),
            SetupUI.box(Lang.t("TTProxy", "DLG_OTHER_SOCKS", "SOCKSプロキシの設定"), SetupUI.row([SetupUI.label(Lang.t("TTProxy", "DLG_OTHER_RESOLV", "名前解決(&R)")), resolvePopup])),
            SetupUI.box(Lang.t("TTProxy", "DLG_OTHER_TELNET", "TELNETプロキシの設定"), SetupUI.grid([
                [SetupUI.label(Lang.t("TTProxy", "DLG_OTHER_HOST", "ホスト名入力プロンプト(&H)")), prompts[0]],
                [SetupUI.label(Lang.t("TTProxy", "DLG_OTHER_USER", "ユーザー名入力プロンプト(&U)")), prompts[1]],
                [SetupUI.label(Lang.t("TTProxy", "DLG_OTHER_PASS", "パスワード入力プロンプト(&P)")), prompts[2]],
                [SetupUI.label(Lang.t("TTProxy", "DLG_OTHER_CONNECT", "接続成功メッセージ(&C)")), prompts[3]],
                [SetupUI.label(Lang.t("TTProxy", "DLG_OTHER_ERROR", "接続失敗メッセージ(&E)")), prompts[4]],
            ])),
        ], spacing: 10))
        present(on: w)
    }

    @objc private func chooseLog() {
        let p = NSSavePanel()
        p.title = Lang.t("TTProxy", "MSG_LOGFILE_SELECT", "ログファイルの選択")
        p.beginSheetModal(for: panel) { r in if r == .OK, let u = p.url { self.logField.stringValue = u.path } }
    }

    override func ok() {
        s.timeout = max(0, Int(timeoutField.stringValue) ?? s.timeout)
        s.debugLog = logField.stringValue
        s.resolve = ["auto", "remote", "local"][max(0, resolvePopup.indexOfSelectedItem)]
        (s.telnetHostnamePrompt, s.telnetUsernamePrompt, s.telnetPasswordPrompt, s.telnetConnectedMessage, s.telnetErrorMessage) =
            (prompts[0].stringValue, prompts[1].stringValue, prompts[2].stringValue, prompts[3].stringValue, prompts[4].stringValue)
        close()
        completion?(s)
    }
    override func cancel() { close(); completion?(nil) }
}
