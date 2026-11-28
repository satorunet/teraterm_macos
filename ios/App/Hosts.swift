import Foundation
import Security

/// アプリのフォルダ (ファイル App の「このiPhone内 > Tera Term SP」に見える)
enum SPPaths {
    static var documents: String { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path }
    /// SSH の鍵を置くフォルダ (ここのファイルを順に試す)
    static var keysDir: String { ensure(documents + "/keys") }
    /// マクロ (.ttl) を置くフォルダ
    static var macrosDir: String { ensure(documents + "/macros") }
    /// ログ
    static var logsDir: String { ensure(documents + "/logs") }

    private static func ensure(_ p: String) -> String {
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    static func prepare() { _ = keysDir; _ = macrosDir; _ = logsDir }
}

/// 接続先 (TeraTerm Menu の 1 件にあたる)
struct SPHost: Codable, Equatable {
    enum Proto: String, Codable, CaseIterable { case ssh, telnet }
    var id = UUID().uuidString
    var name = ""
    var host = ""
    var port = 22
    var proto = Proto.ssh
    var user = ""
    /// 接続したあとに動かすマクロ (macros フォルダのファイル名。空なら動かさない)
    var macro = ""

    var title: String { name.isEmpty ? host : name }
    var subtitle: String {
        let u = user.isEmpty ? "" : user + "@"
        return "\(proto.rawValue.uppercased())  \(u)\(host):\(port)"
    }
    static let defaultPort: [Proto: Int] = [.ssh: 22, .telnet: 23]

    /// 「ssh user@host:port」「telnet host 23」「host」のような書き方から作る (すぐつなぐ)
    static func parse(_ s: String) -> SPHost? {
        var words = s.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var h = SPHost()
        if let p = Proto(rawValue: words[0].lowercased()) { h.proto = p; words.removeFirst() }
        h.port = defaultPort[h.proto] ?? 22
        guard var target = words.first else { return nil }
        if words.count > 1, let p = Int(words[1]) { h.port = p }
        if let at = target.lastIndex(of: "@") { h.user = String(target[..<at]); target = String(target[target.index(after: at)...]) }
        if let colon = target.lastIndex(of: ":"), !target.contains("]"), target.filter({ $0 == ":" }).count == 1,
           let p = Int(target[target.index(after: colon)...]) {
            h.port = p; target = String(target[..<colon])
        }
        h.host = target.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h.host.isEmpty ? nil : h
    }
}

/// 接続先の一覧 (UserDefaults に JSON で)。パスワードはキーチェーンに分けて置く
enum SPHostStore {
    private static let key = "TeraSPHosts"
    static var all: [SPHost] {
        get { (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([SPHost].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
    static func save(_ h: SPHost) {
        var a = all
        if let i = a.firstIndex(where: { $0.id == h.id }) { a[i] = h } else { a.append(h) }
        all = a
    }
    static func remove(_ h: SPHost) {
        all = all.filter { $0.id != h.id }
        Keychain.set(nil, for: h.id)
    }
}

/// パスワードの置き場所 (キーチェーン。この端末だけ)
enum Keychain {
    private static let service = "net.satoru.terasp.password"
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ value: String?, for account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let v = value, !v.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
