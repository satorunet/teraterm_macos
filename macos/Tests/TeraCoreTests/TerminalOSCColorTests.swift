import XCTest
@testable import TeraCore

/// OSC 4 / 5 / 10 / 11 / 17 / 19 / 104 / 110〜119 (vtterm.c XSequence / XsProcColor)、DECSET 1016、dumb 端末のタイムスタンプ
final class TerminalOSCColorTests: XCTestCase {
    private func term() -> (Terminal, () -> [String]) {
        let t = Terminal(cols: 20, rows: 3)
        var out: [String] = []
        t.onResponse = { out.append($0) }
        t.configuredColor = { slot in
            switch slot {
            case .normalFG: return RGB(0xFF, 0xFF, 0xFF)
            case .normalBG: return RGB(0, 0, 0)
            case .boldFG: return RGB(0xFF, 0xFF, 0)
            case .ansi(let n): return RGB(UInt8(n), 0, 0)
            default: return RGB(1, 2, 3)
            }
        }
        return (t, { out })
    }

    func testParseXColor() {
        XCTAssertEqual(Terminal.parseXColor("rgb:f/0/8"), RGB(255, 0, 136))
        XCTAssertEqual(Terminal.parseXColor("rgb:12/34/56"), RGB(0x12, 0x34, 0x56))
        XCTAssertEqual(Terminal.parseXColor("RGB:123/456/789"), RGB(0x12, 0x45, 0x78))
        XCTAssertEqual(Terminal.parseXColor("rgb:1234/5678/9abc"), RGB(0x12, 0x56, 0x9A))
        XCTAssertEqual(Terminal.parseXColor("#f08"), RGB(0xF0, 0x00, 0x80))
        XCTAssertEqual(Terminal.parseXColor("#123456"), RGB(0x12, 0x34, 0x56))
        XCTAssertEqual(Terminal.parseXColor("#123456789"), RGB(0x12, 0x45, 0x78))
        XCTAssertEqual(Terminal.parseXColor("#123456789abc"), RGB(0x12, 0x56, 0x9A))
        XCTAssertNil(Terminal.parseXColor("red"))
        XCTAssertNil(Terminal.parseXColor("#12345"))
        XCTAssertNil(Terminal.parseXColor("rgb:1/2"))
    }

    func testSetAndQueryPalette() {
        let (t, out) = term()
        t.feed("\u{1B}]4;1;#102030;200;rgb:ff/ff/ff\u{07}")
        XCTAssertEqual(t.colorOverrides[.ansi(1)], RGB(0x10, 0x20, 0x30))
        XCTAssertEqual(t.colorOverrides[.ansi(200)], RGB(255, 255, 255))
        t.feed("\u{1B}]4;1;?\u{07}")
        XCTAssertEqual(out().last, "\u{1B}]4;1;rgb:1010/2020/3030\u{07}")
        // ST で来たら ST で答える。変えていない色は設定の色
        t.feed("\u{1B}]4;5;?\u{1B}\\")
        XCTAssertEqual(out().last, "\u{1B}]4;5;rgb:0505/0000/0000\u{1B}\\")
        // 104;n で 1 つ、104 だけならパレット全部を戻す
        t.feed("\u{1B}]104;1\u{07}")
        XCTAssertNil(t.colorOverrides[.ansi(1)])
        XCTAssertNotNil(t.colorOverrides[.ansi(200)])
        t.feed("\u{1B}]4;259;#ff0000\u{07}\u{1B}]104\u{07}")
        XCTAssertNil(t.colorOverrides[.ansi(200)])
        // 259 は反転属性の背景色 (#616)。104 ではそのまま
        XCTAssertEqual(t.colorOverrides[.reverseBG], RGB(255, 0, 0))
        t.feed("\u{1B}]105\u{07}")
        XCTAssertNil(t.colorOverrides[.reverseBG])
    }

    func testEightColorModeSwapsBrightIndex() {
        let (t, out) = term()
        t.eightColorMode = true
        t.feed("\u{1B}]4;1;#111111;9;#999999\u{07}")
        XCTAssertEqual(t.colorOverrides[.ansi(9)], RGB(0x11, 0x11, 0x11))
        XCTAssertEqual(t.colorOverrides[.ansi(1)], RGB(0x99, 0x99, 0x99))
        t.feed("\u{1B}]4;1;?\u{07}")
        XCTAssertEqual(out().last, "\u{1B}]4;1;rgb:1111/1111/1111\u{07}")
    }

    func testSpecialColors() {
        let (t, out) = term()
        // 10;11 で続けて指定すると次の番号の色
        t.feed("\u{1B}]10;#010203;#040506\u{07}")
        XCTAssertEqual(t.colorOverrides[.normalFG], RGB(1, 2, 3))
        XCTAssertEqual(t.colorOverrides[.normalBG], RGB(4, 5, 6))
        // 問い合わせは設定の色 (DispGetColor は ts.VTColor を返す)
        t.feed("\u{1B}]10;?\u{07}")
        XCTAssertEqual(out().last, "\u{1B}]10;rgb:ffff/ffff/ffff\u{07}")
        t.feed("\u{1B}]17;#0a0b0c\u{07}\u{1B}]19;#0d0e0f\u{07}")
        XCTAssertEqual(t.colorOverrides[.boldBG], RGB(10, 11, 12))
        XCTAssertEqual(t.colorOverrides[.boldFG], RGB(13, 14, 15))
        t.feed("\u{1B}]110\u{07}")
        XCTAssertNil(t.colorOverrides[.normalFG])
        XCTAssertNotNil(t.colorOverrides[.normalBG])
        t.feed("\u{1B}]117;111;119\u{07}")
        XCTAssertNil(t.colorOverrides[.normalBG])
        XCTAssertNil(t.colorOverrides[.boldBG])
        XCTAssertNil(t.colorOverrides[.boldFG])
        // OSC 5 の 0 は太字の文字色
        t.feed("\u{1B}]5;0;?\u{07}")
        XCTAssertEqual(out().last, "\u{1B}]5;0;rgb:ffff/ffff/0000\u{07}")
        // メニューのリセットで全部戻す
        t.feed("\u{1B}]11;#123456\u{07}")
        t.menuReset(lfMode: false)
        XCTAssertTrue(t.colorOverrides.isEmpty)
    }

    func testSGRPixelsMode() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("\u{1B}[?1000h\u{1B}[?1016h")
        XCTAssertTrue(t.mouseSGR)
        XCTAssertTrue(t.mouseSGRPixels)
        t.feed("\u{1B}[?1006h")
        XCTAssertTrue(t.mouseSGR)
        XCTAssertFalse(t.mouseSGRPixels)
        t.feed("\u{1B}[?1016h\u{1B}[?1016l")
        XCTAssertFalse(t.mouseSGR)
        XCTAssertFalse(t.mouseSGRPixels)
    }

    func testDumbTimestamp() {
        let t = Terminal(cols: 40, rows: 4)
        t.terminalID = .dumb
        t.dumbTimestamp = { "[T] " }
        t.feed("ab\r\ncd\r\n\r\n")
        XCTAssertEqual(t.lines[0].text.trimmingCharacters(in: .whitespaces), "[T] ab")
        XCTAssertEqual(t.lines[1].text.trimmingCharacters(in: .whitespaces), "[T] cd")
        // 空行には付けない
        XCTAssertEqual(t.lines[2].text.trimmingCharacters(in: .whitespaces), "")
        // nil を返したら付けない
        let u = Terminal(cols: 40, rows: 2)
        u.terminalID = .dumb
        u.dumbTimestamp = { nil }
        u.feed("ab")
        XCTAssertEqual(u.lines[0].text.trimmingCharacters(in: .whitespaces), "ab")
    }
}
