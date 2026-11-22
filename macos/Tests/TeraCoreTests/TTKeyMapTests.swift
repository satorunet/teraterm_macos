import XCTest
@testable import TeraCore

final class TTKeyMapTests: XCTestCase {
    func testIBMDefault() {
        let km = TTKeyMap.ibmDefault
        XCTAssertTrue(km.warnings.isEmpty)
        // 矢印キー (Mac 126 = ↑ → 328)
        let up = TTKeyMap.keyCode(macKeyCode: 126, shift: false, control: false, alt: false)!
        XCTAssertEqual(up, 328)
        XCTAssertEqual(km.keyID(forCode: up), TTKeyID.up)
        XCTAssertEqual(km.action(for: TTKeyID.up, appKeypad: false, appCursor: false), .binary("\u{1B}[A"))
        XCTAssertEqual(km.action(for: TTKeyID.up, appKeypad: false, appCursor: true), .binary("\u{1B}OA"))
        // F1 = PF1, F5 = XF5, Shift+F3 = F13
        XCTAssertEqual(km.action(for: km.keyID(forCode: 59), appKeypad: false, appCursor: false), .binary("\u{1B}OP"))
        XCTAssertEqual(km.action(for: km.keyID(forCode: 63), appKeypad: false, appCursor: false), .binary("\u{1B}[15~"))
        XCTAssertEqual(km.action(for: km.keyID(forCode: 573), appKeypad: false, appCursor: false), .binary("\u{1B}[25~"))
        // Home = Find, Ctrl+↑ = LineUp, Shift+Tab = XBackTab
        XCTAssertEqual(km.action(for: km.keyID(forCode: 327), appKeypad: false, appCursor: false), .binary("\u{1B}[1~"))
        XCTAssertEqual(km.action(for: km.keyID(forCode: 1352), appKeypad: false, appCursor: false), .accel(TTKeyID.cmdLineUp))
        XCTAssertEqual(TTKeyMap.keyCode(macKeyCode: 48, shift: true, control: false, alt: false), 527)
        XCTAssertEqual(km.action(for: km.keyID(forCode: 527), appKeypad: false, appCursor: false), .binary("\u{1B}[Z"))
        // テンキー
        XCTAssertEqual(km.action(for: km.keyID(forCode: 82), appKeypad: false, appCursor: false), .binary("0"))
        XCTAssertEqual(km.action(for: km.keyID(forCode: 82), appKeypad: true, appCursor: false), .binary("\u{1B}Op"))
        XCTAssertEqual(km.action(for: km.keyID(forCode: 284), appKeypad: false, appCursor: false), .text("\r"))
        XCTAssertEqual(km.keyID(forCode: 30), 0)   // A は割り当てなし
    }

    func testUserKeysAndDuplicates() {
        let ini = IniFile(text: """
        [VT editor keypad]
        Up=328
        Down=328
        [User keys]
        User1=1083,0,telnet myhost
        User2=1084,0,$0D$0A
        User3=1085,1,$0D
        User4=1086,2,test.ttl
        User5=1087,3,50110
        User6=off
        """)
        let km = TTKeyMap(ini: ini)
        XCTAssertEqual(km.warnings, ["Keycode 328 is used more than once"])
        XCTAssertEqual(km.keyID(forCode: 328), TTKeyID.down)   // 先の Up が無効になる
        XCTAssertEqual(km.action(for: km.keyID(forCode: 1083), appKeypad: false, appCursor: false), .binary("telnet myhost"))
        XCTAssertEqual(km.action(for: km.keyID(forCode: 1084), appKeypad: false, appCursor: false), .binary("\r\n"))
        XCTAssertEqual(km.action(for: km.keyID(forCode: 1085), appKeypad: false, appCursor: false), .text("\r"))
        XCTAssertEqual(km.action(for: km.keyID(forCode: 1086), appKeypad: false, appCursor: false), .macro("test.ttl"))
        XCTAssertEqual(km.action(for: km.keyID(forCode: 1087), appKeypad: false, appCursor: false), .command(50110))
    }

    func testHex2Str() {
        XCTAssertEqual(TTKeyMap.hex2Str("$20!\"#$24%"), " !\"#$%")
        XCTAssertEqual(TTKeyMap.hex2Str("abc"), "abc")
    }

    func testURL() {
        func urls(_ s: String) -> [String] {
            let u = Array(s.unicodeScalars)
            return TTURL.urlRanges(u).map { r in var v = String.UnicodeScalarView(); v.append(contentsOf: u[r]); return String(v) }
        }
        XCTAssertEqual(urls("see https://example.com/a?b=1#c) and"), ["https://example.com/a?b=1#c"])
        XCTAssertEqual(urls("ftp://x.y/z <http://a.b>"), ["ftp://x.y/z", "http://a.b"])
        XCTAssertEqual(urls("no url here"), [])
    }
}
