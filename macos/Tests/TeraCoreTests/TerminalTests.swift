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
        // vtterm.c ProcessCR (CRReceive=CRLF): CR のあとに LF を足し、そのあとに来た LF もそのまま改行する
        t.feed("a\rb\r\nc")
        XCTAssertEqual(row(t, 0), "b")
        XCTAssertEqual(row(t, 1), "")
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

    func testResizeReflowsNarrowerAndBack() {
        let t = Terminal(cols: 10, rows: 4)
        t.feed("abcdefgh\r\n$ ")
        t.resize(cols: 4, rows: 4)
        XCTAssertEqual(row(t, 0), "abcd")
        XCTAssertEqual(row(t, 1), "efgh")
        XCTAssertEqual(row(t, 2), "$")
        XCTAssertEqual(t.cy, 2); XCTAssertEqual(t.cx, 2)
        t.resize(cols: 10, rows: 4)
        XCTAssertEqual(row(t, 0), "abcdefgh")
        XCTAssertEqual(row(t, 1), "$")
        XCTAssertEqual(t.cy, 1); XCTAssertEqual(t.cx, 2)
        t.feed("x")
        XCTAssertEqual(row(t, 1), "$ x")
    }

    func testResizeReflowJoinsWrappedLines() {
        let t = Terminal(cols: 4, rows: 3)
        t.feed("abcdefg")
        t.resize(cols: 8, rows: 3)
        XCTAssertEqual(row(t, 0), "abcdefg")
        XCTAssertEqual(t.cy, 0); XCTAssertEqual(t.cx, 7)
    }

    func testResizeReflowPushesToScrollback() {
        let t = Terminal(cols: 6, rows: 2)
        t.feed("123456\r\nabcdef")
        t.resize(cols: 3, rows: 2)
        XCTAssertEqual(row(t, 0), "abc")
        XCTAssertEqual(row(t, 1), "def")
        XCTAssertEqual(t.scrollback.map { $0.text }, ["123", "456"])
        t.resize(cols: 6, rows: 2)
        XCTAssertEqual(row(t, 0), "123456")
        XCTAssertEqual(row(t, 1), "abcdef")
        XCTAssertTrue(t.scrollback.isEmpty)
    }

    func testResizeReflowWideChars() {
        let t = Terminal(cols: 6, rows: 3)
        t.feed("aあいう")
        t.resize(cols: 4, rows: 3)
        XCTAssertEqual(row(t, 0), "aあ")
        XCTAssertEqual(row(t, 1), "いう")
        t.resize(cols: 7, rows: 3)
        XCTAssertEqual(row(t, 0), "aあいう")
    }

    func testResizeKeepsClearedScreen() {
        let t = Terminal(cols: 10, rows: 3)
        t.feed("old1\r\nold2\r\nold3\r\n")
        t.feed("\u{1b}[H\u{1b}[2J$ ")
        let sb = t.scrollback.count
        t.resize(cols: 6, rows: 3)
        t.resize(cols: 12, rows: 3)
        XCTAssertEqual(row(t, 0), "$")
        XCTAssertEqual(t.scrollback.count, sb)
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

final class IniFileTests: XCTestCase {
    func testParse() {
        let text = """
        ; comment
        [Tera Term]
        TerminalSize=100,30
        KanjiReceive = SJIS
        LocalEcho=on
        [hosts]
        Host1=a.example.com
        Host2=user@b:2222 /ssh
        """
        let f = IniFile(text: text)
        XCTAssertEqual(f.ints("tera term", "terminalsize"), [100, 30])
        XCTAssertEqual(f.string("Tera Term", "KanjiReceive"), "SJIS")
        XCTAssertEqual(f.onOff("Tera Term", "LocalEcho"), true)
        XCTAssertEqual(f.keys("Hosts").map { $0.1 }, ["a.example.com", "user@b:2222 /ssh"])
    }

    func testEncodings() {
        let s = "[Tera Term]\r\nTitle=日本語\r\n"
        for enc in [String.Encoding.utf16LittleEndian, .utf8, .shiftJIS] {
            var d = s.data(using: enc)!
            if enc == .utf16LittleEndian { d = Data([0xFF, 0xFE]) + d }
            XCTAssertEqual(IniFile(data: d)?.string("Tera Term", "Title"), "日本語", "\(enc)")
        }
    }
}
