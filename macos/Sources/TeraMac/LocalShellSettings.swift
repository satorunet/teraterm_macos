import Foundation

/// ローカルシェルの設定 (Tera Term の Cygwin タブ / cygterm.cfg にあたる。設定の「ローカルシェル」タブ)
///   SHELL / TERM / ENV_1 / ENV_2 / LOGIN_SHELL / HOME_CHDIR
struct LocalShellSettings: Equatable {
    /// SHELL (空なら $SHELL、それもなければ /bin/zsh)
    var shell = ""
    /// LOGIN_SHELL: ログインシェルとして起動する (argv[0] を "-zsh" に)
    var loginShell = true
    /// HOME_CHDIR: ホームディレクトリで始める
    var homeChdir = true
    /// TERM 環境変数
    var term = "xterm-256color"
    /// ENV_1 / ENV_2: "名前=値" の環境変数
    var env1 = ""
    var env2 = ""

    /// 既定のシェル ($SHELL)
    static var defaultShell: String {
        let s = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return s.isEmpty ? "/bin/zsh" : s
    }

    /// 実際に起動するシェル
    var shellPath: String {
        let s = shell.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? Self.defaultShell : (s as NSString).expandingTildeInPath
    }

    /// ENV_1 / ENV_2 を [名前: 値] に (書き方が正しいものだけ)
    var environment: [String: String] {
        var r: [String: String] = [:]
        for e in [env1, env2] {
            let t = e.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "="), eq != t.startIndex else { continue }
            r[String(t[..<eq])] = String(t[t.index(after: eq)...])
        }
        return r
    }

    private static let d = UserDefaults.standard

    static func load() -> LocalShellSettings {
        var s = LocalShellSettings()
        if let v = d.string(forKey: "localShellPath") { s.shell = v }
        if d.object(forKey: "localShellLogin") != nil { s.loginShell = d.bool(forKey: "localShellLogin") }
        if d.object(forKey: "localShellHomeChdir") != nil { s.homeChdir = d.bool(forKey: "localShellHomeChdir") }
        if let v = d.string(forKey: "localShellTerm"), !v.isEmpty { s.term = v }
        if let v = d.string(forKey: "localShellEnv1") { s.env1 = v }
        if let v = d.string(forKey: "localShellEnv2") { s.env2 = v }
        return s
    }

    func save() {
        Self.d.set(shell, forKey: "localShellPath")
        Self.d.set(loginShell, forKey: "localShellLogin")
        Self.d.set(homeChdir, forKey: "localShellHomeChdir")
        Self.d.set(term, forKey: "localShellTerm")
        Self.d.set(env1, forKey: "localShellEnv1")
        Self.d.set(env2, forKey: "localShellEnv2")
    }
}
