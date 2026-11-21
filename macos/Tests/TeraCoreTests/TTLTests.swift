import XCTest
@testable import TeraCore

/// テスト用の端末。送ったものをためるだけ
final class FakeHost: TTLHost {
    var sent: [UInt8] = []
    var sentText: String { String(decoding: sent, as: UTF8.self) }
    var messages: [String] = []
    var inputs: [String] = []
    var errors: [String] = []
    func ttlSend(_ bytes: [UInt8], mode: TTLSendMode) { sent += bytes }
    func ttlMessageBox(_ text: String, title: String) -> Bool { messages.append(text); return true }
    func ttlInputBox(_ text: String, title: String, defaultValue: String, secret: Bool) -> String? {
        inputs.isEmpty ? "typed" : inputs.removeFirst()
    }
    func ttlError(message: String, line: Int, lineText: String, file: String, range: Range<Int>) -> Bool {
        errors.append("\(line): \(message) [\(lineText)]")
        return true
    }
}

/// TTL を動かす。recv は最初から受信していることにする文字列
func runTTL(_ src: String, recv: String = "", host: FakeHost = FakeHost(), file: StaticString = #filePath, line: UInt = #line) throws -> (FakeHost, TTLInterpreter) {
    let i = try TTLInterpreter(source: src, host: host)
    i.feed(Array(recv.utf8))
    try i.run()
    return (host, i)
}

final class TTLCoreTests: XCTestCase {
    func testSendAndConcat() throws {
        let (h, _) = try runTTL("""
        ; comment
        user = 'root'
        sendln 'login ' user
        send 'a'#13#10'b' 65
        """)
        XCTAssertEqual(h.sentText, "login root\ra\r\nbA")
    }

    func testIfWhileFor() throws {
        let (h, i) = try runTTL("""
        n = 0
        sum = 0
        while n < 5
          n = n + 1
          if n == 3 then
            continue
          elseif n == 5 then
            sum = sum + 100
          else
            sum = sum + n
          endif
        endwhile
        for k 1 3
          send 'x'
        next
        if sum > 10 messagebox 'big' 'T'
        """)
        XCTAssertEqual(i.variable("sum"), .int(107))
        XCTAssertEqual(h.sentText, "xxx")
        XCTAssertEqual(h.messages, ["big"])
    }

    func testWaitAndGoto() throws {
        let (h, i) = try runTTL("""
        timeout = 5
        wait 'login:' 'Password:'
        if result = 2 goto pw
        send 'no'
        end
        :pw
        sendln 'secret'
        call sub
        end
        :sub
        x = 1
        return
        """, recv: "Password:")
        XCTAssertEqual(h.sentText, "secret\r")
        XCTAssertEqual(i.variable("x"), .int(1))
    }

    func testWaitTimeout() throws {
        let start = Date()
        let (_, i) = try runTTL("""
        mtimeout = 200
        wait 'never'
        r = result
        """)
        XCTAssertEqual(i.variable("r"), .int(0))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testWaitLnAndRecvLn() throws {
        let (_, i) = try runTTL("""
        timeout = 1
        waitln 'abc'
        a = inputstr
        recvln
        b = inputstr
        """, recv: "xx abc yy\r\nsecond line\r\n")
        XCTAssertEqual(i.variable("a"), .str("xx abc yy"))
        XCTAssertEqual(i.variable("b"), .str("second line"))
    }

    func testWaitRegex() throws {
        let (_, i) = try runTTL("""
        timeout = 1
        waitregex 'ver ([0-9]+)\\.([0-9]+)'
        r = result
        m = matchstr
        g1 = groupmatchstr1
        g2 = groupmatchstr2
        """, recv: "hello ver 12.34 ok\r\n")
        XCTAssertEqual(i.variable("r"), .int(1))
        XCTAssertEqual(i.variable("m"), .str("ver 12.34"))
        XCTAssertEqual(i.variable("g1"), .str("12"))
        XCTAssertEqual(i.variable("g2"), .str("34"))
    }

    func testRegexOnigurumaSemantics() throws {
        // \h は Ruby (鬼車) では 16 進数字
        let (_, i) = try runTTL("""
        timeout = 1
        waitregex 'id=(\\h+)'
        a = groupmatchstr1
        regexoption 'IGNORECASE'
        waitregex 'HELLO (\\w+)'
        b = groupmatchstr1
        regexoption 'OPTION_NONE'
        """, recv: "x id=1aF;z\r\nhello World\r\n", host: FakeHost())
        XCTAssertEqual(i.variable("a"), .str("1aF"))
        XCTAssertEqual(i.variable("b"), .str("World"))
        let h = FakeHost()
        XCTAssertThrowsError(try runTTL("regexoption 'NOPE'\n", host: h))
        XCTAssertEqual(h.errors.first?.hasPrefix("1: Syntax error."), true)
    }

    func testWaitRecvAndWaitN() throws {
        let (_, i) = try runTTL("""
        timeout = 1
        waitrecv 'ID=' 6 1
        a = inputstr
        waitn 3
        b = inputstr
        """, recv: "xxID=123456")
        XCTAssertEqual(i.variable("a"), .str("ID=123"))
        XCTAssertEqual(i.variable("b"), .str("456"))
    }

    func testOperatorsAndPrecedence() throws {
        let (_, i) = try runTTL("""
        a = 1 + 2 * 3
        b = (1 + 2) * 3
        c = 7 / 2
        d = 7 % 3
        e = 1 << 4
        f = -16 >> 2
        g = -1 >>> 28
        h = 5 & 3 | 8
        k = 1 == 1 && 2 > 1
        l = not 0
        m = !5
        n = $1F
        o = 3 xor 1
        p = 1 = 2 || 3 <> 4
        """)
        XCTAssertEqual(i.variable("a"), .int(7))
        XCTAssertEqual(i.variable("b"), .int(9))
        XCTAssertEqual(i.variable("c"), .int(3))
        XCTAssertEqual(i.variable("d"), .int(1))
        XCTAssertEqual(i.variable("e"), .int(16))
        XCTAssertEqual(i.variable("f"), .int(-4))
        XCTAssertEqual(i.variable("g"), .int(15))
        XCTAssertEqual(i.variable("h"), .int(9))
        XCTAssertEqual(i.variable("k"), .int(1))
        XCTAssertEqual(i.variable("l"), .int(-1))
        XCTAssertEqual(i.variable("m"), .int(0))
        XCTAssertEqual(i.variable("n"), .int(31))
        XCTAssertEqual(i.variable("o"), .int(2))
        XCTAssertEqual(i.variable("p"), .int(1))
    }

    func testArraysAndDoLoop() throws {
        let (_, i) = try runTTL("""
        intdim a 5
        strdim s 3
        s[1] = 'one'
        k = 0
        do while k < 5
          a[k] = k * k
          k = k + 1
        loop
        x = a[4]
        y = s[1]
        until k = 0
          k = k - 1
        enduntil
        do
          k = k + 1
        loop until k >= 3
        z = k
        """)
        XCTAssertEqual(i.variable("x"), .int(16))
        XCTAssertEqual(i.variable("y"), .str("one"))
        XCTAssertEqual(i.variable("z"), .int(3))
    }

    func testForDownAndBreak() throws {
        let (h, _) = try runTTL("""
        for i 5 1
          if i = 2 break
          send i + 48
        next
        """)
        XCTAssertEqual(h.sentText, "543")
    }

    func testNestedIfSkipping() throws {
        let (h, _) = try runTTL("""
        a = 0
        if a then
          if 1 then
            send 'X'
          else
            send 'Y'
          endif
        elseif a = 0 then
          send 'B'
          if 0 then
            send 'C'
          endif
        else
          send 'D'
        endif
        """)
        XCTAssertEqual(h.sentText, "B")
    }

    func testCStyleComments() throws {
        let (h, _) = try runTTL("""
        /* comment
           more */ send 'a'
        send /* inline */ 'b' ; tail
        """)
        XCTAssertEqual(h.sentText, "ab")
    }

    func testErrors() throws {
        let host = FakeHost()
        XCTAssertThrowsError(try runTTL("x = 'a'\nx = 1\n", host: host))
        XCTAssertEqual(host.errors.first?.hasPrefix("2: Type mismatch."), true)
        let h2 = FakeHost()
        XCTAssertThrowsError(try runTTL("send y\n", host: h2))
        XCTAssertEqual(h2.errors.first?.hasPrefix("1: Variable not initialized."), true)
        let h3 = FakeHost()
        XCTAssertThrowsError(try runTTL("foo bar\n", host: h3))
        XCTAssertEqual(h3.errors.first?.hasPrefix("1: Unknown command."), true)
    }

    func testIncludeAndExit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ttltest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "send 'in'\nexit\nsend 'no'\n".write(to: dir.appendingPathComponent("sub.ttl"), atomically: true, encoding: .utf8)
        let (h, _) = try runTTL("include 'sub.ttl'\nsend 'out'\n", host: FakeHost(), baseDirURL: dir)
        XCTAssertEqual(h.sentText, "inout")
    }

    func testExecCmndAndIfDefined() throws {
        let (_, i) = try runTTL("""
        execcmnd 'v = 5'
        ifdefined v
        a = result
        ifdefined nothing
        b = result
        """)
        XCTAssertEqual(i.variable("v"), .int(5))
        XCTAssertEqual(i.variable("a"), .int(1))
        XCTAssertEqual(i.variable("b"), .int(0))
    }

    func testShiftJISMacroFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let p = dir.appendingPathComponent("sjis-\(UUID().uuidString).ttl")
        try "send 'あ'\n".data(using: .shiftJIS)!.write(to: p)
        defer { try? FileManager.default.removeItem(at: p) }
        let h = FakeHost()
        let i = try TTLInterpreter(path: p.path, host: h)
        try i.run()
        XCTAssertEqual(h.sentText, "あ")
    }
}

func runTTL(_ src: String, recv: String = "", host: FakeHost, baseDirURL: URL) throws -> (FakeHost, TTLInterpreter) {
    let i = try TTLInterpreter(source: src, host: host, baseDir: baseDirURL)
    i.feed(Array(recv.utf8))
    try i.run()
    return (host, i)
}
