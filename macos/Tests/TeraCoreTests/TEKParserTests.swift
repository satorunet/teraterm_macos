import XCTest
@testable import TeraCore

final class TEKParserTests: XCTestCase {
    /// 4096×3120 の画面 (座標がそのままピクセルになる)
    func makeParser(auto: Bool = true, colorEmu: Bool = false) -> TEKParser {
        var s = TEKSettings()
        s.autoWinSwitch = auto
        s.colorEmulation = colorEmu
        let p = TEKParser(settings: s)
        p.resize(width: 4096, height: 3120, fw: [8, 7, 6, 5], fh: [16, 14, 12, 10])
        _ = p.takeOps()
        return p
    }

    /// 4014 の 12 ビット座標 (HiY Extra LoY HiX LoX)
    func xy(_ x: Int, _ y: Int) -> [UInt8] {
        [UInt8(0x20 + (y >> 7)), UInt8(0x60 + ((y & 3) << 2) + (x & 3)), UInt8(0x60 + ((y >> 2) & 0x1F)),
         UInt8(0x20 + (x >> 7)), UInt8(0x40 + ((x >> 2) & 0x1F))]
    }

    /// 4010 の 10 ビット座標 (HiY LoY HiX LoX)
    func xy10(_ x: Int, _ y: Int) -> [UInt8] {
        [UInt8(0x20 + (y >> 5)), UInt8(0x60 + (y & 0x1F)), UInt8(0x20 + (x >> 5)), UInt8(0x40 + (x & 0x1F))]
    }

    func testVector12Bit() {
        let p = makeParser()
        XCTAssertNil(p.feed([0x1D] + xy(100, 200) + xy(1001, 2002) + xy(4095, 3119)))
        XCTAssertEqual(p.dispMode, .vector)
        XCTAssertEqual(p.takeOps(), [
            .line(from: TEKPoint(100, 3119 - 200), to: TEKPoint(1001, 3119 - 2002), color: 0, style: .solid),
            .line(from: TEKPoint(1001, 3119 - 2002), to: TEKPoint(4095, 0), color: 0, style: .solid),
        ])
    }

    func testVector10Bit() {
        let p = makeParser()
        p.feed([0x1D] + xy10(0, 0) + xy10(1023, 779))
        XCTAssertEqual(p.takeOps(), [.line(from: TEKPoint(0, 3119), to: TEKPoint(4092, 3119 - 3116), color: 0, style: .solid)])
    }

    func testShortAddressKeepsHighBytes() {
        let p = makeParser()
        // 2 点目は LoX だけ (HiY・LoY・HiX はそのまま)
        p.feed([0x1D] + xy10(32, 64) + [0x45])
        XCTAssertEqual(p.takeOps(), [.line(from: TEKPoint(128, 3119 - 256), to: TEKPoint(148, 3119 - 256), color: 0, style: .solid)])
    }

    func testBellAfterGSDrawsFirstVector() {
        let p = makeParser()
        p.feed(Array("A".utf8))   // caret を動かす
        _ = p.takeOps()
        p.feed([0x1D, 0x07] + xy(400, 400))
        XCTAssertEqual(p.takeOps(), [.line(from: TEKPoint(8, 16), to: TEKPoint(400, 3119 - 400), color: 0, style: .solid)])
    }

    func testSamePointIsPixel() {
        let p = makeParser()
        p.feed([0x1D] + xy(10, 10) + xy(10, 10))
        XCTAssertEqual(p.takeOps(), [.pixel(TEKPoint(10, 3109), color: 0)])
    }

    func testAlphaTextAndNewline() {
        let p = makeParser()
        p.feed(Array("AB\r\nC".utf8))
        XCTAssertEqual(p.takeOps(), [
            .char(0x41, at: TEKPoint(0, 16), size: 0, width: 8, height: 16, color: 0),
            .char(0x42, at: TEKPoint(8, 16), size: 0, width: 8, height: 16, color: 0),
            .char(0x43, at: TEKPoint(0, 32), size: 0, width: 8, height: 16, color: 0),
        ])
    }

    func testUSAfterVectorEntersAlphaAtBeamPosition() {
        let p = makeParser()
        p.feed([0x1D] + xy(800, 1000) + [0x1F] + Array("X".utf8))
        XCTAssertEqual(p.dispMode, .alpha)
        XCTAssertEqual(p.takeOps(), [.char(0x58, at: TEKPoint(800, 2119), size: 0, width: 8, height: 16, color: 0)])
    }

    func testEscFFClearsPage() {
        let p = makeParser()
        p.feed([0x1D] + xy(1, 1) + [0x1B, 0x0C])
        XCTAssertEqual(p.takeOps(), [.clear])
        XCTAssertEqual(p.dispMode, .alpha)
        XCTAssertEqual(p.caretX, 0)
        XCTAssertEqual(p.caretY, 0)
    }

    func testTextSize() {
        let p = makeParser()
        p.feed([0x1B, 0x39, 0x41])
        XCTAssertEqual(p.takeOps(), [.char(0x41, at: TEKPoint(0, 16), size: 1, width: 7, height: 14, color: 0)])
        XCTAssertEqual(p.fontWidth, 7)
    }

    func testLineStyle() {
        let p = makeParser()
        p.feed([0x1B, 0x61, 0x1D] + xy(0, 0) + xy(10, 0))
        XCTAssertEqual(p.takeOps(), [.line(from: TEKPoint(0, 3119), to: TEKPoint(10, 3119), color: 0, style: .dot)])
        // ESC FF で実線に戻る
        p.feed([0x1B, 0x0C, 0x1D] + xy(0, 0) + xy(10, 0))
        XCTAssertEqual(p.takeOps().last, .line(from: TEKPoint(0, 3119), to: TEKPoint(10, 3119), color: 0, style: .solid))
    }

    func testPointPlotMode() {
        let p = makeParser()
        p.feed([0x1D] + xy(100, 100) + [0x1C] + xy(200, 300))
        XCTAssertEqual(p.takeOps(), [.marker(UInt8(ascii: "+"), at: TEKPoint(200, 3119 - 300), color: 0)])
        XCTAssertEqual(p.dispMode, .marker)
    }

    func testIncrementalPlot() {
        let p = makeParser()
        p.feed([0x1D] + xy(400, 400) + [0x1E, UInt8(ascii: "P"), UInt8(ascii: "A"), UInt8(ascii: "D")])
        XCTAssertEqual(p.dispMode, .plot)
        let ops = p.takeOps()
        XCTAssertEqual(ops.count, 2)
        // RS で caret をビーム位置に、P でペンを下ろして右へ 4、上へ 4
        guard case .line(_, let to1, _, _) = ops[0], case .line(_, let to2, _, _) = ops[1] else { return XCTFail() }
        XCTAssertEqual(to1.x - 400, 4)
        XCTAssertEqual(to2.y, to1.y - 4)
    }

    func testColorsWithAndWithoutEmulation() {
        // ESC M L 2 (SetLineIndex 2 = 赤)
        let cmd: [UInt8] = [0x1B, 0x4D, 0x4C, 0x32, 0x1D] + xy(0, 0) + xy(5, 0)
        let mono = makeParser()
        mono.feed(cmd)
        XCTAssertEqual(mono.takeOps(), [.line(from: TEKPoint(0, 3119), to: TEKPoint(5, 3119), color: 0x000000, style: .solid)])
        let color = makeParser(colorEmu: true)
        color.feed(cmd)
        XCTAssertEqual(color.takeOps(), [.line(from: TEKPoint(0, 3119), to: TEKPoint(5, 3119), color: 0xFF0000, style: .solid)])
        // CSI 32 m (文字と線を緑)
        color.feed([0x1F, 0x1B, 0x5B, 0x33, 0x32, 0x6D, 0x41])
        XCTAssertEqual(color.takeOps().last, .char(0x41, at: TEKPoint(5, 3119), size: 0, width: 8, height: 16, color: 0x00FF00))
        XCTAssertEqual(color.penColor, 0x00FF00)
    }

    func testCANAndUnknownCSIReturnToVT() {
        let p = makeParser()
        XCTAssertEqual(p.feed([0x1F, 0x41, 0x18, 0x42, 0x43]), [0x42, 0x43])
        // VT のシーケンスは ESC [ ごと VT に戻す
        XCTAssertEqual(p.feed([0x1B, 0x5B, 0x32, 0x4A, 0x44]), [0x1B, 0x5B, 0x32, 0x4A, 0x44])
        // CSI ? 38 h は TEK のまま
        XCTAssertNil(p.feed([0x1B, 0x5B, 0x3F, 0x33, 0x38, 0x68]))
        // ESC 2
        XCTAssertEqual(p.feed([0x1B, 0x32, 0x45]), [0x45])
        // ESC % ! 1 (Select code)
        XCTAssertEqual(p.feed([0x1B, 0x25, 0x21, 0x31, 0x46]), [0x46])
    }

    func testNoAutoSwitchStaysInTEK() {
        let p = makeParser(auto: false)
        XCTAssertNil(p.feed([0x18, 0x1B, 0x5B, 0x32, 0x4A, 0x1B, 0x25, 0x21, 0x31]))
    }

    func testGINReport() {
        let p = makeParser()
        var sent: [UInt8] = []
        p.onSend = { sent += $0 }
        p.feed([0x1B, 0x1A])
        XCTAssertTrue(p.gin)
        p.ginMove(x: 1023, y: 3119 - 512 - 1)   // +1 されて (1024, 2607)
        p.reportGIN(UInt8(ascii: "z"))
        XCTAssertFalse(p.gin)
        XCTAssertEqual(sent, [0x7A, 0x28, 0x20, 0x23, 0x3F, 0x0D] as [UInt8])   // float の丸めで Y = 511 (Tera Term と同じ)
        // 送った 6 バイト (エコー) は読み捨てる
        p.feed(Array("123456A".utf8))
        XCTAssertEqual(p.takeOps(), [.char(0x41, at: TEKPoint(0, 16), size: 0, width: 8, height: 16, color: 0)])
    }

    func testGraphText() {
        let p = makeParser()
        // ESC L T 3 (長さ 3) "abc"
        p.feed([0x1B, 0x4C, 0x54, 0x33] + Array("abc".utf8) + Array("d".utf8))
        let ops = p.takeOps()
        XCTAssertEqual(ops.first, .graphText(Array("abc".utf8), at: TEKPoint(0, 16), width: 39, height: 59, advance: 51, angle: 0, color: 0))
        XCTAssertEqual(ops.last, .char(0x64, at: TEKPoint(153, 16), size: 0, width: 8, height: 16, color: 0))
    }

    func testHoldInputWhileMouseDown() {
        let p = makeParser()
        p.holdInput = true
        p.feed(Array("A".utf8))
        XCTAssertTrue(p.takeOps().isEmpty)
        p.holdInput = false
        p.feed([])
        XCTAssertEqual(p.takeOps().count, 1)
    }

    func testLayout() {
        let l = TEKParser.layout(scale: false, baseFW: 8, baseFH: 16, width: 0, height: 0)
        XCTAssertEqual(l.height, 560)
        XCTAssertEqual(l.width, max(8 * 74, Int(Float(560) / 3120 * 4096)))
        let s = TEKParser.layout(scale: true, baseFW: 0, baseFH: 0, width: 740, height: 700)
        XCTAssertEqual(s.fw[0], 10)
        XCTAssertEqual(s.fh[0], 20)
    }

    // MARK: - VT → TEK (vtterm.c)

    func testVTEntersTEK() {
        func run(_ s: String) -> (Terminal, [UInt8]?) {
            let t = Terminal(cols: 20, rows: 3)
            t.autoWinSwitch = true
            var got: [UInt8]?
            t.onEnterTEK = { got = $0 }
            t.feed(s)
            return (t, got)
        }
        var (t, r) = run("ab\u{1D}xyz")
        XCTAssertEqual(r, [0x1D] + Array("xyz".utf8))
        XCTAssertEqual(t.lines[0].text.trimmingCharacters(in: .whitespaces), "ab")
        (t, r) = run("a\u{1B}\u{0C}q")
        XCTAssertEqual(r, [0x1B, 0x0C, 0x71])
        (t, r) = run("\u{1B}[?38hZ")
        XCTAssertEqual(r, [0x5A])
        (t, r) = run("\u{1B}%!0Z")
        XCTAssertEqual(r, [0x5A])
        // 自動切り替えがオフなら VT のまま (FF は改行)
        let off = Terminal(cols: 20, rows: 3)
        var called = false
        off.onEnterTEK = { _ in called = true }
        off.feed("\u{1D}\u{1B}\u{0C}\u{1B}[?38h")
        XCTAssertFalse(called)
    }
}
