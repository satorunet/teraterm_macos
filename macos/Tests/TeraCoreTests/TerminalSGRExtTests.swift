import XCTest
@testable import TeraCore

/// SGR のサブパラメータ (':')・U+FEFF
final class TerminalSGRExtTests: XCTestCase {
    func fg(_ seq: String) -> TColor {
        let t = Terminal(cols: 10, rows: 2)
        t.feed(seq + "X")
        return t.lines[0].cells[0].attr.fg
    }

    func testColonColors() {
        XCTAssertEqual(fg("\u{1B}[38;2;1;2;3m"), .rgb(1, 2, 3))
        XCTAssertEqual(fg("\u{1B}[38:2:1:2:3m"), .rgb(1, 2, 3))
        XCTAssertEqual(fg("\u{1B}[38:2::1:2:3m"), .rgb(1, 2, 3))
        XCTAssertEqual(fg("\u{1B}[38:2:0:1:2:3m"), .rgb(1, 2, 3))
        XCTAssertEqual(fg("\u{1B}[38;2:1:2:3m"), .rgb(1, 2, 3))
        XCTAssertEqual(fg("\u{1B}[38:5:200m"), .idx(200))
        XCTAssertEqual(fg("\u{1B}[38;5;200m"), .idx(200))
        // サブパラメータのあとの SGR も読む
        let t = Terminal(cols: 10, rows: 2)
        t.feed("\u{1B}[38:2::1:2:3;1;48;5;4mX")
        let a = t.lines[0].cells[0].attr
        XCTAssertEqual(a.fg, .rgb(1, 2, 3))
        XCTAssertEqual(a.bg, .idx(4))
        XCTAssertTrue(a.bold)
        XCTAssertFalse(a.blink)
    }

    func testBOMDropped() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("\u{FEFF}a\u{FEFF}b")
        XCTAssertEqual(t.lines[0].text.trimmingCharacters(in: .whitespaces), "ab")
        XCTAssertEqual(t.cx, 2)
    }
}
