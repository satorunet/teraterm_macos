import XCTest
@testable import TeraCore

/// #1557 INI の引用符
final class IniQuoteTests: XCTestCase {
    func testDequoteOnRead() {
        let f = IniFile(text: """
        [Tera Term]
        A="  spaced  "
        B='single'
        C="mis'
        D=""
        E="in"side"
        F=  plain value
        G="
        """)
        XCTAssertEqual(f.string("Tera Term", "A"), "  spaced  ")
        XCTAssertEqual(f.string("Tera Term", "B"), "single")
        XCTAssertEqual(f.string("Tera Term", "C"), "\"mis'")
        XCTAssertEqual(f.string("Tera Term", "D"), "")
        XCTAssertEqual(f.string("Tera Term", "E"), "in\"side")
        XCTAssertEqual(f.string("Tera Term", "F"), "plain value")
        XCTAssertEqual(f.string("Tera Term", "G"), "\"")
    }

    func testQuoteRoundTrip() {
        for v in ["abc", " lead", "trail ", "\"q\"", "'s'", "", "a \"b\" c"] {
            let f = IniFile(text: "[S]\nK=" + IniFile.quoteIfNeeded(v) + "\n")
            XCTAssertEqual(f.string("S", "K"), v, v)
        }
        XCTAssertEqual(IniFile.quoteIfNeeded("abc"), "abc")
    }

}
