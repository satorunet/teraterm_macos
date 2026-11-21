import XCTest
@testable import TeraCore

/// 端末とやりとりするコマンドのテスト用ホスト
private final class TermHost: TTLHost {
    var sent: [[UInt8]] = []
    var errors: [String] = []
    var logOpened: [(String, TTLLogOptions)] = []
    var logInfo: (flags: Int, path: String)?
    var kcodes: [(Int, Int)] = []
    var beeps: [Int] = []
    var dlgPos: [(Int, Int, Int, Int, Int)] = []
    var listSelected: Int?
    var listItems: [String] = []
    var unlinks = 0
    var closed = 0
    var serialDelay: Bool?
    var modem: Int?
    var scp: [(Bool, String, String)] = []
    func ttlSend(_ bytes: [UInt8], mode: TTLSendMode) { sent.append(bytes) }
    func ttlMessageBox(_ text: String, title: String) -> Bool { true }
    func ttlInputBox(_ text: String, title: String, defaultValue: String, secret: Bool) -> String? { "" }
    func ttlError(message: String, line: Int, lineText: String, file: String, range: Range<Int>) -> Bool {
        errors.append("\(line): \(message)")
        return true
    }
    func ttlLogOpen(_ name: String, options: TTLLogOptions) -> Bool { logOpened.append((name, options)); return true }
    func ttlLogInfo() -> (flags: Int, path: String)? { logInfo }
    func ttlSendKCode(_ keyCode: Int, count: Int) { kcodes.append((keyCode, count)) }
    func ttlBeep(_ type: Int) { beeps.append(type) }
    func ttlSetDialogPos(x: Int, y: Int, position: Int, offsetX: Int, offsetY: Int) { dlgPos.append((x, y, position, offsetX, offsetY)) }
    func ttlListBox(_ text: String, title: String, items: [String], selected: Int, options: TTLListBoxOptions) -> Int {
        listItems = items; listSelected = selected; return selected
    }
    func ttlUnlink() { unlinks += 1 }
    func ttlCloseTT() { closed += 1 }
    func ttlSetSerialDelay(char: Int?, line: Int?) -> Bool? { serialDelay }
    func ttlGetModemStatus() -> Int? { modem }
    func ttlScp(send: Bool, from: String, to: String) -> Bool { scp.append((send, from, to)); return true }
}

private func runTerm(_ src: String, _ host: TermHost = TermHost()) throws -> (TermHost, TTLInterpreter) {
    let i = try TTLInterpreter(source: src, host: host)
    try? i.run()
    return (host, i)
}

private func intVar(_ i: TTLInterpreter, _ n: String) -> Int? {
    if case .int(let v)? = i.variable(n) { return v }
    return nil
}
private func strVar(_ i: TTLInterpreter, _ n: String) -> String? {
    if case .str(let v)? = i.variable(n) { return v }
    return nil
}

final class TTLTerminalTests: XCTestCase {

    // MARK: - マクロに渡す受信 (vtterm.c OutputLogUTF32 / CheckEOL)

    private func stream(_ input: String, setup: (Terminal) -> Void = { _ in }) -> String {
        let t = Terminal(cols: 20, rows: 5)
        setup(t)
        var out: [UInt8] = []
        t.onMacroText = { out += $0 }
        t.feed(input)
        return String(decoding: out, as: UTF8.self)
    }

    func testStreamBackspace() {
        // 既定 (LogTypePlainText=on) では BS を渡さない
        XCTAssertEqual(stream("ab\u{8}c"), "abc")
        // off なら、カーソルが動いたときだけ
        XCTAssertEqual(stream("ab\u{8}c") { $0.logTypePlainText = false }, "ab\u{8}c")
        XCTAssertEqual(stream("\u{8}x") { $0.logTypePlainText = false }, "x")
    }

    func testStreamIndexNextLine() {
        XCTAssertEqual(stream("a\u{1B}Db"), "a\nb")
        XCTAssertEqual(stream("a\u{1B}Eb"), "a\nb")
        XCTAssertEqual(stream("a\r\nb\rc"), "a\r\nbc")   // 単独の CR は捨てる
    }

    func testStreamReceiveCRasCRLF() {
        // CR+LF モード: CR → CR LF、そのあとの LF もそのまま
        XCTAssertEqual(stream("a\rb") { $0.recvCRasCRLF = true }, "a\r\nb")
        XCTAssertEqual(stream("a\r\nb") { $0.recvCRasCRLF = true }, "a\r\n\nb")
        XCTAssertEqual(stream("a\nb") { $0.recvLFasCRLF = true }, "a\r\nb")
    }

    func testStreamNoEscapeSequences() {
        XCTAssertEqual(stream("\u{1B}[31mred\u{1B}[0m\u{1B}]0;title\u{7}!"), "red!")
    }

    // MARK: - コマンドライン (connect)

    func testCommandLineTokens() {
        XCTAssertEqual(TTCommandLine.tokens(#"host /passwd="a b""c" /x"#), ["host", #"/passwd="a b""c""#, "/x"])
        XCTAssertEqual(TTCommandLine.dequote(#"/passwd="a b""c""#), #"/passwd=a b"c"#)
        XCTAssertEqual(TTCommandLine.tokens("a b ; comment"), ["a", "b"])
        XCTAssertEqual(TTCommandLine.tokens("a;b"), ["a"])
    }

    func testCommandLinePassword() {
        let c = TTCommandLine.parse(#"myserver /ssh /auth=password /user=nike /passwd="p@ss word""#)
        XCTAssertEqual(c.host, "myserver")
        XCTAssertEqual(c.ssh, true)
        XCTAssertEqual(c.user, "nike")
        XCTAssertEqual(c.password, "p@ss word")   // @ はそのまま (4.62 で @→空白はなくなった)
        XCTAssertEqual(c.auth, "password")
        XCTAssertTrue(TTCommandLine.parse("h /ssh /ask4passwd").ask4passwd)
    }

    func testCommandLineHostPort() {
        var c = TTCommandLine.parse("myserver:23")
        XCTAssertEqual(c.host, "myserver"); XCTAssertEqual(c.tcpPort, 23)
        XCTAssertEqual(c.tcpProtocol.0, .telnet)
        c = TTCommandLine.parse("myserver 2323")
        XCTAssertEqual(c.tcpPort, 2323); XCTAssertEqual(c.tcpProtocol.0, .telnet)
        c = TTCommandLine.parse("myserver")
        XCTAssertEqual(c.tcpProtocol.0, .ssh); XCTAssertEqual(c.tcpProtocol.1, 22)
        c = TTCommandLine.parse("myserver:23 /ssh")
        XCTAssertEqual(c.tcpProtocol.0, .ssh); XCTAssertEqual(c.tcpProtocol.1, 23)
        c = TTCommandLine.parse("myserver /nossh")
        XCTAssertEqual(c.tcpProtocol.0, .telnet); XCTAssertEqual(c.tcpProtocol.1, 23)
        c = TTCommandLine.parse("myserver:5000 /T=0")
        XCTAssertEqual(c.tcpProtocol.0, .raw)
        c = TTCommandLine.parse("telnet://host.example.jp/")
        XCTAssertEqual(c.host, "host.example.jp"); XCTAssertEqual(c.tcpPort, 23); XCTAssertEqual(c.tcpProtocol.0, .telnet)
        c = TTCommandLine.parse("[::1]:2222 /ssh")
        XCTAssertEqual(c.host, "::1"); XCTAssertEqual(c.tcpPort, 2222)
        c = TTCommandLine.parse("ssh://bob:se%20cret@srv:2222/path")
        XCTAssertEqual(c.host, "srv"); XCTAssertEqual(c.tcpPort, 2222)
        XCTAssertEqual(c.user, "bob"); XCTAssertEqual(c.password, "se cret"); XCTAssertEqual(c.ssh, true)
        c = TTCommandLine.parse("alice@srv /ssh")
        XCTAssertEqual(c.user, "alice"); XCTAssertEqual(c.host, "srv")
        c = TTCommandLine.parse("srv /ssh 2200")   // /ssh は TTSSH が消すので 2200 はホストの直後
        XCTAssertEqual(c.tcpPort, 2200)
    }

    func testCommandLineSerialAndOthers() {
        var c = TTCommandLine.parse("/C=2 /SPEED=115200 /CDATABIT=7 /CPARITY=even /CSTOPBIT=2 /CFLOWCTRL=hard")
        XCTAssertEqual(c.portType, .serial)
        XCTAssertEqual(c.comPort, 2); XCTAssertEqual(c.baud, 115200)
        XCTAssertEqual(c.dataBit, 7); XCTAssertEqual(c.parity, "even"); XCTAssertEqual(c.stopBit, "2"); XCTAssertEqual(c.flowCtrl, "hard")
        c = TTCommandLine.parse("/C=/dev/cu.usbserial /BAUD=9600")
        XCTAssertEqual(c.comDevice, "/dev/cu.usbserial"); XCTAssertEqual(c.baud, 9600)
        c = TTCommandLine.parse(#"host /W="My Title" /timeout=5 /auth=publickey /keyfile=~/.ssh/id_rsa"#)
        XCTAssertEqual(c.title, "My Title"); XCTAssertEqual(c.timeout, 5)
        XCTAssertEqual(c.auth, "publickey"); XCTAssertEqual(c.keyFile, "~/.ssh/id_rsa")
        XCTAssertNil(TTCommandLine.parse("").host)
        XCTAssertNil(TTCommandLine.parse("").portType)
    }

    // MARK: - ログ (filesys_log.cpp)

    private func tmpPath(_ name: String) -> String {
        let d = NSTemporaryDirectory() + "ttlterm-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return (d as NSString).appendingPathComponent(name)
    }

    private func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "<none>" }

    func testLogFixOptionsAndInfo() {
        var o = TTLLogOptions()
        o.binary = true; o.plainText = true; o.timestamp = true; o.append = true; o.hideDialog = true
        let l = TeraLog(path: tmpPath("a.log"), options: o)!
        XCTAssertFalse(l.options.plainText); XCTAssertFalse(l.options.timestamp)
        XCTAssertEqual(l.infoFlags, 1 + 2 + 16)
        var t = TTLLogOptions(); t.plainText = true; t.timestamp = true
        XCTAssertEqual(TeraLog(path: tmpPath("b.log"), options: t)!.infoFlags, 4 + 8)
    }

    func testLogTextTimestampsAndWrite() {
        let p = tmpPath("t.log")
        var o = TTLLogOptions(); o.timestamp = true
        let l = TeraLog(path: p, options: o)!
        let now = Date(timeIntervalSince1970: 0)
        let ts = TeraLog.timestampText(type: 0, now: now, start: now, connected: now)
        l.putText(Array("ab\r\ncd".utf8), now: now)
        l.paused = true
        l.putText(Array("lost".utf8), now: now)
        l.writeString(Array("W\n".utf8), now: now)   // 一時停止中でも書く
        l.close()
        XCTAssertEqual(read(p), "\(ts)ab\r\n\(ts)cdW\n")
        XCTAssertFalse(TeraLog.timestampText(type: 1, now: now, start: now, connected: now).contains("UTC"))
        XCTAssertEqual(TeraLog.timestampText(type: 1, now: now, start: now, connected: now), "[1970-01-01 00:00:00.000] ")
        XCTAssertEqual(TeraLog.timestampText(type: 2, now: now.addingTimeInterval(3661.5), start: now, connected: now), "[0 01:01:01.500] ")
    }

    func testLogBinaryRaw() {
        let p = tmpPath("b.log")
        var o = TTLLogOptions(); o.binary = true
        let l = TeraLog(path: p, options: o)!
        l.putText(Array("text".utf8))
        l.putBinary([0x1B, 0x5B, 0x41, 0x0D])
        l.close()
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: p)), Data([0x1B, 0x5B, 0x41, 0x0D]))
    }

    func testLogRotate() {
        let p = tmpPath("r.log")
        let l = TeraLog(path: p, options: TTLLogOptions())!
        l.setRotate("size 4")
        l.putText(Array("12345".utf8))   // 5 > 4 で回す
        l.putText(Array("abcdef".utf8))
        l.putText(Array("x".utf8))
        l.close()
        XCTAssertEqual(read(p), "x")
        XCTAssertEqual(read(p + ".1"), "abcdef")
        XCTAssertEqual(read(p + ".2"), "12345")
        // rotate 1: 世代は 1 つだけ
        let q = tmpPath("q.log")
        let m = TeraLog(path: q, options: TTLLogOptions())!
        m.setRotate("size 2"); m.setRotate("rotate 1")
        m.putText(Array("aaa".utf8)); m.putText(Array("bbb".utf8)); m.putText(Array("c".utf8))
        m.close()
        XCTAssertEqual(read(q), "c")
        XCTAssertEqual(read(q + ".1"), "bbb")
        XCTAssertFalse(FileManager.default.fileExists(atPath: q + ".2"))
    }

    func testLogFileName() {
        let date = Date(timeIntervalSince1970: 86400 * 365)
        let y = TeraLog.strftime("%Y", date: date)
        XCTAssertEqual(TeraLog.logFileName("log_%Y_&h_&p_%q.txt", logDir: "/tmp/logs", host: "fe80::1", port: 22, user: "u", date: date),
                       "/tmp/logs/log_\(y)_fe80__1_22_.txt")
        XCTAssertEqual(TeraLog.logFileName("/var/x/a&u.log", logDir: "/tmp", host: nil, port: nil, user: "me", date: date), "/var/x/ame.log")
        XCTAssertEqual(TeraLog.logFileName("a&h&p.log", logDir: "/tmp", host: nil, port: nil, user: "me", date: date), "/tmp/a.log")
        XCTAssertEqual(TeraLog.logFileName("t%H:%M.log", logDir: "/tmp", host: nil, port: nil, user: "me", date: date).contains(":"), false)
    }

    // MARK: - TTL コマンド

    func testSendTruncation() throws {
        let (h, _) = try runTerm("""
        strdim a 1
        s = ''
        for i 1 51
          strconcat s '0123456789'
        next
        send s
        sendln s
        sendln 'x'
        """)
        // 510 文字 + sendln の CR = 511
        XCTAssertEqual(h.sent[0].count, 510)
        XCTAssertEqual(h.sent[1].count, 511)
        XCTAssertEqual(h.sent[1].last, 0x0D)
        XCTAssertEqual(h.sent[2], [0x78, 0x0D])
    }

    func testLogOpenAndInfo() throws {
        let host = TermHost()
        let (h, i) = try runTerm("""
        loginfo s
        r1 = result
        logopen 'a%Y.log' 1
        r2 = result
        """, host)
        XCTAssertEqual(intVar(i, "r1"), -1)
        XCTAssertEqual(strVar(i, "s"), "")
        XCTAssertEqual(intVar(i, "r2"), 0)   // append が足りなくても開く
        XCTAssertEqual(h.logOpened.first?.0, "a%Y.log")   // 名前の展開はホスト
        XCTAssertEqual(h.logOpened.first?.1.binary, true)
        XCTAssertTrue(h.errors.isEmpty, "\(h.errors)")

        let h2 = TermHost()
        h2.logInfo = (12, "/tmp/x.log")
        let (_, i2) = try runTerm("loginfo s", h2)
        XCTAssertEqual(intVar(i2, "result"), 12)
        XCTAssertEqual(strVar(i2, "s"), "/tmp/x.log")
    }

    func testLinkFirstAfterUnlink() throws {
        for cmd in ["sendkcode 28 1", "logopen 'x.log' 0 0", "setmulticastname 'a'", "scpsend 'a' 'b'", "scprecv 'a'", "send 'a'"] {
            let (h, i) = try runTerm("unlink\n\(cmd)")
            XCTAssertEqual(h.unlinks, 1)
            XCTAssertEqual(h.errors.count, 1, cmd)
            XCTAssertTrue(h.errors.first?.contains(E.message(E.linkFirst)) ?? false, "\(cmd): \(h.errors)")
            XCTAssertEqual(i.linkState, 0)
        }
    }

    func testCloseTTKeepsRunning() throws {
        let (h, i) = try runTerm("""
        closett
        testlink
        t = result
        x = 1
        """)
        XCTAssertEqual(h.closed, 1)
        XCTAssertEqual(intVar(i, "t"), 0)
        XCTAssertEqual(intVar(i, "x"), 1)
    }

    func testModemStatusAndSerialDelay() throws {
        let h = TermHost()
        let (_, i) = try runTerm("""
        result = 5
        setserialdelaychar 10
        a = result
        getmodemstatus m
        b = result
        """, h)
        XCTAssertEqual(intVar(i, "a"), 5)   // シリアルでなければ変えない
        XCTAssertEqual(intVar(i, "b"), 0)
        XCTAssertEqual(intVar(i, "m"), 0)
        let h2 = TermHost()
        h2.serialDelay = true
        h2.modem = 9
        let (_, i2) = try runTerm("setserialdelayline 3\na = result\ngetmodemstatus m", h2)
        XCTAssertEqual(intVar(i2, "a"), 1)
        XCTAssertEqual(intVar(i2, "m"), 9)
    }

    func testListBoxUnassignedAndSelected() throws {
        let (h, i) = try runTerm("""
        strdim items 3
        items[1] = 'one'
        items[2] = 'two'
        listbox 'pick' 'title' items '2x'
        r = result
        """)
        XCTAssertTrue(h.errors.isEmpty, "\(h.errors)")
        XCTAssertEqual(h.listItems, ["", "one", "two"])
        XCTAssertEqual(h.listSelected, 2)
        XCTAssertEqual(intVar(i, "r"), 2)
        XCTAssertEqual(TTLInterpreter.scanListBoxSize("listboxsize=40X10")?.0, 40)
        XCTAssertEqual(TTLInterpreter.scanListBoxSize("listboxsize=40x10")?.1, 10)
        XCTAssertNil(TTLInterpreter.scanListBoxSize("listboxsize=40"))
    }

    func testSetDlgPosAndBeep() throws {
        let (h, _) = try runTerm("""
        setdlgpos 10 20 7 5 3
        setdlgpos 1 2
        setdlgpos
        beep
        beep 3
        """)
        XCTAssertEqual(h.dlgPos.count, 3)
        guard h.dlgPos.count == 3 else { return }
        XCTAssertTrue(h.dlgPos[0] == (10, 20, 7, 5, 3))
        XCTAssertTrue(h.dlgPos[1] == (1, 2, 0, 0, 0))
        XCTAssertEqual(h.dlgPos[2].0, Int.min)
        XCTAssertEqual(h.beeps, [0, 3])
    }

    func testScpReturnsImmediately() throws {
        let (h, _) = try runTerm("scprecv 'remote.txt'\nscpsend 'local.txt' '/tmp/'")
        XCTAssertEqual(h.scp.count, 2)
        XCTAssertEqual(h.scp[0].0, false)
        XCTAssertEqual(h.scp[0].1, "remote.txt")
    }
}
