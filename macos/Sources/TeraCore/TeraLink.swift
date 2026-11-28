import Foundation
import Network
import CommonCrypto

/// Tera Term Mac と Tera Term SP (iPhone / iPad) の連携。
/// 外のサービス (iCloud など) を使わず、近くの機器どうしで直接やりとりする:
/// - Mac 版が Bonjour (_teraterm-link._tcp) で知らせ、iPhone 版が見つけてつなぐ。同じ Wi-Fi でなくても、
///   近ければ Wi-Fi のピアツーピア (AirDrop と同じ仕組み) でつながる (includePeerToPeer)
/// - 通信はペアリングのコード (6 けた。Mac の画面の QR コード) から作った鍵の TLS (PSK) で暗号化する
/// - パスワードは送らない
public enum TeraLink {
    public static let serviceType = "_teraterm-link._tcp"
    /// Handoff (続きを別の端末で) の種類
    public static let activityType = "net.satoru.teraterm.session"
    /// QR コードの中身: teraterm-sp://pair?mac=<名前>&code=<6 けた>
    public static let urlScheme = "teraterm-sp"

    public static func pairURL(macName: String, code: String) -> String {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "mac", value: macName), URLQueryItem(name: "code", value: code)]
        return c.string ?? ""
    }
    public static func parsePairURL(_ url: URL) -> (mac: String, code: String)? {
        guard url.scheme == urlScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let mac = items.first(where: { $0.name == "mac" })?.value,
              let code = items.first(where: { $0.name == "code" })?.value else { return nil }
        return (mac, code)
    }

    /// 新しいペアリングのコード (6 けたの数字)
    public static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// つなぐ・待つための設定 (コードから作った鍵の TLS 1.2 PSK + TCP。ピアツーピアも使う)
    public static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let opts = tls.securityProtocolOptions
        let key = psk(code)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let idData = Array("Tera Term link".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(opts, keyData as __DispatchData, idData as __DispatchData)
        if #available(macOS 10.15, iOS 13.0, *) {
            sec_protocol_options_append_tls_ciphersuite(opts, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
            sec_protocol_options_set_max_tls_protocol_version(opts, .TLSv12)
        } else {
            sec_protocol_options_add_tls_ciphersuite(opts, SSLCipherSuite(TLS_PSK_WITH_AES_128_GCM_SHA256))
            sec_protocol_options_set_tls_max_version(opts, .tlsProtocol12)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }

    /// コード → 鍵 (HMAC-SHA256)
    static func psk(_ code: String) -> [UInt8] {
        let data = Array("Tera Term Mac / Tera Term SP".utf8)
        let k = Array(code.utf8)
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k, k.count, data, data.count, &out)
        return out
    }

    // MARK: やりとりするもの

    /// 接続先 (TeraTerm Menu の 1 件、または開いている接続)
    public struct Host: Codable, Equatable {
        public var name: String
        public var host: String
        public var port: Int
        /// "ssh" / "telnet"
        public var proto: String
        public var user: String
        /// つないだあとに動かすマクロ (ファイル名だけ。中身は file で取る)
        public var macro: String
        public init(name: String, host: String, port: Int, proto: String, user: String, macro: String = "") {
            self.name = name; self.host = host; self.port = port; self.proto = proto; self.user = user; self.macro = macro
        }
    }

    public struct Request: Codable {
        /// "hello" / "hosts" / "sessions" / "macros" / "file"
        public var cmd: String
        public var name: String?
        public init(cmd: String, name: String? = nil) { self.cmd = cmd; self.name = name }
    }

    public struct Response: Codable {
        public var cmd: String
        public var macName: String?
        public var hosts: [Host]?
        public var sessions: [Host]?
        public var macros: [String]?
        public var name: String?
        public var file: Data?
        public var error: String?
        public init(cmd: String) { self.cmd = cmd }
    }

    // MARK: 送り方 (4 バイトの長さ + JSON)

    public final class Channel {
        public let connection: NWConnection
        public var onMessage: ((Data) -> Void)?
        public var onState: ((NWConnection.State) -> Void)?
        private let queue: DispatchQueue

        public init(_ c: NWConnection, queue: DispatchQueue = .main) {
            connection = c
            self.queue = queue
        }

        public func start() {
            connection.stateUpdateHandler = { [weak self] s in self?.onState?(s) }
            connection.start(queue: queue)
            receiveLength()
        }

        public func send<T: Encodable>(_ v: T) {
            guard let body = try? JSONEncoder().encode(v) else { return }
            var n = UInt32(body.count).bigEndian
            var d = Data(bytes: &n, count: 4)
            d.append(body)
            connection.send(content: d, completion: .contentProcessed { _ in })
        }

        public func cancel() { connection.cancel() }

        private func receiveLength() {
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] d, _, done, err in
                guard let self = self else { return }
                guard err == nil, let d = d, d.count == 4 else { if done || err != nil { self.connection.cancel() }; return }
                let b = [UInt8](d)
                let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                guard n > 0, n < 16 << 20 else { self.connection.cancel(); return }
                self.connection.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] body, _, _, err in
                    guard let self = self, err == nil, let body = body, body.count == n else { self?.connection.cancel(); return }
                    self.onMessage?(body)
                    self.receiveLength()
                }
            }
        }
    }
}
