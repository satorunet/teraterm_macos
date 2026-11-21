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

/// エラーを記録して「続ける」(または stop = true で「止める」) を選ぶ端末
final class ContinueHost: TTLHost {
    var sent: [UInt8] = []
    var sentText: String { String(decoding: sent, as: UTF8.self) }
    var errors: [String] = []
    var errorFiles: [String] = []
    var stop = false
    func ttlSend(_ bytes: [UInt8], mode: TTLSendMode) { sent += bytes }
    func ttlError(message: String, line: Int, lineText: String, file: String, range: Range<Int>) -> Bool {
        errors.append("\(line): \(message)")
        errorFiles.append(file)
        return stop
    }
}

/// Windows 版 Tera Term (ttpmacro) とふるまいを合わせたところのテスト。期待値は元のソースから
final class TTLCompatTests: XCTestCase {
    private func tmpDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ttlcompat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func runFile(_ data: Data, name: String = "m.ttl", params: [String] = [], host: TTLHost = ContinueHost()) throws -> TTLInterpreter {
        let d = try tmpDir()
        let p = d.appendingPathComponent(name)
        try data.write(to: p)
        let i = try TTLInterpreter(path: p.path, host: host, params: params)
        try i.run()
        return i
    }

    // 1. param1 / params[1] はファイル名だけ。params[0] はコマンドライン全体
    func testParamsAreShortName() throws {
        let i = try runFile(Data("s0 = params[0]\ns1 = params[1]\ns2 = params[2]\ns3 = params[3]\nq = param1\nr = param3\nt = param4\n".utf8),
                            name: "my macro.ttl", params: ["a", "b c"])
        XCTAssertEqual(i.variable("q"), .str("my macro.ttl"))
        XCTAssertEqual(i.variable("s1"), .str("my macro.ttl"))
        XCTAssertEqual(i.variable("s2"), .str("a"))
        XCTAssertEqual(i.variable("s3"), .str("b c"))
        XCTAssertEqual(i.variable("r"), .str("b c"))
        XCTAssertEqual(i.variable("t"), .str(""))
        XCTAssertEqual(i.variable("paramcnt"), .int(3))
        guard case .str(let cmd)? = i.variable("s0") else { return XCTFail() }
        XCTAssertTrue(cmd.hasSuffix("my macro.ttl\" a \"b c\""), cmd)
        // 拡張子がなければ .TTL を付けて開き、param1 も .TTL 付き (FitFileNameW)
        let d = try tmpDir()
        try Data("x = param1\n".utf8).write(to: d.appendingPathComponent("noext.TTL"))
        let j = try TTLInterpreter(path: d.appendingPathComponent("noext").path, host: ContinueHost())
        try j.run()
        XCTAssertEqual(j.variable("x"), .str("noext.TTL"))
    }

    // 2. マクロファイルの文字コード
    func testMacroFileDecoding() throws {
        var h = ContinueHost()
        var le = Data([0xFF, 0xFE]); le.append("send 'あ'\n".data(using: .utf16LittleEndian)!)
        _ = try runFile(le, host: h)
        XCTAssertEqual(h.sentText, "あ")
        h = ContinueHost()
        var be = Data([0xFE, 0xFF]); be.append("send 'い'\n".data(using: .utf16BigEndian)!)
        _ = try runFile(be, host: h)
        XCTAssertEqual(h.sentText, "い")
        // UTF-16 の壊れた並び (孤立したサロゲート) は置き換えて読む
        h = ContinueHost()
        var bad = Data([0xFF, 0xFE]); bad.append("send 'a'\nsend '".data(using: .utf16LittleEndian)!)
        bad.append(contentsOf: [0x00, 0xD8]); bad.append("'\n".data(using: .utf16LittleEndian)!)
        _ = try runFile(bad, host: h)
        XCTAssertEqual(h.sentText, "a\u{FFFD}")
        // 最初の NUL で終わり
        h = ContinueHost()
        _ = try runFile(Data("send 'a'\n".utf8 + [0] + "send 'b'\n".utf8), host: h)
        XCTAssertEqual(h.sentText, "a")
        // UTF-8 BOM の後ろの NUL も
        h = ContinueHost()
        _ = try runFile(Data([0xEF, 0xBB, 0xBF] + "send 'c'\n".utf8 + [0] + "send 'd'\n".utf8), host: h)
        XCTAssertEqual(h.sentText, "c")
        // UTF-8 でも CP932 でも読めなければ開けない
        XCTAssertThrowsError(try runFile(Data("send '".utf8 + [0x80, 0xFF, 0xFD] + "'\n".utf8))) { e in
            XCTAssertEqual((e as? TTLError)?.message, "Can't open file.")
        }
    }

    // 3. ラベル登録のエラーは見せるが、「止める」を選んでもマクロは動く。エラーのあとも調べ続ける
    func testLabelErrorsDoNotStopMacro() throws {
        let h = ContinueHost()
        h.stop = true
        _ = try runFile(Data(":x\n:x\nsend 'a'\n:y\n:y\n".utf8), host: h)
        XCTAssertEqual(h.errors, ["2: Label already defined.", "5: Label already defined."])
        XCTAssertEqual(h.sentText, "a")
        let h2 = ContinueHost()
        h2.stop = true
        _ = try runFile(Data("send 'b'\n/* open\n".utf8), host: h2)
        XCTAssertEqual(h2.errors.count, 1)
        XCTAssertTrue(h2.errors[0].hasSuffix("\"*/\" expected."))
        XCTAssertEqual(h2.sentText, "b")
    }

    // 4. wait4all: 動いているマクロ全部で見つかるまで待つ。result は 1
    func testWait4allWaitsForEveryMacro() throws {
        let hb = FakeHost()
        let b = try TTLInterpreter(source: "timeout = 10\nwait 'never'\n", host: hb)
        let bt = Thread { try? b.run() }
        bt.start()
        defer { b.cancelled = true }
        Thread.sleep(forTimeInterval: 0.2)
        let ha = FakeHost()
        let a = try TTLInterpreter(source: "wait4all 'ok'\nr = result\n", host: ha)
        a.feed(Array("..ok..".utf8))
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { b.feed(Array("xxok".utf8)) }
        try a.run()
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.4)
        XCTAssertEqual(a.variable("r"), .int(1))
        // inputstr (recvln のバッファ) は使わない
        XCTAssertEqual(a.variable("inputstr"), .str(""))
    }

    func testWait4allWithTimeoutReturnsAfterFirstTick() throws {
        let start = Date()
        let (_, i) = try runTTL("result = 77\ntimeout = 5\nwait4all 'zz'\nr = result\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertEqual(i.variable("r"), .int(77))
        // 一つだけなら見つかったときに 1
        let (_, j) = try runTTL("wait4all 'b' 'a'\nr = result\n", recv: "xa")
        XCTAssertEqual(j.variable("r"), .int(1))
    }

    // 5. 空の wait 文字列は最初の 1 バイトで合う
    func testEmptyWaitStringMatchesFirstByte() throws {
        let (_, i) = try runTTL("timeout = 1\nwait 'zz' ''\nr = result\n", recv: "q")
        XCTAssertEqual(i.variable("r"), .int(2))
    }

    // 6. waitevent: 接続・切断は waitevent のあとの変化だけで起きる。2 はつながりが切れたとき
    func testWaitEventIsEdgeTriggered() throws {
        // つながったままなら 8 では起きず、時間切れ (1)
        let (_, i) = try runTTL("mtimeout = 300\nwaitevent 8 | 1\nr = result\n")
        XCTAssertEqual(i.variable("r"), .int(1))
        // 切れたら 4
        let h = FakeHost()
        let j = try TTLInterpreter(source: "timeout = 5\nwaitevent 4\nr = result\n", host: h)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { j.setComReady(false) }
        try j.run()
        XCTAssertEqual(j.variable("r"), .int(4))
        // 切れていて、そのあとつながったら 8
        let k = try TTLInterpreter(source: "timeout = 5\nwaitevent 8\nr = result\n", host: FakeHost())
        k.setComReady(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { k.setComReady(true) }
        try k.run()
        XCTAssertEqual(k.variable("r"), .int(8))
        // つながりが切れたら 2
        let l = try TTLInterpreter(source: "timeout = 5\nwaitevent 2\nr = result\n", host: FakeHost())
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { l.endLink() }
        try l.run()
        XCTAssertEqual(l.variable("r"), .int(2))
    }

    // 7. 受信した NUL もマクロに届く (文字列は NUL で終わる、waitn は数える)
    func testReceivedNulReachesMacro() throws {
        let i = try TTLInterpreter(source: "timeout = 1\nrecvln\na = inputstr\nwaitn 3\nb = result\n", host: FakeHost())
        i.feed([0x61, 0x00, 0x62, 0x0D, 0x0A, 0x00, 0x00, 0x41])
        try i.run()
        XCTAssertEqual(i.variable("a"), .str("a"))
        XCTAssertEqual(i.variable("b"), .int(1))
    }

    // 8. intdim / strdim に大きさの上限はない。負なら ErrFewMemory で、変数は残る
    func testLargeAndNegativeArrays() throws {
        let (_, i) = try runTTL("""
        intdim a 70000
        a[69999] = 5
        a[3] = 1
        x = a[69999]
        y = a[3]
        strdim s 70000
        s[66000] = 'q'
        s[464] = 'z'
        t = s[66000]
        u = s[464]
        """)
        XCTAssertEqual(i.variable("x"), .int(5))
        XCTAssertEqual(i.variable("y"), .int(1))
        XCTAssertEqual(i.variable("t"), .str("q"))
        XCTAssertEqual(i.variable("u"), .str("z"))
        let h = ContinueHost()
        let j = try runFile(Data("intdim n -1\nifdefined n\nr = result\n".utf8), host: h)
        XCTAssertEqual(h.errors, ["1: Can't allocate memory."])
        XCTAssertEqual(j.variable("r"), .int(5))
    }

    // 9. include は GetStrVal のエラーを気にせず開く
    func testIncludeIgnoresStringError() throws {
        let d = try tmpDir()
        try Data("send 'in'\n".utf8).write(to: d.appendingPathComponent("sub.ttl"))
        let h = ContinueHost()
        let i = try TTLInterpreter(source: "include 'sub.ttl\nsend 'out'\n", host: h, baseDir: d)
        try i.run()
        XCTAssertEqual(h.sentText, "inout")
        XCTAssertTrue(h.errors.contains("1: Syntax error."), "\(h.errors)")
        let h2 = FakeHost()
        XCTAssertThrowsError(try runTTL("include 5\n", host: h2))
        XCTAssertEqual(h2.errors.first?.hasPrefix("1: Can't open file."), true)
    }

    // 10. flushrecv はつながっているかを見ない
    func testFlushRecvWithoutLink() throws {
        let (h, i) = try runTTL("unlink\nflushrecv\nx = 1\n")
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(i.variable("x"), .int(1))
    }

    // 11. 代入の [ ] のエラーは Unknown command.
    func testAssignIndexErrorIsUnknownCommand() throws {
        let h = FakeHost()
        XCTAssertThrowsError(try runTTL("intdim a 3\na[1 = 2\n", host: h))
        XCTAssertEqual(h.errors.first?.hasPrefix("2: Unknown command."), true)
        let h2 = FakeHost()
        XCTAssertThrowsError(try runTTL("intdim a 3\na[ = 2\n", host: h2))
        XCTAssertEqual(h2.errors.first?.hasPrefix("2: Unknown command."), true)
    }

    // 12. timeout * 1000 + mtimeout は 32 ビットで計算する。INT_MIN / -1 は落ちない
    func testTimeoutIs32BitArithmetic() throws {
        // 4294968 * 1000 = 4294968000 → 32 ビットでは 704 ms
        let start = Date()
        let (_, i) = try runTTL("timeout = 4294968\nwait 'zz'\nr = result\nm = (-2147483647 - 1) / -1\nn = (-2147483647 - 1) % -1\n")
        let t = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(t, 0.6)
        XCTAssertLessThan(t, 3)
        XCTAssertEqual(i.variable("r"), .int(0))
        XCTAssertEqual(i.variable("m"), .int(-2147483648))
        XCTAssertEqual(i.variable("n"), .int(0))
    }

    // 13. エラーダイアログのファイル名はファイル名だけ、127 バイトまで
    func testErrorDialogFileTitle() throws {
        let name = String(repeating: "f", count: 200) + ".ttl"
        let h = ContinueHost()
        _ = try runFile(Data("foo\n".utf8), name: name, host: h)
        XCTAssertEqual(h.errorFiles, [String(repeating: "f", count: 127)])
    }
}
