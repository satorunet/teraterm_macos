import XCTest
@testable import TeraCore

final class TerminalTests: XCTestCase {
    func row(_ t: Terminal, _ y: Int) -> String {
        t.lines[y].text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    func testPlainAndNewline() {
        let t = Terminal(cols: 10, rows: 3)
        t.feed("abc\r\ndef")
        XCTAssertEqual(row(t, 0), "abc")
        XCTAssertEqual(row(t, 1), "def")
        XCTAssertEqual(t.cx, 3)
    }

    func testWrapAndScroll() {
        let t = Terminal(cols: 4, rows: 2)
        t.feed("abcdefghij")
        XCTAssertEqual(row(t, 0), "efgh")
        XCTAssertEqual(row(t, 1), "ij")
        XCTAssertEqual(t.scrollback.count, 1)
        XCTAssertEqual(t.scrollback[0].text, "abcd")
    }

    func testWideChars() {
        let t = Terminal(cols: 5, rows: 2)
        t.feed("あいう")
        XCTAssertEqual(row(t, 0), "あい")
        XCTAssertEqual(row(t, 1), "う")
        XCTAssertEqual(t.lines[0].cells[0].width, 2)
        XCTAssertEqual(t.lines[0].cells[1].width, 0)
    }

    func testCursorAndErase() {
        let t = Terminal(cols: 10, rows: 3)
        t.feed("hello\u{1B}[1;3H\u{1B}[K")
        XCTAssertEqual(row(t, 0), "he")
        t.feed("\u{1B}[2J\u{1B}[2;2HX")
        XCTAssertEqual(row(t, 1), " X")
    }

    func testSGR() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("\u{1B}[1;31mA\u{1B}[38;5;200mB\u{1B}[38;2;1;2;3mC\u{1B}[0mD")
        XCTAssertEqual(t.lines[0].cells[0].attr.fg, .idx(1))
        XCTAssertTrue(t.lines[0].cells[0].attr.bold)
        XCTAssertEqual(t.lines[0].cells[1].attr.fg, .idx(200))
        XCTAssertEqual(t.lines[0].cells[2].attr.fg, .rgb(1, 2, 3))
        XCTAssertEqual(t.lines[0].cells[3].attr, CellAttr())
    }

    func testAltScreen() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("main")
        t.feed("\u{1B}[?1049h\u{1B}[Hvim")
        XCTAssertEqual(row(t, 0), "vim")
        t.feed("\u{1B}[?1049l")
        XCTAssertEqual(row(t, 0), "main")
        XCTAssertEqual(t.cx, 4)
    }

    func testScrollRegionAndDSR() {
        let t = Terminal(cols: 10, rows: 4)
        var resp = ""
        t.onResponse = { resp += $0 }
        t.feed("1\r\n2\r\n3\r\n4\u{1B}[2;3r\u{1B}[3;1H\n")
        XCTAssertEqual(row(t, 0), "1")
        XCTAssertEqual(row(t, 1), "3")
        XCTAssertEqual(row(t, 2), "")
        XCTAssertEqual(row(t, 3), "4")
        t.feed("\u{1B}[6n")
        XCTAssertEqual(resp, "\u{1B}[3;1R")
    }

    func testLineDrawing() {
        let t = Terminal(cols: 10, rows: 1)
        t.feed("\u{1B}(0lqk\u{1B}(Bx")
        XCTAssertEqual(row(t, 0), "┌─┐x")
    }

    func testRecvCR() {
        let t = Terminal(cols: 10, rows: 3)
        t.recvCRasCRLF = true
        t.feed("a\rb\r\nc")
        XCTAssertEqual(row(t, 0), "a")
        XCTAssertEqual(row(t, 1), "b")
        XCTAssertEqual(row(t, 2), "c")
    }

    func testResizeKeepsCursorLine() {
        let t = Terminal(cols: 10, rows: 4)
        t.feed("1\r\n2\r\n3\r\n4")
        t.resize(cols: 10, rows: 2)
        XCTAssertEqual(row(t, 0), "3")
        XCTAssertEqual(row(t, 1), "4")
        t.resize(cols: 10, rows: 4)
        XCTAssertEqual(row(t, 0), "1")
        XCTAssertEqual(row(t, 3), "4")
    }

    func testDecoderSplits() {
        var d = StreamDecoder(encoding: .utf8)
        let b = Array("あい".utf8)
        XCTAssertEqual(d.decode(Array(b[0..<2])), "")
        XCTAssertEqual(d.decode(Array(b[2..<4])), "あ")
        XCTAssertEqual(d.decode(Array(b[4...])), "い")

        var s = StreamDecoder(encoding: .sjis)
        let sj = TermEncoding.sjis.encode("漢字ABC")
        XCTAssertEqual(s.decode(Array(sj[0..<3])), "漢")
        XCTAssertEqual(s.decode(Array(sj[3...])), "字ABC")

        var e = StreamDecoder(encoding: .eucjp)
        let eu = TermEncoding.eucjp.encode("日本")
        XCTAssertEqual(e.decode(Array(eu[0..<1])), "")
        XCTAssertEqual(e.decode(Array(eu[1...])), "日本")
    }
}

final class FakeHost: TTLHost {
    var sent = ""
    var recv = ""
    var messages: [String] = []
    func ttlSend(_ s: String) { sent += s }
    func ttlWait(_ strings: [String], timeout: Double) -> Int {
        for (i, s) in strings.enumerated() where recv.contains(s) { return i + 1 }
        return 0
    }
    func ttlWaitLine(_ strings: [String], timeout: Double) -> (Int, String) { (0, "") }
    func ttlFlushRecv() { recv = "" }
    func ttlMessage(_ text: String, title: String) { messages.append(text) }
    func ttlInput(_ text: String, title: String, secret: Bool) -> String? { "typed" }
    func ttlYesNo(_ text: String, title: String) -> Bool { true }
    func ttlConnect(_ spec: String) -> Bool { messages.append("connect " + spec); return true }
    func ttlDisconnect() {}
    func ttlLogOpen(_ path: String) -> Bool { true }
    func ttlLogClose() {}
    func ttlSetTitle(_ s: String) {}
    func ttlBeep() {}
    func ttlSendBreak() {}
    func ttlIsConnected() -> Bool { true }
    func ttlStatus(_ s: String) {}
}

final class TTLTests: XCTestCase {
    func run(_ src: String, _ host: FakeHost = FakeHost()) throws -> (FakeHost, TTLInterpreter) {
        let i = try TTLInterpreter(source: src, host: host)
        try i.run()
        return (host, i)
    }

    func testSendAndConcat() throws {
        let (h, _) = try run("""
        ; comment
        user = 'root'
        sendln 'login ' user
        send 'a'#13#10'b' 65
        """)
        XCTAssertEqual(h.sent, "login root\ra\r\nbA")
    }

    func testIfWhileFor() throws {
        let (h, i) = try run("""
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
        XCTAssertEqual(i.variable("sum")?.description, "107")
        XCTAssertEqual(h.sent, "xxx")
        XCTAssertEqual(h.messages, ["big"])
    }

    func testWaitAndGoto() throws {
        let host = FakeHost()
        host.recv = "Password:"
        let (h, i) = try run("""
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
        strconcat inputstr '!'
        return
        """, host)
        XCTAssertEqual(h.sent, "secret\r")
        XCTAssertEqual(i.variable("inputstr")?.description, "!")
    }

    func testStringFuncs() throws {
        let (_, i) = try run("""
        s = 'Hello World'
        strlen s
        len = result
        strcopy s 7 5 w
        int2str t 42
        sprintf2 f '%s-%03d' w 7
        """)
        XCTAssertEqual(i.variable("len")?.description, "11")
        XCTAssertEqual(i.variable("w")?.description, "World")
        XCTAssertEqual(i.variable("t")?.description, "42")
        XCTAssertEqual(i.variable("f")?.description, "World-007")
    }
}
