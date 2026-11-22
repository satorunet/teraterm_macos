import XCTest
@testable import TeraCore

/// TTProxy のやりとり・ChangeTitle・ファイルのフィルタ・マーク/スペースのパリティ
final class ConnectionSettingsTests: XCTestCase {

    private func noResolve(_ h: String, _ v4: Bool) -> [UInt8]? { nil }

    // MARK: HTTP

    func testHTTPConnectWithBasicAuth() {
        let c = ProxyConfig(kind: .http, host: "proxy", port: 8080, user: "user", pass: "pass")
        let h = ProxyHandshake(config: c, host: "example.com", port: 23, resolver: noResolve)
        let o = h.start()
        XCTAssertEqual(String(decoding: o.send, as: UTF8.self),
                       "CONNECT example.com:23 HTTP/1.1\r\nHost: example.com:23\r\nProxy-Authorization: Basic dXNlcjpwYXNz\r\n\r\n")
        XCTAssertNil(h.feed(Array("HTTP/1.1 200 Connection established\r\n".utf8)).result)
        let r = h.feed(Array("Via: x\r\n\r\nlogin:".utf8))
        XCTAssertEqual(r.result, .connected(leftover: Array("login:".utf8)))
    }

    func testHTTPIPv6AndErrors() {
        let c = ProxyConfig(kind: .http, host: "proxy")
        XCTAssertEqual(c.effectivePort, 80)
        let h = ProxyHandshake(config: c, host: "::1", port: 22, resolver: noResolve)
        XCTAssertTrue(String(decoding: h.start().send, as: UTF8.self).hasPrefix("CONNECT [::1]:22 HTTP/1.1\r\nHost: [::1]:22\r\n\r\n"))
        XCTAssertEqual(h.feed(Array("HTTP/1.0 407 Auth\r\n\r\n".utf8)).result, .failed(ProxyHandshake.msgUnauthorized))
        let h2 = ProxyHandshake(config: c, host: "a", port: 1, resolver: noResolve)
        _ = h2.start()
        XCTAssertEqual(h2.feed(Array("HTTP/1.0 403 No\r\n\r\n".utf8)).result,
                       .failed(ProxyHandshake.msgBadRequest + "(HTTP: status code 403)"))
    }

    // MARK: SOCKS5

    func testSOCKS5UserPassDomain() {
        let c = ProxyConfig(kind: .socks5, host: "p", user: "u", pass: "pw", resolve: .remote)
        XCTAssertEqual(c.effectivePort, 1080)
        let h = ProxyHandshake(config: c, host: "host", port: 0x1234, resolver: noResolve)
        XCTAssertEqual(h.start().send, [5, 2, 0, 2])
        XCTAssertEqual(h.feed([5, 2]).send, [1, 1, 0x75, 2, 0x70, 0x77])
        XCTAssertEqual(h.feed([1, 0]).send, [5, 1, 0, 3, 4] + Array("host".utf8) + [0x12, 0x34])
        XCTAssertNil(h.feed([5, 0, 0, 1, 1, 2]).result)
        XCTAssertEqual(h.feed([3, 4, 0, 23, 9]).result, .connected(leftover: [9]))
    }

    func testSOCKS5LocalResolveAndFailure() {
        let c = ProxyConfig(kind: .socks5, host: "p")
        let h = ProxyHandshake(config: c, host: "host", port: 80) { _, _ in [10, 0, 0, 1] }
        XCTAssertEqual(h.start().send, [5, 1, 0])
        XCTAssertEqual(h.feed([5, 0]).send, [5, 1, 0, 1, 10, 0, 0, 1, 0, 80])
        XCTAssertEqual(h.feed([5, 5, 0, 1]).result, .failed(ProxyHandshake.msgBadRequest + "(SOCKS5:VER 5 REP 5 ATYP 1)"))
        let h2 = ProxyHandshake(config: ProxyConfig(kind: .socks5, host: "p", user: "u", pass: "x"), host: "h", port: 1, resolver: noResolve)
        _ = h2.start()
        _ = h2.feed([5, 2])
        XCTAssertEqual(h2.feed([1, 1]).result, .failed(ProxyHandshake.msgUnauthorized))
    }

    // MARK: SOCKS4 / 4a

    func testSOCKS4() {
        let h = ProxyHandshake(config: ProxyConfig(kind: .socks4, host: "p", user: "me"), host: "192.168.0.1", port: 23, resolver: noResolve)
        XCTAssertEqual(h.start().send, [4, 1, 0, 23, 192, 168, 0, 1] + Array("me".utf8) + [0])
        XCTAssertEqual(h.feed([0, 90, 0, 0, 0, 0, 0, 0, 65]).result, .connected(leftover: [65]))
        // 引けなければ 4a
        let h2 = ProxyHandshake(config: ProxyConfig(kind: .socks4, host: "p"), host: "name", port: 23, resolver: noResolve)
        XCTAssertEqual(h2.start().send, [4, 1, 0, 23, 0, 0, 0, 1, 0] + Array("name".utf8) + [0])
        XCTAssertEqual(h2.feed([0, 91, 0, 0, 0, 0, 0, 0]).result, .failed(ProxyHandshake.msgBadRequest + "(SOCKS4:VN 0 CD 91)"))
        // local で引けなければ失敗
        let h3 = ProxyHandshake(config: ProxyConfig(kind: .socks4, host: "p", resolve: .local), host: "name", port: 23, resolver: noResolve)
        if case .failed? = h3.start().result {} else { XCTFail() }
    }

    // MARK: TELNET

    func testTelnetProxy() {
        let c = ProxyConfig(kind: .telnet, host: "p", user: "u", pass: "s")
        XCTAssertEqual(c.effectivePort, 23)
        let h = ProxyHandshake(config: c, host: "target", port: 22, resolver: noResolve)
        XCTAssertEqual(h.start().send, [])
        XCTAssertEqual(h.feed(Array("Welcome\r\nUsername:".utf8)).send, Array("u\n".utf8))
        XCTAssertEqual(h.feed(Array("Password:".utf8)).send, Array("s\n".utf8))
        XCTAssertEqual(h.feed(Array(">> Host name: ".utf8)).send, Array("target:22\n".utf8))
        XCTAssertEqual(h.feed(Array("-- Connected to target\r\nSSH-2.0".utf8)).result, .connected(leftover: Array("SSH-2.0".utf8)))
        let h2 = ProxyHandshake(config: c, host: "t", port: 1, resolver: noResolve)
        XCTAssertEqual(h2.feed(Array("!!!!!!!! refused\n".utf8)).result, .failed(ProxyHandshake.msgBadRequest))
    }

    func testProxyEnvironmentRoundTrip() {
        let c = ProxyConfig(kind: .socks5, host: "h", port: 9, user: "u", pass: "p w", timeout: 3, resolve: .local,
                            telnetPrompts: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(ProxyConfig(environment: c.environment), c)
        XCTAssertFalse(ProxyConfig(type: "http", host: "", port: 0, user: "", pass: "", timeout: 1, resolve: "", telnetPrompts: []).isEnabled)
        XCTAssertEqual(ProxyConfig(type: "SOCKS", host: "x", port: 0, user: "", pass: "", timeout: 1, resolve: "", telnetPrompts: []).kind, .socks5)
    }

    // MARK: ChangeTitle

    func testTitleFormat() {
        var i = WindowTitleInput(title: "Tera Term Mac")
        XCTAssertEqual(WindowTitle.make(i), "Tera Term Mac - [未接続] VT")
        i.connecting = true
        XCTAssertEqual(WindowTitle.make(i), "Tera Term Mac - [接続中...] VT")
        i.connecting = false; i.ready = true; i.port = .tcp(host: "host", port: 22)
        XCTAssertEqual(WindowTitle.make(i), "host - Tera Term Mac VT")          // 13
        i.titleFormat = 1 | 16
        XCTAssertEqual(WindowTitle.make(i), "Tera Term Mac - host:22")
        i.titleFormat = 1 | 2 | 8 | 32; i.port = .serial(name: "cu.usb", baud: 9600); i.serialNo = 3
        XCTAssertEqual(WindowTitle.make(i), "cu.usb:9600bps - Tera Term Mac (3)")
        i.titleFormat = 0
        XCTAssertEqual(WindowTitle.make(i), "Tera Term Mac")
    }

    func testAcceptTitleChangeRequest() {
        var i = WindowTitleInput(title: "T", remoteTitle: "R", titleFormat: 0, ready: true)
        XCTAssertEqual(WindowTitle.make(i), "R")
        i.acceptTitleChangeRequest = "ahead"; XCTAssertEqual(WindowTitle.make(i), "R T")
        i.acceptTitleChangeRequest = "last"; XCTAssertEqual(WindowTitle.make(i), "T R")
        i.acceptTitleChangeRequest = "off"; XCTAssertEqual(WindowTitle.make(i), "T")
        i.acceptTitleChangeRequest = "overwrite"; i.ready = false
        XCTAssertEqual(WindowTitle.make(i), "T")   // 未接続ならリモートのタイトルは使わない
        i.ready = true; i.titleFormat = 13; i.port = .tcp(host: "h", port: 23)
        XCTAssertEqual(WindowTitle.make(i), "h - R VT")
    }

    // MARK: フィルタ

    func testFileDialogFilter() {
        let f = FileDialogFilter("*.txt; *.LOG")
        XCTAssertEqual(f.allowedExtensions, ["txt", "LOG"])
        XCTAssertTrue(f.matches("a.TXT"))
        XCTAssertTrue(f.matches("b.log"))
        XCTAssertFalse(f.matches("c.bin"))
        XCTAssertEqual(f.userFilterName, "ユーザ定義(*.txt; *.LOG)")
        XCTAssertNil(FileDialogFilter("*.*").allowedExtensions)
        XCTAssertTrue(FileDialogFilter("*.*").matches("noext"))
        XCTAssertNil(FileDialogFilter("data?.bin").allowedExtensions)
        XCTAssertTrue(FileDialogFilter("data?.bin").matches("data1.bin"))
        XCTAssertFalse(FileDialogFilter("data?.bin").matches("data12.bin"))
        XCTAssertTrue(FileDialogFilter("readme.*").matches("readme"))
        XCTAssertTrue(FileDialogFilter("").isEmpty)
        XCTAssertTrue(FileDialogFilter("").matches("x"))
    }

    func testCommandLineSplit() {
        XCTAssertEqual(CommandLineSplit.split(#"-a "b c"  d"#), ["-a", "b c", "d"])
        XCTAssertEqual(CommandLineSplit.split(""), [])
    }

    // MARK: シリアル

    func testSerialLineMode() {
        let m = SerialLineMode.make(dataBits: 7, parity: "mark", stopBits: 1)!
        XCTAssertEqual(m.dataBits, 8); XCTAssertEqual(m.parity, "none")
        XCTAssertEqual(m.transmit([0x41]), [0xC1])
        XCTAssertEqual(m.receive([0xC1]), [0x41])
        let s = SerialLineMode.make(dataBits: 7, parity: "space", stopBits: 2)!
        XCTAssertEqual(s.transmit([0xC1]), [0x41]); XCTAssertEqual(s.stopBits, 2)
        XCTAssertEqual(SerialLineMode.make(dataBits: 8, parity: "mark", stopBits: 1)?.stopBits, 2)
        XCTAssertNil(SerialLineMode.make(dataBits: 8, parity: "space", stopBits: 1))
        let e = SerialLineMode.make(dataBits: 7, parity: "even", stopBits: 1)!
        XCTAssertFalse(e.changesData); XCTAssertEqual(e.dataBits, 7)
    }

    // MARK: ログ

    func testLogRotationAndName() throws {
        let dir = NSTemporaryDirectory() + "rot-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/a.log"
        var o = TTLLogOptions(); o.binary = true
        let l = try XCTUnwrap(TeraLog(path: path, options: o))
        l.configureRotation(enabled: true, size: 4, step: 2)
        l.putBinary([1, 2, 3, 4, 5])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".1"))
        l.close()
        let n = TeraLog.logFileName("%Y_&h_&p_&u.log", logDir: dir, host: "h:1", port: 22, user: "me",
                                    date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(n.hasSuffix("_h_1_22_me.log"), n)
        XCTAssertTrue(n.hasPrefix(dir))
    }
}
